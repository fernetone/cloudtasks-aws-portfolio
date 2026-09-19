param(
  [string]$Region = "us-east-1",
  [string]$RepositoryName = "cloudtasks",
  [string]$Tag = ""
)

$ErrorActionPreference = "Stop"

function Require-Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Comando '$Name' nao encontrado no PATH."
  }
}

Require-Command "aws"
Require-Command "docker"

if ([string]::IsNullOrWhiteSpace($Tag)) {
  $Tag = "manual-" + (Get-Date -Format "yyyyMMddHHmmss")
}

Write-Host "[1/5] Validando AWS e ECR..."
$identityJson = aws sts get-caller-identity --output json
if ($LASTEXITCODE -ne 0) {
  throw "Falha ao validar a sessao AWS."
}

$accountId = ($identityJson | ConvertFrom-Json).Account
$repoJson = aws ecr describe-repositories --repository-names $RepositoryName --region $Region --output json 2>$null
if ($LASTEXITCODE -ne 0) {
  throw "Repositorio ECR '$RepositoryName' nao encontrado em $Region. Execute primeiro .\scripts\aws\create-ecr.ps1."
}

$repositoryUri = (($repoJson | ConvertFrom-Json).repositories[0]).repositoryUri
$registryUri = "$accountId.dkr.ecr.$Region.amazonaws.com"
$imageUri = "$repositoryUri`:$Tag"

Write-Host "[2/5] Autenticando Docker no Amazon ECR..."
aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin $registryUri
if ($LASTEXITCODE -ne 0) {
  throw "Falha ao autenticar o Docker no Amazon ECR."
}

Write-Host "[3/5] Construindo imagem CloudTasks..."
docker build --tag "cloudtasks:$Tag" .
if ($LASTEXITCODE -ne 0) {
  throw "Falha no docker build."
}

Write-Host "[4/5] Marcando e publicando imagem..."
docker tag "cloudtasks:$Tag" $imageUri
if ($LASTEXITCODE -ne 0) {
  throw "Falha ao criar a tag ECR."
}

docker push $imageUri
if ($LASTEXITCODE -ne 0) {
  throw "Falha ao enviar a imagem para o Amazon ECR."
}

Write-Host "[5/5] Confirmando imagem no ECR..."
aws ecr describe-images `
  --repository-name $RepositoryName `
  --image-ids imageTag=$Tag `
  --region $Region `
  --output table

if ($LASTEXITCODE -ne 0) {
  throw "A imagem foi enviada, mas a confirmacao no ECR falhou."
}

Write-Host ""
Write-Host "Primeira imagem CloudTasks publicada com sucesso."
Write-Host "Image URI: $imageUri"
Write-Host "Guarde esta URI: ela sera usada na proxima etapa com Amazon ECS."
