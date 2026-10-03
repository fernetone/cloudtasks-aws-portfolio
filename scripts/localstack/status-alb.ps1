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

function Test-ListenerForTargetGroup {
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

$loadBalancers = Invoke-AwsLocalJson @("elbv2", "describe-load-balancers")
$loadBalancer = @($loadBalancers.LoadBalancers) | Where-Object { [string]$_.LoadBalancerName -eq $LoadBalancerName } | Select-Object -First 1
if ($null -eq $loadBalancer) {
    throw "ALB '$LoadBalancerName' nao encontrado. Como ELB nao persiste no LocalStack, rode .\scripts\localstack\create-alb.ps1 apos cada restart."
}

$targetGroups = Invoke-AwsLocalJson @("elbv2", "describe-target-groups")
$targetGroup = @($targetGroups.TargetGroups) | Where-Object { [string]$_.TargetGroupName -eq $TargetGroupName } | Select-Object -First 1
if ($null -eq $targetGroup) {
    throw "Target Group '$TargetGroupName' nao encontrado."
}

$listeners = Invoke-AwsLocalJson @("elbv2", "describe-listeners", "--load-balancer-arn", ([string]$loadBalancer.LoadBalancerArn))
$health = Invoke-AwsLocalJson @("elbv2", "describe-target-health", "--target-group-arn", ([string]$targetGroup.TargetGroupArn))

Write-Host "CloudTasks ALB status" -ForegroundColor Cyan
Write-Host "ALB:        $($loadBalancer.LoadBalancerName)"
Write-Host "State:      $($loadBalancer.State.Code)"
Write-Host "Scheme:     $($loadBalancer.Scheme)"
Write-Host "DNS:        $($loadBalancer.DNSName)"
Write-Host "URL local:  http://$($loadBalancer.DNSName):4566"
Write-Host "TG:         $($targetGroup.TargetGroupName) / targetType=$($targetGroup.TargetType) / port=$($targetGroup.Port)"
Write-Host "Health:     $($targetGroup.HealthCheckPath)"
Write-Host "Listeners:  $(@($listeners.Listeners).Count)"
foreach ($listener in @($listeners.Listeners)) {
    $forwarding = Test-ListenerForTargetGroup -Listener $listener -TargetGroupArn ([string]$targetGroup.TargetGroupArn)
    $logicalPort = [int]$listener.Port
    if ([string]$listener.Protocol -eq "HTTP") { $logicalPort = 80 }
    if ([string]$listener.Protocol -eq "HTTPS") { $logicalPort = 443 }
    if ($forwarding) {
        Write-Host "- $($listener.Protocol):$($listener.Port) runtime LocalStack / logico :$logicalPort / forward=$TargetGroupName / $($listener.ListenerArn)"
    }
    else {
        Write-Host "- $($listener.Protocol):$($listener.Port) / $($listener.ListenerArn)"
    }
}
Write-Host "Targets:"
foreach ($item in @($health.TargetHealthDescriptions)) {
    $reason = [string]$item.TargetHealth.Reason
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "-" }
    Write-Host "- $($item.Target.Id):$($item.Target.Port) -> $($item.TargetHealth.State) / $reason"
}
