$ErrorActionPreference = "Stop"

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $projectRoot
$tokenFile = Join-Path $projectRoot ".env.localstack"
$imageName = "localstack/localstack-pro:latest"

if (-not (Test-Path $tokenFile)) {
    throw "Arquivo .env.localstack nao encontrado. Rode .\scripts\localstack\start-localstack.ps1 primeiro."
}

$running = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}"
if ($running -eq "cloudtasks-localstack") {
    Write-Host "Parando runtime efemero atual antes da atualizacao..." -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot "stop-localstack.ps1")
}

Write-Host "Atualizando a imagem LocalStack de forma explicita..." -ForegroundColor Cyan
docker pull $imageName
if ($LASTEXITCODE -ne 0) { throw "Falha ao atualizar a imagem LocalStack." }

Write-Host "Atualizacao concluida. Rode .\scripts\localstack\start-localstack.ps1." -ForegroundColor Green
Write-Host "A proxima inicializacao criara um runtime LocalStack limpo, sem restaurar snapshots antigos." -ForegroundColor Yellow
