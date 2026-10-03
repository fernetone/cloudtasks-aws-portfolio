$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "rds-runtime-context.ps1")
$rdsRuntimeContext = Get-CloudTasksRdsRuntime
$DbIdentifier = [string]$rdsRuntimeContext.DbIdentifier
$SecretName = "cloudtasks/database"

$container = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}"
if ($container -ne "cloudtasks-localstack") {
    throw "LocalStack nao esta em execucao."
}

function Invoke-AwsLocalJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & docker exec cloudtasks-localstack awslocal @Arguments --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao executar: awslocal $($Arguments -join ' ')"
    }
    if ([string]::IsNullOrWhiteSpace(($output -join "`n"))) {
        return $null
    }
    return (($output -join "`n") | ConvertFrom-Json)
}

$instances = Invoke-AwsLocalJson @("rds", "describe-db-instances")
$db = $instances.DBInstances | Where-Object { $_.DBInstanceIdentifier -eq $DbIdentifier } | Select-Object -First 1
if ($null -eq $db) {
    throw "RDS '$DbIdentifier' nao encontrado. Rode .\scripts\localstack\create-database.ps1."
}

$secrets = Invoke-AwsLocalJson @("secretsmanager", "list-secrets")
$secret = $secrets.SecretList | Where-Object { $_.Name -eq $SecretName } | Select-Object -First 1

Write-Host "CloudTasks database status" -ForegroundColor Cyan
Write-Host "RDS:       $($db.DBInstanceIdentifier)"
Write-Host "Status:    $($db.DBInstanceStatus)"
Write-Host "Engine API: $($db.Engine) $($db.EngineVersion)"
Write-Host "Runtime:    PostgreSQL padrao do LocalStack (custom versions=0)"
Write-Host "Database:  $($db.DBName)"
if ($null -ne $db.Endpoint) {
    Write-Host "Endpoint:  $($db.Endpoint.Address):$($db.Endpoint.Port)"
}
if ($null -ne $db.DBSubnetGroup) {
    Write-Host "SubnetGrp: $($db.DBSubnetGroup.DBSubnetGroupName)"
}
if ($null -ne $secret) {
    Write-Host "Secret:    $($secret.Name)"
    Write-Host "SecretARN: $($secret.ARN)"
}
else {
    Write-Host "Secret:    NAO ENCONTRADO" -ForegroundColor Yellow
}
Write-Host "RuntimeID:  $($rdsRuntimeContext.Generation)" -ForegroundColor DarkGray
Write-Host "StateFile:  $($rdsRuntimeContext.StateFile)" -ForegroundColor DarkGray
Write-Host "Senha:      nao exibida" -ForegroundColor DarkGray
