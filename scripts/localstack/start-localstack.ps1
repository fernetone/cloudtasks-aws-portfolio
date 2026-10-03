$ErrorActionPreference = "Stop"

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $projectRoot
$tokenFile = Join-Path $projectRoot ".env.localstack"
$imageName = "localstack/localstack-pro:latest"

if ([string]::IsNullOrWhiteSpace([string]$env:USERPROFILE)) {
    throw "USERPROFILE nao esta disponivel; nao foi possivel definir o bind mount de runtime do LocalStack."
}

$runtimeRoot = Join-Path $env:USERPROFILE ".cloudtasks\localstack-runtime"
$runtimeSession = "session-$(Get-Date -Format 'yyyyMMddHHmmssfff')"
$hostVolumeDir = Join-Path $runtimeRoot $runtimeSession
$runtimePointerFile = Join-Path $env:USERPROFILE ".cloudtasks\localstack-runtime-current.txt"
$hostVolumeDirDocker = $hostVolumeDir.Replace('\', '/')
$env:LOCALSTACK_VOLUME_DIR = $hostVolumeDirDocker

function Save-LocalStackToken {
    Write-Host "Token LocalStack ainda nao configurado neste projeto." -ForegroundColor Yellow
    Write-Host "Cole o Personal Auth Token mostrado em app.localstack.cloud." -ForegroundColor Yellow
    Write-Host "Ele sera salvo SOMENTE em .env.localstack, arquivo ignorado pelo Git." -ForegroundColor DarkGray

    $secureToken = Read-Host "LOCALSTACK_AUTH_TOKEN" -AsSecureString
    $tokenPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    try {
        $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPtr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPtr)
    }

    if ([string]::IsNullOrWhiteSpace($plainToken)) {
        throw "O Personal Auth Token do LocalStack e obrigatorio."
    }

    "LOCALSTACK_AUTH_TOKEN=$plainToken" | Set-Content -Path $tokenFile -Encoding utf8
    Write-Host "Token salvo localmente em .env.localstack." -ForegroundColor Green
}

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
        throw "Nao foi possivel inspecionar o container LocalStack (exit=$exitCode)."
    }

    $jsonText = (($raw | ForEach-Object { $_.ToString() }) -join "`n")
    try { $items = @($jsonText | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw 'JSON Docker LocalStack invalido.' }
    if ($items.Count -lt 1 -or $null -eq $items[0]) {
        throw "docker inspect nao retornou metadados do container LocalStack."
    }

    return $items[0]
}

function Get-ConfiguredEnvValue {
    param(
        [Parameter(Mandatory = $true)]$ContainerInfo,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($entryObject in @($ContainerInfo.Config.Env)) {
        $entry = [string]$entryObject
        foreach ($name in $Names) {
            $prefix = "$name="
            if ($entry.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
                return $entry.Substring($prefix.Length)
            }
        }
    }

    return $null
}

Write-Host "[1/6] Verificando Docker Desktop..." -ForegroundColor Cyan
docker version --format '{{.Server.Version}}' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Docker Desktop nao esta disponivel. Abra o Docker Desktop e tente novamente."
}

if (-not (Test-Path $tokenFile)) {
    Write-Host "[2/6] Configurando token LocalStack pela primeira vez..." -ForegroundColor Cyan
    Save-LocalStackToken
}
else {
    Write-Host "[2/6] Token LocalStack local detectado." -ForegroundColor Cyan
}

$tokenLine = Get-Content -Path $tokenFile | Where-Object { $_ -match '^LOCALSTACK_AUTH_TOKEN=' } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($tokenLine)) {
    throw "Arquivo .env.localstack invalido. Apague-o e execute novamente para configurar o token."
}

$env:LOCALSTACK_AUTH_TOKEN = $tokenLine.Substring('LOCALSTACK_AUTH_TOKEN='.Length)
if ([string]::IsNullOrWhiteSpace($env:LOCALSTACK_AUTH_TOKEN)) {
    throw "LOCALSTACK_AUTH_TOKEN vazio. Apague .env.localstack e execute novamente."
}

Write-Host "[3/6] Garantindo imagem do LocalStack sem atualizar automaticamente..." -ForegroundColor Cyan
$previousPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    $imageInspectRaw = @(& docker image inspect $imageName 2>$null)
    $imageInspectExit = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousPreference
}

$imageExists = ($imageInspectExit -eq 0 -and @($imageInspectRaw).Count -gt 0)
if (-not $imageExists) {
    Write-Host "Imagem ainda nao existe localmente; baixando uma vez..." -ForegroundColor Yellow
    docker pull $imageName
    if ($LASTEXITCODE -ne 0) {
        throw "Nao foi possivel baixar a imagem do LocalStack."
    }
}
else {
    Write-Host "Imagem local existente reutilizada. Nenhuma atualizacao automatica foi feita." -ForegroundColor DarkGray
}

Write-Host "[4/6] Preparando runtime LocalStack limpo e bind mount compativel com CodeBuild..." -ForegroundColor Cyan
if (-not (Test-Path $runtimeRoot)) {
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
}
if (-not (Test-Path $hostVolumeDir)) {
    New-Item -ItemType Directory -Path $hostVolumeDir -Force | Out-Null
}

# Cada sessao usa um diretorio novo. Isso evita restaurar snapshots com URLs/ports
# internos pertencentes a runtimes anteriores do LocalStack (ECR/RDS/ECS/ELB).
$hostVolumeDir | Set-Content -Path $runtimePointerFile -Encoding ascii
Write-Host "Runtime efemero: $hostVolumeDir" -ForegroundColor DarkGray
Write-Host "Estado AWS local anterior: nao sera restaurado; a infraestrutura sera reconstruida pelos scripts idempotentes." -ForegroundColor DarkGray

Write-Host "[5/6] Iniciando LocalStack..." -ForegroundColor Cyan
docker compose --env-file $tokenFile -f docker-compose.localstack.yml up -d localstack
if ($LASTEXITCODE -ne 0) {
    throw "Nao foi possivel iniciar o LocalStack."
}

$ready = $false
for ($attempt = 1; $attempt -le 60; $attempt++) {
    try {
        $health = Invoke-RestMethod -Uri "http://localhost:4566/_localstack/health" -TimeoutSec 3
        if ($null -ne $health) {
            $ready = $true
            break
        }
    }
    catch {
        Start-Sleep -Seconds 2
    }
}

if (-not $ready) {
    Write-Host "Consulte os logs localmente; eles podem conter dados sensiveis e nao sao exibidos automaticamente." -ForegroundColor Yellow
    throw "LocalStack nao ficou pronto dentro do tempo esperado."
}

Write-Host "[6/6] Validando API, bind mount e runtime deterministico..." -ForegroundColor Cyan
docker exec cloudtasks-localstack awslocal sts get-caller-identity
if ($LASTEXITCODE -ne 0) {
    throw "LocalStack iniciou, mas a API AWS emulada nao respondeu corretamente."
}

$containerInfo = Get-ContainerInspection
$persistenceEnabled = Get-ConfiguredEnvValue -ContainerInfo $containerInfo -Names @("PERSISTENCE", "LOCALSTACK_PERSISTENCE")
$mainDockerNetwork = Get-ConfiguredEnvValue -ContainerInfo $containerInfo -Names @("MAIN_DOCKER_NETWORK")
$codeBuildDockerFlags = Get-ConfiguredEnvValue -ContainerInfo $containerInfo -Names @("CODEBUILD_DOCKER_FLAGS")
$codeBuildRemoveContainers = Get-ConfiguredEnvValue -ContainerInfo $containerInfo -Names @("CODEBUILD_REMOVE_CONTAINERS")
$rdsPgCustomVersions = Get-ConfiguredEnvValue -ContainerInfo $containerInfo -Names @("RDS_PG_CUSTOM_VERSIONS")
$ecsRemoveContainers = Get-ConfiguredEnvValue -ContainerInfo $containerInfo -Names @("ECS_REMOVE_CONTAINERS")
$ecsReconcileInterval = Get-ConfiguredEnvValue -ContainerInfo $containerInfo -Names @("ECS_SERVICE_RECONCILE_INTERVAL")

if ($persistenceEnabled -ne "0") {
    throw "O laboratorio deterministico exige PERSISTENCE=0 para nao restaurar estado runtime-bound obsoleto. Recebido: PERSISTENCE=$persistenceEnabled"
}
if ($mainDockerNetwork -ne "cloudtasks-localstack-network") {
    throw "Rede Docker principal do LocalStack inesperada: $mainDockerNetwork"
}
if ([string]::IsNullOrWhiteSpace([string]$codeBuildDockerFlags) -or
    $codeBuildDockerFlags -notlike "*cloudtasks-localstack-network*" -or
    $codeBuildDockerFlags -notlike "*/var/run/docker.sock:/var/run/docker.sock*") {
    throw "CODEBUILD_DOCKER_FLAGS nao contem rede + mount do docker.sock. Recebido: $codeBuildDockerFlags"
}
if ($codeBuildRemoveContainers -ne "0") {
    throw "CODEBUILD_REMOVE_CONTAINERS deve ser 0 durante a validacao CI/CD para preservar logs de builds com falha."
}
if ($rdsPgCustomVersions -ne "0") {
    throw "RDS_PG_CUSTOM_VERSIONS deve ser 0 no laboratorio para evitar instalacao dinamica de PostgreSQL dentro do LocalStack. Recebido: '$rdsPgCustomVersions'."
}
if ($ecsRemoveContainers -ne "0") {
    throw "ECS_REMOVE_CONTAINERS deve ser 0 durante a homologacao para preservar containers de tasks com falha para diagnostico."
}
if ($ecsReconcileInterval -ne "3") {
    throw "ECS_SERVICE_RECONCILE_INTERVAL deve ser 3 durante a homologacao. Recebido: '$ecsReconcileInterval'."
}

$mount = @($containerInfo.Mounts | Where-Object { $_.Destination -eq "/var/lib/localstack" }) | Select-Object -First 1
if ($null -eq $mount) {
    throw "O container LocalStack nao possui mount em /var/lib/localstack."
}
if ([string]$mount.Type -ne "bind") {
    throw "O mount /var/lib/localstack precisa ser do tipo bind para o CodeBuild. Recebido: '$($mount.Type)'."
}
if ([string]::IsNullOrWhiteSpace([string]$mount.Source)) {
    throw "O bind mount /var/lib/localstack nao possui Source de host detectavel."
}

$dockerNetworks = @($containerInfo.NetworkSettings.Networks.PSObject.Properties | ForEach-Object { $_.Name })
if ($dockerNetworks -notcontains "cloudtasks-localstack-network") {
    throw "Container LocalStack nao esta conectado a rede Docker fixa 'cloudtasks-localstack-network'."
}

Write-Host ""
Write-Host "LocalStack ativo e validado." -ForegroundColor Green
Write-Host "Gateway AWS local: http://localhost:4566" -ForegroundColor Green
Write-Host "Regiao padrao: us-east-1" -ForegroundColor Green
Write-Host "Estado AWS local: efemero/deterministico (PERSISTENCE=0); recursos sao reconstruidos por script" -ForegroundColor Green
Write-Host "Mount /var/lib/localstack: bind de runtime novo por sessao (requisito CodeBuild atendido)" -ForegroundColor Green
Write-Host "Atualizacao automatica da imagem: desativada" -ForegroundColor Green
Write-Host "Rede Docker ECS: cloudtasks-localstack-network" -ForegroundColor Green
Write-Host "ECS local: modo Docker-backed padrao; containers com falha preservados para diagnostico" -ForegroundColor Green
Write-Host "CodeBuild Docker: rede fixa + docker.sock montado; containers de build preservados para diagnostico" -ForegroundColor Green
Write-Host "RDS PostgreSQL local: custom versions desativadas; runtime padrao do LocalStack para evitar provisioning por apt" -ForegroundColor Green
Write-Host "Token salvo apenas localmente em .env.localstack e ignorado pelo Git." -ForegroundColor DarkGray
