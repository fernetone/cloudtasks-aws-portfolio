$ErrorActionPreference = "Stop"

$LoadBalancerName = "cloudtasks-alb"
$TargetGroupName = "cloudtasks-tg"
$DomainName = "cloudtasks-alb.elb.localhost.localstack.cloud"
$PrimarySslPolicy = "ELBSecurityPolicy-TLS13-1-2-2021-06"
$FallbackSslPolicy = "ELBSecurityPolicy-2016-08"

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $projectRoot

$container = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}"
if ($container -ne "cloudtasks-localstack") {
    throw "LocalStack nao esta em execucao. Rode .\scripts\localstack\resume-environment.ps1 primeiro."
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
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
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

function Test-ForwardToTargetGroup {
    param(
        [Parameter(Mandatory = $true)]$Listener,
        [Parameter(Mandatory = $true)][string]$TargetGroupArn
    )

    foreach ($action in @($Listener.DefaultActions)) {
        if ([string]$action.Type -ne "forward") {
            continue
        }
        if ([string]$action.TargetGroupArn -eq $TargetGroupArn) {
            return $true
        }
        foreach ($forwardTarget in @($action.ForwardConfig.TargetGroups)) {
            if ([string]$forwardTarget.TargetGroupArn -eq $TargetGroupArn) {
                return $true
            }
        }
    }
    return $false
}

function Get-IssuedCertificateForDomain {
    param([Parameter(Mandatory = $true)][string]$Domain)

    $certificates = Invoke-AwsLocalJson @("acm", "list-certificates")
    foreach ($summary in @($certificates.CertificateSummaryList)) {
        if ([string]$summary.DomainName -ne $Domain) {
            continue
        }
        $detail = Invoke-AwsLocalJson @("acm", "describe-certificate", "--certificate-arn", ([string]$summary.CertificateArn))
        if ($null -ne $detail.Certificate -and [string]$detail.Certificate.Status -eq "ISSUED") {
            return $detail.Certificate
        }
    }
    return $null
}

function Get-AnyCertificateForDomain {
    param([Parameter(Mandatory = $true)][string]$Domain)

    $certificates = Invoke-AwsLocalJson @("acm", "list-certificates")
    foreach ($summary in @($certificates.CertificateSummaryList)) {
        if ([string]$summary.DomainName -eq $Domain) {
            $detail = Invoke-AwsLocalJson @("acm", "describe-certificate", "--certificate-arn", ([string]$summary.CertificateArn))
            if ($null -ne $detail.Certificate) {
                return $detail.Certificate
            }
        }
    }
    return $null
}

function New-LocalImportedCertificate {
    param([Parameter(Mandatory = $true)][string]$Domain)

    $certPath = "/tmp/cloudtasks-acm-cert.pem"
    $keyPath = "/tmp/cloudtasks-acm-key.pem"

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & docker exec cloudtasks-localstack openssl version 2>$null | Out-Null
        $opensslAvailable = ($LASTEXITCODE -eq 0)
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if (-not $opensslAvailable) {
        return $null
    }

    try {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & docker exec cloudtasks-localstack openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -keyout $keyPath -out $certPath -subj "/CN=$Domain" 2>&1 | Out-Null
            $generateExit = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }

        if ($generateExit -ne 0) {
            return $null
        }

        $importResult = Invoke-AwsLocalRaw @(
            "acm", "import-certificate",
            "--certificate", "fileb://$certPath",
            "--private-key", "fileb://$keyPath"
        )
        if ($importResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($importResult.Text)) {
            return $null
        }

        $imported = $importResult.Text | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace([string]$imported.CertificateArn)) {
            return $null
        }

        $detail = Invoke-AwsLocalJson @("acm", "describe-certificate", "--certificate-arn", ([string]$imported.CertificateArn))
        return $detail.Certificate
    }
    finally {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & docker exec cloudtasks-localstack rm -f $certPath $keyPath 2>$null | Out-Null
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }
    }
}

Write-Host "[1/6] Garantindo ALB HTTP e Target Group existentes..." -ForegroundColor Cyan
$loadBalancers = Invoke-AwsLocalJson @("elbv2", "describe-load-balancers")
$loadBalancer = @($loadBalancers.LoadBalancers) | Where-Object { [string]$_.LoadBalancerName -eq $LoadBalancerName } | Select-Object -First 1
if ($null -eq $loadBalancer) {
    Write-Host "ALB nao existe neste runtime; reconciliando primeiro..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot "create-alb.ps1")
    $loadBalancers = Invoke-AwsLocalJson @("elbv2", "describe-load-balancers")
    $loadBalancer = @($loadBalancers.LoadBalancers) | Where-Object { [string]$_.LoadBalancerName -eq $LoadBalancerName } | Select-Object -First 1
}
if ($null -eq $loadBalancer) {
    throw "ALB '$LoadBalancerName' nao foi encontrado apos a reconciliacao."
}
$loadBalancerArn = [string]$loadBalancer.LoadBalancerArn
$dnsName = [string]$loadBalancer.DNSName

$targetGroups = Invoke-AwsLocalJson @("elbv2", "describe-target-groups")
$targetGroup = @($targetGroups.TargetGroups) | Where-Object { [string]$_.TargetGroupName -eq $TargetGroupName } | Select-Object -First 1
if ($null -eq $targetGroup) {
    throw "Target Group '$TargetGroupName' nao encontrado. Rode .\scripts\localstack\create-alb.ps1."
}
$targetGroupArn = [string]$targetGroup.TargetGroupArn

Write-Host "[2/6] Garantindo certificado no ACM local..." -ForegroundColor Cyan
$certificate = Get-IssuedCertificateForDomain -Domain $DomainName
$certificateMode = "reutilizado"

if ($null -eq $certificate) {
    Write-Host "Nenhum certificado ISSUED encontrado para $DomainName; gerando um certificado local efemero e importando no ACM..." -ForegroundColor Yellow
    $certificate = New-LocalImportedCertificate -Domain $DomainName
    $certificateMode = "importado localmente"
}

if ($null -eq $certificate) {
    $certificate = Get-AnyCertificateForDomain -Domain $DomainName
}

if ($null -eq $certificate) {
    Write-Host "Importacao local indisponivel; solicitando certificado ACM emulado..." -ForegroundColor Yellow
    $requested = Invoke-AwsLocalJson @(
        "acm", "request-certificate",
        "--domain-name", $DomainName,
        "--validation-method", "DNS",
        "--idempotency-token", "cloudtasks2026",
        "--options", "CertificateTransparencyLoggingPreference=DISABLED"
    )
    $certificateArnRequested = [string]$requested.CertificateArn
    if ([string]::IsNullOrWhiteSpace($certificateArnRequested)) {
        throw "ACM nao retornou CertificateArn."
    }
    $detailRequested = Invoke-AwsLocalJson @("acm", "describe-certificate", "--certificate-arn", $certificateArnRequested)
    $certificate = $detailRequested.Certificate
    $certificateMode = "solicitado no ACM emulado"
}

$certificateArn = [string]$certificate.CertificateArn
if ([string]::IsNullOrWhiteSpace($certificateArn)) {
    throw "Certificado ACM sem ARN."
}

Write-Host "  ACM: $certificateArn" -ForegroundColor Green
Write-Host "  Domain: $([string]$certificate.DomainName)" -ForegroundColor Green
Write-Host "  Status: $([string]$certificate.Status) / origem=$certificateMode" -ForegroundColor Green

Write-Host "[3/6] Garantindo listener HTTPS logico :443 -> Target Group..." -ForegroundColor Cyan
$listenersResult = Invoke-AwsLocalJson @("elbv2", "describe-listeners", "--load-balancer-arn", $loadBalancerArn)
$httpsListener = @($listenersResult.Listeners) | Where-Object { [string]$_.Protocol -eq "HTTPS" } | Select-Object -First 1
$forwardAction = "Type=forward,TargetGroupArn=$targetGroupArn"
$certificateSpec = "CertificateArn=$certificateArn"
$sslPolicyUsed = $PrimarySslPolicy

if ($null -eq $httpsListener) {
    $createResult = Invoke-AwsLocalRaw @(
        "elbv2", "create-listener",
        "--load-balancer-arn", $loadBalancerArn,
        "--protocol", "HTTPS",
        "--port", "443",
        "--certificates", $certificateSpec,
        "--ssl-policy", $PrimarySslPolicy,
        "--default-actions", $forwardAction
    )

    if ($createResult.ExitCode -ne 0) {
        Write-Host "Policy TLS moderna nao foi aceita pelo runtime local; tentando policy compativel..." -ForegroundColor Yellow
        $sslPolicyUsed = $FallbackSslPolicy
        $createResult = Invoke-AwsLocalRaw @(
            "elbv2", "create-listener",
            "--load-balancer-arn", $loadBalancerArn,
            "--protocol", "HTTPS",
            "--port", "443",
            "--certificates", $certificateSpec,
            "--ssl-policy", $FallbackSslPolicy,
            "--default-actions", $forwardAction
        )
    }

    if ($createResult.ExitCode -ne 0) {
        throw "Falha ao criar listener HTTPS (exit=$($createResult.ExitCode)); ACM status=$([string]$certificate.Status)."
    }
}
else {
    $listenerArnExisting = [string]$httpsListener.ListenerArn
    $modifyResult = Invoke-AwsLocalRaw @(
        "elbv2", "modify-listener",
        "--listener-arn", $listenerArnExisting,
        "--certificates", $certificateSpec,
        "--default-actions", $forwardAction
    )
    if ($modifyResult.ExitCode -ne 0) {
        throw "Listener HTTPS existente nao pode ser reconciliado (exit=$($modifyResult.ExitCode))."
    }
}

Write-Host "[4/6] Validando associacao HTTPS -> ACM -> Target Group..." -ForegroundColor Cyan
$listenersResult = Invoke-AwsLocalJson @("elbv2", "describe-listeners", "--load-balancer-arn", $loadBalancerArn)
$httpsListener = @($listenersResult.Listeners) | Where-Object {
    [string]$_.Protocol -eq "HTTPS" -and (Test-ForwardToTargetGroup -Listener $_ -TargetGroupArn $targetGroupArn)
} | Select-Object -First 1
if ($null -eq $httpsListener) {
    throw "Listener HTTPS com forward para '$TargetGroupName' nao foi encontrado apos a criacao."
}
$httpsListenerArn = [string]$httpsListener.ListenerArn

$listenerCertificatesResult = Invoke-AwsLocalRaw @("elbv2", "describe-listener-certificates", "--listener-arn", $httpsListenerArn)
$boundCertificateArns = @()
if ($listenerCertificatesResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($listenerCertificatesResult.Text)) {
    $listenerCertificates = $listenerCertificatesResult.Text | ConvertFrom-Json
    $boundCertificateArns = @($listenerCertificates.Certificates | ForEach-Object { [string]$_.CertificateArn })
}
else {
    $boundCertificateArns = @($httpsListener.Certificates | ForEach-Object { [string]$_.CertificateArn })
}
if ($boundCertificateArns -notcontains $certificateArn) {
    throw "Listener HTTPS foi criado, mas o certificado ACM esperado nao aparece associado."
}

Write-Host "[5/6] Confirmando dois targets healthy para o caminho HTTPS..." -ForegroundColor Cyan
$healthyCount = 0
for ($attempt = 1; $attempt -le 24; $attempt++) {
    $health = Invoke-AwsLocalJson @("elbv2", "describe-target-health", "--target-group-arn", $targetGroupArn)
    $healthyCount = @($health.TargetHealthDescriptions | Where-Object { [string]$_.TargetHealth.State -eq "healthy" }).Count
    if ($healthyCount -eq 2) {
        break
    }
    Start-Sleep -Seconds 5
}
if ($healthyCount -ne 2) {
    throw "Target Group nao ficou com 2/2 healthy para o listener HTTPS."
}

Write-Host "[6/6] HTTPS configurado no plano de controle local." -ForegroundColor Cyan
Write-Host ""
Write-Host "HTTPS CloudTasks criado e validado no LocalStack." -ForegroundColor Green
Write-Host "Certificate domain: $DomainName" -ForegroundColor Green
Write-Host "Certificate status: $([string]$certificate.Status)" -ForegroundColor Green
Write-Host "Certificate ARN:    $certificateArn" -ForegroundColor Green
Write-Host "Listener:           HTTPS :443 logico / runtime LocalStack :$([int]$httpsListener.Port)" -ForegroundColor Green
Write-Host "SSL policy:         $([string]$httpsListener.SslPolicy)" -ForegroundColor Green
Write-Host "Target Group:       $TargetGroupName / 2/2 healthy" -ForegroundColor Green
Write-Host "HTTPS local:        https://${dnsName}:4566" -ForegroundColor Green
Write-Host ""
Write-Host "Paridade local:" -ForegroundColor Yellow
Write-Host "O listener e a associacao ACM sao recursos ELBv2/ACM reais da emulacao." -ForegroundColor DarkGray
Write-Host "O TLS no gateway :4566 e terminado pelo certificado de infraestrutura do LocalStack, nao pelo PEM importado no ACM." -ForegroundColor DarkGray
Write-Host "Em AWS real, o listener :443 do ALB termina TLS usando o certificado ACM associado." -ForegroundColor DarkGray
