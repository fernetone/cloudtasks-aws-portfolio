param(
    [ValidateRange(0, 2)][int]$RuntimeRecoveryAttempt = 0
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "rds-runtime-context.ps1")
$runtimeContext = Get-CloudTasksRdsRuntime
$DbIdentifier = [string]$runtimeContext.DbIdentifier
$DbName = "cloudtasks"
$DbUser = "cloudtasks_admin"
$DbEngine = "postgres"
$DbEngineVersion = "16"
$DbClass = "db.t3.micro"
$DbSubnetGroupName = "cloudtasks-db-subnet-group"
$SecretName = "cloudtasks/database"
$VpcName = "cloudtasks-vpc"
$ProjectTag = "CloudTasks"

$container = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}"
if ($container -ne "cloudtasks-localstack") {
    throw "LocalStack nao esta em execucao. Rode .\scripts\localstack\start-localstack.ps1 primeiro."
}

$rdsCustomVersionRows = @(& docker exec cloudtasks-localstack printenv RDS_PG_CUSTOM_VERSIONS 2>$null)
$rdsCustomVersions = $rdsCustomVersionRows | Select-Object -First 1
if ([string]$rdsCustomVersions -ne "0") {
    throw "Runtime LocalStack sem RDS_PG_CUSTOM_VERSIONS=0. Rode .\scripts\localstack\resume-environment.ps1 para aplicar a configuracao RDS estavel antes de criar o banco."
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


function Get-SecretMetadataSafely {
    param([Parameter(Mandatory = $true)][string]$SecretId)

    $result = Invoke-AwsLocalRaw @("secretsmanager", "describe-secret", "--secret-id", $SecretId)
    if ($result.ExitCode -eq 0) {
        if ([string]::IsNullOrWhiteSpace($result.Text)) {
            return $null
        }
        try { return ($result.Text | ConvertFrom-Json -ErrorAction Stop) }
        catch { throw 'JSON de secretsmanager describe-secret invalido.' }
    }

    if ($result.Text -match "ResourceNotFoundException") {
        return $null
    }

    throw "secretsmanager describe-secret falhou (exit=$($result.ExitCode))."
}

function Get-SecretValueSafely {
    param([Parameter(Mandatory = $true)][string]$SecretId)

    $result = Invoke-AwsLocalRaw @("secretsmanager", "get-secret-value", "--secret-id", $SecretId)
    if ($result.ExitCode -eq 0) {
        if ([string]::IsNullOrWhiteSpace($result.Text)) {
            return $null
        }
        try { return ($result.Text | ConvertFrom-Json -ErrorAction Stop) }
        catch { throw 'JSON de secretsmanager get-secret-value invalido.' }
    }

    if ($result.Text -match "ResourceNotFoundException") {
        return $null
    }

    throw "secretsmanager get-secret-value falhou (exit=$($result.ExitCode))."
}

function New-RandomPassword {
    param([int]$Length = 32)

    $alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }

    $chars = foreach ($byte in $bytes) {
        $alphabet[$byte % $alphabet.Length]
    }
    return (-join $chars)
}

function ConvertFrom-SecretJsonSafely {
    param($SecretString)

    if ($null -eq $SecretString) {
        return $null
    }

    $text = [string]$SecretString
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Get-LegacySecretPassword {
    param($SecretString)

    if ($null -eq $SecretString) {
        return $null
    }

    $text = [string]$SecretString
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    # Senhas geradas pelo CloudTasks usam apenas letras e numeros. Isso nos
    # permite recuperar com seguranca o password de um JSON legado que perdeu
    # aspas no Windows PowerShell 5.1, sem imprimir o valor.
    $match = [System.Text.RegularExpressions.Regex]::Match(
        $text,
        '(?i)(?:^|[,\{])\s*"?password"?\s*:\s*"?([A-Za-z0-9]+)"?'
    )
    if ($match.Success -and -not [string]::IsNullOrWhiteSpace($match.Groups[1].Value)) {
        return $match.Groups[1].Value
    }

    return $null
}

function Invoke-SecretJsonFileOperation {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Create", "Put")][string]$Mode,
        [Parameter(Mandatory = $true)][string]$SecretId,
        [Parameter(Mandatory = $true)][string]$Json
    )

    # Windows PowerShell 5.1 pode remover aspas internas de JSON quando o valor
    # atravessa docker.exe como argumento. Para evitar qualquer quoting fragil,
    # gravamos o JSON em arquivo UTF-8 sem BOM e usamos file:// dentro do container.
    $hostTemp = [System.IO.Path]::GetTempFileName()
    $containerTemp = "/tmp/cloudtasks-secret-$([Guid]::NewGuid().ToString('N')).json"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    try {
        [System.IO.File]::WriteAllText($hostTemp, $Json, $utf8NoBom)

        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & docker cp $hostTemp "cloudtasks-localstack:$containerTemp" | Out-Null
            $copyExit = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }
        if ($copyExit -ne 0) {
            throw "Nao foi possivel copiar o arquivo temporario do secret para o LocalStack."
        }

        if ($Mode -eq "Create") {
            $createResult = Invoke-AwsLocalRaw @(
                "secretsmanager", "create-secret",
                "--name", $SecretId,
                "--description", "CloudTasks RDS PostgreSQL credentials for LocalStack",
                "--secret-string", "file://$containerTemp",
                "--tags", "Key=Project,Value=$ProjectTag", "Key=Environment,Value=localstack"
            )

            if ($createResult.ExitCode -eq 0) {
                if ([string]::IsNullOrWhiteSpace($createResult.Text)) {
                    return $null
                }
                return ($createResult.Text | ConvertFrom-Json)
            }

            # O estado persistido do LocalStack pode terminar de materializar o
            # secret entre a consulta e o create-secret. Nesse caso a operacao
            # correta e idempotente e atualizar o valor existente, nunca falhar.
            if ($createResult.Text -match "ResourceExistsException") {
                Write-Host "Secret apareceu no runtime durante a reconciliacao; atualizando o valor existente de forma idempotente." -ForegroundColor Yellow
                return Invoke-AwsLocalJson @(
                    "secretsmanager", "put-secret-value",
                    "--secret-id", $SecretId,
                    "--secret-string", "file://$containerTemp"
                )
            }

            throw "CreateSecret falhou para $SecretId (exit=$($createResult.ExitCode))."
        }

        return Invoke-AwsLocalJson @(
            "secretsmanager", "put-secret-value",
            "--secret-id", $SecretId,
            "--secret-string", "file://$containerTemp"
        )
    }
    finally {
        Remove-Item -Path $hostTemp -Force -ErrorAction SilentlyContinue
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & docker exec cloudtasks-localstack rm -f $containerTemp 2>$null | Out-Null
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }
    }
}

Write-Host "[1/7] Localizando VPC, subnets privadas de dados e security group..." -ForegroundColor Cyan
$vpcs = Invoke-AwsLocalJson @("ec2", "describe-vpcs")
$vpc = $vpcs.Vpcs | Where-Object {
    ($_.Tags | Where-Object { $_.Key -eq "Name" -and $_.Value -eq $VpcName })
} | Select-Object -First 1
if ($null -eq $vpc) {
    Write-Host "VPC '$VpcName' nao encontrada. Recriando automaticamente a fundacao de rede..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot "create-network.ps1")
    if ($LASTEXITCODE -ne 0) {
        throw "Nao foi possivel recriar a rede CloudTasks automaticamente."
    }

    $vpcs = Invoke-AwsLocalJson @("ec2", "describe-vpcs")
    $vpc = $vpcs.Vpcs | Where-Object {
        ($_.Tags | Where-Object { $_.Key -eq "Name" -and $_.Value -eq $VpcName })
    } | Select-Object -First 1

    if ($null -eq $vpc) {
        throw "A rede foi executada, mas a VPC '$VpcName' continua ausente."
    }
}

$subnets = Invoke-AwsLocalJson @("ec2", "describe-subnets", "--filters", "Name=vpc-id,Values=$($vpc.VpcId)")
$dataSubnets = @($subnets.Subnets | Where-Object {
    $nameTag = $_.Tags | Where-Object { $_.Key -eq "Name" } | Select-Object -First 1
    $null -ne $nameTag -and $nameTag.Value -like "cloudtasks-data-private-*"
} | Sort-Object AvailabilityZone)
if ($dataSubnets.Count -lt 2) {
    throw "Esperadas duas subnets privadas de dados; encontradas $($dataSubnets.Count)."
}

$sgs = Invoke-AwsLocalJson @("ec2", "describe-security-groups", "--filters", "Name=vpc-id,Values=$($vpc.VpcId)")
$defaultSg = $sgs.SecurityGroups | Where-Object { $_.GroupName -eq "default" } | Select-Object -First 1
if ($null -eq $defaultSg) {
    throw "Security group default da VPC nao encontrado."
}

Write-Host "[2/7] Garantindo DB subnet group logico..." -ForegroundColor Cyan
$dbSubnetGroupSupported = $true
$dbSubnetGroupsResult = Invoke-AwsLocalRaw @("rds", "describe-db-subnet-groups")
if ($dbSubnetGroupsResult.ExitCode -ne 0) {
    $dbSubnetGroupSupported = $false
    Write-Host "LocalStack nao disponibilizou DB subnet groups neste provider; continuando com o runtime RDS local." -ForegroundColor Yellow
}
else {
    $dbSubnetGroups = $dbSubnetGroupsResult.Text | ConvertFrom-Json
    $dbSubnetGroup = $dbSubnetGroups.DBSubnetGroups | Where-Object { $_.DBSubnetGroupName -eq $DbSubnetGroupName } | Select-Object -First 1
    if ($null -eq $dbSubnetGroup) {
        $createSubnetGroup = Invoke-AwsLocalRaw @(
            "rds", "create-db-subnet-group",
            "--db-subnet-group-name", $DbSubnetGroupName,
            "--db-subnet-group-description", "CloudTasks private data subnets",
            "--subnet-ids", $dataSubnets[0].SubnetId, $dataSubnets[1].SubnetId,
            "--tags", "Key=Project,Value=$ProjectTag", "Key=Environment,Value=localstack"
        )
        if ($createSubnetGroup.ExitCode -ne 0) {
            $dbSubnetGroupSupported = $false
            Write-Host "DB subnet group nao foi aplicado pelo provider RDS local; o desenho permanece documentado e o banco sera criado no runtime local." -ForegroundColor Yellow
        }
    }
}

Write-Host "[3/7] Preparando credencial do Secrets Manager..." -ForegroundColor Cyan
# Nao use list-secrets como prova de inexistencia durante o startup persistido do
# LocalStack: a listagem pode ficar momentaneamente atrasada em relacao ao acesso
# direto pelo nome. A consulta exata evita gerar uma nova senha para um secret
# que ja existe e ainda elimina a corrida observada no resume-environment.ps1.
$secret = Get-SecretMetadataSafely -SecretId $SecretName
$secretNeedsRepair = $false
$passwordNeedsRdsSync = $false
$legacyPasswordRecovered = $false

if ($null -eq $secret) {
    $password = New-RandomPassword
    Write-Host "Secret nao foi encontrado por consulta direta; uma credencial nova sera armazenada apos o RDS ficar disponivel." -ForegroundColor DarkGray
}
else {
    $secretValue = Get-SecretValueSafely -SecretId $SecretName
    if ($null -eq $secretValue) {
        # Se o metadado existe, mas o valor ainda nao apareceu, aguarde brevemente
        # a restauracao do estado persistido antes de concluir que precisa reparar.
        for ($secretAttempt = 1; $secretAttempt -le 10 -and $null -eq $secretValue; $secretAttempt++) {
            Start-Sleep -Seconds 1
            $secretValue = Get-SecretValueSafely -SecretId $SecretName
        }
        if ($null -eq $secretValue) {
            throw "O secret '$SecretName' existe, mas seu valor nao ficou disponivel apos a restauracao do estado LocalStack."
        }
    }
    $stored = ConvertFrom-SecretJsonSafely -SecretString $secretValue.SecretString
    if ($null -ne $stored -and -not [string]::IsNullOrWhiteSpace([string]$stored.password)) {
        $password = [string]$stored.password
        Write-Host "Secret existente em JSON valido reutilizado." -ForegroundColor DarkGray
    }
    else {
        # v1.2.8 e anteriores podiam perder as aspas internas do JSON ao passar
        # --secret-string pelo Windows PowerShell 5.1 -> docker.exe. Primeiro
        # tentamos recuperar a senha original do formato legado para nao alterar
        # a credencial de um RDS que ja existe.
        $legacyPassword = Get-LegacySecretPassword -SecretString $secretValue.SecretString
        $secretNeedsRepair = $true
        if (-not [string]::IsNullOrWhiteSpace([string]$legacyPassword)) {
            $password = [string]$legacyPassword
            $legacyPasswordRecovered = $true
            Write-Host "Secret legado detectado; a credencial original foi recuperada em memoria e sera regravada em JSON valido." -ForegroundColor Yellow
        }
        else {
            $password = New-RandomPassword
            $passwordNeedsRdsSync = $true
            Write-Host "Secret legado detectado e a senha antiga nao pode ser recuperada; uma nova credencial sera sincronizada com o RDS." -ForegroundColor Yellow
        }
    }
}

Write-Host "[4/7] Garantindo RDS PostgreSQL 16..." -ForegroundColor Cyan
$instances = Invoke-AwsLocalJson @("rds", "describe-db-instances")
$db = $instances.DBInstances | Where-Object { $_.DBInstanceIdentifier -eq $DbIdentifier } | Select-Object -First 1

if ($null -eq $db) {
    $createArgs = @(
        "rds", "create-db-instance",
        "--db-instance-identifier", $DbIdentifier,
        "--db-instance-class", $DbClass,
        "--engine", $DbEngine,
        "--engine-version", $DbEngineVersion,
        "--db-name", $DbName,
        "--master-username", $DbUser,
        "--master-user-password", $password,
        "--allocated-storage", "20",
        "--storage-type", "gp2",
        "--storage-encrypted",
        "--no-publicly-accessible",
        "--vpc-security-group-ids", $defaultSg.GroupId,
        "--tags", "Key=Project,Value=$ProjectTag", "Key=Environment,Value=localstack"
    )

    if ($dbSubnetGroupSupported) {
        $createArgs += @("--db-subnet-group-name", $DbSubnetGroupName)
    }

    $null = Invoke-AwsLocalJson -Arguments $createArgs
    Write-Host "RDS solicitado. RDS_PG_CUSTOM_VERSIONS=0 seleciona a versao padrao do provider; o LocalStack ainda pode instalar seus pacotes." -ForegroundColor Green
}
elseif ([string]$db.DBInstanceStatus -ne "available") {
    if ($RuntimeRecoveryAttempt -ge 2) {
        throw "RDS continuou preso em '$($db.DBInstanceStatus)' apos duas rotacoes de runtime. Consulte docker logs --tail 200 cloudtasks-localstack."
    }
    Write-Host "RDS '$DbIdentifier' foi encontrado em estado '$($db.DBInstanceStatus)' e nao esta utilizavel." -ForegroundColor Yellow
    Write-Host "Rotacionando somente o namespace RDS local, sem resetar os demais servicos..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot "repair-rds-runtime.ps1") -Quiet
    & $PSCommandPath -RuntimeRecoveryAttempt ($RuntimeRecoveryAttempt + 1)
    return
}
elseif ($passwordNeedsRdsSync) {
    Write-Host "Sincronizando nova credencial com o RDS existente..." -ForegroundColor Yellow
    $null = Invoke-AwsLocalJson @(
        "rds", "modify-db-instance",
        "--db-instance-identifier", $DbIdentifier,
        "--master-user-password", $password,
        "--apply-immediately"
    )
    Write-Host "Credencial do RDS atualizada; aguardando a instancia estabilizar." -ForegroundColor DarkGray
}
else {
    Write-Host "RDS '$DbIdentifier' ja existe; reutilizando." -ForegroundColor DarkGray
}

Write-Host "[5/7] Aguardando RDS ficar disponivel..." -ForegroundColor Cyan
$db = $null
for ($attempt = 1; $attempt -le 36; $attempt++) {
    $instances = Invoke-AwsLocalJson @("rds", "describe-db-instances")
    $db = $instances.DBInstances | Where-Object { $_.DBInstanceIdentifier -eq $DbIdentifier } | Select-Object -First 1
    if ($null -ne $db -and $db.DBInstanceStatus -eq "available" -and $null -ne $db.Endpoint -and -not [string]::IsNullOrWhiteSpace([string]$db.Endpoint.Address)) {
        break
    }
    if ($null -ne $db -and [string]$db.DBInstanceStatus -eq "error") {
        break
    }
    if ($attempt % 6 -eq 0) {
        $statusText = if ($null -eq $db) { "provisionando" } else { [string]$db.DBInstanceStatus }
        Write-Host "  Status: $statusText ..." -ForegroundColor DarkGray
    }
    Start-Sleep -Seconds 5
}

if ($null -eq $db -or $db.DBInstanceStatus -ne "available" -or $null -eq $db.Endpoint) {
    $failedStatus = if ($null -eq $db) { "ausente" } else { [string]$db.DBInstanceStatus }
    if ($RuntimeRecoveryAttempt -lt 2) {
        Write-Host "RDS '$DbIdentifier' nao convergiu para available (status=$failedStatus)." -ForegroundColor Yellow
        Write-Host "Aplicando rotacao segura do runtime RDS e tentando novamente uma vez..." -ForegroundColor Yellow
        & (Join-Path $PSScriptRoot "repair-rds-runtime.ps1") -Quiet
        & $PSCommandPath -RuntimeRecoveryAttempt ($RuntimeRecoveryAttempt + 1)
        return
    }
    throw "RDS nao ficou disponivel apos recuperacao automatica (status=$failedStatus). Consulte: docker logs --tail 200 cloudtasks-localstack"
}

Write-Host "[6/7] Gravando secret JSON por arquivo, sem quoting fragil..." -ForegroundColor Cyan
$finalSecret = [ordered]@{
    engine = $DbEngine
    username = $DbUser
    password = $password
    host = [string]$db.Endpoint.Address
    port = [int]$db.Endpoint.Port
    dbname = $DbName
    dbInstanceIdentifier = $DbIdentifier
} | ConvertTo-Json -Compress

# Revalida imediatamente antes da escrita. Isso torna a operacao correta mesmo
# quando o estado persistido do Secrets Manager aparece enquanto o RDS esta sendo
# provisionado. O helper de Create tambem trata ResourceExistsException como uma
# corrida idempotente e converte para put-secret-value.
$secretAtWrite = Get-SecretMetadataSafely -SecretId $SecretName
if ($null -eq $secretAtWrite) {
    $null = Invoke-SecretJsonFileOperation -Mode "Create" -SecretId $SecretName -Json $finalSecret
}
else {
    $null = Invoke-SecretJsonFileOperation -Mode "Put" -SecretId $SecretName -Json $finalSecret
}

# Confirma que o valor salvo e JSON valido sem imprimir o SecretString.
$secretValueCheck = Invoke-AwsLocalJson @("secretsmanager", "get-secret-value", "--secret-id", $SecretName)
$storedCheck = ConvertFrom-SecretJsonSafely -SecretString $secretValueCheck.SecretString
if ($null -eq $storedCheck -or [string]::IsNullOrWhiteSpace([string]$storedCheck.password)) {
    throw "O Secrets Manager respondeu, mas o SecretString nao ficou em JSON valido."
}
if ([string]$storedCheck.username -ne $DbUser -or [string]$storedCheck.dbname -ne $DbName) {
    throw "O secret foi salvo, mas os metadados esperados nao conferem."
}

Write-Host "[7/7] Validando metadados sem exibir segredo..." -ForegroundColor Cyan
$dbCheck = Invoke-AwsLocalJson @("rds", "describe-db-instances")
$dbFinal = $dbCheck.DBInstances | Where-Object { $_.DBInstanceIdentifier -eq $DbIdentifier } | Select-Object -First 1
$secretCheck = Invoke-AwsLocalJson @("secretsmanager", "describe-secret", "--secret-id", $SecretName)

if ($null -eq $dbFinal -or $dbFinal.DBInstanceStatus -ne "available") {
    throw "Validacao final do RDS falhou."
}
if ($null -eq $secretCheck -or $secretCheck.Name -ne $SecretName) {
    throw "Validacao final do Secrets Manager falhou."
}

$null = Set-CloudTasksRdsRuntime -DbIdentifier $DbIdentifier -Generation ([string]$runtimeContext.Generation)

Write-Host ""
if ($secretNeedsRepair -and $legacyPasswordRecovered) {
    Write-Host "Secret legado reparado preservando a credencial original do RDS." -ForegroundColor Green
}
elseif ($secretNeedsRepair -and $passwordNeedsRdsSync) {
    Write-Host "Secret legado reparado e nova credencial sincronizada com o RDS." -ForegroundColor Green
}
Write-Host "Banco CloudTasks criado e validado no LocalStack." -ForegroundColor Green
Write-Host "RDS:          $DbIdentifier"
Write-Host "Engine API:   $($dbFinal.Engine) $($dbFinal.EngineVersion)"
Write-Host "Runtime local: PostgreSQL padrao do LocalStack (RDS_PG_CUSTOM_VERSIONS=0)"
Write-Host "Database:     $DbName"
Write-Host "Endpoint:     $($dbFinal.Endpoint.Address):$($dbFinal.Endpoint.Port)"
if ($dbSubnetGroupSupported) {
    Write-Host "Subnet group: $DbSubnetGroupName"
}
else {
    Write-Host "Subnet group: nao aplicado pelo runtime RDS LocalStack (topologia logica preservada)" -ForegroundColor Yellow
}
Write-Host "Secret:       $SecretName"
Write-Host "Secret ARN:   $($secretCheck.ARN)"
Write-Host "Secret JSON:  validado" -ForegroundColor Green
Write-Host "Senha:        armazenada somente no Secrets Manager; nao exibida." -ForegroundColor DarkGray
