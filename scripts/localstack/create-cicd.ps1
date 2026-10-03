$ErrorActionPreference = "Stop"

$PipelineName = "cloudtasks-pipeline"
$BuildProjectName = "cloudtasks-build"
$CodeBuildImage = "public.ecr.aws/codebuild/amazonlinux-x86_64-standard:5.0"
$SourceBucket = "cloudtasks-pipeline-source"
$SourceObjectKey = "cloudtasks-source.zip"
$ArtifactBucket = "cloudtasks-pipeline-artifacts"
$CodeBuildRoleName = "cloudtasks-codebuild-role"
$CodePipelineRoleName = "cloudtasks-codepipeline-role"
$RepositoryName = "cloudtasks"
$ContainerName = "cloudtasks-app"
$Region = "us-east-1"
$AccountId = "000000000000"
$DesiredCount = 2

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $projectRoot

function Test-LocalStackRunning {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $names = @(& docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}" 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($exitCode -ne 0) { return $false }
    return (@($names | ForEach-Object { [string]$_ }) -contains "cloudtasks-localstack")
}

function Test-LocalStackDeterministicMode {
    if (-not (Test-LocalStackRunning)) { return $false }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = & docker inspect cloudtasks-localstack 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) { return $false }
    try {
        $items = @(($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop)
        if ($items.Count -lt 1) { return $false }
        $envEntries = @($items[0].Config.Env | ForEach-Object { [string]$_ })
        return ($envEntries -contains "PERSISTENCE=0")
    }
    catch { return $false }
}

if (-not (Test-LocalStackRunning)) {
    throw "Docker/LocalStack indisponivel. Verifique o Docker Desktop e execute .\scripts\localstack\resume-environment.ps1 antes do CI/CD."
}
if (-not (Test-LocalStackDeterministicMode)) {
    throw "CI/CD requer a sessao LocalStack configurada com PERSISTENCE=0. Consulte status-localstack.ps1 antes de retomar o ambiente."
}

# O namespace ECS e por sessao do container LocalStack.
# Resolva-o somente DEPOIS que o runtime estiver garantidamente ativo/reconciliado.
. (Join-Path $PSScriptRoot "ecs-runtime-context.ps1")
. (Join-Path $PSScriptRoot "cicd-artifact-context.ps1")
$runtimeContext = Get-CloudTasksEcsRuntime
$ClusterName = [string]$runtimeContext.ClusterName
$ServiceName = [string]$runtimeContext.ServiceName

function Get-LocalStackContainerInspection {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = & docker inspect cloudtasks-localstack 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($exitCode -ne 0) {
        throw "Nao foi possivel inspecionar o container LocalStack (exit=$exitCode)."
    }

    $jsonText = (($raw | ForEach-Object { $_.ToString() }) -join "`n")
    try { $items = @($jsonText | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw 'JSON de docker inspect LocalStack invalido.' }
    if ($items.Count -lt 1 -or $null -eq $items[0]) {
        throw "docker inspect nao retornou metadados do container LocalStack."
    }

    return $items[0]
}

function Get-ContainerEnvValue {
    param(
        [Parameter(Mandatory = $true)]$ContainerInfo,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $prefix = "$Name="
    foreach ($entryObject in @($ContainerInfo.Config.Env)) {
        $entry = [string]$entryObject
        if ($entry.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            return $entry.Substring($prefix.Length)
        }
    }
    return $null
}

function Ensure-CicdBuildImage {
    param([Parameter(Mandatory = $true)][string]$Image)

    # O compose observado usa o socket do Docker Desktop. Prepare a imagem
    # antes de iniciar CodePipeline; um download falho nao deve virar um build.
    for ($inspection = 0; $inspection -lt 2; $inspection++) {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $raw = @(& docker image inspect --format '{{.Id}}' $Image 2>&1)
            $exitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previousPreference }

        if ($exitCode -eq 0) {
            $imageId = ($raw -join "`n").Trim()
            if ($imageId -notmatch '^sha256:[a-f0-9]{64}$') {
                throw 'Docker nao retornou uma identidade valida para a imagem CodeBuild; resposta omitida.'
            }
            Write-Host "  Imagem CodeBuild disponivel: $Image / $imageId" -ForegroundColor DarkGray
            return $imageId
        }
        if ($inspection -eq 1) {
            throw 'Download terminou, mas a imagem CodeBuild nao ficou disponivel no Docker. Pipeline nao iniciada.'
        }

        Write-Host "  Baixando imagem CodeBuild antes da pipeline: $Image (pode demorar)..." -ForegroundColor DarkGray
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $pullOutput = @(& docker pull $Image 2>&1)
            $pullExit = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previousPreference }
        # Erros de registry podem conter URLs assinadas com credenciais temporarias.
        $pullOutput = $null
        if ($pullExit -ne 0) {
            throw "Download da imagem CodeBuild falhou (exit=$pullExit). Pipeline nao iniciada; confira conectividade/TLS do Docker Desktop. Resposta bruta omitida."
        }
    }
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
    if ([string]::IsNullOrWhiteSpace($result.Text)) { return $null }
    try { return ($result.Text | ConvertFrom-Json -ErrorAction Stop) } catch { throw "JSON de awslocal $($Arguments[0]) $($Arguments[1]) invalido." }
}

function Refresh-CicdEcsRuntimeContext {
    $runtime = Get-CloudTasksEcsRuntime
    $script:ClusterName = [string]$runtime.ClusterName
    $script:ServiceName = [string]$runtime.ServiceName
    return $runtime
}

function Test-CicdEcsRuntimeReady {
    $script:CicdRuntimeReason = ''
    $runtime = Refresh-CicdEcsRuntimeContext
    $currentContainerId = Get-CloudTasksLocalStackContainerId
    if ([string]::IsNullOrWhiteSpace($currentContainerId)) {
        $script:CicdRuntimeReason = 'Docker nao retornou o ID do LocalStack.'; return $false
    }
    if ([string]$runtime.LocalStackContainerId -ne $currentContainerId) {
        $script:CicdRuntimeReason = 'Metadata ECS nao pertence ao container LocalStack atual.'; return $false
    }
    foreach ($query in @(
        [pscustomobject]@{ Kind = 'cluster'; Arguments = @('ecs','describe-clusters','--clusters',$script:ClusterName) },
        [pscustomobject]@{ Kind = 'service'; Arguments = @('ecs','describe-services','--cluster',$script:ClusterName,'--services',$script:ServiceName) }
    )) {
        $result = Invoke-AwsLocalRaw -Arguments $query.Arguments
        if ($result.ExitCode -ne 0) {
            $script:CicdRuntimeReason = "Consulta ECS $($query.Kind) falhou (exit=$($result.ExitCode))."; return $false
        }
        try { $payload = $result.Text | ConvertFrom-Json -ErrorAction Stop }
        catch { $script:CicdRuntimeReason = "JSON ECS $($query.Kind) invalido."; return $false }
        if ($query.Kind -eq 'cluster') {
            $cluster = @($payload.clusters) | Where-Object { [string]$_.clusterName -eq $script:ClusterName -and [string]$_.status -eq 'ACTIVE' } | Select-Object -First 1
            if ($null -eq $cluster) { $script:CicdRuntimeReason = 'Cluster esperado nao esta ACTIVE.'; return $false }
        } else {
            $service = @($payload.services) | Where-Object { [string]$_.serviceName -eq $script:ServiceName -and [string]$_.status -eq 'ACTIVE' } | Select-Object -First 1
            if ($null -eq $service) { $script:CicdRuntimeReason = 'Service esperado nao esta ACTIVE.'; return $false }
            if ([int]$service.desiredCount -ne $DesiredCount -or [int]$service.runningCount -ne $DesiredCount -or [int]$service.pendingCount -ne 0) {
                $script:CicdRuntimeReason = "ECS desired=$($service.desiredCount) running=$($service.runningCount) pending=$($service.pendingCount)."; return $false
            }
        }
    }
    $tasksResult = Invoke-AwsLocalRaw -Arguments @('ecs','list-tasks','--cluster',$script:ClusterName,'--service-name',$script:ServiceName,'--desired-status','RUNNING')
    if ($tasksResult.ExitCode -ne 0) { $script:CicdRuntimeReason = "ListTasks falhou (exit=$($tasksResult.ExitCode))."; return $false }
    try { $tasksPayload = $tasksResult.Text | ConvertFrom-Json -ErrorAction Stop }
    catch { $script:CicdRuntimeReason = 'JSON ListTasks invalido.'; return $false }
    $taskArns = @($tasksPayload.taskArns)
    if ($taskArns.Count -ne $DesiredCount) { $script:CicdRuntimeReason = "ListTasks retornou $($taskArns.Count) tasks; esperado=$DesiredCount."; return $false }
    foreach ($taskArn in $taskArns) {
        $taskId = ([string]$taskArn -split '/')[-1]
        if ([string]::IsNullOrWhiteSpace($taskId)) { $script:CicdRuntimeReason = 'Task ARN sem ID.'; return $false }
        $dockerRuntime = Get-CloudTasksTaskDockerRuntime -TaskId $taskId
        if ($dockerRuntime.ExitCode -ne 0 -or -not $dockerRuntime.ValidOutput) {
            $script:CicdRuntimeReason = "docker ps falhou na task $taskId (exit=$($dockerRuntime.ExitCode))."; return $false
        }
        if (@($dockerRuntime.Containers).Count -ne 1) {
            $script:CicdRuntimeReason = "Task $taskId corresponde a $(@($dockerRuntime.Containers).Count) containers RUNNING; esperado=1."; return $false
        }
    }
    return $true
}

function Ensure-CicdEcsRuntimeReady {
    if (-not (Test-CicdEcsRuntimeReady)) {
        throw "Preflight ECS recusado: $script:CicdRuntimeReason Consulte .\scripts\localstack\status-ecs.ps1 e .\scripts\localstack\diagnose-ecs.ps1."
    }
    return Refresh-CicdEcsRuntimeContext
}

function Invoke-AwsLocalWithJsonFile {
    param(
        [Parameter(Mandatory = $true)][string[]]$ArgumentsBeforeFile,
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][ValidateSet("cli-input-json", "assume-role-policy-document", "policy-document", "pipeline")][string]$FileArgument
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
        if ($copyExit -ne 0) { throw "Nao foi possivel copiar JSON temporario para o LocalStack." }

        $arguments = @($ArgumentsBeforeFile) + @("--$FileArgument", "file://$containerTemp")
        return Invoke-AwsLocalJson -Arguments $arguments
    }
    finally {
        Remove-Item -Path $hostTemp -Force -ErrorAction SilentlyContinue
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try { & docker exec cloudtasks-localstack rm -f $containerTemp 2>$null | Out-Null }
        finally { $ErrorActionPreference = $previousPreference }
    }
}

function Ensure-Bucket {
    param([Parameter(Mandatory = $true)][string]$Name)
    $buckets = Invoke-AwsLocalJson @("s3api", "list-buckets")
    $exists = @($buckets.Buckets) | Where-Object { [string]$_.Name -eq $Name } | Select-Object -First 1
    if ($null -eq $exists) {
        $null = Invoke-AwsLocalJson @("s3api", "create-bucket", "--bucket", $Name)
    }
}

function Ensure-Role {
    param(
        [Parameter(Mandatory = $true)][string]$RoleName,
        [Parameter(Mandatory = $true)][string]$ServicePrincipal,
        [Parameter(Mandatory = $true)][string]$PolicyName,
        [Parameter(Mandatory = $true)][object]$PolicyDocument
    )

    $roles = Invoke-AwsLocalJson @("iam", "list-roles")
    $role = @($roles.Roles) | Where-Object { [string]$_.RoleName -eq $RoleName } | Select-Object -First 1

    $trust = [ordered]@{
        Version = "2012-10-17"
        Statement = @(
            [ordered]@{
                Effect = "Allow"
                Principal = [ordered]@{ Service = $ServicePrincipal }
                Action = "sts:AssumeRole"
            }
        )
    } | ConvertTo-Json -Depth 8 -Compress

    if ($null -eq $role) {
        $created = Invoke-AwsLocalWithJsonFile `
            -ArgumentsBeforeFile @("iam", "create-role", "--role-name", $RoleName) `
            -Json $trust `
            -FileArgument "assume-role-policy-document"
        $role = $created.Role
    }

    $policyJson = $PolicyDocument | ConvertTo-Json -Depth 12 -Compress
    $null = Invoke-AwsLocalWithJsonFile `
        -ArgumentsBeforeFile @("iam", "put-role-policy", "--role-name", $RoleName, "--policy-name", $PolicyName) `
        -Json $policyJson `
        -FileArgument "policy-document"

    return [string]$role.Arn
}

function Get-EcsService {
    $result = Invoke-AwsLocalJson @("ecs", "describe-services", "--cluster", $ClusterName, "--services", $ServiceName)
    return @($result.services) | Where-Object { [string]$_.serviceName -eq $ServiceName } | Select-Object -First 1
}

function Get-TaskImage {
    param([Parameter(Mandatory = $true)][string]$TaskDefinitionArn)
    $result = Invoke-AwsLocalJson @("ecs", "describe-task-definition", "--task-definition", $TaskDefinitionArn)
    $containerDefinition = @($result.taskDefinition.containerDefinitions) | Where-Object { [string]$_.name -eq $ContainerName } | Select-Object -First 1
    return [string]$containerDefinition.image
}

function Get-CodeBuildById {
    param([Parameter(Mandatory = $true)][string]$BuildId)

    $result = Invoke-AwsLocalJson @("codebuild", "batch-get-builds", "--ids", $BuildId)
    return @($result.builds) | Select-Object -First 1
}

function Assert-NoActivePipelineExecution {
    $executions = Invoke-AwsLocalJson @('codepipeline','list-pipeline-executions','--pipeline-name',$PipelineName,'--max-results','100')
    $active = @($executions.pipelineExecutionSummaries) | Where-Object { [string]$_.status -in @('InProgress','Stopping') }
    if (@($active).Count -gt 0) {
        throw "Existe execucao CodePipeline em andamento: $($active[0].pipelineExecutionId). Consulte status-cicd.ps1 antes de iniciar outra."
    }
}

function Get-PipelineActionDetails {
    param([Parameter(Mandatory = $true)][string]$ExecutionId)

    $actions = Invoke-AwsLocalJson @("codepipeline", "list-action-executions", "--pipeline-name", $PipelineName,
        "--filter", "pipelineExecutionId=$ExecutionId")
    return @($actions.actionExecutionDetails) |
        Where-Object { [string]$_.pipelineExecutionId -eq $ExecutionId } |
        Sort-Object startTime
}

function Write-PipelineActionSummary {
    param([Parameter(Mandatory = $true)][object[]]$Actions)

    foreach ($action in @($Actions)) {
        Write-Host "    $($action.stageName)/$($action.actionName): $($action.status)" -ForegroundColor DarkGray
    }
}

function Wait-PipelineExecution {
    param(
        [Parameter(Mandatory = $true)][string]$ExecutionId,
        [Parameter(Mandatory = $true)][string]$SourceVersionId
    )
    for ($attempt = 1; $attempt -le 420; $attempt++) {
        $result = Invoke-AwsLocalJson @('codepipeline','get-pipeline-execution','--pipeline-name',$PipelineName,'--pipeline-execution-id',$ExecutionId)
        $status = [string]$result.pipelineExecution.status
        $actions = @(Get-PipelineActionDetails -ExecutionId $ExecutionId)
        $failed = @($actions | Where-Object { [string]$_.status -in @('Failed','Abandoned') })
        if ($failed.Count -gt 0) {
            Write-PipelineActionSummary -Actions $actions
            throw "Acao CodePipeline falhou na execucao $ExecutionId. A etapa 8 permanece pendente."
        }
        $buildAction = $actions | Where-Object { [string]$_.stageName -eq 'Build' -and [string]$_.actionName -eq 'BuildAndPush' } | Select-Object -First 1
        $build = $null
        $buildId = [string]$buildAction.output.executionResult.externalExecutionId
        if (-not [string]::IsNullOrWhiteSpace($buildId)) {
            $build = Get-CodeBuildById -BuildId $buildId
            if ($null -ne $build -and [string]$build.buildStatus -in @('FAILED','FAULT','STOPPED','TIMED_OUT')) {
                throw "CodeBuild $buildId terminou com status $($build.buildStatus)."
            }
        }
        if ($status -in @('Failed','Stopped','Superseded','Cancelled')) { throw "CodePipeline $ExecutionId terminou com status $status." }
        if ($status -eq 'Succeeded') {
            $complete = $true
            foreach ($name in @('SourceSnapshot','BuildAndPush','DeployECS')) {
                $action = $actions | Where-Object { [string]$_.actionName -eq $name } | Select-Object -First 1
                if ($null -eq $action -or [string]$action.status -ne 'Succeeded') { $complete = $false }
            }
            if ($complete -and $null -ne $build -and [string]$build.buildStatus -eq 'SUCCEEDED') {
                $revision = @($result.pipelineExecution.artifactRevisions) | Where-Object { [string]$_.name -eq 'SourceOutput' } | Select-Object -First 1
                $sourceAction = $actions | Where-Object { [string]$_.actionName -eq 'SourceSnapshot' } | Select-Object -First 1
                # S3 exposes VersionId explicitly; revisionId is provider-specific.
                $nativeSourceVersion = [string]$sourceAction.output.outputVariables.VersionId
                if ([string]::IsNullOrWhiteSpace($nativeSourceVersion)) { $nativeSourceVersion = [string]$revision.revisionId }
                if ($nativeSourceVersion -ne $SourceVersionId) {
                    throw 'Source nativo nao comprova o VersionId exato publicado para esta execucao.'
                }
                return [pscustomobject]@{ Mode = 'NativeCodePipeline'; PipelineExecution = $result.pipelineExecution; CodeBuildId = [string]$build.id }
            }
        }
        if ($attempt % 6 -eq 0) {
            Write-Host "  CodePipeline $ExecutionId / $status" -ForegroundColor DarkGray
            if ($actions.Count -gt 0) { Write-PipelineActionSummary -Actions $actions }
        }
        Start-Sleep -Seconds 5
    }
    throw "Timeout da execucao $ExecutionId. Consulte diagnose-cicd.ps1. Source, Build e Deploy nativos precisam estar Succeeded; a etapa 8 permanece pendente."
}

function Wait-EcsStable {
    for ($attempt = 1; $attempt -le 120; $attempt++) {
        $service = Get-EcsService
        if ($null -ne $service -and [int]$service.desiredCount -eq $DesiredCount -and [int]$service.runningCount -eq $DesiredCount -and [int]$service.pendingCount -eq 0) {
            $listed = Invoke-AwsLocalJson @('ecs','list-tasks','--cluster',$ClusterName,'--service-name',$ServiceName,'--desired-status','RUNNING')
            if (@($listed.taskArns).Count -eq $DesiredCount) {
                $tasks = Invoke-AwsLocalJson -Arguments (@('ecs','describe-tasks','--cluster',$ClusterName,'--tasks') + @($listed.taskArns))
                $current = @($tasks.tasks | Where-Object { [string]$_.lastStatus -eq 'RUNNING' -and [string]$_.taskDefinitionArn -eq [string]$service.taskDefinition })
                if (@($tasks.failures).Count -eq 0 -and $current.Count -eq $DesiredCount) { return $service }
            }
        }
        if ($attempt % 6 -eq 0 -and $null -ne $service) {
            Write-Host "  ECS desired=$($service.desiredCount) running=$($service.runningCount) pending=$($service.pendingCount)" -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 5
    }
    throw "ECS nao estabilizou em $DesiredCount/$DesiredCount apos o deploy da pipeline."
}

$lockPath = Join-Path $script:CloudTasksRuntimeRoot 'cicd.lock'
$lockStream = $null
try {
    New-Item -ItemType Directory -Path $script:CloudTasksRuntimeRoot -Force | Out-Null
    try { $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'Outra operacao CI/CD esta usando este laboratorio. Aguarde sua conclusao.' }
Write-Host "CloudTasks - CodePipeline + CodeBuild + ECR + ECS" -ForegroundColor Cyan
Write-Host ""

Write-Host "[1/10] Validando runtime e configuracao do CodeBuild..." -ForegroundColor Cyan
$runtimeContext = Ensure-CicdEcsRuntimeReady
$ClusterName = [string]$runtimeContext.ClusterName
$ServiceName = [string]$runtimeContext.ServiceName
$containerInfo = Get-LocalStackContainerInspection
$codeBuildDockerFlags = Get-ContainerEnvValue -ContainerInfo $containerInfo -Name "CODEBUILD_DOCKER_FLAGS"
$hasNetworkFlag = -not [string]::IsNullOrWhiteSpace([string]$codeBuildDockerFlags) -and ([string]$codeBuildDockerFlags -like "*cloudtasks-localstack-network*")
$hasDockerSocketFlag = -not [string]::IsNullOrWhiteSpace([string]$codeBuildDockerFlags) -and ([string]$codeBuildDockerFlags -like "*/var/run/docker.sock:/var/run/docker.sock*")
if (-not $hasNetworkFlag -or -not $hasDockerSocketFlag) {
    throw "CodeBuild requer CODEBUILD_DOCKER_FLAGS com rede + docker.sock. Verifique a configuracao antes de recriar a sessao."
}

$localstackVolumeMount = @($containerInfo.Mounts | Where-Object { [string]$_.Destination -eq "/var/lib/localstack" }) | Select-Object -First 1
if ($null -eq $localstackVolumeMount -or [string]$localstackVolumeMount.Type -ne "bind") {
    $receivedType = if ($null -eq $localstackVolumeMount) { "ausente" } else { [string]$localstackVolumeMount.Type }
    throw "CodeBuild requer /var/lib/localstack como bind mount. Recebido: $receivedType. Verifique a configuracao antes de recriar a sessao."
}
if ([string]::IsNullOrWhiteSpace([string]$localstackVolumeMount.Source)) {
    throw "O bind mount /var/lib/localstack existe, mas o Docker nao informou o caminho Source no host."
}
Write-Host "  /var/lib/localstack: bind mount OK ($($localstackVolumeMount.Source))" -ForegroundColor DarkGray
Write-Host "  CODEBUILD_DOCKER_FLAGS: rede + docker.sock OK" -ForegroundColor DarkGray
$codeBuildImageId = Ensure-CicdBuildImage -Image $CodeBuildImage

$service = Get-EcsService
if ($null -eq $service -or [int]$service.runningCount -ne $DesiredCount) {
    throw "ECS nao esta estavel em 2/2. Rode .\scripts\localstack\resume-environment.ps1 primeiro."
}
$previousTaskDefinition = [string]$service.taskDefinition
$previousImage = Get-TaskImage -TaskDefinitionArn $previousTaskDefinition

& (Join-Path $PSScriptRoot "create-ecr.ps1") -RepositoryName $RepositoryName
$repos = Invoke-AwsLocalJson @("ecr", "describe-repositories", "--repository-names", $RepositoryName,
    "--registry-id", $AccountId, "--region", $Region)
$repo = @($repos.repositories) | Where-Object { [string]$_.repositoryName -eq $RepositoryName } | Select-Object -First 1
if ($null -eq $repo) { throw "Repositorio ECR '$RepositoryName' nao ficou disponivel." }
$script:EcrRepositoryUri = [string]$repo.repositoryUri

Write-Host "[2/10] Garantindo buckets S3 da pipeline..." -ForegroundColor Cyan
Ensure-Bucket -Name $SourceBucket
Ensure-Bucket -Name $ArtifactBucket
$null = Invoke-AwsLocalJson @("s3api", "put-bucket-versioning", "--bucket", $SourceBucket, "--versioning-configuration", "Status=Enabled")

$pipelines = Invoke-AwsLocalJson @('codepipeline','list-pipelines')
$pipelineExists = @($pipelines.pipelines) | Where-Object { [string]$_.name -eq $PipelineName } | Select-Object -First 1
if ($null -ne $pipelineExists) { Assert-NoActivePipelineExecution }
Write-Host "[3/10] Publicando snapshot seguro do projeto como Source..." -ForegroundColor Cyan
$publishedSource = & (Join-Path $PSScriptRoot "publish-cicd-source.ps1") -BucketName $SourceBucket -ObjectKey $SourceObjectKey
$SourceVersionId = [string]$publishedSource.VersionId
if ([string]::IsNullOrWhiteSpace($SourceVersionId)) {
    throw "Nao foi possivel resolver o VersionId do snapshot S3 recem-publicado."
}

Write-Host "[4/10] Garantindo IAM do CodeBuild..." -ForegroundColor Cyan
$codeBuildPolicy = [ordered]@{
    Version = "2012-10-17"
    Statement = @(
        [ordered]@{ Effect = "Allow"; Action = @("s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning"); Resource = @("arn:aws:s3:::$SourceBucket", "arn:aws:s3:::$SourceBucket/*", "arn:aws:s3:::$ArtifactBucket", "arn:aws:s3:::$ArtifactBucket/*") },
        [ordered]@{ Effect = "Allow"; Action = @("ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:CompleteLayerUpload", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:DescribeRepositories", "ecr:DescribeImages"); Resource = "*" },
        [ordered]@{ Effect = "Allow"; Action = @("logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"); Resource = "*" },
        [ordered]@{ Effect = "Allow"; Action = @("sts:GetCallerIdentity"); Resource = "*" }
    )
}
$codeBuildRoleArn = Ensure-Role -RoleName $CodeBuildRoleName -ServicePrincipal "codebuild.amazonaws.com" -PolicyName "cloudtasks-codebuild" -PolicyDocument $codeBuildPolicy

Write-Host "[5/10] Garantindo projeto CodeBuild..." -ForegroundColor Cyan
$buildProject = [ordered]@{
    name = $BuildProjectName
    description = "CloudTasks local CodeBuild - quality gate, Docker build e push ECR"
    source = [ordered]@{
        type = "CODEPIPELINE"
        buildspec = "buildspec.localstack.yml"
    }
    artifacts = [ordered]@{ type = "CODEPIPELINE" }
    environment = [ordered]@{
        type = "LINUX_CONTAINER"
        image = $CodeBuildImage
        computeType = "BUILD_GENERAL1_SMALL"
        privilegedMode = $true
        environmentVariables = @(
            [ordered]@{ name = "IMAGE_REPO_NAME"; value = $RepositoryName; type = "PLAINTEXT" },
            [ordered]@{ name = "CONTAINER_NAME"; value = $ContainerName; type = "PLAINTEXT" },
            [ordered]@{ name = "AWS_DEFAULT_REGION"; value = $Region; type = "PLAINTEXT" },
            [ordered]@{ name = "AWS_ENDPOINT_URL"; value = "http://cloudtasks-localstack:4566"; type = "PLAINTEXT" },
            [ordered]@{ name = "DOCKER_HOST"; value = "unix:///var/run/docker.sock"; type = "PLAINTEXT" }
        )
    }
    serviceRole = $codeBuildRoleArn
    timeoutInMinutes = 30
}
$buildProjectJson = $buildProject | ConvertTo-Json -Depth 12 -Compress
$projects = Invoke-AwsLocalJson @("codebuild", "list-projects")
$projectExists = @($projects.projects) -contains $BuildProjectName
if ($projectExists) {
    $null = Invoke-AwsLocalWithJsonFile -ArgumentsBeforeFile @("codebuild", "update-project") -Json $buildProjectJson -FileArgument "cli-input-json"
}
else {
    $null = Invoke-AwsLocalWithJsonFile -ArgumentsBeforeFile @("codebuild", "create-project") -Json $buildProjectJson -FileArgument "cli-input-json"
}

Write-Host "[6/10] Garantindo IAM do CodePipeline..." -ForegroundColor Cyan
$codePipelinePolicy = [ordered]@{
    Version = "2012-10-17"
    Statement = @(
        [ordered]@{ Effect = "Allow"; Action = @("s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning"); Resource = @("arn:aws:s3:::$SourceBucket", "arn:aws:s3:::$SourceBucket/*", "arn:aws:s3:::$ArtifactBucket", "arn:aws:s3:::$ArtifactBucket/*") },
        [ordered]@{ Effect = "Allow"; Action = @("codebuild:StartBuild", "codebuild:BatchGetBuilds"); Resource = "*" },
        [ordered]@{ Effect = "Allow"; Action = @("ecs:DescribeServices", "ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition", "ecs:UpdateService", "ecs:ListTasks", "ecs:DescribeTasks"); Resource = "*" },
        [ordered]@{ Effect = "Allow"; Action = @("iam:PassRole"); Resource = "*" }
    )
}
$codePipelineRoleArn = Ensure-Role -RoleName $CodePipelineRoleName -ServicePrincipal "codepipeline.amazonaws.com" -PolicyName "cloudtasks-codepipeline" -PolicyDocument $codePipelinePolicy

Write-Host "[7/10] Criando/atualizando CodePipeline V1..." -ForegroundColor Cyan
$pipelineDeclaration = [ordered]@{
    name = $PipelineName
    roleArn = $codePipelineRoleArn
    artifactStore = [ordered]@{ type = "S3"; location = $ArtifactBucket }
    stages = @(
        [ordered]@{
            name = "Source"
            actions = @(
                [ordered]@{
                    name = "SourceSnapshot"
                    actionTypeId = [ordered]@{ category = "Source"; owner = "AWS"; provider = "S3"; version = "1" }
                    runOrder = 1
                    configuration = [ordered]@{ S3Bucket = $SourceBucket; S3ObjectKey = $SourceObjectKey; PollForSourceChanges = "false" }
                    outputArtifacts = @([ordered]@{ name = "SourceOutput" })
                    inputArtifacts = @()
                }
            )
        },
        [ordered]@{
            name = "Build"
            actions = @(
                [ordered]@{
                    name = "BuildAndPush"
                    actionTypeId = [ordered]@{ category = "Build"; owner = "AWS"; provider = "CodeBuild"; version = "1" }
                    runOrder = 1
                    configuration = [ordered]@{ ProjectName = $BuildProjectName }
                    inputArtifacts = @([ordered]@{ name = "SourceOutput" })
                    outputArtifacts = @([ordered]@{ name = "BuildOutput" })
                }
            )
        },
        [ordered]@{
            name = "Deploy"
            actions = @(
                [ordered]@{
                    name = "DeployECS"
                    actionTypeId = [ordered]@{ category = "Deploy"; owner = "AWS"; provider = "ECS"; version = "1" }
                    runOrder = 1
                    configuration = [ordered]@{ ClusterName = $ClusterName; ServiceName = $ServiceName; FileName = "imagedefinitions.json" }
                    inputArtifacts = @([ordered]@{ name = "BuildOutput" })
                    outputArtifacts = @()
                }
            )
        }
    )
    version = 1
    executionMode = "SUPERSEDED"
    pipelineType = "V1"
}
$pipelineJson = $pipelineDeclaration | ConvertTo-Json -Depth 16 -Compress

$pipelines = Invoke-AwsLocalJson @("codepipeline", "list-pipelines")
$pipelineExists = @($pipelines.pipelines) | Where-Object { [string]$_.name -eq $PipelineName } | Select-Object -First 1

$executionId = $null
if ($null -eq $pipelineExists) {
    $null = Invoke-AwsLocalWithJsonFile -ArgumentsBeforeFile @("codepipeline", "create-pipeline") -Json $pipelineJson -FileArgument "pipeline"
    Write-Host "  LocalStack inicia uma execucao automaticamente em CreatePipeline." -ForegroundColor DarkGray
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $executions = Invoke-AwsLocalJson @("codepipeline", "list-pipeline-executions", "--pipeline-name", $PipelineName)
        $latest = @($executions.pipelineExecutionSummaries) | Sort-Object startTime -Descending | Select-Object -First 1
        if ($null -ne $latest) {
            $executionId = [string]$latest.pipelineExecutionId
            break
        }
        Start-Sleep -Seconds 1
    }
    if ([string]::IsNullOrWhiteSpace([string]$executionId)) {
        throw "Pipeline foi criada, mas nenhuma execucao CreatePipeline foi encontrada."
    }
}
else {
    Assert-NoActivePipelineExecution
    $null = Invoke-AwsLocalWithJsonFile -ArgumentsBeforeFile @("codepipeline", "update-pipeline") -Json $pipelineJson -FileArgument "pipeline"
    $started = Invoke-AwsLocalJson @("codepipeline", "start-pipeline-execution", "--name", $PipelineName,
        "--source-revisions", "actionName=SourceSnapshot,revisionType=S3_OBJECT_VERSION_ID,revisionValue=$SourceVersionId")
    $executionId = [string]$started.pipelineExecutionId
}

Write-Host "[8/10] Aguardando Source -> CodeBuild -> Deploy ECS..." -ForegroundColor Cyan
$pipelineResult = Wait-PipelineExecution -ExecutionId $executionId -SourceVersionId $SourceVersionId
$execution = $pipelineResult.PipelineExecution
$executionMode = 'NativeCodePipeline'
$codeBuildId = [string]$pipelineResult.CodeBuildId

Write-Host "[9/10] Validando nova revisao ECS e sincronizando targets locais..." -ForegroundColor Cyan
$service = Wait-EcsStable
$newTaskDefinition = [string]$service.taskDefinition
$newImage = Get-TaskImage -TaskDefinitionArn $newTaskDefinition
$buildAction = @(Get-PipelineActionDetails -ExecutionId $executionId) | Where-Object { [string]$_.actionName -eq 'BuildAndPush' } | Select-Object -First 1
$linkedBuild = Get-CodeBuildById -BuildId $codeBuildId
$buildArtifact = Get-CloudTasksNativeBuildImage -BuildAction $buildAction -Build $linkedBuild -RepositoryUri $script:EcrRepositoryUri
$imageTag = $buildArtifact.ImageTag
$expectedImage = $buildArtifact.ImageUri
if ($newImage -ne $expectedImage) { throw "ECS nao usa a imagem do CodeBuild vinculado a esta execucao ($codeBuildId)." }

if ($newTaskDefinition -eq $previousTaskDefinition) {
    throw "O CI/CD concluiu, mas o ECS continua na mesma task definition."
}
if ($newImage -eq $previousImage) {
    throw "O CI/CD criou nova task definition, mas a imagem do container nao mudou."
}

$images = Invoke-AwsLocalJson @('ecr','describe-images','--repository-name',$RepositoryName,'--image-ids',"imageTag=$imageTag")
$imageDetail = @($images.imageDetails) | Select-Object -First 1
$newImageDigest = [string]$imageDetail.imageDigest
if ($newImageDigest -notmatch '^sha256:[a-f0-9]{64}$') { throw 'ECR nao retornou digest verificavel para a imagem deste build.' }
& (Join-Path $PSScriptRoot "create-alb.ps1")
& (Join-Path $PSScriptRoot "create-https.ps1")

Write-Host "[10/10] Gravando metadados locais para teste/rollback..." -ForegroundColor Cyan
$stateDirectory = Join-Path $projectRoot ".localstack\cicd"
New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
$statePath = Join-Path $stateDirectory "last-deploy.json"
$finalPipelineStatus = $null
try {
    $finalPipeline = Invoke-AwsLocalJson @(
        "codepipeline", "get-pipeline-execution",
        "--pipeline-name", $PipelineName,
        "--pipeline-execution-id", $executionId
    )
    $finalPipelineStatus = [string]$finalPipeline.pipelineExecution.status
}
catch {
    $finalPipelineStatus = [string]$execution.status
}

$state = [ordered]@{
    pipelineName = $PipelineName
    executionId = $executionId
    executionMode = $executionMode
    pipelineStatus = $finalPipelineStatus
    buildArtifactSha256 = $buildArtifact.ArtifactSha256
    buildArtifactBucket = $buildArtifact.ArtifactBucket
    buildArtifactKey = $buildArtifact.ArtifactKey
    codeBuildId = $codeBuildId
    codeBuildImageId = $codeBuildImageId
    localStackContainerId = [string]$containerInfo.Id
    localStackImageId = [string]$containerInfo.Image
    sourceVersionId = $SourceVersionId
    sourceSha256 = [string]$publishedSource.Sha256
    executedAt = (Get-Date).ToUniversalTime().ToString("o")
    clusterName = $ClusterName
    serviceName = $ServiceName
    previousTaskDefinition = $previousTaskDefinition
    previousImage = $previousImage
    deployedTaskDefinition = $newTaskDefinition
    deployedImage = $newImage
    deployedImageDigest = $newImageDigest
    sourceBucket = $SourceBucket
    sourceObjectKey = $SourceObjectKey
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 8), $utf8NoBom)

Write-Host ""
Write-Host "Deploy nativo registrado; execute test-cicd.ps1 para validar todas as tasks e HTTPS." -ForegroundColor Green
Write-Host "Pipeline: $PipelineName / $executionId / $finalPipelineStatus"
Write-Host "CodeBuild: $codeBuildId"
Write-Host "Source: s3://$SourceBucket/$SourceObjectKey / version=$SourceVersionId / sha256=$($publishedSource.Sha256)"
Write-Host "Image: $newImage"
Write-Host "Task definition: $newTaskDefinition"
Write-Host "Paridade: S3 Source no laboratorio; GitHub/CodeConnections no alvo AWS."

}
finally { if ($null -ne $lockStream) { $lockStream.Dispose() } }
