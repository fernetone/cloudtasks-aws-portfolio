param(
  [string]$Region = "us-east-1",
  [string]$RepositoryName = "cloudtasks"
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

Write-Host "[1/4] Validando credenciais AWS..."
$identityJson = aws sts get-caller-identity --output json
if ($LASTEXITCODE -ne 0) {
  throw "Falha ao validar a sessao AWS. Configure a AWS CLI antes de continuar."
}

$identity = $identityJson | ConvertFrom-Json
$accountId = $identity.Account
Write-Host "Conta AWS: $accountId"
Write-Host "Regiao: $Region"

Write-Host "[2/4] Verificando repositorio ECR '$RepositoryName'..."
$repoJson = aws ecr describe-repositories --repository-names $RepositoryName --region $Region --output json 2>$null

if ($LASTEXITCODE -ne 0) {
  Write-Host "Repositorio nao existe. Criando..."
  $repoJson = aws ecr create-repository `
    --repository-name $RepositoryName `
    --region $Region `
    --image-tag-mutability IMMUTABLE `
    --image-scanning-configuration scanOnPush=true `
    --encryption-configuration encryptionType=AES256 `
    --tags Key=Project,Value=CloudTasks Key=Purpose,Value=Portfolio `
    --output json

  if ($LASTEXITCODE -ne 0) {
    throw "Falha ao criar o repositorio ECR."
  }
} else {
  Write-Host "Repositorio encontrado. Reforcando configuracoes..."
  aws ecr put-image-tag-mutability `
    --repository-name $RepositoryName `
    --image-tag-mutability IMMUTABLE `
    --region $Region | Out-Null

  if ($LASTEXITCODE -ne 0) {
    throw "Falha ao configurar tags imutaveis."
  }

  aws ecr put-image-scanning-configuration `
    --repository-name $RepositoryName `
    --image-scanning-configuration scanOnPush=true `
    --region $Region | Out-Null

  if ($LASTEXITCODE -ne 0) {
    throw "Falha ao habilitar scan on push."
  }
}

Write-Host "[3/4] Aplicando lifecycle policy..."
$lifecyclePath = Join-Path $PSScriptRoot "..\..\aws\ecr\lifecycle-policy.json"
$lifecyclePolicy = Get-Content $lifecyclePath -Raw

aws ecr put-lifecycle-policy `
  --repository-name $RepositoryName `
  --lifecycle-policy-text $lifecyclePolicy `
  --region $Region | Out-Null

if ($LASTEXITCODE -ne 0) {
  throw "Falha ao aplicar a lifecycle policy."
}

Write-Host "[4/4] Confirmando configuracao..."
$repoJson = aws ecr describe-repositories --repository-names $RepositoryName --region $Region --output json
if ($LASTEXITCODE -ne 0) {
  throw "Falha ao consultar o repositorio ECR apos a configuracao."
}

$repo = ($repoJson | ConvertFrom-Json).repositories[0]

Write-Host ""
Write-Host "Amazon ECR configurado com sucesso."
Write-Host "Repository URI: $($repo.repositoryUri)"
Write-Host "Tag mutability: $($repo.imageTagMutability)"
Write-Host "Scan on push: $($repo.imageScanningConfiguration.scanOnPush)"
Write-Host ""
Write-Host "Proximo comando:"
Write-Host ".\scripts\aws\push-ecr-image.ps1 -Region $Region -RepositoryName $RepositoryName"
