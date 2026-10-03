$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace([string]$env:USERPROFILE)) {
    throw "USERPROFILE nao esta disponivel; nao foi possivel resolver o runtime ECS CloudTasks."
}

$script:CloudTasksRuntimeRoot = Join-Path $env:USERPROFILE ".cloudtasks"
$script:CloudTasksEcsRuntimeFile = Join-Path $script:CloudTasksRuntimeRoot "ecs-runtime.json"
$script:CloudTasksDefaultCluster = "cloudtasks-cluster"
$script:CloudTasksDefaultService = "cloudtasks-service"

function Test-CloudTasksRuntimeName {
    param([Parameter(Mandatory = $true)][string]$ClusterName)
    return ($ClusterName -match '^cloudtasks-cluster(?:-r[0-9]{17})?$')
}

function Get-CloudTasksLocalStackContainerId {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = & docker inspect --format "{{.Id}}" cloudtasks-localstack 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($exitCode -ne 0) { return "" }
    return (($raw | Select-Object -First 1).ToString()).Trim()
}

function Get-CloudTasksTaskDockerRuntime {
    param([Parameter(Mandatory = $true)][string]$TaskId)

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Drain the native process before selecting rows or reading LASTEXITCODE.
        # Select-Object -First on a live pipeline can stop docker.exe in PS 5.1.
        $raw = @(& docker ps --filter "name=$TaskId" --filter 'status=running' --no-trunc --format '{{.ID}}|{{.Names}}|{{.Status}}' 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }

    $containers = @()
    $validOutput = ($exitCode -eq 0)
    if ($validOutput) {
        foreach ($row in $raw) {
            if ([string]::IsNullOrWhiteSpace([string]$row)) { continue }
            $parts = [string]$row -split '\|', 3
            if ($parts.Count -ne 3 -or $parts[0] -notmatch '^[a-f0-9]{12,64}$') {
                $validOutput = $false
                break
            }
            $containers += [pscustomobject]@{ ContainerId = $parts[0]; Name = $parts[1]; Status = $parts[2] }
        }
    }
    return [pscustomobject]@{ ExitCode = $exitCode; ValidOutput = $validOutput; Containers = @($containers) }
}

function Get-CloudTasksEcsRuntime {
    if (Test-Path $script:CloudTasksEcsRuntimeFile) {
        try {
            $state = Get-Content -Raw -Path $script:CloudTasksEcsRuntimeFile | ConvertFrom-Json -ErrorAction Stop
            $clusterName = [string]$state.clusterName
            $serviceName = [string]$state.serviceName
            if ((Test-CloudTasksRuntimeName -ClusterName $clusterName) -and $serviceName -eq $script:CloudTasksDefaultService) {
                return [pscustomobject]@{
                    ClusterName = $clusterName
                    ServiceName = $serviceName
                    Generation = [string]$state.generation
                    UpdatedAt = [string]$state.updatedAt
                    LocalStackContainerId = [string]$state.localStackContainerId
                    StateFile = $script:CloudTasksEcsRuntimeFile
                }
            }
        }
        catch {
            # Invalid local metadata is ignored and replaced with the safe default below.
        }
    }

    return [pscustomobject]@{
        ClusterName = $script:CloudTasksDefaultCluster
        ServiceName = $script:CloudTasksDefaultService
        Generation = "base"
        UpdatedAt = ""
        LocalStackContainerId = ""
        StateFile = $script:CloudTasksEcsRuntimeFile
    }
}

function Set-CloudTasksEcsRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$ClusterName,
        [string]$ServiceName = $script:CloudTasksDefaultService,
        [string]$Generation = "manual",
        [string]$LocalStackContainerId = ""
    )

    if (-not (Test-CloudTasksRuntimeName -ClusterName $ClusterName)) {
        throw "Nome de cluster ECS local invalido para CloudTasks: '$ClusterName'."
    }
    if ($ServiceName -ne $script:CloudTasksDefaultService) {
        throw "Nome de service ECS local inesperado: '$ServiceName'."
    }

    if ([string]::IsNullOrWhiteSpace($LocalStackContainerId)) {
        $LocalStackContainerId = Get-CloudTasksLocalStackContainerId
    }

    if (-not (Test-Path $script:CloudTasksRuntimeRoot)) {
        New-Item -ItemType Directory -Path $script:CloudTasksRuntimeRoot -Force | Out-Null
    }

    $payload = [ordered]@{
        clusterName = $ClusterName
        serviceName = $ServiceName
        generation = $Generation
        localStackContainerId = $LocalStackContainerId
        updatedAt = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Depth 4

    $temp = "$script:CloudTasksEcsRuntimeFile.tmp"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temp, $payload, $utf8NoBom)
    Move-Item -Path $temp -Destination $script:CloudTasksEcsRuntimeFile -Force

    return Get-CloudTasksEcsRuntime
}

function New-CloudTasksEcsRuntime {
    param([string]$LocalStackContainerId = "")

    if ([string]::IsNullOrWhiteSpace($LocalStackContainerId)) {
        $LocalStackContainerId = Get-CloudTasksLocalStackContainerId
    }
    if ([string]::IsNullOrWhiteSpace($LocalStackContainerId)) {
        throw "Nao foi possivel identificar a sessao atual do container LocalStack para criar um runtime ECS seguro."
    }

    $suffix = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmssfff")
    $clusterName = "cloudtasks-cluster-r$suffix"
    return Set-CloudTasksEcsRuntime -ClusterName $clusterName -ServiceName $script:CloudTasksDefaultService -Generation $suffix -LocalStackContainerId $LocalStackContainerId
}

function Ensure-CloudTasksEcsRuntimeForCurrentSession {
    $currentContainerId = Get-CloudTasksLocalStackContainerId
    if ([string]::IsNullOrWhiteSpace($currentContainerId)) {
        throw "Container LocalStack nao esta disponivel para inicializar a sessao ECS."
    }

    $runtime = Get-CloudTasksEcsRuntime
    if (-not [string]::IsNullOrWhiteSpace([string]$runtime.LocalStackContainerId) -and
        [string]$runtime.LocalStackContainerId -eq $currentContainerId -and
        [string]$runtime.ClusterName -ne $script:CloudTasksDefaultCluster) {
        return $runtime
    }

    # ECS tasks are Docker runtime objects outside LocalStack's persisted control plane.
    # A new LocalStack container/network session therefore gets a fresh ECS namespace.
    return New-CloudTasksEcsRuntime -LocalStackContainerId $currentContainerId
}
