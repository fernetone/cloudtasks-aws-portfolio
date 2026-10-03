param(
    [ValidateRange(0, 3)][int]$RuntimeRecoveryAttempt = 0,
    [string]$ImageUriOverride = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ecs-runtime-context.ps1")
. (Join-Path $PSScriptRoot "rds-runtime-context.ps1")
$TaskFamily = "cloudtasks"
$ContainerName = "cloudtasks-app"
$RepositoryName = "cloudtasks"
$SecretName = "cloudtasks/database"
$rdsRuntimeContext = Get-CloudTasksRdsRuntime
$DbIdentifier = [string]$rdsRuntimeContext.DbIdentifier
$ExecutionRoleName = "cloudtasks-ecs-task-execution-role"
$LogGroup = "/cloudtasks/ecs"
$DesiredCount = 2
$Region = "us-east-1"
$AccountId = "000000000000"

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $projectRoot

$container = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}"
if ($container -ne "cloudtasks-localstack") {
    throw "LocalStack nao esta em execucao. Rode .\scripts\localstack\start-localstack.ps1 primeiro."
}

$runtimeBeforeSessionCheck = Get-CloudTasksEcsRuntime
$runtimeContext = Ensure-CloudTasksEcsRuntimeForCurrentSession
$ClusterName = [string]$runtimeContext.ClusterName
$ServiceName = [string]$runtimeContext.ServiceName
if ([string]$runtimeBeforeSessionCheck.ClusterName -ne $ClusterName) {
    Write-Host "Sessao Docker LocalStack nova ou metadata ECS legado detectado." -ForegroundColor Yellow
    Write-Host "Usando namespace ECS efemero seguro para esta sessao: $ClusterName" -ForegroundColor Yellow
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

function Invoke-AwsLocalWithJsonFile {
    param(
        [Parameter(Mandatory = $true)][string[]]$ArgumentsBeforeFile,
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ValidateSet("cli-input-json", "assume-role-policy-document", "policy-document")][string]$FileArgument
    )

    $hostTemp = [System.IO.Path]::GetTempFileName()
    $containerTemp = "/tmp/cloudtasks-$([Guid]::NewGuid().ToString('N')).json"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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
            throw "Nao foi possivel copiar JSON temporario para o LocalStack."
        }

        $arguments = @($ArgumentsBeforeFile) + @("--$FileArgument", "file://$containerTemp")
        return Invoke-AwsLocalJson -Arguments $arguments
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


function Test-StaleEcsControlPlane {
    $clusters = Invoke-AwsLocalJson @("ecs", "list-clusters")
    $clusterArn = @($clusters.clusterArns) | Where-Object { [string]$_ -like "*/$ClusterName" } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace([string]$clusterArn)) {
        return $false
    }

    $services = Invoke-AwsLocalJson @("ecs", "list-services", "--cluster", $ClusterName)
    $serviceArn = @($services.serviceArns) | Where-Object { [string]$_ -like "*/$ServiceName" } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace([string]$serviceArn)) {
        return $false
    }

    $runningDocker = @(docker ps --filter "name=ls-ecs-$ClusterName" --filter "status=running" --format "{{.ID}}")
    if ($runningDocker.Count -gt 0) {
        return $false
    }

    $described = Invoke-AwsLocalJson @("ecs", "describe-services", "--cluster", $ClusterName, "--services", $ServiceName)
    $service = @($described.services) | Select-Object -First 1
    if ($null -eq $service) {
        return $false
    }

    # The ECS control plane can be restored from a snapshot while the child Docker
    # runtime cannot be restored with equivalent identity. Reusing such a service can
    # leave tasks permanently PENDING or containers stuck in Created state.
    return $true
}

function Repair-StaleEcsControlPlane {
    Write-Host "ECS foi encontrado sem runtime Docker correspondente." -ForegroundColor Yellow
    Write-Host "Aplicando recuperacao por novo namespace ECS; dados e demais servicos serao preservados..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot "repair-ecs-runtime.ps1")
}

function Get-DatabaseState {
    $instances = Invoke-AwsLocalJson @("rds", "describe-db-instances")
    return $instances.DBInstances | Where-Object { $_.DBInstanceIdentifier -eq $DbIdentifier } | Select-Object -First 1
}

function Get-SecretMetadata {
    $secrets = Invoke-AwsLocalJson @("secretsmanager", "list-secrets")
    return $secrets.SecretList | Where-Object { $_.Name -eq $SecretName } | Select-Object -First 1
}

if (Test-StaleEcsControlPlane) {
    if ($RuntimeRecoveryAttempt -ge 3) {
        throw "ECS continuou inconsistente apos 3 rotacoes de runtime. Interrompendo para evitar loop."
    }
    Repair-StaleEcsControlPlane
    & $PSCommandPath -ImageUriOverride $ImageUriOverride -RuntimeRecoveryAttempt ($RuntimeRecoveryAttempt + 1)
    return
}

Write-Host "[1/9] Validando RDS PostgreSQL e Secrets Manager..." -ForegroundColor Cyan
$db = Get-DatabaseState
$secretMeta = Get-SecretMetadata
$databaseNeedsSync = $false

if ($null -eq $db -or $null -eq $secretMeta) {
    $databaseNeedsSync = $true
}
elseif ($db.DBInstanceStatus -ne "available" -or $null -eq $db.Endpoint) {
    $databaseNeedsSync = $true
}
else {
    $secretValue = Invoke-AwsLocalJson @("secretsmanager", "get-secret-value", "--secret-id", $SecretName)
    try {
        $secretPayload = [string]$secretValue.SecretString | ConvertFrom-Json -ErrorAction Stop
        if ([string]$secretPayload.host -ne [string]$db.Endpoint.Address -or [int]$secretPayload.port -ne [int]$db.Endpoint.Port) {
            $databaseNeedsSync = $true
        }
    }
    catch {
        $databaseNeedsSync = $true
    }
}

if ($databaseNeedsSync) {
    Write-Host "Banco/secret precisam ser criados ou sincronizados. Executando create-database.ps1..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot "create-database.ps1")
    if ($LASTEXITCODE -ne 0) {
        throw "Nao foi possivel preparar o RDS/Secrets Manager."
    }
    $rdsRuntimeContext = Get-CloudTasksRdsRuntime
    $DbIdentifier = [string]$rdsRuntimeContext.DbIdentifier
    $db = Get-DatabaseState
    $secretMeta = Get-SecretMetadata
}
else {
    Write-Host "RDS available e secret sincronizado com o endpoint atual." -ForegroundColor DarkGray
}

if ($null -eq $db -or $db.DBInstanceStatus -ne "available" -or $null -eq $secretMeta) {
    throw "RDS/Secrets Manager nao ficaram prontos para o ECS."
}
$secretArn = [string]$secretMeta.ARN

Write-Host "[2/9] Garantindo ECR e imagem CloudTasks..." -ForegroundColor Cyan
$repositories = Invoke-AwsLocalJson @("ecr", "describe-repositories")
$repository = $repositories.repositories | Where-Object { $_.repositoryName -eq $RepositoryName } | Select-Object -First 1
if ($null -eq $repository) {
    Write-Host "Repositorio ECR nao existe neste snapshot; criando..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot "create-ecr.ps1") -RepositoryName $RepositoryName
    if ($LASTEXITCODE -ne 0) {
        throw "Nao foi possivel criar o ECR local."
    }
    $repositories = Invoke-AwsLocalJson @("ecr", "describe-repositories")
    $repository = $repositories.repositories | Where-Object { $_.repositoryName -eq $RepositoryName } | Select-Object -First 1
}

$imageUri = $null
if (-not [string]::IsNullOrWhiteSpace($ImageUriOverride)) {
    $repositoryUri = [string]$repository.repositoryUri
    if (-not $ImageUriOverride.StartsWith("${repositoryUri}:", [System.StringComparison]::Ordinal)) {
        throw "ImageUriOverride nao pertence ao repositorio ECR '$RepositoryName'."
    }

    $overrideTag = $ImageUriOverride.Substring($repositoryUri.Length + 1)
    if ([string]::IsNullOrWhiteSpace($overrideTag)) {
        throw "ImageUriOverride nao contem uma tag valida."
    }

    $overrideLookup = Invoke-AwsLocalJson @(
        "ecr", "describe-images",
        "--repository-name", $RepositoryName,
        "--image-ids", "imageTag=$overrideTag"
    )
    $overrideImage = @($overrideLookup.imageDetails) | Select-Object -First 1
    if ($null -eq $overrideImage) {
        throw "A imagem solicitada pelo CI/CD nao foi encontrada no ECR: $ImageUriOverride"
    }

    $imageUri = $ImageUriOverride
    Write-Host "Imagem selecionada pelo CI/CD: $imageUri" -ForegroundColor DarkGray
}
else {
    $images = Invoke-AwsLocalJson @("ecr", "describe-images", "--repository-name", $RepositoryName)
    $imageDetail = $images.imageDetails |
        Where-Object { $null -ne $_.imageTags -and @($_.imageTags).Count -gt 0 } |
        Sort-Object { [double]$_.imagePushedAt } -Descending |
        Select-Object -First 1

    if ($null -eq $imageDetail) {
        Write-Host "ECR existe, mas nao possui imagem. Construindo e publicando uma imagem imutavel..." -ForegroundColor Yellow
        & (Join-Path $PSScriptRoot "push-ecr-image.ps1") -RepositoryName $RepositoryName
        if ($LASTEXITCODE -ne 0) {
            throw "Nao foi possivel publicar a imagem CloudTasks no ECR local."
        }
        $images = Invoke-AwsLocalJson @("ecr", "describe-images", "--repository-name", $RepositoryName)
        $imageDetail = $images.imageDetails |
            Where-Object { $null -ne $_.imageTags -and @($_.imageTags).Count -gt 0 } |
            Sort-Object { [double]$_.imagePushedAt } -Descending |
            Select-Object -First 1
    }

    if ($null -eq $imageDetail) {
        throw "Nenhuma imagem versionada foi encontrada no ECR apos a publicacao."
    }
    $imageTag = @($imageDetail.imageTags)[0]
    $imageUri = "$($repository.repositoryUri):$imageTag"
    Write-Host "Imagem selecionada: $imageUri" -ForegroundColor DarkGray
}

Write-Host "[3/9] Garantindo IAM task execution role..." -ForegroundColor Cyan
$roles = Invoke-AwsLocalJson @("iam", "list-roles")
$executionRole = $roles.Roles | Where-Object { $_.RoleName -eq $ExecutionRoleName } | Select-Object -First 1

$trustPolicy = [ordered]@{
    Version = "2012-10-17"
    Statement = @(
        [ordered]@{
            Effect = "Allow"
            Principal = [ordered]@{ Service = "ecs-tasks.amazonaws.com" }
            Action = "sts:AssumeRole"
        }
    )
} | ConvertTo-Json -Depth 8 -Compress

if ($null -eq $executionRole) {
    $createdRole = Invoke-AwsLocalWithJsonFile `
        -ArgumentsBeforeFile @("iam", "create-role", "--role-name", $ExecutionRoleName, "--description", "CloudTasks ECS task execution role") `
        -Json $trustPolicy `
        -FileArgument "assume-role-policy-document"
    $executionRole = $createdRole.Role
}
$executionRoleArn = [string]$executionRole.Arn

$executionPolicy = [ordered]@{
    Version = "2012-10-17"
    Statement = @(
        [ordered]@{
            Effect = "Allow"
            Action = @("ecr:GetAuthorizationToken")
            Resource = "*"
        },
        [ordered]@{
            Effect = "Allow"
            Action = @("ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage")
            Resource = "arn:aws:ecr:${Region}:${AccountId}:repository/${RepositoryName}"
        },
        [ordered]@{
            Effect = "Allow"
            Action = @("logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents")
            Resource = "arn:aws:logs:${Region}:${AccountId}:log-group:${LogGroup}:*"
        },
        [ordered]@{
            Effect = "Allow"
            Action = @("secretsmanager:GetSecretValue")
            Resource = $secretArn
        }
    )
} | ConvertTo-Json -Depth 10 -Compress

$null = Invoke-AwsLocalWithJsonFile `
    -ArgumentsBeforeFile @("iam", "put-role-policy", "--role-name", $ExecutionRoleName, "--policy-name", "cloudtasks-ecs-execution") `
    -Json $executionPolicy `
    -FileArgument "policy-document"

Write-Host "[4/9] Garantindo CloudWatch Logs..." -ForegroundColor Cyan
$logGroups = Invoke-AwsLocalJson @("logs", "describe-log-groups", "--log-group-name-prefix", $LogGroup)
$logGroupExists = $logGroups.logGroups | Where-Object { $_.logGroupName -eq $LogGroup } | Select-Object -First 1
if ($null -eq $logGroupExists) {
    $null = Invoke-AwsLocalJson @("logs", "create-log-group", "--log-group-name", $LogGroup)
}

Write-Host "[5/9] Garantindo ECS cluster..." -ForegroundColor Cyan
$clusters = Invoke-AwsLocalJson @("ecs", "list-clusters")
$clusterArn = @($clusters.clusterArns) | Where-Object { $_ -like "*/$ClusterName" } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace([string]$clusterArn)) {
    $createdCluster = Invoke-AwsLocalJson @(
        "ecs", "create-cluster",
        "--cluster-name", $ClusterName
    )
    $clusterArn = [string]$createdCluster.cluster.clusterArn
}

Write-Host "[6/9] Registrando task definition bridge para o Docker executor LocalStack..." -ForegroundColor Cyan
$taskDefinitionInput = [ordered]@{
    family = $TaskFamily
    networkMode = "bridge"
    executionRoleArn = $executionRoleArn
    containerDefinitions = @(
        [ordered]@{
            name = $ContainerName
            image = $imageUri
            cpu = 256
            memory = 512
            essential = $true
            portMappings = @(
                [ordered]@{
                    containerPort = 3000
                    hostPort = 0
                    protocol = "tcp"
                }
            )
            environment = @(
                [ordered]@{ name = "NODE_ENV"; value = "production" },
                [ordered]@{ name = "PORT"; value = "3000" },
                [ordered]@{ name = "DATABASE_SSL"; value = "false" },
                [ordered]@{ name = "DATABASE_HOST_OVERRIDE"; value = "cloudtasks-localstack" }
            )
            secrets = @(
                [ordered]@{
                    name = "DATABASE_SECRET_JSON"
                    valueFrom = $secretArn
                }
            )
            healthCheck = [ordered]@{
                # Use CMD (exec form) instead of CMD-SHELL so no nested shell quoting is needed.
                # This is intentionally safe for Windows PowerShell 5.1.
                command = @(
                    "CMD",
                    "node",
                    "-e",
                    "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
                )
                interval = 15
                timeout = 5
                retries = 3
                startPeriod = 15
            }
            logConfiguration = [ordered]@{
                logDriver = "awslogs"
                options = [ordered]@{
                    "awslogs-group" = $LogGroup
                    "awslogs-region" = $Region
                    "awslogs-stream-prefix" = "app"
                    "awslogs-create-group" = "true"
                }
            }
        }
    )
} | ConvertTo-Json -Depth 14 -Compress

$registered = Invoke-AwsLocalWithJsonFile `
    -ArgumentsBeforeFile @("ecs", "register-task-definition") `
    -Json $taskDefinitionInput `
    -FileArgument "cli-input-json"
$taskDefinitionArn = [string]$registered.taskDefinition.taskDefinitionArn

Write-Host "[7/9] Garantindo ECS service com duas replicas..." -ForegroundColor Cyan
$services = Invoke-AwsLocalJson @("ecs", "list-services", "--cluster", $ClusterName)
$serviceArn = @($services.serviceArns) | Where-Object { $_ -like "*/$ServiceName" } | Select-Object -First 1

if (-not [string]::IsNullOrWhiteSpace([string]$serviceArn)) {
    $existingServiceResult = Invoke-AwsLocalJson @("ecs", "describe-services", "--cluster", $ClusterName, "--services", $ServiceName)
    $existingService = @($existingServiceResult.services) | Select-Object -First 1
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $runningRuntimeContainers = @(& docker ps --filter "name=ls-ecs-$ClusterName" --filter "status=running" --format "{{.ID}}" 2>&1); $runtimeExit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    if ($runtimeExit -ne 0) { throw "Consulta Docker falhou (exit=$runtimeExit); o namespace ECS nao sera rotacionado por esta consulta." }
    if ($null -ne $existingService -and
        ([int]$existingService.runningCount -ne $DesiredCount -or [int]$existingService.pendingCount -ne 0 -or $runningRuntimeContainers.Count -lt $DesiredCount)) {
        if ($RuntimeRecoveryAttempt -ge 3) {
            throw "ECS service existente continuou inconsistente apos 3 rotacoes de runtime. Interrompendo para evitar loop."
        }
        Write-Host "Service ECS existente nao possui runtime Docker 2/2 saudavel nesta sessao." -ForegroundColor Yellow
        Write-Host "Rotacionando o namespace ECS antes de tentar update-service..." -ForegroundColor Yellow
        & (Join-Path $PSScriptRoot "repair-ecs-runtime.ps1") -Quiet
        & $PSCommandPath -ImageUriOverride $ImageUriOverride -RuntimeRecoveryAttempt ($RuntimeRecoveryAttempt + 1)
        return
    }
}

if ([string]::IsNullOrWhiteSpace([string]$serviceArn)) {
    $createResult = Invoke-AwsLocalRaw @(
        "ecs", "create-service",
        "--cluster", $ClusterName,
        "--service-name", $ServiceName,
        "--task-definition", $taskDefinitionArn,
        "--desired-count", ([string]$DesiredCount),
        "--deployment-configuration", "maximumPercent=200,minimumHealthyPercent=50"
    )

    if ($createResult.ExitCode -ne 0) {
        if ($createResult.Text -match "InvalidInstanceID\.NotFound" -and $RuntimeRecoveryAttempt -lt 3) {
            Write-Host "A criacao do service encontrou referencia EC2 efemera obsoleta no runtime LocalStack." -ForegroundColor Yellow
            Write-Host "Rotacionando novamente o namespace ECS e repetindo a reconciliacao..." -ForegroundColor Yellow
            & (Join-Path $PSScriptRoot "repair-ecs-runtime.ps1")
            & $PSCommandPath -ImageUriOverride $ImageUriOverride -RuntimeRecoveryAttempt ($RuntimeRecoveryAttempt + 1)
            return
        }
        throw "awslocal ecs create-service falhou (exit=$($createResult.ExitCode))."
    }

    $createdService = $createResult.Text | ConvertFrom-Json
    $serviceArn = [string]$createdService.service.serviceArn
}
else {
    $updateResult = Invoke-AwsLocalRaw @(
        "ecs", "update-service",
        "--cluster", $ClusterName,
        "--service", $ServiceName,
        "--task-definition", $taskDefinitionArn,
        "--desired-count", ([string]$DesiredCount),
        "--force-new-deployment"
    )

    if ($updateResult.ExitCode -ne 0) {
        if ($updateResult.Text -match "InvalidInstanceID\.NotFound" -and $RuntimeRecoveryAttempt -lt 3) {
            Write-Host "O service ECS restaurado referencia uma instancia EC2 efemera que nao existe mais no runtime LocalStack." -ForegroundColor Yellow
            Write-Host "Isolando o runtime ECS obsoleto em um novo cluster e repetindo automaticamente a reconciliacao..." -ForegroundColor Yellow
            & (Join-Path $PSScriptRoot "repair-ecs-runtime.ps1")

            & $PSCommandPath -ImageUriOverride $ImageUriOverride -RuntimeRecoveryAttempt ($RuntimeRecoveryAttempt + 1)
            return
        }

        throw "awslocal ecs update-service falhou (exit=$($updateResult.ExitCode))."
    }
}

Write-Host "[8/9] Aguardando duas tasks RUNNING..." -ForegroundColor Cyan
$service = $null
for ($attempt = 1; $attempt -le 72; $attempt++) {
    $described = Invoke-AwsLocalJson @("ecs", "describe-services", "--cluster", $ClusterName, "--services", $ServiceName)
    $service = $described.services | Select-Object -First 1
    if ($null -ne $service -and [int]$service.runningCount -eq $DesiredCount -and [int]$service.pendingCount -eq 0) {
        break
    }

    $runtimeContainers = @(docker ps -a --filter "name=ls-ecs-$ClusterName" --format "{{.ID}}")
    if ($attempt -eq 12 -and $null -ne $service -and [int]$service.runningCount -eq 0 -and [int]$service.pendingCount -gt 0 -and $runtimeContainers.Count -eq 0) {
        Write-Host "  O service ficou PENDING sem sequer criar container Docker por 60s." -ForegroundColor Yellow
        Write-Host "  Executando diagnostico antecipado do scheduler ECS LocalStack..." -ForegroundColor Yellow
        & (Join-Path $PSScriptRoot "diagnose-ecs.ps1") -ClusterName $ClusterName -ServiceName $ServiceName
        throw "ECS ficou PENDING sem criar containers Docker. O diagnostico acima contem a causa do scheduler/runtime."
    }

    if ($attempt % 4 -eq 0 -and $null -ne $service) {
        Write-Host "  desired=$($service.desiredCount) running=$($service.runningCount) pending=$($service.pendingCount)" -ForegroundColor DarkGray
    }
    Start-Sleep -Seconds 5
}

if ($null -eq $service -or [int]$service.runningCount -ne $DesiredCount) {
    Write-Host "ECS service nao estabilizou. Eventos recentes:" -ForegroundColor Yellow
    if ($null -ne $service) {
        Write-Host "Eventos do service disponiveis na API para revisao local antes de compartilhar." -ForegroundColor DarkGray
    }
    Write-Host "Containers ECS visiveis no Docker:" -ForegroundColor Yellow
    docker ps -a --filter "name=ls-ecs-$ClusterName" --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"
    & (Join-Path $PSScriptRoot "diagnose-ecs.ps1") -ClusterName $ClusterName -ServiceName $ServiceName
    throw "ECS service nao chegou a $DesiredCount tasks RUNNING dentro do tempo esperado. O diagnostico acima contem a causa do runtime."
}

Write-Host "[9/9] Validando tasks e runtime Docker..." -ForegroundColor Cyan
$taskList = Invoke-AwsLocalJson @("ecs", "list-tasks", "--cluster", $ClusterName, "--service-name", $ServiceName, "--desired-status", "RUNNING")
$taskArns = @($taskList.taskArns)
if ($taskArns.Count -ne $DesiredCount) {
    throw "ECS informou $($taskArns.Count) tasks RUNNING; esperado: $DesiredCount."
}

$dockerRows = @(docker ps --filter "name=ls-ecs-$ClusterName" --format "{{.ID}}|{{.Names}}|{{.Status}}|{{.Ports}}")
if ($dockerRows.Count -lt $DesiredCount) {
    throw "ECS esta RUNNING, mas apenas $($dockerRows.Count) containers de task foram encontrados no Docker."
}

Write-Host ""
Write-Host "ECS CloudTasks criado e validado no LocalStack." -ForegroundColor Green
Write-Host "Cluster:          $ClusterName"
Write-Host "Service:          $ServiceName"
Write-Host "API launch type:  $($service.launchType)"
Write-Host "Desired/Running:  $DesiredCount/$($service.runningCount)"
Write-Host "Task definition:  $taskDefinitionArn"
Write-Host "Image:            $imageUri"
Write-Host "CloudWatch Logs:  $LogGroup"
Write-Host "Database secret:  $SecretName (injetado como secret; valor nao exibido)"
Write-Host "Runtime:          $($dockerRows.Count) containers Docker de task detectados"
Write-Host ""
Write-Host "Observacao de paridade:" -ForegroundColor Yellow
Write-Host "No laboratorio, as tasks sao executadas diretamente pelo Docker executor do LocalStack." -ForegroundColor Yellow
Write-Host "A API local pode reportar launchType=EC2 mesmo no exemplo Docker-backed do proprio LocalStack; isso nao significa que exista uma EC2 real." -ForegroundColor Yellow
Write-Host "Cada nova sessao do container LocalStack recebe um namespace ECS novo para isolar o runtime Docker correspondente." -ForegroundColor Yellow
Write-Host "O desenho AWS alvo continua ECS sobre EC2; o laboratorio nao afirma possuir container instances EC2 reais." -ForegroundColor Yellow
