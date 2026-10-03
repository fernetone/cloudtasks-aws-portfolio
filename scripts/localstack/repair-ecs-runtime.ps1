param(
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ecs-runtime-context.ps1")
$currentRuntime = Get-CloudTasksEcsRuntime
$CurrentClusterName = [string]$currentRuntime.ClusterName
$ServiceName = [string]$currentRuntime.ServiceName

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $projectRoot

$container = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}" | Select-Object -First 1
if ([string]$container -ne "cloudtasks-localstack") {
    throw "LocalStack nao esta em execucao. Rode .\scripts\localstack\start-localstack.ps1 primeiro."
}

if (-not $Quiet) {
    Write-Host "CloudTasks - recuperacao segura do runtime ECS LocalStack" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "O LocalStack atual nao inclui mais o executavel 'localstack' dentro da imagem." -ForegroundColor DarkGray
    Write-Host "Por isso a recuperacao nao tenta mais 'localstack state reset' dentro do container." -ForegroundColor DarkGray
}

# Remove only Docker task containers that belong to the stale CloudTasks ECS runtime.
$dockerContainers = @(docker ps -a --filter "name=ls-ecs-$CurrentClusterName" --format "{{.ID}}|{{.Names}}|{{.Status}}")
if (-not $Quiet) {
    Write-Host "Runtime obsoleto detectado:" -ForegroundColor Yellow
    Write-Host "- Cluster logico: $CurrentClusterName" -ForegroundColor DarkGray
    Write-Host "- Service:        $ServiceName" -ForegroundColor DarkGray
    Write-Host "- Containers:     $($dockerContainers.Count)" -ForegroundColor DarkGray
}

if ($dockerContainers.Count -gt 0) {
    if (-not $Quiet) { Write-Host "Removendo somente containers Docker do runtime ECS obsoleto..." -ForegroundColor Yellow }
    foreach ($row in $dockerContainers) {
        $id = ([string]$row -split '\|')[0]
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & docker rm -f $id 2>&1 | Out-Null
            $exitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previousPreference }
        if ($exitCode -ne 0) { throw "Nao foi possivel remover o container ECS antigo '$id'." }
    }
}

# Do NOT modify LocalStack's persisted service state directly. Current LocalStack images
# no longer ship the deprecated CLI inside the emulator container. Instead, isolate the
# stale control-plane references by moving CloudTasks to a fresh ECS cluster namespace.
$currentContainerId = Get-CloudTasksLocalStackContainerId
$newRuntime = New-CloudTasksEcsRuntime -LocalStackContainerId $currentContainerId

if (-not $Quiet) {
    Write-Host ""
    Write-Host "Runtime ECS isolado com sucesso." -ForegroundColor Green
    Write-Host "Cluster antigo preservado apenas como estado obsoleto: $CurrentClusterName" -ForegroundColor DarkGray
    Write-Host "Novo cluster ativo: $($newRuntime.ClusterName)" -ForegroundColor Green
    Write-Host "Metadado local: $($newRuntime.StateFile)" -ForegroundColor DarkGray
    Write-Host "RDS, Secrets, ECR, S3, CodeBuild, CodePipeline, VPC e demais servicos nao foram resetados." -ForegroundColor Green
    Write-Host "O create-ecs.ps1 agora recriara o service/tasks no novo namespace desta sessao Docker, sem reutilizar scheduler/task state restaurado." -ForegroundColor DarkGray
}
