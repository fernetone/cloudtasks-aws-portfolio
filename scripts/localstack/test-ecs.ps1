$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ecs-runtime-context.ps1")
$runtimeContext = Get-CloudTasksEcsRuntime
$ClusterName = [string]$runtimeContext.ClusterName
$ServiceName = [string]$runtimeContext.ServiceName
$DesiredCount = 2
$LogGroup = "/cloudtasks/ecs"

$container = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}"
if ($container -ne "cloudtasks-localstack") {
    throw "LocalStack nao esta em execucao."
}

function Invoke-AwsLocalJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = & docker exec cloudtasks-localstack awslocal @Arguments --output json 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    $text = (($raw | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if ($exitCode -ne 0) {
        throw "awslocal $($Arguments[0]) $($Arguments[1]) falhou (exit=$exitCode)."
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    try { return ($text | ConvertFrom-Json -ErrorAction Stop) } catch { throw "JSON de awslocal $($Arguments[0]) $($Arguments[1]) invalido." }
}

function Get-TaskEndpoint {
    param([Parameter(Mandatory = $true)]$Task)

    $taskArn = [string]$Task.taskArn
    $taskId = ($taskArn -split '/')[-1]
    $dockerRuntime = Get-CloudTasksTaskDockerRuntime -TaskId $taskId
    if ($dockerRuntime.ExitCode -ne 0 -or -not $dockerRuntime.ValidOutput -or @($dockerRuntime.Containers).Count -ne 1) {
        throw "Runtime Docker invalido para task $taskId (exit=$($dockerRuntime.ExitCode))."
    }
    $containerId = [string]$dockerRuntime.Containers[0].ContainerId

    $hostPort = 0
    $binding = @($Task.containers | ForEach-Object { @($_.networkBindings) }) |
        Where-Object { [int]$_.containerPort -eq 3000 } |
        Select-Object -First 1
    if ($null -ne $binding -and [int]$binding.hostPort -gt 0) {
        $hostPort = [int]$binding.hostPort
    }
    else {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $portRows = @(& docker port $containerId 3000/tcp 2>&1); $portExit = $LASTEXITCODE }
        finally { $ErrorActionPreference = $previous }
        if ($portExit -ne 0) { throw "docker port falhou para task $taskId (exit=$portExit)." }
        $portLine = $portRows | Select-Object -First 1
        if (-not ([string]$portLine -match ':(\d+)$')) {
            throw "Nao foi possivel descobrir a porta dinamica da task $taskId. Retorno: $portLine"
        }
        $hostPort = [int]$Matches[1]
    }

    return [pscustomobject]@{
        TaskId = $taskId
        ContainerId = [string]$containerId
        Port = $hostPort
        Url = "http://127.0.0.1:$hostPort"
    }
}

Write-Host "[1/5] Aguardando ECS service estabilizar em duas replicas..." -ForegroundColor Cyan
$service = $null
for ($attempt = 1; $attempt -le 60; $attempt++) {
    $serviceResult = Invoke-AwsLocalJson @("ecs", "describe-services", "--cluster", $ClusterName, "--services", $ServiceName)
    $service = $serviceResult.services | Select-Object -First 1
    if ($null -ne $service -and [int]$service.runningCount -eq $DesiredCount -and [int]$service.pendingCount -eq 0) {
        break
    }
    Start-Sleep -Seconds 5
}
if ($null -eq $service -or [int]$service.runningCount -ne $DesiredCount) {
    throw "ECS service nao estabilizou com $DesiredCount tasks RUNNING."
}

Write-Host "[2/5] Descobrindo portas dinamicas das duas tasks..." -ForegroundColor Cyan
$taskList = Invoke-AwsLocalJson @("ecs", "list-tasks", "--cluster", $ClusterName, "--service-name", $ServiceName, "--desired-status", "RUNNING")
$taskArns = @($taskList.taskArns)
if ($taskArns.Count -ne $DesiredCount) {
    throw "Foram encontradas $($taskArns.Count) tasks RUNNING; esperado: $DesiredCount."
}

$describeArguments = @("ecs", "describe-tasks", "--cluster", $ClusterName, "--tasks") + $taskArns
$taskDetails = Invoke-AwsLocalJson -Arguments $describeArguments
$tasks = @($taskDetails.tasks)
if ($tasks.Count -ne $DesiredCount) {
    throw "DescribeTasks retornou $($tasks.Count) tasks; esperado: $DesiredCount."
}

$endpoints = @()
foreach ($task in $tasks) {
    $endpoints += Get-TaskEndpoint -Task $task
}

if (@($endpoints | Select-Object -ExpandProperty Port -Unique).Count -ne $DesiredCount) {
    throw "As duas replicas nao receberam portas dinamicas distintas no host."
}

Write-Host "[3/5] Validando /health de cada replica e conexao com RDS..." -ForegroundColor Cyan
foreach ($endpoint in $endpoints) {
    $health = Invoke-RestMethod -Uri "$($endpoint.Url)/health" -Method Get -TimeoutSec 10
    if ([string]$health.status -ne "ok" -or [string]$health.database -ne "ok") {
        throw "Health check falhou na task $($endpoint.TaskId)."
    }
    Write-Host "  $($endpoint.TaskId) -> $($endpoint.Url) / database=ok" -ForegroundColor Green
}

Write-Host "[4/5] Provando estado compartilhado entre replicas..." -ForegroundColor Cyan
$testTitle = "ECS replica test $([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$body = [ordered]@{
    title = $testTitle
    dueDate = $null
    important = $false
} | ConvertTo-Json -Compress

$created = $null
try {
    $created = Invoke-RestMethod `
        -Uri "$($endpoints[0].Url)/api/tasks" `
        -Method Post `
        -ContentType "application/json" `
        -Body $body `
        -TimeoutSec 10

    if ([string]::IsNullOrWhiteSpace([string]$created.id)) {
        throw "Replica 1 respondeu ao POST, mas nao retornou id."
    }

    $replicaTwoTasks = Invoke-RestMethod -Uri "$($endpoints[1].Url)/api/tasks" -Method Get -TimeoutSec 10
    $found = @($replicaTwoTasks) | Where-Object { [string]$_.id -eq [string]$created.id } | Select-Object -First 1
    if ($null -eq $found) {
        throw "Tarefa criada pela replica 1 nao foi encontrada pela replica 2."
    }

    Write-Host "  POST na replica 1 -> GET na replica 2: OK (RDS compartilhado)" -ForegroundColor Green
}
finally {
    if ($null -ne $created -and -not [string]::IsNullOrWhiteSpace([string]$created.id)) {
        try {
            Invoke-RestMethod -Uri "$($endpoints[1].Url)/api/tasks/$($created.id)" -Method Delete -TimeoutSec 10 | Out-Null
        }
        catch {
            Write-Host "Aviso: nao foi possivel remover automaticamente a tarefa temporaria $($created.id)." -ForegroundColor Yellow
        }
    }
}

Write-Host "[5/5] Validando CloudWatch Logs do ECS..." -ForegroundColor Cyan
$events = @()
for ($attempt = 1; $attempt -le 12; $attempt++) {
    $logResult = Invoke-AwsLocalJson @("logs", "filter-log-events", "--log-group-name", $LogGroup, "--limit", "50")
    $events = @($logResult.events)
    if ($events.Count -gt 0) {
        break
    }
    Start-Sleep -Seconds 5
}
if ($events.Count -lt 1) {
    throw "Nenhum evento foi encontrado no CloudWatch Logs '$LogGroup'."
}

Write-Host ""
Write-Host "ECS CloudTasks validado ponta a ponta." -ForegroundColor Green
Write-Host "Replicas RUNNING:      $DesiredCount" -ForegroundColor Green
Write-Host "Health + RDS:          OK nas duas replicas" -ForegroundColor Green
Write-Host "Estado compartilhado:  OK via PostgreSQL" -ForegroundColor Green
Write-Host "CloudWatch Logs:       OK ($($events.Count) evento(s) consultado(s))" -ForegroundColor Green
Write-Host "Segredo do banco:      nao exibido" -ForegroundColor DarkGray
