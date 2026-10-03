param(
    [string]$RepositoryName = "cloudtasks",
    [string]$Tag = ""
)

$ErrorActionPreference = "Stop"

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $projectRoot

$container = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}"
if ($container -ne "cloudtasks-localstack") {
    throw "LocalStack nao esta em execucao. Rode .\scripts\localstack\start-localstack.ps1 primeiro."
}

# Consulta idempotente: nao usamos uma chamada que falha quando o repositorio
# ainda nao existe, pois Windows PowerShell 5.1 transforma stderr nativo em
# NativeCommandError quando ErrorActionPreference=Stop.
$repositoriesJson = docker exec cloudtasks-localstack awslocal ecr describe-repositories --output json
if ($LASTEXITCODE -ne 0) {
    throw "Falha ao consultar o ECR local."
}

$repositories = $repositoriesJson | ConvertFrom-Json
$repository = $repositories.repositories | Where-Object { $_.repositoryName -eq $RepositoryName } | Select-Object -First 1

if ($null -eq $repository) {
    Write-Host "Repositorio ECR ainda nao existe; criando agora..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot "create-ecr.ps1") -RepositoryName $RepositoryName

    $repositoriesJson = docker exec cloudtasks-localstack awslocal ecr describe-repositories --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Repositorio criado, mas nao foi possivel consulta-lo."
    }

    $repositories = $repositoriesJson | ConvertFrom-Json
    $repository = $repositories.repositories | Where-Object { $_.repositoryName -eq $RepositoryName } | Select-Object -First 1
}

if ($null -eq $repository) {
    throw "Nao foi possivel localizar o repositorio ECR '$RepositoryName'."
}

$repositoryUri = $repository.repositoryUri

if ([string]::IsNullOrWhiteSpace($Tag)) {
    $Tag = "local-$(Get-Date -Format 'yyyyMMddHHmmss')"
}

$localImage = "cloudtasks:$Tag"
$remoteImage = "${repositoryUri}:$Tag"

Write-Host "[1/4] Construindo imagem CloudTasks..." -ForegroundColor Cyan
docker build -t $localImage .
if ($LASTEXITCODE -ne 0) {
    throw "Falha no docker build."
}

Write-Host "[2/4] Criando tag para o ECR local..." -ForegroundColor Cyan
docker tag $localImage $remoteImage
if ($LASTEXITCODE -ne 0) {
    throw "Falha ao criar a tag ECR."
}

Write-Host "[3/4] Enviando imagem para o ECR emulado..." -ForegroundColor Cyan
docker push $remoteImage
if ($LASTEXITCODE -ne 0) {
    throw "Falha no docker push para o ECR local."
}

Write-Host "[4/4] Validando imagem no ECR..." -ForegroundColor Cyan
docker exec cloudtasks-localstack awslocal ecr describe-images `
    --repository-name $RepositoryName `
    --image-ids "imageTag=$Tag"

if ($LASTEXITCODE -ne 0) {
    throw "A imagem foi enviada, mas nao foi possivel confirma-la no ECR."
}

Write-Host ""
Write-Host "Primeira imagem CloudTasks publicada no ECR local." -ForegroundColor Green
Write-Host "Imagem: $remoteImage" -ForegroundColor Green
