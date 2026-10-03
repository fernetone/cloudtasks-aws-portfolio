$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ecs-runtime-context.ps1")
$DesiredCount = 2

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $projectRoot

function Test-LocalStackRunning {
    $names = @(docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}")
    $exitCode = $LASTEXITCODE
    return ($exitCode -eq 0 -and ($names -contains 'cloudtasks-localstack'))
}


function Test-LocalStackRuntimeConfig {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = & docker inspect cloudtasks-localstack 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) { return $false }

    try {
        $items = @(($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop)
        if ($items.Count -lt 1) { return $false }
        $envEntries = @($items[0].Config.Env | ForEach-Object { [string]$_ })
        return (
            ($envEntries -contains "PERSISTENCE=0") -and
            ($envEntries -contains "RDS_PG_CUSTOM_VERSIONS=0") -and
            ($envEntries -contains "ECS_REMOVE_CONTAINERS=0") -and
            ($envEntries -contains "ECS_SERVICE_RECONCILE_INTERVAL=3")
        )
    }
    catch {
        return $false
    }
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
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        try { return ($text | ConvertFrom-Json -ErrorAction Stop) } catch { throw "JSON de awslocal $($Arguments[0]) $($Arguments[1]) invalido." }
    }
    catch {
        return $null
    }
}

function Test-EcsRuntimeReady {
    $current = Get-CloudTasksEcsRuntime
    $containerId = Get-CloudTasksLocalStackContainerId
    if ([string]::IsNullOrWhiteSpace($containerId) -or [string]$current.LocalStackContainerId -ne $containerId) { return $false }
    $currentClusterName = [string]$current.ClusterName
    $currentServiceName = [string]$current.ServiceName
    $clusterResult = Invoke-AwsLocalJson @("ecs", "describe-clusters", "--clusters", $currentClusterName)
    if ($null -eq $clusterResult) { return $false }

    $cluster = @($clusterResult.clusters) | Where-Object { [string]$_.clusterName -eq $currentClusterName -and [string]$_.status -eq "ACTIVE" } | Select-Object -First 1
    if ($null -eq $cluster) { return $false }

    $serviceResult = Invoke-AwsLocalJson @("ecs", "describe-services", "--cluster", $currentClusterName, "--services", $currentServiceName)
    if ($null -eq $serviceResult) { return $false }

    $service = @($serviceResult.services) | Where-Object { [string]$_.serviceName -eq $currentServiceName -and [string]$_.status -eq "ACTIVE" } | Select-Object -First 1
    if ($null -eq $service) { return $false }

    if ([int]$service.desiredCount -ne $DesiredCount -or [int]$service.runningCount -ne $DesiredCount -or [int]$service.pendingCount -ne 0) {
        return $false
    }

    $taskList = Invoke-AwsLocalJson @("ecs", "list-tasks", "--cluster", $currentClusterName, "--service-name", $currentServiceName, "--desired-status", "RUNNING")
    if ($null -eq $taskList) { return $false }

    $taskArns = @($taskList.taskArns)
    if ($taskArns.Count -ne $DesiredCount) { return $false }

    $dockerRuntimeCount = 0
    foreach ($taskArn in $taskArns) {
        $taskId = ([string]$taskArn -split '/')[-1]
        $dockerRuntime = Get-CloudTasksTaskDockerRuntime -TaskId $taskId
        if ($dockerRuntime.ExitCode -eq 0 -and $dockerRuntime.ValidOutput -and @($dockerRuntime.Containers).Count -eq 1) {
            $dockerRuntimeCount++
        }
    }

    return ($dockerRuntimeCount -eq $DesiredCount)
}

Write-Host "CloudTasks - bootstrap/reconciliacao deterministica do ambiente LocalStack" -ForegroundColor Cyan
Write-Host ""

Write-Host "[1/5] Garantindo LocalStack..." -ForegroundColor Cyan
if (-not (Test-LocalStackRunning)) {
    & (Join-Path $PSScriptRoot "start-localstack.ps1")
}
elseif (-not (Test-LocalStackRuntimeConfig)) {
    Write-Host "LocalStack esta ativo em modo legado/persistente. Reiniciando uma vez para aplicar o runtime efemero deterministico..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot "stop-localstack.ps1")
    & (Join-Path $PSScriptRoot "start-localstack.ps1")
}
else {
    Write-Host "LocalStack ja esta em execucao com a configuracao atual." -ForegroundColor DarkGray
}

$runtimeBefore = Get-CloudTasksEcsRuntime
$runtimeAfter = Ensure-CloudTasksEcsRuntimeForCurrentSession
if ([string]$runtimeBefore.ClusterName -ne [string]$runtimeAfter.ClusterName) {
    Write-Host "Sessao LocalStack/Docker nova detectada." -ForegroundColor Yellow
    Write-Host "ECS local sera recriado em namespace de sessao: $($runtimeAfter.ClusterName)" -ForegroundColor Yellow

    $oldClusterName = [string]$runtimeBefore.ClusterName
    if (-not [string]::IsNullOrWhiteSpace($oldClusterName)) {
        $oldContainers = @(docker ps -a --filter "name=ls-ecs-$oldClusterName" --format "{{.ID}}")
        foreach ($oldId in $oldContainers) {
            if ([string]::IsNullOrWhiteSpace([string]$oldId)) { continue }
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try { & docker rm -f ([string]$oldId) 2>$null | Out-Null }
            finally { $ErrorActionPreference = $previousPreference }
        }
    }
}

Write-Host "[2/5] Reconciliando runtime ECS..." -ForegroundColor Cyan
if (Test-EcsRuntimeReady) {
    Write-Host "ECS ja esta estavel em 2/2 replicas com runtime Docker ativo." -ForegroundColor Green
}
else {
    Write-Host "ECS ausente ou incompleto neste runtime. Recriando/reconciliando de forma idempotente..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot "create-ecs.ps1")
}

if (-not (Test-EcsRuntimeReady)) {
    throw "ECS nao ficou estavel em 2/2 replicas apos a reconciliacao. Rode .\scripts\localstack\status-ecs.ps1 para diagnostico."
}

Write-Host "[3/5] Reconciliando ALB e Target Group..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot "create-alb.ps1")

Write-Host "[4/5] Reconciliando ACM e listener HTTPS..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot "create-https.ps1")

Write-Host "[5/5] Validando estado final..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot "status-ecs.ps1")
Write-Host ""
& (Join-Path $PSScriptRoot "status-alb.ps1")
Write-Host ""
& (Join-Path $PSScriptRoot "status-https.ps1")

Write-Host ""
Write-Host "Ambiente CloudTasks retomado e reconciliado." -ForegroundColor Green
Write-Host "LocalStack: ativo" -ForegroundColor Green
$finalRuntime = Get-CloudTasksEcsRuntime
Write-Host "ECS:        2/2 replicas / cluster=$($finalRuntime.ClusterName)" -ForegroundColor Green
Write-Host "ALB/TG:     reconciliados" -ForegroundColor Green
Write-Host "HTTPS/ACM:  reconciliados" -ForegroundColor Green
Write-Host ""
Write-Host "Para a prova ponta a ponta:" -ForegroundColor DarkGray
Write-Host ".\scripts\localstack\test-ecs.ps1" -ForegroundColor DarkGray
Write-Host ".\scripts\localstack\test-alb.ps1" -ForegroundColor DarkGray
Write-Host ".\scripts\localstack\test-https.ps1" -ForegroundColor DarkGray
