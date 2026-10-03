$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace([string]$env:USERPROFILE)) {
    throw "USERPROFILE nao esta disponivel; nao foi possivel resolver o runtime RDS CloudTasks."
}

$script:CloudTasksRuntimeRoot = Join-Path $env:USERPROFILE ".cloudtasks"
$script:CloudTasksRdsRuntimeFile = Join-Path $script:CloudTasksRuntimeRoot "rds-runtime.json"
$script:CloudTasksDefaultDbIdentifier = "cloudtasks-postgres"

function Test-CloudTasksRdsRuntimeName {
    param([Parameter(Mandatory = $true)][string]$DbIdentifier)
    return ($DbIdentifier -match '^cloudtasks-postgres(?:-r[0-9]{17})?$')
}

function Get-CloudTasksRdsRuntime {
    if (Test-Path $script:CloudTasksRdsRuntimeFile) {
        try {
            $state = Get-Content -Raw -Path $script:CloudTasksRdsRuntimeFile | ConvertFrom-Json -ErrorAction Stop
            $dbIdentifier = [string]$state.dbIdentifier
            if (Test-CloudTasksRdsRuntimeName -DbIdentifier $dbIdentifier) {
                return [pscustomobject]@{
                    DbIdentifier = $dbIdentifier
                    Generation = [string]$state.generation
                    UpdatedAt = [string]$state.updatedAt
                    StateFile = $script:CloudTasksRdsRuntimeFile
                }
            }
        }
        catch {
            # Invalid local metadata is ignored and replaced with the safe default below.
        }
    }

    return [pscustomobject]@{
        DbIdentifier = $script:CloudTasksDefaultDbIdentifier
        Generation = "base"
        UpdatedAt = ""
        StateFile = $script:CloudTasksRdsRuntimeFile
    }
}

function Set-CloudTasksRdsRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$DbIdentifier,
        [string]$Generation = "manual"
    )

    if (-not (Test-CloudTasksRdsRuntimeName -DbIdentifier $DbIdentifier)) {
        throw "Identificador RDS local invalido para CloudTasks: '$DbIdentifier'."
    }

    if (-not (Test-Path $script:CloudTasksRuntimeRoot)) {
        New-Item -ItemType Directory -Path $script:CloudTasksRuntimeRoot -Force | Out-Null
    }

    $payload = [ordered]@{
        dbIdentifier = $DbIdentifier
        generation = $Generation
        updatedAt = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Depth 4

    $temp = "$script:CloudTasksRdsRuntimeFile.tmp"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temp, $payload, $utf8NoBom)
    Move-Item -Path $temp -Destination $script:CloudTasksRdsRuntimeFile -Force

    return Get-CloudTasksRdsRuntime
}

function New-CloudTasksRdsRuntime {
    $suffix = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmssfff")
    $dbIdentifier = "cloudtasks-postgres-r$suffix"
    return Set-CloudTasksRdsRuntime -DbIdentifier $dbIdentifier -Generation $suffix
}
