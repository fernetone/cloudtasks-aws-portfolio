$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ecs-runtime-context.ps1")
$runtimeContext = Get-CloudTasksEcsRuntime
$ClusterName = [string]$runtimeContext.ClusterName
$ServiceName = [string]$runtimeContext.ServiceName
$ContainerName = "cloudtasks-app"
$DesiredCount = 2

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $projectRoot
$statePath = Join-Path $projectRoot ".localstack\cicd\last-deploy.json"

$container = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}"
if ($container -ne "cloudtasks-localstack") { throw "LocalStack nao esta em execucao." }
if (-not (Test-Path $statePath)) { throw "Estado do ultimo deploy nao encontrado. Rode create-cicd.ps1 primeiro." }

function Invoke-AwsLocalJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = & docker exec cloudtasks-localstack awslocal @Arguments --output json 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    $text = (($raw | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if ($exitCode -ne 0) { throw "awslocal $($Arguments[0]) $($Arguments[1]) falhou (exit=$exitCode)." }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { return ($text | ConvertFrom-Json -ErrorAction Stop) } catch { throw "JSON de awslocal $($Arguments[0]) $($Arguments[1]) invalido." }
}

$state = Get-Content -Raw -Path $statePath | ConvertFrom-Json
if (-not [string]::IsNullOrWhiteSpace([string]$state.clusterName)) { $ClusterName = [string]$state.clusterName }
if (-not [string]::IsNullOrWhiteSpace([string]$state.serviceName)) { $ServiceName = [string]$state.serviceName }
$previousTaskDefinition = [string]$state.previousTaskDefinition
if ([string]::IsNullOrWhiteSpace($previousTaskDefinition)) { throw "Task definition anterior ausente nos metadados." }

Write-Host "[1/4] Solicitando rollback ECS para a revisao anterior..." -ForegroundColor Cyan
$null = Invoke-AwsLocalJson @(
    "ecs", "update-service",
    "--cluster", $ClusterName,
    "--service", $ServiceName,
    "--task-definition", $previousTaskDefinition,
    "--desired-count", ([string]$DesiredCount),
    "--force-new-deployment"
)

Write-Host "[2/4] Aguardando 2/2 replicas na revisao anterior..." -ForegroundColor Cyan
$service = $null
for ($attempt = 1; $attempt -le 120; $attempt++) {
    $result = Invoke-AwsLocalJson @("ecs", "describe-services", "--cluster", $ClusterName, "--services", $ServiceName)
    $service = @($result.services) | Select-Object -First 1
    if ($null -ne $service -and [string]$service.taskDefinition -eq $previousTaskDefinition -and [int]$service.runningCount -eq $DesiredCount -and [int]$service.pendingCount -eq 0) { break }
    if ($attempt % 6 -eq 0 -and $null -ne $service) {
        Write-Host "  task=$($service.taskDefinition) running=$($service.runningCount) pending=$($service.pendingCount)" -ForegroundColor DarkGray
    }
    Start-Sleep -Seconds 5
}
if ($null -eq $service -or [string]$service.taskDefinition -ne $previousTaskDefinition -or [int]$service.runningCount -ne $DesiredCount) {
    throw "Rollback ECS nao estabilizou na task definition anterior."
}

Write-Host "[3/4] Reconciliando targets ALB e HTTPS..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot "create-alb.ps1")
& (Join-Path $PSScriptRoot "create-https.ps1")

Write-Host "[4/4] Validando imagem restaurada..." -ForegroundColor Cyan
$taskDefinition = Invoke-AwsLocalJson @("ecs", "describe-task-definition", "--task-definition", $previousTaskDefinition)
$app = @($taskDefinition.taskDefinition.containerDefinitions) | Where-Object { [string]$_.name -eq $ContainerName } | Select-Object -First 1
$currentImage = [string]$app.image
if ($currentImage -ne [string]$state.previousImage) {
    throw "A task definition anterior foi restaurada, mas a imagem difere dos metadados do deploy."
}

$state | Add-Member -NotePropertyName rolledBackAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 8), $utf8NoBom)

Write-Host ""
Write-Host "Rollback CloudTasks concluido." -ForegroundColor Green
Write-Host "Task definition: $previousTaskDefinition" -ForegroundColor Green
Write-Host "Image:           $currentImage" -ForegroundColor Green
Write-Host "ECS:             2/2 replicas" -ForegroundColor Green
Write-Host "ALB/HTTPS:       reconciliados" -ForegroundColor Green
Write-Host ""
Write-Host "Observacao: LocalStack nao oferece rollback nativo/stage retry do CodePipeline; este script demonstra rollback operacional do ECS para a revisao anterior." -ForegroundColor Yellow
