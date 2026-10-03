param(
    [string]$ClusterName = "",
    [string]$ServiceName = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ecs-runtime-context.ps1")
$current = Get-CloudTasksEcsRuntime
if ([string]::IsNullOrWhiteSpace($ClusterName)) { $ClusterName = [string]$current.ClusterName }
if ([string]::IsNullOrWhiteSpace($ServiceName)) { $ServiceName = [string]$current.ServiceName }

function Invoke-AwsLocalText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = & docker exec cloudtasks-localstack awslocal @Arguments --output json 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = (($raw | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    }
}

Write-Host ""
Write-Host "CloudTasks - diagnostico ECS LocalStack" -ForegroundColor Cyan
Write-Host "Cluster: $ClusterName"
Write-Host "Service: $ServiceName"

$serviceResult = Invoke-AwsLocalText @("ecs", "describe-services", "--cluster", $ClusterName, "--services", $ServiceName)
if ($serviceResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($serviceResult.Text)) {
    try {
        $payload = $serviceResult.Text | ConvertFrom-Json
        $svc = @($payload.services) | Select-Object -First 1
        if ($null -ne $svc) {
            Write-Host "Service counts: desired=$($svc.desiredCount) running=$($svc.runningCount) pending=$($svc.pendingCount)"
            Write-Host "API launchType: $($svc.launchType)"
            Write-Host "Task definition: $($svc.taskDefinition)"
            if (@($svc.events).Count -gt 0) {
                Write-Host "Eventos registrados: $(@($svc.events).Count); mensagens brutas devem ser revisadas localmente." -ForegroundColor DarkGray
            }
        }
    }
    catch { Write-Host "Nao foi possivel interpretar describe-services." -ForegroundColor Yellow }
}
else {
    Write-Host "describe-services falhou (exit=$($serviceResult.ExitCode))." -ForegroundColor Yellow
}

$taskArns = @()
foreach ($desiredStatus in @("RUNNING", "PENDING", "STOPPED")) {
    $list = Invoke-AwsLocalText @("ecs", "list-tasks", "--cluster", $ClusterName, "--service-name", $ServiceName, "--desired-status", $desiredStatus)
    if ($list.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($list.Text)) {
        try {
            $obj = $list.Text | ConvertFrom-Json
            $taskArns += @($obj.taskArns)
        }
        catch { }
    }
}
$taskArns = @($taskArns | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

if ($taskArns.Count -gt 0) {
    Write-Host "Tasks conhecidas pelo ECS: $($taskArns.Count)" -ForegroundColor Yellow
    foreach ($taskArn in $taskArns) {
        $desc = Invoke-AwsLocalText @("ecs", "describe-tasks", "--cluster", $ClusterName, "--tasks", [string]$taskArn)
        if ($desc.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($desc.Text)) { continue }
        try {
            $task = @(($desc.Text | ConvertFrom-Json).tasks) | Select-Object -First 1
            if ($null -eq $task) { continue }
            $taskId = ([string]$task.taskArn -split '/')[-1]
            Write-Host "- $taskId desired=$($task.desiredStatus) last=$($task.lastStatus) stopCode=$($task.stopCode)" -ForegroundColor DarkGray
            if (-not [string]::IsNullOrWhiteSpace([string]$task.stoppedReason)) {
                Write-Host "  stoppedReason: disponivel na API para revisao local" -ForegroundColor DarkGray
            }
            foreach ($c in @($task.containers)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$c.reason)) {
                    Write-Host "  container reason: disponivel na API para revisao local" -ForegroundColor DarkGray
                }
            }
        }
        catch { }
    }
}
else {
    Write-Host "Tasks conhecidas pelo ECS: nenhuma" -ForegroundColor Yellow
}

Write-Host "Containers Docker ECS (inclusive parados):" -ForegroundColor Yellow
$dockerRows = @(docker ps -a --filter "name=ls-ecs-$ClusterName" --format "{{.ID}}|{{.Names}}|{{.Status}}|{{.Image}}")
if ($dockerRows.Count -eq 0) {
    Write-Host "- nenhum" -ForegroundColor DarkGray
}
else {
    foreach ($row in $dockerRows) {
        Write-Host "- $row" -ForegroundColor DarkGray
        $containerId = ([string]$row -split '\|')[0]
        if (-not [string]::IsNullOrWhiteSpace($containerId)) {
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $inspectRaw = & docker inspect $containerId 2>&1
                $inspectExit = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $previousPreference }
            if ($inspectExit -eq 0) {
                try {
                    $inspect = @(($inspectRaw -join "`n") | ConvertFrom-Json) | Select-Object -First 1
                    if ($null -ne $inspect) {
                        Write-Host "  Docker state=$($inspect.State.Status) exit=$($inspect.State.ExitCode)" -ForegroundColor DarkGray
                        Write-Host "  NetworkMode=$($inspect.HostConfig.NetworkMode)" -ForegroundColor DarkGray
                    }
                }
                catch { }
            }
        }
    }
}

$runtimeMetadata = Get-CloudTasksEcsRuntime
$currentLocalStackId = Get-CloudTasksLocalStackContainerId
Write-Host "Runtime metadata: cluster=$($runtimeMetadata.ClusterName) session=$($runtimeMetadata.LocalStackContainerId)" -ForegroundColor DarkGray
Write-Host "LocalStack atual: session=$currentLocalStackId" -ForegroundColor DarkGray

Write-Host ""
Write-Host "Logs brutos permanecem no Docker/CloudWatch e exigem revisao local antes de compartilhar. Este diagnostico exibe estado e identidade, sem despejar logs ou variaveis de ambiente." -ForegroundColor DarkGray
