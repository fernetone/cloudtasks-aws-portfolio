$ErrorActionPreference = "Stop"

$PipelineName = "cloudtasks-pipeline"
$BuildProjectName = "cloudtasks-build"

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $projectRoot

$container = docker ps --filter "name=cloudtasks-localstack" --filter "status=running" --format "{{.Names}}"
if ($container -ne "cloudtasks-localstack") {
    throw "LocalStack nao esta em execucao."
}

function Invoke-DockerJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = @(& docker @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    $text = (($raw | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try { return ($text | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Invoke-AwsLocalJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    return Invoke-DockerJson (@('exec', 'cloudtasks-localstack', 'awslocal') + $Arguments + @('--output', 'json'))
}

Write-Host "CloudTasks - diagnostico CI/CD" -ForegroundColor Cyan
Write-Host ""

$previousPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    $inspectRaw = & docker inspect cloudtasks-localstack 2>&1
    $inspectExit = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousPreference
}
if ($inspectExit -eq 0) {
    try {
        $inspectText = (($inspectRaw | ForEach-Object { $_.ToString() }) -join "`n")
        $inspectItems = @($inspectText | ConvertFrom-Json)
        $containerInfo = @($inspectItems) | Select-Object -First 1
        $lsMount = @($containerInfo.Mounts | Where-Object { [string]$_.Destination -eq "/var/lib/localstack" }) | Select-Object -First 1
        if ($null -ne $lsMount) {
            Write-Host "LocalStack volume: /var/lib/localstack -> type=$($lsMount.Type) / source=$($lsMount.Source)"
        }
        else {
            Write-Host "LocalStack volume: /var/lib/localstack -> nao localizado no inspect completo" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "LocalStack volume: nao foi possivel interpretar docker inspect completo" -ForegroundColor Yellow
    }
}

$buildId = ''
$linkedBuild = $false
$pipelines = Invoke-AwsLocalJson @("codepipeline", "list-pipelines")
$pipeline = $null
if ($null -ne $pipelines) {
    $pipeline = @($pipelines.pipelines) | Where-Object { [string]$_.name -eq $PipelineName } | Select-Object -First 1
}
if ($null -ne $pipeline) {
    $executions = Invoke-AwsLocalJson @("codepipeline", "list-pipeline-executions", "--pipeline-name", $PipelineName, "--max-results", "3")
    $latest = @($executions.pipelineExecutionSummaries) | Sort-Object startTime -Descending | Select-Object -First 1
    if ($null -ne $latest) {
        Write-Host "Pipeline:         $($latest.pipelineExecutionId) / $($latest.status)"
        $actions = Invoke-AwsLocalJson @('codepipeline', 'list-action-executions', '--pipeline-name', $PipelineName,
            '--filter', "pipelineExecutionId=$($latest.pipelineExecutionId)")
        $executionActions = @($actions.actionExecutionDetails | Where-Object { [string]$_.pipelineExecutionId -eq [string]$latest.pipelineExecutionId })
        foreach ($action in $executionActions) {
            Write-Host "Acao:             $($action.stageName)/$($action.actionName) / $($action.status)"
            if ([string]$action.actionName -eq 'BuildAndPush') {
                $buildId = [string]$action.output.executionResult.externalExecutionId
                $linkedBuild = -not [string]::IsNullOrWhiteSpace($buildId)
                # Classificar uma mensagem conhecida sem reproduzir texto do provider.
                if ([string]$action.output.executionResult.errorDetails.message -match '(?i)build timed out') {
                    Write-Host 'BuildAndPush:     timeout informado pela acao nativa.' -ForegroundColor Yellow
                }
            }
        }
    }
}

if (-not $linkedBuild) {
    $buildIds = Invoke-AwsLocalJson @('codebuild', 'list-builds-for-project', '--project-name', $BuildProjectName, '--sort-order', 'DESCENDING')
    $buildId = [string](@($buildIds.ids) | Select-Object -First 1)
    Write-Host 'Vinculo CodeBuild: nao informado pela acao; ultimo build e somente candidato de diagnostico.' -ForegroundColor Yellow
} else { Write-Host 'Vinculo CodeBuild: ID fornecido pela acao BuildAndPush desta execucao.' }

if (-not [string]::IsNullOrWhiteSpace($buildId)) {
    $builds = Invoke-AwsLocalJson @('codebuild', 'batch-get-builds', '--ids', $buildId)
    $build = @($builds.builds | Where-Object { [string]$_.id -eq $buildId }) | Select-Object -First 1
    if ($null -ne $build) {
        Write-Host "CodeBuild ID:     $($build.id)"
        Write-Host "CodeBuild status: $($build.buildStatus)"
        Write-Host "Inicio API:       $($build.startTime)"
    }
    if ($buildId -match '^cloudtasks-build:([a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12})?)$') {
        $runnerName = 'localstack-codebuild-' + $Matches[1]
        $runner = @(Invoke-DockerJson @('inspect', $runnerName)) | Select-Object -First 1
        if ($null -ne $runner) {
            Write-Host "Runner:           $runnerName / status=$($runner.State.Status) / exit=$($runner.State.ExitCode) / OOM=$($runner.State.OOMKilled)"
            Write-Host "Inicio/fim Docker: $($runner.State.StartedAt) / $($runner.State.FinishedAt)"
            # Somente identificadores publicos conhecidos; nunca despejar Config.Env.
            foreach ($entry in @($runner.Config.Env)) {
                if ([string]$entry -match '^(LOCAL_AGENT_IMAGE_NAME|IMAGE_NAME)=((?:localstack/aws-codebuild-local|amazon/aws-codebuild-local|public\.ecr\.aws/codebuild/[a-z0-9/_-]+):[a-zA-Z0-9_.-]+)$') {
                    Write-Host "Imagem resolvida: $($Matches[1])=$($Matches[2])"
                }
            }
            Write-Host 'Exit 0 do runner nao comprova sucesso: confirme as APIs, artifacts e deploy.' -ForegroundColor Yellow
        }
    }
} else { Write-Host 'CodeBuild: nenhum build localizado.' -ForegroundColor Yellow }

Write-Host ""
Write-Host "Containers CodeBuild preservados (somente metadados):" -ForegroundColor Cyan
$previousPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    $containerRows = @(& docker ps -a --filter "name=localstack-codebuild" --format "{{.Names}} | {{.Status}} | {{.Image}}" 2>&1)
    $containerExit = $LASTEXITCODE
}
finally { $ErrorActionPreference = $previousPreference }
if ($containerExit -ne 0) { Write-Host "Consulta Docker falhou (exit=$containerExit)." -ForegroundColor Yellow }
elseif ($containerRows.Count -eq 0) { Write-Host "- nenhum container CodeBuild encontrado" }
else { $containerRows | ForEach-Object { Write-Host "- $_" } }

Write-Host ""
Write-Host "Logs brutos permanecem disponiveis localmente no Docker/CloudWatch. Nao sao impressos automaticamente, pois podem conter credenciais em erros do provider." -ForegroundColor DarkGray
