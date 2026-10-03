$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ecs-runtime-context.ps1")
$runtimeContext = Get-CloudTasksEcsRuntime
$ClusterName = [string]$runtimeContext.ClusterName
$ServiceName = [string]$runtimeContext.ServiceName
$TargetGroupName = "cloudtasks-tg"
$ContainerPort = 3000
$DockerNetwork = "cloudtasks-localstack-network"

$container = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}"
if ($container -ne "cloudtasks-localstack") {
    throw "LocalStack nao esta em execucao."
}

function Invoke-AwsLocalRaw {
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
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

function Invoke-AwsLocalJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $result = Invoke-AwsLocalRaw -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw "awslocal $($Arguments[0]) $($Arguments[1]) falhou (exit=$($result.ExitCode))."
    }
    if ([string]::IsNullOrWhiteSpace($result.Text)) {
        return $null
    }
    try { return ($result.Text | ConvertFrom-Json -ErrorAction Stop) } catch { throw "JSON de awslocal $($Arguments[0]) $($Arguments[1]) invalido." }
}

function Get-DockerTaskTarget {
    param([Parameter(Mandatory = $true)]$Task)

    $taskId = ([string]$Task.taskArn -split '/')[-1]
    $dockerRuntime = Get-CloudTasksTaskDockerRuntime -TaskId $taskId
    if ($dockerRuntime.ExitCode -ne 0 -or -not $dockerRuntime.ValidOutput -or @($dockerRuntime.Containers).Count -ne 1) {
        throw "Runtime Docker invalido para task $taskId (exit=$($dockerRuntime.ExitCode))."
    }
    $containerId = [string]$dockerRuntime.Containers[0].ContainerId

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $inspectRaw = & docker inspect $containerId 2>&1
        $inspectExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($inspectExit -ne 0) {
        throw "docker inspect falhou para a task $taskId."
    }

    try { $inspect = (($inspectRaw | ForEach-Object { $_.ToString() }) -join "`n") | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "JSON Docker invalido para task $taskId." }
    $containerInspect = @($inspect) | Select-Object -First 1
    $networkProperty = $containerInspect.NetworkSettings.Networks.PSObject.Properties |
        Where-Object { $_.Name -eq $DockerNetwork } |
        Select-Object -First 1
    if ($null -eq $networkProperty) {
        throw "Task $taskId nao esta conectada a rede Docker '$DockerNetwork'."
    }

    $ip = [string]$networkProperty.Value.IPAddress
    if ([string]::IsNullOrWhiteSpace($ip)) {
        throw "Nao foi possivel obter o IP Docker da task $taskId."
    }

    return [pscustomobject]@{
        TaskId = $taskId
        ContainerId = [string]$containerId
        Ip = $ip
        Port = $ContainerPort
    }
}

$targetGroups = Invoke-AwsLocalJson @("elbv2", "describe-target-groups")
$targetGroup = @($targetGroups.TargetGroups) | Where-Object { [string]$_.TargetGroupName -eq $TargetGroupName } | Select-Object -First 1
if ($null -eq $targetGroup) {
    throw "Target Group '$TargetGroupName' nao encontrado. Rode .\scripts\localstack\create-alb.ps1."
}
$targetGroupArn = [string]$targetGroup.TargetGroupArn

$taskList = Invoke-AwsLocalJson @("ecs", "list-tasks", "--cluster", $ClusterName, "--service-name", $ServiceName, "--desired-status", "RUNNING")
$taskArns = @($taskList.taskArns)
if ($taskArns.Count -ne 2) {
    throw "Foram encontradas $($taskArns.Count) tasks ECS RUNNING; esperado: 2."
}

$describeArguments = @("ecs", "describe-tasks", "--cluster", $ClusterName, "--tasks") + $taskArns
$taskDetails = Invoke-AwsLocalJson -Arguments $describeArguments
$tasks = @($taskDetails.tasks)
if ($tasks.Count -ne 2) {
    throw "DescribeTasks retornou $($tasks.Count) tasks; esperado: 2."
}

$currentTargets = @()
foreach ($task in $tasks) {
    $currentTargets += Get-DockerTaskTarget -Task $task
}
if (@($currentTargets | Select-Object -ExpandProperty Ip -Unique).Count -ne 2) {
    throw "As duas tasks nao possuem IPs Docker distintos na rede '$DockerNetwork'."
}

$registeredHealth = Invoke-AwsLocalJson @("elbv2", "describe-target-health", "--target-group-arn", $targetGroupArn)
$registeredTargets = @($registeredHealth.TargetHealthDescriptions | ForEach-Object { $_.Target })
if ($registeredTargets.Count -gt 0) {
    $deregisterArgs = @("elbv2", "deregister-targets", "--target-group-arn", $targetGroupArn, "--targets")
    foreach ($target in $registeredTargets) {
        $deregisterArgs += "Id=$([string]$target.Id),Port=$([int]$target.Port),AvailabilityZone=all"
    }
    $null = Invoke-AwsLocalJson -Arguments $deregisterArgs
}

$registerArgs = @("elbv2", "register-targets", "--target-group-arn", $targetGroupArn, "--targets")
foreach ($target in $currentTargets) {
    $registerArgs += "Id=$($target.Ip),Port=$($target.Port),AvailabilityZone=all"
}
$null = Invoke-AwsLocalJson -Arguments $registerArgs

Write-Host "Targets ECS sincronizados com '$TargetGroupName':" -ForegroundColor Green
foreach ($target in $currentTargets) {
    Write-Host "- task $($target.TaskId) -> $($target.Ip):$($target.Port)" -ForegroundColor Green
}
