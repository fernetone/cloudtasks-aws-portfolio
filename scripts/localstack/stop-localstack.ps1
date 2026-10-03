$ErrorActionPreference = "Stop"

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $projectRoot
$tokenFile = Join-Path $projectRoot ".env.localstack"

if ([string]::IsNullOrWhiteSpace([string]$env:USERPROFILE)) {
    throw "USERPROFILE nao esta disponivel; nao foi possivel resolver o runtime do LocalStack."
}

$runtimePointerFile = Join-Path $env:USERPROFILE ".cloudtasks\localstack-runtime-current.txt"
$hostVolumeDir = $null
if (Test-Path $runtimePointerFile) {
    $hostVolumeDir = (Get-Content -Path $runtimePointerFile -ErrorAction SilentlyContinue | Select-Object -First 1)
}

# Se estamos desligando uma versao anterior do laboratorio, derive o mount real
# do container em vez de depender do ponteiro novo.
$runningContainer = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}" | Select-Object -First 1
if ([string]$runningContainer -eq "cloudtasks-localstack") {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $inspectRaw = & docker inspect cloudtasks-localstack 2>&1
        $inspectExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($inspectExit -eq 0) {
        try {
            $info = @(($inspectRaw -join "`n") | ConvertFrom-Json -ErrorAction Stop) | Select-Object -First 1
            $mount = @($info.Mounts | Where-Object { $_.Destination -eq "/var/lib/localstack" }) | Select-Object -First 1
            if ($null -ne $mount -and -not [string]::IsNullOrWhiteSpace([string]$mount.Source)) {
                $hostVolumeDir = [string]$mount.Source
            }
        }
        catch { }
    }
}

if ([string]::IsNullOrWhiteSpace([string]$hostVolumeDir)) {
    $hostVolumeDir = Join-Path $env:USERPROFILE ".cloudtasks\localstack-runtime\shutdown-placeholder"
}
$env:LOCALSTACK_VOLUME_DIR = ([string]$hostVolumeDir).Replace('\', '/')

if (Test-Path $tokenFile) {
    docker compose --env-file $tokenFile -f docker-compose.localstack.yml down --remove-orphans
}
else {
    $env:LOCALSTACK_AUTH_TOKEN = "not-used-during-down"
    docker compose -f docker-compose.localstack.yml down --remove-orphans
}

if ($LASTEXITCODE -ne 0) {
    throw "Nao foi possivel desligar o LocalStack."
}

Write-Host "LocalStack desligado." -ForegroundColor Green
Write-Host "O estado AWS emulado desta sessao e descartavel por design; a proxima sessao sera reconstruida de forma deterministica." -ForegroundColor DarkGray
Write-Host "Codigo-fonte, Git, Docker image cache e token local nao sao apagados." -ForegroundColor DarkGray
