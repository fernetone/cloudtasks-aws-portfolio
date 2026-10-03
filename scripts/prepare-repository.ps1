$ErrorActionPreference = "Stop"

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $projectRoot

Write-Host "[1/5] Verificando Docker..." -ForegroundColor Cyan
docker version --format '{{.Server.Version}}' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Docker Desktop nao esta disponivel. Abra o Docker Desktop e tente novamente."
}

Write-Host "[2/5] Preparando Node.js 24 em container..." -ForegroundColor Cyan
$nodeVersion = docker run --rm node:24-alpine node --version
if ($LASTEXITCODE -ne 0 -or -not $nodeVersion.StartsWith("v24.")) {
    throw "Nao foi possivel executar Node.js 24 via Docker."
}
Write-Host "Node.js detectado no container: $nodeVersion" -ForegroundColor DarkGray

Write-Host "[3/5] Instalando dependencias e validando..." -ForegroundColor Cyan
# O codigo e o package-lock.json ficam no Windows, mas TODOS os node_modules ficam em volumes Docker.
# Isso evita symlinks/.bin Linux sendo gravados no NTFS e depois enviados como contexto de build.
if (-not (Test-Path (Join-Path $projectRoot "package-lock.json"))) { throw "package-lock.json e obrigatorio." }

docker run --rm `
    --mount "type=bind,source=$projectRoot,target=/workspace" `
    --mount "type=volume,source=cloudtasks_node_modules,target=/workspace/node_modules" `
    --mount "type=volume,source=cloudtasks_api_node_modules,target=/workspace/apps/api/node_modules" `
    --mount "type=volume,source=cloudtasks_web_node_modules,target=/workspace/apps/web/node_modules" `
    --workdir /workspace `
    node:24-alpine `
    sh -lc "npm ci --no-audit --no-fund && npm run verify"

if ($LASTEXITCODE -ne 0) {
    throw "A validacao Node.js falhou. Consulte o erro exibido acima."
}

Write-Host "[4/5] Verificando build Docker..." -ForegroundColor Cyan
docker build --tag cloudtasks:local-check .
if ($LASTEXITCODE -ne 0) {
    throw "O build Docker de validacao falhou."
}

Write-Host "[5/5] Validacao concluida." -ForegroundColor Cyan
Write-Host ""
Write-Host "Qualidade da aplicacao e Docker build aprovados. CI/CD requer validacao nativa separada." -ForegroundColor Green
Write-Host "O package-lock.json foi utilizado sem exigir Node.js instalado no Windows." -ForegroundColor Green
Write-Host "Formatacao: revisar npm run format:check antes de publicar." -ForegroundColor Yellow
Write-Host "Dependencias de validacao ficaram isoladas em volumes Docker." -ForegroundColor Green
Write-Host "Node.js utilizado: $nodeVersion (via Docker)" -ForegroundColor Green
