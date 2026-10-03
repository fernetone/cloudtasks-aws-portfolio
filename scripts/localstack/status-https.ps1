$ErrorActionPreference = "Stop"

$LoadBalancerName = "cloudtasks-alb"
$TargetGroupName = "cloudtasks-tg"

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
    throw "Listener HTTPS -> '$TargetGroupName' nao encontrado. Rode .\scripts\localstack\create-https.ps1."
}

$certificateArn = @($httpsListener.Certificates | ForEach-Object { [string]$_.CertificateArn }) | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace([string]$certificateArn)) {
    try {
        $listenerCertificates = Invoke-AwsLocalJson @("elbv2", "describe-listener-certificates", "--listener-arn", ([string]$httpsListener.ListenerArn))
        $certificateArn = @($listenerCertificates.Certificates | ForEach-Object { [string]$_.CertificateArn }) | Select-Object -First 1
    }
    catch {
        $certificateArn = $null
    }
}
if ([string]::IsNullOrWhiteSpace([string]$certificateArn)) {
    throw "Listener HTTPS nao possui certificado associado."
}
$certificateDetails = Invoke-AwsLocalJson @("acm", "describe-certificate", "--certificate-arn", $certificateArn)
$acm = $certificateDetails.Certificate

$targetHealth = Invoke-AwsLocalJson @("elbv2", "describe-target-health", "--target-group-arn", $targetGroupArn)
$healthyCount = @($targetHealth.TargetHealthDescriptions | Where-Object { [string]$_.TargetHealth.State -eq "healthy" }).Count

Write-Host "CloudTasks HTTPS/ACM status" -ForegroundColor Cyan
Write-Host "ALB:         $($loadBalancer.LoadBalancerName) / $($loadBalancer.State.Code)"
Write-Host "DNS:         $($loadBalancer.DNSName)"
Write-Host "HTTPS URL:   https://$($loadBalancer.DNSName):4566"
Write-Host "Listener:    HTTPS:$($httpsListener.Port) runtime LocalStack / logico :443"
Write-Host "SSL policy:  $($httpsListener.SslPolicy)"
Write-Host "Forward:     $TargetGroupName"
Write-Host "Targets:     $healthyCount/2 healthy"
Write-Host "ACM domain:  $($acm.DomainName)"
Write-Host "ACM status:  $($acm.Status)"
Write-Host "ACM type:    $($acm.Type)"
Write-Host "ACM ARN:     $certificateArn"
Write-Host "TLS runtime: certificado de gateway do LocalStack em :4566; associacao ACM validada no plano de controle."
