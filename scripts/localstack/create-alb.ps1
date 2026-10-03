$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ecs-runtime-context.ps1")
$runtimeContext = Get-CloudTasksEcsRuntime
$ClusterName = [string]$runtimeContext.ClusterName
$ServiceName = [string]$runtimeContext.ServiceName
$LoadBalancerName = "cloudtasks-alb"
$TargetGroupName = "cloudtasks-tg"
$ContainerPort = 3000
$DockerNetwork = "cloudtasks-localstack-network"
$VpcName = "cloudtasks-vpc"
$PublicSubnetNames = @("cloudtasks-public-a", "cloudtasks-public-b")
$Region = "us-east-1"

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $projectRoot

$container = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}"
if ($container -ne "cloudtasks-localstack") {
    throw "LocalStack nao esta em execucao. Rode .\scripts\localstack\start-localstack.ps1 primeiro."
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

Write-Host "[1/7] Validando ECS com duas replicas RUNNING..." -ForegroundColor Cyan
$serviceResult = Invoke-AwsLocalJson @("ecs", "describe-services", "--cluster", $ClusterName, "--services", $ServiceName)
$service = $serviceResult.services | Select-Object -First 1
if ($null -eq $service -or [string]$service.status -ne "ACTIVE") {
    throw "ECS service '$ServiceName' nao esta ativo. Rode .\scripts\localstack\create-ecs.ps1 primeiro."
}
if ([int]$service.runningCount -ne 2 -or [int]$service.pendingCount -ne 0) {
    throw "ECS service ainda nao esta estavel em 2/2 replicas. Rode .\scripts\localstack\test-ecs.ps1 antes de criar o ALB."
}

Write-Host "[2/7] Localizando VPC, subnets publicas e security group..." -ForegroundColor Cyan
$vpcs = Invoke-AwsLocalJson @("ec2", "describe-vpcs", "--filters", "Name=tag:Name,Values=$VpcName")
$vpc = @($vpcs.Vpcs) | Select-Object -First 1
if ($null -eq $vpc) {
    throw "VPC '$VpcName' nao encontrada. Rode .\scripts\localstack\create-network.ps1."
}
$vpcId = [string]$vpc.VpcId

$subnetsResult = Invoke-AwsLocalJson @("ec2", "describe-subnets", "--filters", "Name=vpc-id,Values=$vpcId")
$publicSubnetIds = @()
foreach ($name in $PublicSubnetNames) {
    $subnet = @($subnetsResult.Subnets) | Where-Object {
        $tag = @($_.Tags) | Where-Object { $_.Key -eq "Name" } | Select-Object -First 1
        $null -ne $tag -and [string]$tag.Value -eq $name
    } | Select-Object -First 1
    if ($null -eq $subnet) {
        throw "Subnet publica '$name' nao encontrada na VPC $vpcId."
    }
    $publicSubnetIds += [string]$subnet.SubnetId
}

$securityGroups = Invoke-AwsLocalJson @("ec2", "describe-security-groups", "--filters", "Name=vpc-id,Values=$vpcId", "Name=group-name,Values=default")
$defaultSecurityGroup = @($securityGroups.SecurityGroups) | Select-Object -First 1
if ($null -eq $defaultSecurityGroup) {
    throw "Security group default da VPC $vpcId nao encontrado."
}
$securityGroupId = [string]$defaultSecurityGroup.GroupId

Write-Host "[3/7] Garantindo Target Group HTTP /health..." -ForegroundColor Cyan
$targetGroups = Invoke-AwsLocalJson @("elbv2", "describe-target-groups")
$targetGroup = @($targetGroups.TargetGroups) | Where-Object { [string]$_.TargetGroupName -eq $TargetGroupName } | Select-Object -First 1

if ($null -ne $targetGroup -and [string]$targetGroup.VpcId -ne $vpcId) {
    Write-Host "Target Group pertence a outra VPC; removendo recurso antigo do runtime local..." -ForegroundColor Yellow
    $loadBalancersOld = Invoke-AwsLocalJson @("elbv2", "describe-load-balancers")
    $oldLb = @($loadBalancersOld.LoadBalancers) | Where-Object { [string]$_.LoadBalancerName -eq $LoadBalancerName } | Select-Object -First 1
    if ($null -ne $oldLb) {
        $null = Invoke-AwsLocalJson @("elbv2", "delete-load-balancer", "--load-balancer-arn", ([string]$oldLb.LoadBalancerArn))
        Start-Sleep -Seconds 2
    }
    $null = Invoke-AwsLocalJson @("elbv2", "delete-target-group", "--target-group-arn", ([string]$targetGroup.TargetGroupArn))
    $targetGroup = $null
}

if ($null -eq $targetGroup) {
    $createdTargetGroup = Invoke-AwsLocalJson @(
        "elbv2", "create-target-group",
        "--name", $TargetGroupName,
        "--protocol", "HTTP",
        "--port", ([string]$ContainerPort),
        "--vpc-id", $vpcId,
        "--target-type", "ip",
        "--health-check-protocol", "HTTP",
        "--health-check-port", "traffic-port",
        "--health-check-path", "/health",
        "--health-check-interval-seconds", "5",
        "--health-check-timeout-seconds", "3",
        "--healthy-threshold-count", "2",
        "--unhealthy-threshold-count", "2",
        "--matcher", "HttpCode=200"
    )
    $targetGroup = @($createdTargetGroup.TargetGroups) | Select-Object -First 1
}
$targetGroupArn = [string]$targetGroup.TargetGroupArn

Write-Host "[4/7] Sincronizando as duas tasks ECS como targets IP..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot "sync-alb-targets.ps1")
if ($LASTEXITCODE -ne 0) {
    throw "Falha ao sincronizar targets ECS com o Target Group."
}

Write-Host "[5/7] Garantindo Application Load Balancer nas subnets publicas..." -ForegroundColor Cyan
$loadBalancers = Invoke-AwsLocalJson @("elbv2", "describe-load-balancers")
$loadBalancer = @($loadBalancers.LoadBalancers) | Where-Object { [string]$_.LoadBalancerName -eq $LoadBalancerName } | Select-Object -First 1

if ($null -eq $loadBalancer) {
    $createdLoadBalancer = Invoke-AwsLocalJson -Arguments (@(
        "elbv2", "create-load-balancer",
        "--name", $LoadBalancerName,
        "--type", "application",
        "--scheme", "internet-facing",
        "--security-groups", $securityGroupId,
        "--subnets"
    ) + $publicSubnetIds)
    $loadBalancer = @($createdLoadBalancer.LoadBalancers) | Select-Object -First 1
}
$loadBalancerArn = [string]$loadBalancer.LoadBalancerArn
$dnsName = [string]$loadBalancer.DNSName

Write-Host "[6/7] Garantindo listener HTTP :80 -> Target Group..." -ForegroundColor Cyan
$listenersResult = Invoke-AwsLocalJson @("elbv2", "describe-listeners", "--load-balancer-arn", $loadBalancerArn)
$listener = @($listenersResult.Listeners) | Where-Object {
    Test-ListenerForTargetGroup -Listener $_ -TargetGroupArn $targetGroupArn
} | Select-Object -First 1

# No gateway compartilhado do LocalStack, um listener criado logicamente em :80
# pode ser devolvido por describe-listeners como Port=4566. Se a acao forward
# ainda nao apontar para o TG atual, reutilizamos o unico listener HTTP do ALB.
if ($null -eq $listener) {
    $listener = @($listenersResult.Listeners) | Where-Object { [string]$_.Protocol -eq "HTTP" } | Select-Object -First 1
}

$forwardAction = "Type=forward,TargetGroupArn=$targetGroupArn"

if ($null -eq $listener) {
    $createdListener = Invoke-AwsLocalJson @(
        "elbv2", "create-listener",
        "--load-balancer-arn", $loadBalancerArn,
        "--protocol", "HTTP",
        "--port", "80",
        "--default-actions", $forwardAction
    )
    $listener = @($createdListener.Listeners) | Select-Object -First 1
}
else {
    $modifiedListener = Invoke-AwsLocalJson @(
        "elbv2", "modify-listener",
        "--listener-arn", ([string]$listener.ListenerArn),
        "--default-actions", $forwardAction
    )
    $listener = @($modifiedListener.Listeners) | Select-Object -First 1
}

if (-not (Test-ListenerForTargetGroup -Listener $listener -TargetGroupArn $targetGroupArn)) {
    throw "Listener HTTP existe, mas a acao forward para '$TargetGroupName' nao foi confirmada."
}

Write-Host "[7/7] Aguardando os dois targets ficarem healthy..." -ForegroundColor Cyan
$healthyTargets = @()
for ($attempt = 1; $attempt -le 24; $attempt++) {
    $healthResult = Invoke-AwsLocalJson @("elbv2", "describe-target-health", "--target-group-arn", $targetGroupArn)
    $descriptions = @($healthResult.TargetHealthDescriptions)
    $healthyTargets = @($descriptions | Where-Object { [string]$_.TargetHealth.State -eq "healthy" })
    if ($descriptions.Count -eq 2 -and $healthyTargets.Count -eq 2) {
        break
    }
    if ($attempt % 4 -eq 0) {
        Write-Host "  healthy=$($healthyTargets.Count)/2" -ForegroundColor DarkGray
        foreach ($target in $descriptions) {
            Write-Host "    $($target.Target.Id):$($target.Target.Port) -> $($target.TargetHealth.State) $($target.TargetHealth.Reason)" -ForegroundColor DarkGray
        }
    }
    Start-Sleep -Seconds 5
}

if ($healthyTargets.Count -ne 2) {
    throw "Target Group nao chegou a 2 targets healthy no tempo esperado. Rode .\scripts\localstack\status-alb.ps1 para diagnostico."
}

Write-Host ""
Write-Host "ALB CloudTasks criado e validado no LocalStack." -ForegroundColor Green
Write-Host "Load Balancer:   $LoadBalancerName" -ForegroundColor Green
Write-Host "DNS local:       $dnsName" -ForegroundColor Green
Write-Host "URL local:       http://${dnsName}:4566" -ForegroundColor Green
Write-Host "Listener:        HTTP :80 logico / runtime LocalStack :$([int]$listener.Port)" -ForegroundColor Green
Write-Host "Gateway local:   :4566" -ForegroundColor Green
Write-Host "Target Group:    $TargetGroupName" -ForegroundColor Green
Write-Host "Targets healthy: 2/2" -ForegroundColor Green
Write-Host "Health path:     /health" -ForegroundColor Green
Write-Host ""
Write-Host "Paridade local:" -ForegroundColor Yellow
Write-Host "No LocalStack Docker executor nao existem ECS container instances EC2 reais." -ForegroundColor DarkGray
Write-Host "Por isso o Target Group local usa target-type=ip e registra os IPs dos containers ECS na porta 3000." -ForegroundColor DarkGray
Write-Host "Em AWS real com ECS/EC2 + bridge/hostPort dinamico, o desenho alvo usa target-type=instance e registro automatico pelo ECS." -ForegroundColor DarkGray
Write-Host "O ELB do LocalStack nao possui persistencia de estado; apos restart, rode create-alb.ps1 novamente." -ForegroundColor DarkGray
