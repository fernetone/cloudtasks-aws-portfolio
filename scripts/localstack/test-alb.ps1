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

    if ([string]$Listener.Protocol -ne "HTTP") {
        return $false
    }

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

function Wait-ForHealthyTargets {
    param(
        [Parameter(Mandatory = $true)][string]$TargetGroupArn,
        [Parameter(Mandatory = $true)][int]$ExpectedCount,
        [int]$Attempts = 24
    )

    $healthy = @()
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $healthResult = Invoke-AwsLocalJson @("elbv2", "describe-target-health", "--target-group-arn", $TargetGroupArn)
        $all = @($healthResult.TargetHealthDescriptions)
        $healthy = @($all | Where-Object { [string]$_.TargetHealth.State -eq "healthy" })
        if ($healthy.Count -eq $ExpectedCount) {
            return $healthy
        }
        Start-Sleep -Seconds 5
    }
    return $healthy
}

Write-Host "[1/5] Validando ALB, listener e Target Group..." -ForegroundColor Cyan
$loadBalancers = Invoke-AwsLocalJson @("elbv2", "describe-load-balancers")
$loadBalancer = @($loadBalancers.LoadBalancers) | Where-Object { [string]$_.LoadBalancerName -eq $LoadBalancerName } | Select-Object -First 1
if ($null -eq $loadBalancer) {
    throw "ALB '$LoadBalancerName' nao encontrado. Rode .\scripts\localstack\create-alb.ps1."
}

$targetGroups = Invoke-AwsLocalJson @("elbv2", "describe-target-groups")
$targetGroup = @($targetGroups.TargetGroups) | Where-Object { [string]$_.TargetGroupName -eq $TargetGroupName } | Select-Object -First 1
if ($null -eq $targetGroup) {
    throw "Target Group '$TargetGroupName' nao encontrado."
}
$targetGroupArn = [string]$targetGroup.TargetGroupArn

$listeners = Invoke-AwsLocalJson @("elbv2", "describe-listeners", "--load-balancer-arn", ([string]$loadBalancer.LoadBalancerArn))
$listener = @($listeners.Listeners) | Where-Object {
    Test-ListenerForTargetGroup -Listener $_ -TargetGroupArn $targetGroupArn
} | Select-Object -First 1
if ($null -eq $listener) {
    $reported = @($listeners.Listeners | ForEach-Object { "$($_.Protocol):$($_.Port)" }) -join ", "
    throw "Listener HTTP com forward para '$TargetGroupName' nao encontrado. Listeners reportados pelo LocalStack: $reported"
}
$reportedListenerPort = [int]$listener.Port
Write-Host "  Listener validado por protocolo+forward: HTTP (logico :80 / runtime LocalStack :$reportedListenerPort)" -ForegroundColor Green

Write-Host "[2/5] Confirmando dois targets healthy..." -ForegroundColor Cyan
$healthy = @(Wait-ForHealthyTargets -TargetGroupArn $targetGroupArn -ExpectedCount 2)
if ($healthy.Count -ne 2) {
    throw "Target Group nao possui 2 targets healthy. Rode .\scripts\localstack\sync-alb-targets.ps1 e tente novamente."
}
foreach ($item in $healthy) {
    Write-Host "  $($item.Target.Id):$($item.Target.Port) -> healthy" -ForegroundColor Green
}

$dnsName = [string]$loadBalancer.DNSName
$primaryBaseUrl = "http://${dnsName}:4566"
$fallbackBaseUrl = "http://localhost.localstack.cloud:4566/_aws/elb/$LoadBalancerName"
$baseUrl = $primaryBaseUrl

Write-Host "[3/5] Testando trafego HTTP pelo ALB..." -ForegroundColor Cyan
try {
    $probe = Invoke-RestMethod -Uri "$baseUrl/health" -Method Get -TimeoutSec 10
}
catch {
    Write-Host "DNS ELB local nao respondeu; usando a URL alternativa oficial do gateway LocalStack." -ForegroundColor Yellow
    $baseUrl = $fallbackBaseUrl
    $probe = Invoke-RestMethod -Uri "$baseUrl/health" -Method Get -TimeoutSec 10
}
if ([string]$probe.status -ne "ok" -or [string]$probe.database -ne "ok") {
    throw "ALB respondeu /health sem database=ok no probe inicial."
}
for ($i = 2; $i -le 5; $i++) {
    $health = Invoke-RestMethod -Uri "$baseUrl/health" -Method Get -TimeoutSec 10
    if ([string]$health.status -ne "ok" -or [string]$health.database -ne "ok") {
        throw "ALB respondeu /health sem database=ok na tentativa $i."
    }
}
Write-Host "  5/5 requests /health -> status=ok / database=ok" -ForegroundColor Green

Write-Host "[4/5] Validando CRUD pelo caminho ALB -> ECS -> RDS..." -ForegroundColor Cyan
$testTitle = "ALB test $([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$body = [ordered]@{ title = $testTitle; dueDate = $null; important = $false } | ConvertTo-Json -Compress
$created = $null
try {
    $created = Invoke-RestMethod -Uri "$baseUrl/api/tasks" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 10
    if ([string]::IsNullOrWhiteSpace([string]$created.id)) {
        throw "POST via ALB nao retornou id."
    }
    $tasks = Invoke-RestMethod -Uri "$baseUrl/api/tasks" -Method Get -TimeoutSec 10
    $found = @($tasks) | Where-Object { [string]$_.id -eq [string]$created.id } | Select-Object -First 1
    if ($null -eq $found) {
        throw "Tarefa criada via ALB nao foi encontrada no GET via ALB."
    }
    Write-Host "  POST -> RDS -> GET via ALB: OK" -ForegroundColor Green
}
finally {
    if ($null -ne $created -and -not [string]::IsNullOrWhiteSpace([string]$created.id)) {
        try {
            Invoke-RestMethod -Uri "$baseUrl/api/tasks/$($created.id)" -Method Delete -TimeoutSec 10 | Out-Null
        }
        catch {
            Write-Host "Aviso: nao foi possivel remover automaticamente a tarefa temporaria $($created.id)." -ForegroundColor Yellow
        }
    }
}

Write-Host "[5/5] Testando continuidade com um target temporariamente removido..." -ForegroundColor Cyan
$removed = $healthy[0].Target
$removedSpec = "Id=$([string]$removed.Id),Port=$([int]$removed.Port),AvailabilityZone=all"
try {
    $null = Invoke-AwsLocalJson @("elbv2", "deregister-targets", "--target-group-arn", $targetGroupArn, "--targets", $removedSpec)
    $remaining = @(Wait-ForHealthyTargets -TargetGroupArn $targetGroupArn -ExpectedCount 1 -Attempts 12)
    if ($remaining.Count -ne 1) {
        throw "Nao foi possivel estabilizar o Target Group com um unico target para o teste de failover."
    }

    for ($i = 1; $i -le 3; $i++) {
        $health = Invoke-RestMethod -Uri "$baseUrl/health" -Method Get -TimeoutSec 10
        if ([string]$health.status -ne "ok" -or [string]$health.database -ne "ok") {
            throw "ALB falhou durante o teste com um target removido."
        }
    }
    Write-Host "  ALB continuou respondendo com 1/2 target: OK" -ForegroundColor Green
}
finally {
    $null = Invoke-AwsLocalJson @("elbv2", "register-targets", "--target-group-arn", $targetGroupArn, "--targets", $removedSpec)
}

$restored = @(Wait-ForHealthyTargets -TargetGroupArn $targetGroupArn -ExpectedCount 2)
if ($restored.Count -ne 2) {
    throw "Target removido no teste nao retornou a healthy. Rode .\scripts\localstack\sync-alb-targets.ps1."
}

Write-Host ""
Write-Host "ALB CloudTasks validado ponta a ponta." -ForegroundColor Green
Write-Host "Target Group:       2/2 healthy" -ForegroundColor Green
Write-Host "ALB /health:        OK" -ForegroundColor Green
Write-Host "ALB -> ECS -> RDS:  CRUD OK" -ForegroundColor Green
Write-Host "Failover 1/2:       OK" -ForegroundColor Green
Write-Host "Targets restaurados: 2/2 healthy" -ForegroundColor Green
Write-Host "URL local:          $baseUrl" -ForegroundColor Green
