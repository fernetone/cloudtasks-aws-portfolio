$ErrorActionPreference = "Stop"

$VpcName = "cloudtasks-vpc"
$VpcCidr = "10.20.0.0/16"
$ProjectTag = "CloudTasks"

$container = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}"
if ($container -ne "cloudtasks-localstack") {
    throw "LocalStack nao esta em execucao. Rode .\scripts\localstack\start-localstack.ps1 primeiro."
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

function Add-Tags {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)][string]$Name
    )

    & docker exec cloudtasks-localstack awslocal ec2 create-tags `
        --resources $ResourceId `
        --tags "Key=Name,Value=$Name" "Key=Project,Value=$ProjectTag" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao aplicar tags no recurso $ResourceId."
    }
}

function Ensure-Subnet {
    param(
        [Parameter(Mandatory = $true)][string]$VpcId,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Cidr,
        [Parameter(Mandatory = $true)][string]$Az,
        [Parameter(Mandatory = $true)][bool]$Public
    )

    $all = Invoke-AwsLocalJson @("ec2", "describe-subnets", "--filters", "Name=vpc-id,Values=$VpcId")
    $existing = $all.Subnets | Where-Object {
        ($_.Tags | Where-Object { $_.Key -eq "Name" -and $_.Value -eq $Name })
    } | Select-Object -First 1

    if ($null -ne $existing) {
        Write-Host "Subnet '$Name' ja existe: $($existing.SubnetId)" -ForegroundColor DarkGray
        return $existing
    }

    Write-Host "Criando subnet '$Name' ($Cidr / $Az)..." -ForegroundColor Cyan
    $created = Invoke-AwsLocalJson @(
        "ec2", "create-subnet",
        "--vpc-id", $VpcId,
        "--cidr-block", $Cidr,
        "--availability-zone", $Az
    )
    $subnet = $created.Subnet
    Add-Tags -ResourceId $subnet.SubnetId -Name $Name

    if ($Public) {
        & docker exec cloudtasks-localstack awslocal ec2 modify-subnet-attribute `
            --subnet-id $subnet.SubnetId `
            --map-public-ip-on-launch | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao habilitar IP publico automatico em $Name."
        }
    }

    return $subnet
}

function Ensure-RouteTable {
    param(
        [Parameter(Mandatory = $true)][string]$VpcId,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $all = Invoke-AwsLocalJson @("ec2", "describe-route-tables", "--filters", "Name=vpc-id,Values=$VpcId")
    $existing = $all.RouteTables | Where-Object {
        ($_.Tags | Where-Object { $_.Key -eq "Name" -and $_.Value -eq $Name })
    } | Select-Object -First 1

    if ($null -ne $existing) {
        Write-Host "Route table '$Name' ja existe: $($existing.RouteTableId)" -ForegroundColor DarkGray
        return $existing
    }

    Write-Host "Criando route table '$Name'..." -ForegroundColor Cyan
    $created = Invoke-AwsLocalJson @("ec2", "create-route-table", "--vpc-id", $VpcId)
    $routeTable = $created.RouteTable
    Add-Tags -ResourceId $routeTable.RouteTableId -Name $Name
    return $routeTable
}

function Ensure-Association {
    param(
        [Parameter(Mandatory = $true)][string]$RouteTableId,
        [Parameter(Mandatory = $true)][string]$SubnetId
    )

    $rt = Invoke-AwsLocalJson @("ec2", "describe-route-tables", "--route-table-ids", $RouteTableId)
    $associated = $rt.RouteTables[0].Associations | Where-Object { $_.SubnetId -eq $SubnetId } | Select-Object -First 1
    if ($null -ne $associated) {
        return
    }

    & docker exec cloudtasks-localstack awslocal ec2 associate-route-table `
        --route-table-id $RouteTableId `
        --subnet-id $SubnetId | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao associar subnet $SubnetId a route table $RouteTableId."
    }
}

Write-Host "[1/6] Garantindo VPC CloudTasks..." -ForegroundColor Cyan
$vpcs = Invoke-AwsLocalJson @("ec2", "describe-vpcs")
$vpc = $vpcs.Vpcs | Where-Object {
    ($_.Tags | Where-Object { $_.Key -eq "Name" -and $_.Value -eq $VpcName })
} | Select-Object -First 1

if ($null -eq $vpc) {
    $createdVpc = Invoke-AwsLocalJson @("ec2", "create-vpc", "--cidr-block", $VpcCidr)
    $vpc = $createdVpc.Vpc
    Add-Tags -ResourceId $vpc.VpcId -Name $VpcName
    Write-Host "VPC criada: $($vpc.VpcId)" -ForegroundColor Green
}
else {
    Write-Host "VPC ja existe: $($vpc.VpcId)" -ForegroundColor DarkGray
}
$vpcId = $vpc.VpcId

Write-Host "[2/6] Garantindo seis subnets em duas AZs..." -ForegroundColor Cyan
$publicA = Ensure-Subnet -VpcId $vpcId -Name "cloudtasks-public-a" -Cidr "10.20.1.0/24" -Az "us-east-1a" -Public $true
$publicB = Ensure-Subnet -VpcId $vpcId -Name "cloudtasks-public-b" -Cidr "10.20.2.0/24" -Az "us-east-1b" -Public $true
$appA = Ensure-Subnet -VpcId $vpcId -Name "cloudtasks-app-private-a" -Cidr "10.20.11.0/24" -Az "us-east-1a" -Public $false
$appB = Ensure-Subnet -VpcId $vpcId -Name "cloudtasks-app-private-b" -Cidr "10.20.12.0/24" -Az "us-east-1b" -Public $false
$dataA = Ensure-Subnet -VpcId $vpcId -Name "cloudtasks-data-private-a" -Cidr "10.20.21.0/24" -Az "us-east-1a" -Public $false
$dataB = Ensure-Subnet -VpcId $vpcId -Name "cloudtasks-data-private-b" -Cidr "10.20.22.0/24" -Az "us-east-1b" -Public $false

Write-Host "[3/6] Garantindo Internet Gateway..." -ForegroundColor Cyan
$igws = Invoke-AwsLocalJson @("ec2", "describe-internet-gateways")
$igw = $igws.InternetGateways | Where-Object {
    ($_.Attachments | Where-Object { $_.VpcId -eq $vpcId })
} | Select-Object -First 1

if ($null -eq $igw) {
    $createdIgw = Invoke-AwsLocalJson @("ec2", "create-internet-gateway")
    $igw = $createdIgw.InternetGateway
    Add-Tags -ResourceId $igw.InternetGatewayId -Name "cloudtasks-igw"

    & docker exec cloudtasks-localstack awslocal ec2 attach-internet-gateway `
        --internet-gateway-id $igw.InternetGatewayId `
        --vpc-id $vpcId | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao anexar Internet Gateway a VPC."
    }
}
$igwId = $igw.InternetGatewayId

Write-Host "[4/6] Garantindo route tables e associacoes..." -ForegroundColor Cyan
$publicRt = Ensure-RouteTable -VpcId $vpcId -Name "cloudtasks-public-rt"
$appRt = Ensure-RouteTable -VpcId $vpcId -Name "cloudtasks-app-private-rt"
$dataRt = Ensure-RouteTable -VpcId $vpcId -Name "cloudtasks-data-private-rt"

$publicRtRefresh = Invoke-AwsLocalJson @("ec2", "describe-route-tables", "--route-table-ids", $publicRt.RouteTableId)
$hasDefaultRoute = $publicRtRefresh.RouteTables[0].Routes | Where-Object {
    $_.DestinationCidrBlock -eq "0.0.0.0/0" -and $_.GatewayId -eq $igwId
} | Select-Object -First 1

if ($null -eq $hasDefaultRoute) {
    & docker exec cloudtasks-localstack awslocal ec2 create-route `
        --route-table-id $publicRt.RouteTableId `
        --destination-cidr-block "0.0.0.0/0" `
        --gateway-id $igwId | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao criar rota publica 0.0.0.0/0."
    }
}

Ensure-Association -RouteTableId $publicRt.RouteTableId -SubnetId $publicA.SubnetId
Ensure-Association -RouteTableId $publicRt.RouteTableId -SubnetId $publicB.SubnetId
Ensure-Association -RouteTableId $appRt.RouteTableId -SubnetId $appA.SubnetId
Ensure-Association -RouteTableId $appRt.RouteTableId -SubnetId $appB.SubnetId
Ensure-Association -RouteTableId $dataRt.RouteTableId -SubnetId $dataA.SubnetId
Ensure-Association -RouteTableId $dataRt.RouteTableId -SubnetId $dataB.SubnetId

Write-Host "[5/6] Identificando security group padrao da VPC..." -ForegroundColor Cyan
$sgs = Invoke-AwsLocalJson @("ec2", "describe-security-groups", "--filters", "Name=vpc-id,Values=$vpcId")
$defaultSg = $sgs.SecurityGroups | Where-Object { $_.GroupName -eq "default" } | Select-Object -First 1
if ($null -eq $defaultSg) {
    throw "LocalStack nao retornou o security group padrao da VPC."
}

# O Docker VM Manager do EC2 no LocalStack aplica efetivamente regras de entrada
# apenas ao security group default. Por isso mantemos esse SG como runtime local.
# A separacao ALB/ECS/RDS usada em AWS real esta documentada em docs/NETWORK.md.

Write-Host "[6/6] Validando topologia criada..." -ForegroundColor Cyan
$vpcCheck = Invoke-AwsLocalJson @("ec2", "describe-vpcs", "--vpc-ids", $vpcId)
$subnetCheck = Invoke-AwsLocalJson @("ec2", "describe-subnets", "--filters", "Name=vpc-id,Values=$vpcId")
$routeCheck = Invoke-AwsLocalJson @("ec2", "describe-route-tables", "--filters", "Name=vpc-id,Values=$vpcId")

if ($vpcCheck.Vpcs.Count -ne 1) {
    throw "Validacao da VPC falhou."
}
if ($subnetCheck.Subnets.Count -lt 6) {
    throw "Validacao das subnets falhou: esperado ao menos 6, encontrado $($subnetCheck.Subnets.Count)."
}

Write-Host ""
Write-Host "Rede CloudTasks criada e validada no LocalStack." -ForegroundColor Green
Write-Host "VPC:              $vpcId ($VpcCidr)"
Write-Host "Internet Gateway: $igwId"
Write-Host "Publicas:          $($publicA.SubnetId), $($publicB.SubnetId)"
Write-Host "App privadas:      $($appA.SubnetId), $($appB.SubnetId)"
Write-Host "Dados privadas:    $($dataA.SubnetId), $($dataB.SubnetId)"
Write-Host "Security Group:    $($defaultSg.GroupId) (default, compatibilidade EC2 LocalStack)"
Write-Host "Route tables:      $($routeCheck.RouteTables.Count) detectadas na VPC"
