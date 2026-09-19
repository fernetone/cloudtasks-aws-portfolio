$ErrorActionPreference = 'Stop'

Write-Host '[1/5] Verificando Docker...'
docker version | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop nao esta disponivel.' }

Write-Host '[2/5] Preparando Node.js 24 em container...'
$nodeVersion = docker run --rm node:24-alpine node --version
if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel iniciar o container Node.js 24.' }
Write-Host "Node.js detectado no container: $nodeVersion"

Write-Host '[3/5] Instalando dependencias, formatando e validando...'
$projectPath = (Get-Location).Path
$dockerProjectPath = $projectPath -replace '\\','/'

$installAndVerify = @'
set -e
if [ -f package-lock.json ]; then
  npm ci --no-audit --no-fund
else
  npm install --no-audit --no-fund
fi
npm run format
npm run format:check
npm run verify
'@

docker run --rm `
  -v "${dockerProjectPath}:/workspace" `
  -v cloudtasks_root_node_modules:/workspace/node_modules `
  -v cloudtasks_api_node_modules:/workspace/apps/api/node_modules `
  -v cloudtasks_web_node_modules:/workspace/apps/web/node_modules `
  -w /workspace `
  node:24-alpine sh -c $installAndVerify

if ($LASTEXITCODE -ne 0) {
  throw 'A validacao Node.js falhou. Consulte o erro exibido acima.'
}

Write-Host '[4/5] Verificando build Docker...'
docker build -t cloudtasks:local-check .
if ($LASTEXITCODE -ne 0) {
  throw 'O build Docker de validacao falhou.'
}

Write-Host '[5/5] Validacao concluida.'
Write-Host ''
Write-Host 'CloudTasks validado e pronto para GitHub.' -ForegroundColor Green
Write-Host 'O package-lock.json foi gerado/atualizado sem exigir Node.js instalado no Windows.'
Write-Host 'Dependencias de validacao ficaram isoladas em volumes Docker.'
Write-Host "Node.js utilizado: $nodeVersion (via Docker)"
