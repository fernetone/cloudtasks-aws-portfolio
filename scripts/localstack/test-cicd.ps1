$ErrorActionPreference = "Stop"

$PipelineName = "cloudtasks-pipeline"
$BuildProjectName = "cloudtasks-build"
. (Join-Path $PSScriptRoot "ecs-runtime-context.ps1")
. (Join-Path $PSScriptRoot "cicd-artifact-context.ps1")
$runtimeContext = Get-CloudTasksEcsRuntime
$ClusterName = [string]$runtimeContext.ClusterName
$ServiceName = [string]$runtimeContext.ServiceName
$ContainerName = "cloudtasks-app"
$RepositoryName = "cloudtasks"
$DesiredCount = 2

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $projectRoot
$statePath = Join-Path $projectRoot ".localstack\cicd\last-deploy.json"

$container = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}"
if ($container -ne "cloudtasks-localstack") { throw "LocalStack nao esta em execucao." }
if (-not (Test-Path $statePath)) { throw "Metadados do ultimo deploy nao encontrados. Rode .\scripts\localstack\create-cicd.ps1 primeiro." }

function Invoke-AwsLocalJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = & docker exec cloudtasks-localstack awslocal @Arguments --output json 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    $text = (($raw | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if ($exitCode -ne 0) { throw "awslocal $($Arguments[0]) $($Arguments[1]) falhou (exit=$exitCode)." }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { return ($text | ConvertFrom-Json -ErrorAction Stop) } catch { throw "JSON de awslocal $($Arguments[0]) $($Arguments[1]) invalido." }
}

$state = Get-Content -Raw -Path $statePath | ConvertFrom-Json
if ([string]$state.executionMode -ne 'NativeCodePipeline') { throw 'Este registro nao comprova o fluxo nativo; a etapa 8 permanece pendente.' }
if ([string]$state.clusterName -ne $ClusterName -or [string]$state.serviceName -ne $ServiceName -or
    [string]$runtimeContext.LocalStackContainerId -ne (Get-CloudTasksLocalStackContainerId)) {
    throw 'O deploy registrado nao pertence ao runtime ECS atual.'
}
if ([string]$state.sourceSha256 -notmatch '^[a-f0-9]{64}$' -or [string]::IsNullOrWhiteSpace([string]$state.sourceVersionId)) {
    throw 'Registro de Source sem VersionId/SHA256 verificaveis.'
}
$executionMode = 'NativeCodePipeline'

Write-Host "[1/6] Validando CodePipeline V1 e a execucao registrada..." -ForegroundColor Cyan
$declaration = Invoke-AwsLocalJson @("codepipeline", "get-pipeline", "--name", $PipelineName)
if ([string]$declaration.pipeline.pipelineType -ne "V1") { throw "CodePipeline nao esta declarada como V1." }
foreach ($expectedStage in @("Source", "Build", "Deploy")) {
    if ($null -eq (@($declaration.pipeline.stages) | Where-Object { [string]$_.name -eq $expectedStage } | Select-Object -First 1)) {
        throw "Stage '$expectedStage' nao existe na declaracao CodePipeline."
    }
}

$execution = Invoke-AwsLocalJson @(
    "codepipeline", "get-pipeline-execution",
    "--pipeline-name", $PipelineName,
    "--pipeline-execution-id", ([string]$state.executionId)
)
$pipelineStatus = [string]$execution.pipelineExecution.status
if ($pipelineStatus -ne "Succeeded") {
    throw "Execucao CodePipeline nativa nao esta Succeeded: $pipelineStatus"
}
Write-Host "  $($state.executionId) -> $pipelineStatus / mode=$executionMode" -ForegroundColor Green

Write-Host "[2/6] Validando Source e evidencia de Build/Deploy..." -ForegroundColor Cyan
$actions = Invoke-AwsLocalJson @("codepipeline", "list-action-executions", "--pipeline-name", $PipelineName,
    "--filter", "pipelineExecutionId=$($state.executionId)")
$executionActions = @($actions.actionExecutionDetails) | Where-Object { [string]$_.pipelineExecutionId -eq [string]$state.executionId }
$sourceAction = $executionActions | Where-Object { [string]$_.actionName -eq "SourceSnapshot" } | Select-Object -First 1
if ($null -eq $sourceAction -or [string]$sourceAction.status -ne "Succeeded") {
    throw "Source/SourceSnapshot nao foi validado como Succeeded."
}
Write-Host "  Source/SourceSnapshot -> Succeeded" -ForegroundColor Green

$isBlueGreen = ([string]$state.deploymentMode -ceq 'LocalStackBlueGreenAdapter')
$deployName = if ($isBlueGreen) { 'DeployBlueGreen' } else { 'DeployECS' }
foreach ($expected in @('BuildAndPush',$deployName)) {
    $action = $executionActions | Where-Object { [string]$_.actionName -eq $expected } | Select-Object -First 1
    if ($null -eq $action -or [string]$action.status -ne 'Succeeded') { throw "Acao $expected nao esta Succeeded." }
    Write-Host "  $($action.stageName)/$expected -> Succeeded"
}
$revision = @($execution.pipelineExecution.artifactRevisions) | Where-Object { [string]$_.name -eq 'SourceOutput' } | Select-Object -First 1
$nativeSourceVersion = [string]$sourceAction.output.outputVariables.VersionId
if ([string]::IsNullOrWhiteSpace($nativeSourceVersion)) { $nativeSourceVersion = [string]$revision.revisionId }
if ($nativeSourceVersion -ne [string]$state.sourceVersionId) { throw 'Source nativo diverge do VersionId registrado.' }

# Hash the bytes of the exact version; HEAD of the latest key is insufficient.
$sourceTemp = [IO.Path]::GetTempFileName()
$containerSource = '/tmp/cloudtasks-source-check-' + [Guid]::NewGuid().ToString('N') + '.zip'
try {
    $null = Invoke-AwsLocalJson @('s3api','get-object','--bucket',([string]$state.sourceBucket),'--key',([string]$state.sourceObjectKey),
        '--version-id',([string]$state.sourceVersionId),$containerSource)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $copyOutput = @(& docker cp "cloudtasks-localstack:$containerSource" $sourceTemp 2>&1); $copyExit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    if ($copyExit -ne 0) { throw "Consulta do Source exato falhou (exit=$copyExit)." }
    if ((Get-FileHash -LiteralPath $sourceTemp -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$state.sourceSha256) { throw 'SHA256 do Source S3 diverge do upload registrado.' }
}
finally {
    Remove-Item -LiteralPath $sourceTemp -Force -ErrorAction SilentlyContinue
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $null = & docker exec cloudtasks-localstack rm -f $containerSource 2>&1 }
    finally { $ErrorActionPreference = $previous }
}

Write-Host '[3/6] Validando CodeBuild vinculado a acao Build...' -ForegroundColor Cyan
$buildAction = $executionActions | Where-Object { [string]$_.actionName -eq 'BuildAndPush' } | Select-Object -First 1
$nativeBuildId = [string]$buildAction.output.executionResult.externalExecutionId
if ([string]::IsNullOrWhiteSpace($nativeBuildId)) { throw 'BuildAndPush nao informou CodeBuild ID.' }
$builds = Invoke-AwsLocalJson @('codebuild','batch-get-builds','--ids',$nativeBuildId)
$build = @($builds.builds) | Select-Object -First 1
if ($null -eq $build -or [string]$build.buildStatus -ne 'SUCCEEDED' -or [string]$build.id -ne [string]$state.codeBuildId) { throw 'CodeBuild vinculado a esta execucao nao foi confirmado SUCCEEDED.' }
$repos = Invoke-AwsLocalJson @('ecr','describe-repositories','--repository-names',$RepositoryName)
$repo = @($repos.repositories) | Select-Object -First 1
if ([string]$repo.imageTagMutability -ne 'IMMUTABLE') { throw 'ECR nao esta IMMUTABLE.' }
$buildArtifact = Get-CloudTasksNativeBuildImage -BuildAction $buildAction -Build $build -RepositoryUri ([string]$repo.repositoryUri)
if ([string]$state.buildArtifactSha256 -cne $buildArtifact.ArtifactSha256 -or [string]$state.buildArtifactBucket -cne $buildArtifact.ArtifactBucket -or [string]$state.buildArtifactKey -cne $buildArtifact.ArtifactKey) { throw 'Artifact nativo diverge do deploy registrado.' }
$expectedImage = $buildArtifact.ImageUri
if ([string]$state.deployedImage -ne $expectedImage) { throw 'A imagem registrada nao pertence ao CodeBuild desta execucao.' }

Write-Host "[4/6] Validando ECR e imagem implantada..." -ForegroundColor Cyan
$deployedImage = [string]$state.deployedImage
$separatorIndex = $deployedImage.LastIndexOf(':')
if ($separatorIndex -lt 0) { throw "Imagem implantada nao contem tag: $deployedImage" }
$imageTag = $deployedImage.Substring($separatorIndex + 1)
$images = Invoke-AwsLocalJson @("ecr", "describe-images", "--repository-name", $RepositoryName, "--image-ids", "imageTag=$imageTag")
$imageDetail = @($images.imageDetails) | Select-Object -First 1
if ($null -eq $imageDetail) { throw "Imagem $imageTag nao encontrada no ECR." }
$digest = [string]$imageDetail.imageDigest
if ($digest -notmatch '^sha256:[a-f0-9]{64}$' -or $digest -ne [string]$state.deployedImageDigest) { throw 'Digest ECR diverge do deploy registrado.' }
Write-Host "  ECR ${RepositoryName}:$imageTag / $digest" -ForegroundColor Green
if ($isBlueGreen) {
    $deployAction = $executionActions | Where-Object { [string]$_.actionName -ceq 'DeployBlueGreen' } | Select-Object -First 1
    $deployId = [string]$deployAction.output.executionResult.externalExecutionId
    if ([string]::IsNullOrWhiteSpace($deployId) -or $deployId -cne [string]$state.deployCodeBuildId) { throw 'CodeBuild de deploy nao corresponde ao registro Blue/Green.' }
    $deployBuild = @((Invoke-AwsLocalJson @('codebuild','batch-get-builds','--ids',$deployId)).builds) | Select-Object -First 1
    $deployArtifact = Get-CloudTasksBlueGreenReceipt -DeployAction $deployAction -Build $deployBuild
    if ($deployArtifact.ArtifactSha256 -cne [string]$state.deployArtifactSha256 -or
        $deployArtifact.ArtifactBucket -cne [string]$state.deployArtifactBucket -or $deployArtifact.ArtifactKey -cne [string]$state.deployArtifactKey) { throw 'DeployOutput Blue/Green diverge do registro.' }
    Assert-CloudTasksBlueGreenReceipt -Receipt $deployArtifact.Receipt -ExecutionId ([string]$state.executionId) -ImageBuildId $nativeBuildId -ImageUri $deployedImage -ImageDigest $digest -TaskDefinitionArn ([string]$state.deployedTaskDefinition)
    Write-Host '  Blue/Green: CodeBuild vinculado, isolamento, CRUD, HTTPS, bake e limpeza comprovados; adaptacao LocalStack.' -ForegroundColor Green
}

Write-Host "[5/6] Validando ECS 2/2 na nova task definition..." -ForegroundColor Cyan
$services = Invoke-AwsLocalJson @("ecs", "describe-services", "--cluster", $ClusterName, "--services", $ServiceName)
$service = @($services.services) | Select-Object -First 1
if ($null -eq $service -or [int]$service.desiredCount -ne $DesiredCount -or [int]$service.runningCount -ne $DesiredCount -or [int]$service.pendingCount -ne 0) {
    throw "ECS nao esta 2/2 estavel."
}
if ([string]$service.taskDefinition -ne [string]$state.deployedTaskDefinition) {
    throw "ECS nao esta usando a task definition registrada pelo ultimo deploy."
}
$taskDefinition = Invoke-AwsLocalJson @("ecs", "describe-task-definition", "--task-definition", ([string]$service.taskDefinition))
$app = @($taskDefinition.taskDefinition.containerDefinitions) | Where-Object { [string]$_.name -eq $ContainerName } | Select-Object -First 1
if ([string]$app.image -ne $deployedImage) { throw "Imagem atual do ECS difere da imagem do ultimo deploy." }
$taskList = Invoke-AwsLocalJson @('ecs','list-tasks','--cluster',$ClusterName,'--service-name',$ServiceName,'--desired-status','RUNNING')
$taskArns = @($taskList.taskArns)
if ($taskArns.Count -ne $DesiredCount) { throw 'ListTasks nao retornou exatamente duas tasks.' }
$tasks = Invoke-AwsLocalJson -Arguments (@('ecs','describe-tasks','--cluster',$ClusterName,'--tasks') + $taskArns)
if (@($tasks.failures).Count -gt 0 -or @($tasks.tasks).Count -ne $DesiredCount) { throw 'DescribeTasks nao confirmou as duas tasks.' }
$dockerIds = @()
foreach ($task in @($tasks.tasks)) {
    if ([string]$task.lastStatus -ne 'RUNNING' -or [string]$task.taskDefinitionArn -ne [string]$state.deployedTaskDefinition) { throw 'Uma task ainda usa revisao antiga ou nao esta RUNNING.' }
    $taskApp = @($task.containers) | Where-Object { [string]$_.name -eq $ContainerName } | Select-Object -First 1
    if ($null -eq $taskApp -or [string]$taskApp.image -ne $deployedImage) { throw 'Imagem da task difere do build implantado.' }
    $taskId = ([string]$task.taskArn -split '/')[-1]
    $runtime = Get-CloudTasksTaskDockerRuntime -TaskId $taskId
    if ($runtime.ExitCode -ne 0 -or -not $runtime.ValidOutput -or @($runtime.Containers).Count -ne 1) { throw "Runtime Docker invalido para task $taskId." }
    $dockerId = [string]$runtime.Containers[0].ContainerId
    if ($dockerIds -contains $dockerId) { throw 'Duas task ARNs correspondem ao mesmo container Docker.' }
    $dockerIds += $dockerId
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $raw = @(& docker inspect $dockerId 2>&1); $inspectExit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    if ($inspectExit -ne 0) { throw "Docker inspect falhou para task $taskId (exit=$inspectExit)." }
    try { $info = @(($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop)[0] }
    catch { throw "JSON Docker invalido para task $taskId." }
    if (-not $info.State.Running -or [string]$info.State.Health.Status -ne 'healthy') { throw "Container da task $taskId nao esta healthy." }
    # Config.Image is an input reference/alias; inspect the actual image ID below.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $raw = @(& docker image inspect --format '{{json .RepoDigests}}' ([string]$info.Image) 2>&1); $imageExit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    if ($imageExit -ne 0) { throw "Docker image inspect falhou para task $taskId." }
    # PS 5.1 can emit a JSON array as one pipeline item; cast after parsing.
    try { $repoDigests = [string[]](($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw "RepoDigests Docker invalidos para task $taskId." }
    if (-not ($repoDigests -contains "$($repo.repositoryUri)@$digest")) { throw "Docker nao comprova o digest ECR na task $taskId." }
    Write-Host "  Task $taskId / nova revisao / Docker healthy / digest ECR confirmado"
}
Write-Host "  ECS 2/2 -> $($service.taskDefinition)" -ForegroundColor Green

Write-Host "[6/6] Validando caminho HTTPS apos o deploy..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot "test-https.ps1")

Write-Host ""
Write-Host 'Execucao CI/CD nativa validada: Source versionado -> CodeBuild -> ECR -> ECS -> HTTPS/RDS.' -ForegroundColor Green
Write-Host "Execution=$($state.executionId) Build=$($state.codeBuildId) ImageDigest=$digest"
Write-Host 'Criterio da etapa 8: duas entregas reais e quality gate falho bloqueando Deploy.'
