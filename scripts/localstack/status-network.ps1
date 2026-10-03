$ErrorActionPreference = "Stop"

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
    return (($output -join "`n") | ConvertFrom-Json)
}

$vpcs = Invoke-AwsLocalJson @("ec2", "describe-vpcs")
$vpc = $vpcs.Vpcs | Where-Object {
    ($_.Tags | Where-Object { $_.Key -eq "Name" -and $_.Value -eq "cloudtasks-vpc" })
} | Select-Object -First 1

if ($null -eq $vpc) {
    Write-Host "A VPC cloudtasks-vpc ainda nao existe." -ForegroundColor Yellow
    exit 1
}

$vpcId = $vpc.VpcId
$subnets = Invoke-AwsLocalJson @("ec2", "describe-subnets", "--filters", "Name=vpc-id,Values=$vpcId")
$routeTables = Invoke-AwsLocalJson @("ec2", "describe-route-tables", "--filters", "Name=vpc-id,Values=$vpcId")
$igws = Invoke-AwsLocalJson @("ec2", "describe-internet-gateways")
$sgs = Invoke-AwsLocalJson @("ec2", "describe-security-groups", "--filters", "Name=vpc-id,Values=$vpcId")

Write-Host "CloudTasks network status" -ForegroundColor Cyan
Write-Host "VPC: $vpcId / $($vpc.CidrBlock)" -ForegroundColor Green
Write-Host ""
Write-Host "Subnets:" -ForegroundColor Cyan
$subnets.Subnets | Sort-Object AvailabilityZone, CidrBlock | ForEach-Object {
    $name = ($_.Tags | Where-Object { $_.Key -eq "Name" } | Select-Object -First 1).Value
    Write-Host ("- {0,-28} {1,-18} {2,-12} {3}" -f $name, $_.SubnetId, $_.AvailabilityZone, $_.CidrBlock)
}

Write-Host ""
Write-Host "Route tables: $($routeTables.RouteTables.Count)" -ForegroundColor Cyan
$routeTables.RouteTables | ForEach-Object {
    $name = ($_.Tags | Where-Object { $_.Key -eq "Name" } | Select-Object -First 1).Value
    if ([string]::IsNullOrWhiteSpace($name)) { $name = "main/default" }
    Write-Host "- $name / $($_.RouteTableId)"
}

$attachedIgw = $igws.InternetGateways | Where-Object {
    ($_.Attachments | Where-Object { $_.VpcId -eq $vpcId })
} | Select-Object -First 1
Write-Host ""
Write-Host "Internet Gateway: $($attachedIgw.InternetGatewayId)" -ForegroundColor Cyan
Write-Host "Security groups na VPC: $($sgs.SecurityGroups.Count)" -ForegroundColor Cyan
$sgs.SecurityGroups | ForEach-Object { Write-Host "- $($_.GroupName) / $($_.GroupId)" }
