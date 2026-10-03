$ErrorActionPreference = "Stop"

$PipelineName = "cloudtasks-pipeline"
$BuildProjectName = "cloudtasks-build"
. (Join-Path $PSScriptRoot "ecs-runtime-context.ps1")
$runtimeContext = Get-CloudTasksEcsRuntime
$ClusterName = [string]$runtimeContext.ClusterName
$ServiceName = [string]$runtimeContext.ServiceName
$ContainerName = "cloudtasks-app"
$SourceBucket = "cloudtasks-pipeline-source"
$SourceObjectKey = "cloudtasks-source.zip"

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $projectRoot
$statePath = Join-Path $projectRoot ".localstack\cicd\last-deploy.json"

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
    finally { $ErrorActionPreference = $previousPreference }
    $text = (($raw | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if ($exitCode -ne 0) { return $null }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { try { return ($text | ConvertFrom-Json -ErrorAction Stop) } catch { throw "JSON de awslocal $($Arguments[0]) $($Arguments[1]) invalido." } } catch { return $null }
}

Write-Host "CloudTasks CI/CD status" -ForegroundColor Cyan

$projects = Invoke-AwsLocalJson @("codebuild", "list-projects")
$projectExists = $null -ne $projects -and (@($projects.projects) -contains $BuildProjectName)
Write-Host "CodeBuild:   $(if ($projectExists) { "$BuildProjectName / presente" } else { "ausente" })"

$pipelines = Invoke-AwsLocalJson @("codepipeline", "list-pipelines")
$pipeline = $null
if ($null -ne $pipelines) {
    $pipeline = @($pipelines.pipelines) | Where-Object { [string]$_.name -eq $PipelineName } | Select-Object -First 1
}
if ($null -ne $pipeline) {
    $declaration = Invoke-AwsLocalJson @("codepipeline", "get-pipeline", "--name", $PipelineName)
    $pipelineType = if ($null -ne $declaration -and -not [string]::IsNullOrWhiteSpace([string]$declaration.pipeline.pipelineType)) { [string]$declaration.pipeline.pipelineType } else { "desconhecido" }
    Write-Host "CodePipeline: $PipelineName / revision=$($pipeline.version) / type=$pipelineType"
}
else {
    Write-Host "CodePipeline: ausente"
}

if ($null -ne $pipeline) {
    if ($null -ne $declaration) {
        Write-Host "Stages:"
        foreach ($stage in @($declaration.pipeline.stages)) {
            foreach ($action in @($stage.actions)) {
                Write-Host "- $($stage.name)/$($action.name) -> $($action.actionTypeId.provider)"
            }
        }
    }

    $executions = Invoke-AwsLocalJson @("codepipeline", "list-pipeline-executions", "--pipeline-name", $PipelineName, "--max-results", "5")
    $latest = @($executions.pipelineExecutionSummaries) | Sort-Object startTime -Descending | Select-Object -First 1
    if ($null -ne $latest) {
        Write-Host "Latest execution: $($latest.pipelineExecutionId) / $($latest.status) / trigger=$($latest.trigger.triggerType)"
    }
}

if ($projectExists) {
    $buildIdsResponse = Invoke-AwsLocalJson @("codebuild", "list-builds-for-project", "--project-name", $BuildProjectName, "--sort-order", "DESCENDING")
    $buildIds = @($buildIdsResponse.ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($buildIds.Count -gt 0) {
        $batchArgs = @("codebuild", "batch-get-builds", "--ids") + $buildIds
        $buildsResponse = Invoke-AwsLocalJson $batchArgs
        $build = @($buildsResponse.builds | Sort-Object { [datetime]$_.startTime } -Descending) | Select-Object -First 1
        if ($null -ne $build) {
            Write-Host "CodeBuild API:    $($build.id) / $($build.buildStatus)"
        }
    }
}

$head = Invoke-AwsLocalJson @("s3api", "head-object", "--bucket", $SourceBucket, "--key", $SourceObjectKey)
if ($null -ne $head) {
    Write-Host "Source S3:        s3://$SourceBucket/$SourceObjectKey / version=$($head.VersionId)"
}

$services = Invoke-AwsLocalJson @("ecs", "describe-services", "--cluster", $ClusterName, "--services", $ServiceName)
$service = @($services.services) | Select-Object -First 1
if ($null -ne $service) {
    $taskDefinitionArn = [string]$service.taskDefinition
    $taskDefinition = Invoke-AwsLocalJson @("ecs", "describe-task-definition", "--task-definition", $taskDefinitionArn)
    $app = @($taskDefinition.taskDefinition.containerDefinitions) | Where-Object { [string]$_.name -eq $ContainerName } | Select-Object -First 1
    Write-Host "ECS:              desired=$($service.desiredCount) running=$($service.runningCount) pending=$($service.pendingCount)"
    Write-Host "Task definition:  $taskDefinitionArn"
    Write-Host "Image:            $($app.image)"
}

if (Test-Path $statePath) {
    try {
        $state = Get-Content -Raw -Path $statePath | ConvertFrom-Json
        if (-not [string]::IsNullOrWhiteSpace([string]$state.executionMode)) {
            Write-Host "Last deploy mode: $($state.executionMode)"
            Write-Host "Last deploy:      $($state.deployedTaskDefinition)"
            Write-Host "Last image:       $($state.deployedImage)"
            if (-not [string]::IsNullOrWhiteSpace([string]$state.codeBuildId)) {
                Write-Host "Build ID:         $($state.codeBuildId)"
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$state.sourceVersionId)) {
                Write-Host "Source version:   $($state.sourceVersionId)"
            }
        }
    }
    catch { }
}

Write-Host "Sessao efemera:    recriar recursos em uma nova sessao; status nao substitui test-cicd.ps1." -ForegroundColor DarkGray
