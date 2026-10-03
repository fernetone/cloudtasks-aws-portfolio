$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace([string]$env:USERPROFILE)) {
    throw "USERPROFILE nao esta disponivel; nao foi possivel resolver o runtime do LocalStack."
}
$runtimePointerFile = Join-Path $env:USERPROFILE ".cloudtasks\localstack-runtime-current.txt"

function Get-ContainerInspection {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = & docker inspect cloudtasks-localstack 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        throw "Falha ao inspecionar o container LocalStack (exit=$exitCode)."
    }
    try { $items = @(($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw 'JSON Docker LocalStack invalido.' }
    if ($items.Count -lt 1 -or $null -eq $items[0]) { throw "docker inspect nao retornou metadados." }
    return $items[0]
}

function Get-ConfiguredEnvValue {
    param([Parameter(Mandatory = $true)]$ContainerInfo, [Parameter(Mandatory = $true)][string]$Name)
    $prefix = "$Name="
    foreach ($entryObject in @($ContainerInfo.Config.Env)) {
        $entry = [string]$entryObject
        if ($entry.StartsWith($prefix, [System.StringComparison]::Ordinal)) { return $entry.Substring($prefix.Length) }
    }
    return $null
}

Write-Host "CloudTasks LocalStack deterministic runtime status" -ForegroundColor Cyan
$running = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}"
if ($running -ne "cloudtasks-localstack") {
    Write-Host "Container: parado" -ForegroundColor Yellow
    exit 0
}

$containerInfo = Get-ContainerInspection
$persistenceEnabled = Get-ConfiguredEnvValue -ContainerInfo $containerInfo -Name "PERSISTENCE"
$rdsPgCustomVersions = Get-ConfiguredEnvValue -ContainerInfo $containerInfo -Name "RDS_PG_CUSTOM_VERSIONS"
$ecsRemoveContainers = Get-ConfiguredEnvValue -ContainerInfo $containerInfo -Name "ECS_REMOVE_CONTAINERS"
$ecsReconcileInterval = Get-ConfiguredEnvValue -ContainerInfo $containerInfo -Name "ECS_SERVICE_RECONCILE_INTERVAL"

Write-Host "PERSISTENCE:             $persistenceEnabled"
Write-Host "RDS_PG_CUSTOM_VERSIONS:  $rdsPgCustomVersions"
Write-Host "ECS_REMOVE_CONTAINERS:    $ecsRemoveContainers"
Write-Host "ECS_RECONCILE_INTERVAL:   $ecsReconcileInterval"

if ($persistenceEnabled -ne "0") {
    Write-Host "Modo deterministico: INESPERADO (esperado PERSISTENCE=0)" -ForegroundColor Red
    exit 1
}
Write-Host "Modo deterministico: OK (snapshots AWS nao sao restaurados entre sessoes)" -ForegroundColor Green

$mount = @($containerInfo.Mounts | Where-Object { $_.Destination -eq "/var/lib/localstack" }) | Select-Object -First 1
if ($null -eq $mount -or [string]$mount.Type -ne "bind") {
    Write-Host "Mount /var/lib/localstack: INESPERADO (CodeBuild exige bind)" -ForegroundColor Red
    exit 1
}
Write-Host "Mount /var/lib/localstack: OK (bind)" -ForegroundColor Green
Write-Host "Runtime host: $($mount.Source)" -ForegroundColor DarkGray

if (Test-Path $runtimePointerFile) {
    $pointer = Get-Content -Path $runtimePointerFile | Select-Object -First 1
    Write-Host "Runtime pointer: $pointer" -ForegroundColor DarkGray
}

if ($rdsPgCustomVersions -ne "0") { throw "RDS_PG_CUSTOM_VERSIONS precisa ser 0." }
if ($ecsRemoveContainers -ne "0" -or $ecsReconcileInterval -ne "3") { throw "Configuracao ECS de diagnostico inesperada." }

$networkNames = @($containerInfo.NetworkSettings.Networks.PSObject.Properties | ForEach-Object { $_.Name })
if ($networkNames -notcontains "cloudtasks-localstack-network") {
    throw "Rede Docker cloudtasks-localstack-network ausente."
}
Write-Host "Rede Docker ECS/CodeBuild: OK" -ForegroundColor Green
