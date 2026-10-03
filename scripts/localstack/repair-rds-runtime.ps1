param(
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "rds-runtime-context.ps1")
$currentRuntime = Get-CloudTasksRdsRuntime
$CurrentDbIdentifier = [string]$currentRuntime.DbIdentifier

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $projectRoot

$container = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}" | Select-Object -First 1
if ([string]$container -ne "cloudtasks-localstack") {
    throw "LocalStack nao esta em execucao. Rode .\scripts\localstack\start-localstack.ps1 primeiro."
}

if (-not $Quiet) {
    Write-Host "CloudTasks - recuperacao segura do runtime RDS LocalStack" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "O recurso RDS anterior sera preservado apenas como estado obsoleto; nenhum reset global sera executado." -ForegroundColor DarkGray
    Write-Host "Essa estrategia evita ficar preso em um DBInstanceStatus de provisionamento que nao converge." -ForegroundColor DarkGray
}

$newRuntime = New-CloudTasksRdsRuntime

if (-not $Quiet) {
    Write-Host ""
    Write-Host "Runtime RDS isolado com sucesso." -ForegroundColor Green
    Write-Host "RDS antigo preservado como estado obsoleto: $CurrentDbIdentifier" -ForegroundColor DarkGray
    Write-Host "Novo RDS ativo: $($newRuntime.DbIdentifier)" -ForegroundColor Green
    Write-Host "Metadado local: $($newRuntime.StateFile)" -ForegroundColor DarkGray
    Write-Host "VPC, ECR, S3, CodeBuild, CodePipeline e ECS nao foram resetados." -ForegroundColor Green
}
