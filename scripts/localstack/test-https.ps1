$ErrorActionPreference = "Stop"

$LoadBalancerName = "cloudtasks-alb"
$TargetGroupName = "cloudtasks-tg"
$ExpectedDomain = "cloudtasks-alb.elb.localhost.localstack.cloud"

$container = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}"
if ($container -ne "cloudtasks-localstack") {
    throw "LocalStack nao esta em execucao."
}

function Invoke-AwsLocalJson {
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
    if ($exitCode -ne 0) {
        throw "awslocal $($Arguments[0]) $($Arguments[1]) falhou (exit=$exitCode)."
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { return ($text | ConvertFrom-Json -ErrorAction Stop) } catch { throw "JSON de awslocal $($Arguments[0]) $($Arguments[1]) invalido." }
}

function Test-ForwardToTargetGroup {
    param(
        [Parameter(Mandatory = $true)]$Listener,
        [Parameter(Mandatory = $true)][string]$TargetGroupArn
    )

    foreach ($action in @($Listener.DefaultActions)) {
        if ([string]$action.Type -ne "forward") { continue }
        if ([string]$action.TargetGroupArn -eq $TargetGroupArn) { return $true }
        foreach ($forwardTarget in @($action.ForwardConfig.TargetGroups)) {
            if ([string]$forwardTarget.TargetGroupArn -eq $TargetGroupArn) { return $true }
        }
    }
    return $false
}

Write-Host "[1/5] Validando listener HTTPS e certificado ACM..." -ForegroundColor Cyan
$loadBalancers = Invoke-AwsLocalJson @("elbv2", "describe-load-balancers")
$loadBalancer = @($loadBalancers.LoadBalancers) | Where-Object { [string]$_.LoadBalancerName -eq $LoadBalancerName } | Select-Object -First 1
if ($null -eq $loadBalancer) {
    throw "ALB '$LoadBalancerName' nao encontrado. Rode .\scripts\localstack\resume-environment.ps1."
}

$targetGroups = Invoke-AwsLocalJson @("elbv2", "describe-target-groups")
$targetGroup = @($targetGroups.TargetGroups) | Where-Object { [string]$_.TargetGroupName -eq $TargetGroupName } | Select-Object -First 1
if ($null -eq $targetGroup) {
    throw "Target Group '$TargetGroupName' nao encontrado."
}
$targetGroupArn = [string]$targetGroup.TargetGroupArn

$listeners = Invoke-AwsLocalJson @("elbv2", "describe-listeners", "--load-balancer-arn", ([string]$loadBalancer.LoadBalancerArn))
$httpsListener = @($listeners.Listeners) | Where-Object {
    [string]$_.Protocol -eq "HTTPS" -and (Test-ForwardToTargetGroup -Listener $_ -TargetGroupArn $targetGroupArn)
} | Select-Object -First 1
if ($null -eq $httpsListener) {
    throw "Listener HTTPS com forward para '$TargetGroupName' nao encontrado. Rode .\scripts\localstack\create-https.ps1."
}

$boundCertificateArn = @($httpsListener.Certificates | ForEach-Object { [string]$_.CertificateArn }) | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace([string]$boundCertificateArn)) {
    try {
        $listenerCertificates = Invoke-AwsLocalJson @("elbv2", "describe-listener-certificates", "--listener-arn", ([string]$httpsListener.ListenerArn))
        $boundCertificateArn = @($listenerCertificates.Certificates | ForEach-Object { [string]$_.CertificateArn }) | Select-Object -First 1
    }
    catch {
        $boundCertificateArn = $null
    }
}
if ([string]::IsNullOrWhiteSpace([string]$boundCertificateArn)) {
    throw "Listener HTTPS nao possui certificado ACM associado."
}

$certificateDetails = Invoke-AwsLocalJson @("acm", "describe-certificate", "--certificate-arn", ([string]$boundCertificateArn))
$acm = $certificateDetails.Certificate
if ([string]$acm.DomainName -ne $ExpectedDomain) {
    throw "Certificado ACM associado possui dominio inesperado: $($acm.DomainName)"
}
Write-Host "  HTTPS listener -> $TargetGroupName / ACM=$($acm.Status) / domain=$($acm.DomainName)" -ForegroundColor Green

Write-Host "[2/5] Confirmando 2/2 targets healthy..." -ForegroundColor Cyan
$healthResult = Invoke-AwsLocalJson @("elbv2", "describe-target-health", "--target-group-arn", $targetGroupArn)
$healthy = @($healthResult.TargetHealthDescriptions | Where-Object { [string]$_.TargetHealth.State -eq "healthy" })
if ($healthy.Count -ne 2) {
    throw "Target Group possui $($healthy.Count)/2 targets healthy. Rode .\scripts\localstack\sync-alb-targets.ps1."
}
Write-Host "  2/2 targets healthy" -ForegroundColor Green

Write-Host "[3/5] Testando transporte HTTPS pelo gateway LocalStack..." -ForegroundColor Cyan
$oldSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$dnsName = [string]$loadBalancer.DNSName
$primaryBaseUrl = "https://${dnsName}:4566"
$fallbackBaseUrl = "https://localhost.localstack.cloud:4566/_aws/elb/$LoadBalancerName"
$baseUrl = $primaryBaseUrl

try {
    try {
        $probe = Invoke-RestMethod -Uri "$baseUrl/health" -Method Get -TimeoutSec 15
    }
    catch {
        Write-Host "DNS HTTPS do ALB nao respondeu com validacao TLS; usando a URL alternativa oficial do gateway LocalStack." -ForegroundColor Yellow
        $baseUrl = $fallbackBaseUrl
        $probe = Invoke-RestMethod -Uri "$baseUrl/health" -Method Get -TimeoutSec 15
    }

    if ([string]$probe.status -ne "ok" -or [string]$probe.database -ne "ok") {
        throw "HTTPS /health respondeu sem status=ok e database=ok."
    }

    for ($i = 2; $i -le 3; $i++) {
        $health = Invoke-RestMethod -Uri "$baseUrl/health" -Method Get -TimeoutSec 15
        if ([string]$health.status -ne "ok" -or [string]$health.database -ne "ok") {
            throw "HTTPS /health falhou na tentativa $i."
        }
    }
    Write-Host "  3/3 requests HTTPS /health -> status=ok / database=ok" -ForegroundColor Green

    Write-Host "[4/5] Validando CRUD pelo caminho HTTPS -> ALB -> ECS -> RDS..." -ForegroundColor Cyan
    $testTitle = "HTTPS test $([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    $body = [ordered]@{ title = $testTitle; dueDate = $null; important = $false } | ConvertTo-Json -Compress
    $created = $null
    try {
        $created = Invoke-RestMethod -Uri "$baseUrl/api/tasks" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 15
        if ([string]::IsNullOrWhiteSpace([string]$created.id)) {
            throw "POST HTTPS nao retornou id."
        }
        $tasks = Invoke-RestMethod -Uri "$baseUrl/api/tasks" -Method Get -TimeoutSec 15
        $found = @($tasks) | Where-Object { [string]$_.id -eq [string]$created.id } | Select-Object -First 1
        if ($null -eq $found) {
            throw "Tarefa criada por HTTPS nao apareceu no GET HTTPS."
        }
        Write-Host "  POST -> RDS -> GET via HTTPS: OK" -ForegroundColor Green
    }
    finally {
        if ($null -ne $created -and -not [string]::IsNullOrWhiteSpace([string]$created.id)) {
            try {
                Invoke-RestMethod -Uri "$baseUrl/api/tasks/$($created.id)" -Method Delete -TimeoutSec 15 | Out-Null
            }
            catch {
                Write-Host "Aviso: nao foi possivel remover automaticamente a tarefa temporaria $($created.id)." -ForegroundColor Yellow
            }
        }
    }

    Write-Host "[5/5] Confirmando coexistencia HTTP + HTTPS..." -ForegroundColor Cyan
    $httpBaseUrl = "http://${dnsName}:4566"
    try {
        $httpHealth = Invoke-RestMethod -Uri "$httpBaseUrl/health" -Method Get -TimeoutSec 10
    }
    catch {
        $httpBaseUrl = "http://localhost.localstack.cloud:4566/_aws/elb/$LoadBalancerName"
        $httpHealth = Invoke-RestMethod -Uri "$httpBaseUrl/health" -Method Get -TimeoutSec 10
    }
    if ([string]$httpHealth.status -ne "ok" -or [string]$httpHealth.database -ne "ok") {
        throw "Listener HTTP deixou de responder corretamente apos habilitar HTTPS."
    }
    Write-Host "  HTTP e HTTPS respondem em paralelo: OK" -ForegroundColor Green
}
finally {
    [Net.ServicePointManager]::SecurityProtocol = $oldSecurityProtocol
}

Write-Host ""
Write-Host "HTTPS CloudTasks validado ponta a ponta." -ForegroundColor Green
Write-Host "HTTPS /health:       OK" -ForegroundColor Green
Write-Host "HTTPS -> ECS -> RDS: CRUD OK" -ForegroundColor Green
Write-Host "ACM associado:       OK" -ForegroundColor Green
Write-Host "HTTP + HTTPS:        OK" -ForegroundColor Green
Write-Host "URL testada:         $baseUrl" -ForegroundColor Green
Write-Host ""
Write-Host "Nota de paridade: no laboratorio, o TLS de rede em :4566 usa o certificado do gateway LocalStack." -ForegroundColor DarkGray
Write-Host "A associacao do certificado ACM ao listener HTTPS e validada pelo plano de controle ELBv2." -ForegroundColor DarkGray
