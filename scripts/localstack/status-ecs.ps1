$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ecs-runtime-context.ps1")
$runtimeContext = Get-CloudTasksEcsRuntime
$ClusterName = [string]$runtimeContext.ClusterName
$ServiceName = [string]$runtimeContext.ServiceName
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

function Get-TaskDockerRuntime {
    param([Parameter(Mandatory = $true)]$Task)

    $taskArn = [string]$Task.taskArn
    $taskId = ($taskArn -split '/')[-1]
    $dockerRuntime = Get-CloudTasksTaskDockerRuntime -TaskId $taskId
    if ($dockerRuntime.ExitCode -ne 0 -or -not $dockerRuntime.ValidOutput) {
        throw "Consulta Docker da task $taskId falhou (exit=$($dockerRuntime.ExitCode))."
    }
    if (@($dockerRuntime.Containers).Count -gt 1) { throw "Mais de um container corresponde a task $taskId." }
    $row = @($dockerRuntime.Containers) | Select-Object -First 1

    $containerId = ""
    $name = ""
    $dockerStatus = ""
    if ($null -ne $row) {
        $containerId = [string]$row.ContainerId
        $name = [string]$row.Name
        $dockerStatus = [string]$row.Status
    }

    $hostPort = ""
    $binding = @($Task.containers | ForEach-Object { @($_.networkBindings) }) |
        Where-Object { [int]$_.containerPort -eq 3000 } |
        Select-Object -First 1
    if ($null -ne $binding -and [int]$binding.hostPort -gt 0) {
        $hostPort = [string]$binding.hostPort
    }
    elseif (-not [string]::IsNullOrWhiteSpace($containerId)) {
        $portRows = @(docker port $containerId 3000/tcp)
        $portExit = $LASTEXITCODE
        if ($portExit -ne 0) { throw "Consulta da porta Docker falhou (exit=$portExit)." }
        $portLine = $portRows | Select-Object -First 1
        if ([string]$portLine -match ':(\d+)$') {
            $hostPort = $Matches[1]
        }
    }

    return [pscustomobject]@{
        TaskId = $taskId
        ContainerId = $containerId
        Name = $name
        Status = $dockerStatus
        HostPort = $hostPort
    }
}

$clusterResult = Invoke-AwsLocalJson @("ecs", "describe-clusters", "--clusters", $ClusterName)
$cluster = $clusterResult.clusters | Select-Object -First 1
if ($null -eq $cluster) {
    throw "ECS cluster '$ClusterName' nao encontrado. Rode .\scripts\localstack\create-ecs.ps1."
}

$serviceResult = Invoke-AwsLocalJson @("ecs", "describe-services", "--cluster", $ClusterName, "--services", $ServiceName)
$service = $serviceResult.services | Select-Object -First 1
if ($null -eq $service) {
    throw "ECS service '$ServiceName' nao encontrado. Rode .\scripts\localstack\create-ecs.ps1."
}

$taskList = Invoke-AwsLocalJson @("ecs", "list-tasks", "--cluster", $ClusterName, "--service-name", $ServiceName)
$taskArns = @($taskList.taskArns)
$tasks = @()
if ($taskArns.Count -gt 0) {
    $arguments = @("ecs", "describe-tasks", "--cluster", $ClusterName, "--tasks") + $taskArns
    $tasksResult = Invoke-AwsLocalJson -Arguments $arguments
    $tasks = @($tasksResult.tasks)
}

$taskDefinition = Invoke-AwsLocalJson @("ecs", "describe-task-definition", "--task-definition", ([string]$service.taskDefinition))
$containerDefinition = @($taskDefinition.taskDefinition.containerDefinitions) | Select-Object -First 1

Write-Host "CloudTasks ECS status" -ForegroundColor Cyan
Write-Host "Cluster:            $($cluster.clusterName) / $($cluster.status)"
Write-Host "ContainerInstances: $($cluster.registeredContainerInstancesCount) (esperado 0 no Docker executor local)"
Write-Host "Service:            $($service.serviceName) / $($service.status)"
Write-Host "Launch type:        $($service.launchType)"
Write-Host "Desired:            $($service.desiredCount)"
Write-Host "Running:            $($service.runningCount)"
Write-Host "Pending:            $($service.pendingCount)"
Write-Host "Task definition:    $($service.taskDefinition)"
Write-Host "Image:              $($containerDefinition.image)"
Write-Host "Network mode:       $($taskDefinition.taskDefinition.networkMode)"
Write-Host "CloudWatch Logs:    $LogGroup"
Write-Host "Secret injection:   DATABASE_SECRET_JSON configurado; valor nao exibido"
Write-Host ""
Write-Host "Tasks/runtime Docker:" -ForegroundColor Cyan

foreach ($task in $tasks) {
    $runtime = Get-TaskDockerRuntime -Task $task
    $portText = if ([string]::IsNullOrWhiteSpace([string]$runtime.HostPort)) { "sem porta host detectada" } else { "http://127.0.0.1:$($runtime.HostPort)" }
    Write-Host "- $($runtime.TaskId) / ECS=$($task.lastStatus) / Docker=$($runtime.Status) / $portText"
}

$logGroups = Invoke-AwsLocalJson @("logs", "describe-log-groups", "--log-group-name-prefix", $LogGroup)
$logExists = $logGroups.logGroups | Where-Object { $_.logGroupName -eq $LogGroup } | Select-Object -First 1
if ($null -eq $logExists) {
    Write-Host "CloudWatch log group: AUSENTE" -ForegroundColor Yellow
}
else {
    $streams = Invoke-AwsLocalJson @("logs", "describe-log-streams", "--log-group-name", $LogGroup)
    Write-Host "CloudWatch log streams: $(@($streams.logStreams).Count)"
}
