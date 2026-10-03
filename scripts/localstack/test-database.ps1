$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "rds-runtime-context.ps1")
$rdsRuntimeContext = Get-CloudTasksRdsRuntime
$DbIdentifier = [string]$rdsRuntimeContext.DbIdentifier
$SecretName = "cloudtasks/database"

$container = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}"
if ($container -ne "cloudtasks-localstack") {
    throw "LocalStack nao esta em execucao."
}

function Invoke-AwsLocalRaw {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = & docker exec cloudtasks-localstack awslocal @Arguments --output json 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    $text = (($raw | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = $text
    }
}

function Invoke-AwsLocalJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $result = Invoke-AwsLocalRaw -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw "awslocal $($Arguments[0]) $($Arguments[1]) falhou (exit=$($result.ExitCode))."
    }
    if ([string]::IsNullOrWhiteSpace($result.Text)) {
        return $null
    }
    try { return ($result.Text | ConvertFrom-Json -ErrorAction Stop) } catch { throw "JSON de awslocal $($Arguments[0]) $($Arguments[1]) invalido." }
}

function Get-DatabaseSecret {
    $response = Invoke-AwsLocalJson @("secretsmanager", "get-secret-value", "--secret-id", $SecretName)
    try {
        $parsed = [string]$response.SecretString | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }

    if ($null -eq $parsed) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace([string]$parsed.username) -or
        [string]::IsNullOrWhiteSpace([string]$parsed.password) -or
        [string]::IsNullOrWhiteSpace([string]$parsed.dbname)) {
        return $null
    }
    return $parsed
}

$instances = Invoke-AwsLocalJson @("rds", "describe-db-instances")
$db = $instances.DBInstances | Where-Object { $_.DBInstanceIdentifier -eq $DbIdentifier } | Select-Object -First 1
if ($null -eq $db -or $db.DBInstanceStatus -ne "available" -or $null -eq $db.Endpoint) {
    throw "RDS '$DbIdentifier' ainda nao esta disponivel."
}

$secret = Get-DatabaseSecret
if ($null -eq $secret) {
    Write-Host "Secret existente nao esta em JSON valido. Executando reparo seguro da v1.2.9..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot "create-database.ps1")
    if ($LASTEXITCODE -ne 0) {
        throw "O reparo automatico do secret falhou."
    }
    $secret = Get-DatabaseSecret
}

if ($null -eq $secret) {
    throw "Secret '$SecretName' continua invalido apos o reparo."
}

Write-Host "Executando SELECT 1 no PostgreSQL RDS emulado..." -ForegroundColor Cyan

$oldPassword = $env:PGPASSWORD
try {
    $env:PGPASSWORD = [string]$secret.password
    $queryOutput = & docker run --rm `
        -e PGPASSWORD `
        -e PGSSLMODE=prefer `
        postgres:16-alpine `
        psql `
        -h host.docker.internal `
        -p ([string]$db.Endpoint.Port) `
        -U ([string]$secret.username) `
        -d ([string]$secret.dbname) `
        -tAc "SELECT 1;"
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao conectar no PostgreSQL RDS emulado."
    }
}
finally {
    if ($null -eq $oldPassword) {
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    }
    else {
        $env:PGPASSWORD = $oldPassword
    }
}

$result = (($queryOutput | ForEach-Object { $_.ToString().Trim() }) | Where-Object { $_ -ne "" } | Select-Object -Last 1)
if ($result -ne "1") {
    throw "O banco respondeu, mas o SELECT 1 nao retornou o valor esperado. Retorno: $result"
}

Write-Host "PostgreSQL RDS emulado respondeu corretamente: SELECT 1 -> 1" -ForegroundColor Green
Write-Host "Conexao validada via Docker sem exibir a senha do Secrets Manager." -ForegroundColor DarkGray
