param([string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path)

$savedArtifactBytes = $env:CLOUDTASKS_TEST_ARTIFACT_BYTES
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('cloudtasks-tests-' + [Guid]::NewGuid().ToString('N'))
$savedProfile = $env:USERPROFILE
$savedPath = $env:PATH
$savedCase = $env:CLOUDTASKS_TEST_CASE
$savedCounter = $env:CLOUDTASKS_TEST_COUNTER
$savedZip = $env:CLOUDTASKS_TEST_ZIP
$savedDbCanary = $env:CLOUDTASKS_TEST_DB_CANARY
$savedSourceBytes = $env:CLOUDTASKS_TEST_SOURCE_BYTES
$savedNode = $env:CLOUDTASKS_TEST_NODE
$savedFixture = $env:CLOUDTASKS_TEST_FIXTURE
$savedLocation = (Get-Location).Path
$failures = New-Object 'System.Collections.Generic.List[string]'
$testCount = 0

function Import-TestFunctions {
    param([string]$Path, [string[]]$Names)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "Syntax error in $Path" }
    foreach ($name in $Names) {
        $fn = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
        }, $false) | Select-Object -First 1
        if ($null -eq $fn) { throw "Missing function: $name" }
        Set-Item -Path "Function:script:$name" -Value ([scriptblock]::Create($fn.Body.Extent.Text.TrimStart('{').TrimEnd('}')))
    }
}

function Check {
    param([string]$Name, [scriptblock]$Body)
    $script:testCount++
    try { & $Body; Write-Host "PASS $Name" }
    catch { $failures.Add($Name); Write-Host "FAIL $Name / $($_.Exception.Message)" }
}

function Assert-True {
    param([bool]$Value)
    if (-not $Value) { throw 'Assertion failed' }
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $bin = Join-Path $testRoot 'bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    $node = (Get-Command node -ErrorAction Stop).Source
    $fixture = Join-Path $PSScriptRoot 'docker-fixture.mjs'
    $utf8 = New-Object Text.UTF8Encoding($false)
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        # A real executable keeps CMD from interpreting Docker Go-template pipes.
        $env:CLOUDTASKS_TEST_NODE = $node
        $env:CLOUDTASKS_TEST_FIXTURE = $fixture
        $launcherSource = @'
using System;
using System.Diagnostics;
using System.Text;
public static class DockerFixtureLauncher {
    static string Quote(string value) {
        var text = new StringBuilder().Append('"');
        int slashes = 0;
        foreach (char c in value) {
            if (c == '\\') { slashes++; continue; }
            text.Append('\\', slashes * (c == '"' ? 2 : 1) + (c == '"' ? 1 : 0));
            text.Append(c); slashes = 0;
        }
        return text.Append('\\', slashes * 2).Append('"').ToString();
    }
    public static int Main(string[] args) {
        var command = new ProcessStartInfo(Environment.GetEnvironmentVariable("CLOUDTASKS_TEST_NODE"));
        command.UseShellExecute = false;
        var arguments = new StringBuilder(Quote(Environment.GetEnvironmentVariable("CLOUDTASKS_TEST_FIXTURE")));
        foreach (string arg in args) arguments.Append(' ').Append(Quote(arg));
        command.Arguments = arguments.ToString();
        using (var child = Process.Start(command)) {
            child.WaitForExit(); return child.ExitCode;
        }
    }
}
'@
        $launcherPath = Join-Path $bin 'docker-fixture-launcher.cs'
        [IO.File]::WriteAllText($launcherPath, $launcherSource, $utf8)
        $framework = if ([Environment]::Is64BitProcess) { 'Framework64' } else { 'Framework' }
        $compiler = Join-Path ([Environment]::GetFolderPath('Windows')) "Microsoft.NET/$framework/v4.0.30319/csc.exe"
        if (-not (Test-Path -LiteralPath $compiler)) { throw 'Windows PowerShell .NET Framework compiler not found' }
        $compileOutput = @(& $compiler /nologo /target:exe "/out:$(Join-Path $bin 'docker.exe')" $launcherPath 2>&1)
        $compileExit = $LASTEXITCODE
        if ($compileExit -ne 0) { throw 'Cannot prepare the native Windows Docker fixture' }
    } else {
        $command = "#!/bin/sh`nexec '" + $node.Replace("'", "'\" + '"' + "'\" + '"' + "'") + "' '" + $fixture + "' " + '"$@"' + "`n"
        [IO.File]::WriteAllText((Join-Path $bin 'docker'), $command, $utf8)
        & chmod +x (Join-Path $bin 'docker')
        if ($LASTEXITCODE -ne 0) { throw 'Cannot prepare native fixture' }
    }
    $env:PATH = $bin + [IO.Path]::PathSeparator + $savedPath
    $env:USERPROFILE = Join-Path $testRoot 'profile'
    $env:CLOUDTASKS_TEST_COUNTER = Join-Path $testRoot 'counter'
    $env:CLOUDTASKS_TEST_ZIP = Join-Path $testRoot 'captured.zip'
    $dir = Join-Path $ProjectRoot 'scripts/localstack'
    . (Join-Path $dir 'ecs-runtime-context.ps1')
    $null = Set-CloudTasksEcsRuntime -ClusterName 'cloudtasks-cluster-r20261001000000000' -LocalStackContainerId ('a' * 64)
    $DesiredCount = 2
    $PipelineName = 'cloudtasks-pipeline'
    $BuildProjectName = 'cloudtasks-build'
    Import-TestFunctions (Join-Path $dir 'create-cicd.ps1') @(
        'Invoke-AwsLocalRaw', 'Invoke-AwsLocalJson', 'Refresh-CicdEcsRuntimeContext',
        'Test-CicdEcsRuntimeReady', 'Get-PipelineActionDetails', 'Get-CodeBuildById',
        'Write-PipelineActionSummary', 'Wait-PipelineExecution'
    )

    Check 'healthy tasks accepted after native completion' {
        $env:CLOUDTASKS_TEST_CASE = 'healthy'
        Assert-True (Test-CicdEcsRuntimeReady)
    }
    Check 'ID printed before native exit 7 must be rejected' {
        $env:CLOUDTASKS_TEST_CASE = 'late-native-failure'
        Assert-True (-not (Test-CicdEcsRuntimeReady))
    }
    Check 'missing Docker containers rejected' {
        $env:CLOUDTASKS_TEST_CASE = 'missing-container'
        Assert-True (-not (Test-CicdEcsRuntimeReady))
    }
    Check 'incomplete ECS service rejected' {
        $env:CLOUDTASKS_TEST_CASE = 'incomplete-service'
        Assert-True (-not (Test-CicdEcsRuntimeReady))
    }
    Check 'metadata from another session rejected' {
        $env:CLOUDTASKS_TEST_CASE = 'healthy'
        $null = Set-CloudTasksEcsRuntime -ClusterName 'cloudtasks-cluster-r20261001000000000' -LocalStackContainerId ('b' * 64)
        try { Assert-True (-not (Test-CicdEcsRuntimeReady)) }
        finally { $null = Set-CloudTasksEcsRuntime -ClusterName 'cloudtasks-cluster-r20261001000000000' -LocalStackContainerId ('a' * 64) }
    }
    foreach ($case in @('failed-action', 'failed-build')) {
        Check "pipeline Succeeded cannot override $case" {
            $env:CLOUDTASKS_TEST_CASE = $case
            $rejected = $false
            try { $null = Wait-PipelineExecution -ExecutionId '22222222-2222-4222-8222-222222222222' -SourceVersionId 'source-version' }
            catch { $rejected = $true }
            Assert-True $rejected
        }
    }
    Check 'native pipeline identifies its actual CodeBuild' {
        $env:CLOUDTASKS_TEST_CASE = 'healthy'
        $result = Wait-PipelineExecution -ExecutionId '22222222-2222-4222-8222-222222222222' -SourceVersionId 'source-version'
        Assert-True ([string]$result.CodeBuildId -eq 'cloudtasks-build:11111111-1111-4111-8111-111111111111')
    }
    Check 'native pipeline retains exact short API build ID' {
        $env:CLOUDTASKS_TEST_CASE = 'short-id'
        $result = Wait-PipelineExecution -ExecutionId '22222222-2222-4222-8222-222222222222' -SourceVersionId 'source-version'
        Assert-True ([string]$result.CodeBuildId -eq 'cloudtasks-build:4a3385dc')
    }
    foreach ($case in @('image-cached', 'image-cold')) {
        Check "CodeBuild image preparation verifies $case before pipeline startup" {
            Import-TestFunctions (Join-Path $dir 'create-cicd.ps1') @('Ensure-CicdBuildImage')
            Remove-Item -LiteralPath $env:CLOUDTASKS_TEST_COUNTER -Force -ErrorAction SilentlyContinue
            $env:CLOUDTASKS_TEST_CASE = $case
            $imageId = Ensure-CicdBuildImage -Image 'public.ecr.aws/codebuild/amazonlinux-x86_64-standard:5.0'
            Assert-True ($imageId -ceq ('sha256:' + ('3' * 64)))
        }
    }
    Check 'failed image download is rejected without exposing registry query credentials' {
        Import-TestFunctions (Join-Path $dir 'create-cicd.ps1') @('Ensure-CicdBuildImage')
        $env:CLOUDTASKS_TEST_CASE = 'image-pull-failed'
        $env:CLOUDTASKS_TEST_DB_CANARY = 'CT_' + [Guid]::NewGuid().ToString('N')
        $script:imagePreparationRejected = $false
        $script:imagePreparationError = ''
        $output = @(& {
            try { Ensure-CicdBuildImage -Image 'public.ecr.aws/codebuild/amazonlinux-x86_64-standard:5.0' }
            catch { $script:imagePreparationError = $_.Exception.Message; $script:imagePreparationRejected = $true }
        } *>&1)
        Assert-True $script:imagePreparationRejected
        $displayed = ($output -join "`n") + $script:imagePreparationError
        Assert-True (-not $displayed.Contains($env:CLOUDTASKS_TEST_DB_CANARY))
        Assert-True (-not $displayed.Contains('X-Amz-Credential'))
        Assert-True (-not $displayed.Contains('registry.example.test'))
    }
    Check 'successful pull exit without a cached image cannot pass preflight' {
        Import-TestFunctions (Join-Path $dir 'create-cicd.ps1') @('Ensure-CicdBuildImage')
        $env:CLOUDTASKS_TEST_CASE = 'image-pull-empty'
        $rejected = $false
        try { $null = Ensure-CicdBuildImage -Image 'public.ecr.aws/codebuild/amazonlinux-x86_64-standard:5.0' }
        catch { $rejected = $true }
        Assert-True $rejected
    }
    foreach ($case in @('diagnostic-linked-short-id', 'diagnostic-candidate-short-id')) {
        Check "diagnostic distinguishes native linkage in $case without exposing environment secrets" {
            $env:CLOUDTASKS_TEST_CASE = $case
            $env:CLOUDTASKS_TEST_DB_CANARY = 'CT_' + [Guid]::NewGuid().ToString('N')
            $output = @(& (Join-Path $dir 'diagnose-cicd.ps1') *>&1) -join "`n"
            Assert-True (-not $output.Contains($env:CLOUDTASKS_TEST_DB_CANARY))
            Assert-True (-not $output.Contains('registry.example.test'))
            Assert-True ($output.Contains('CodeBuild ID:     cloudtasks-build:4a3385dc'))
            Assert-True ($output.Contains('Exit 0 do runner nao comprova sucesso'))
            if ($case -eq 'diagnostic-linked-short-id') {
                Assert-True ($output.Contains('ID fornecido pela acao BuildAndPush desta execucao'))
                Assert-True (-not $output.Contains('somente candidato'))
            } else {
                Assert-True ($output.Contains('somente candidato de diagnostico'))
                Assert-True ($output.Contains('timeout informado pela acao nativa'))
            }
        }
    }
    # Diagnose runs as a script and must not replace the functions under test.
    Import-TestFunctions (Join-Path $dir 'create-cicd.ps1') @('Invoke-AwsLocalRaw', 'Invoke-AwsLocalJson')
    Check 'S3 VersionId output variable is the canonical native identity' {
        $env:CLOUDTASKS_TEST_CASE = 'source-variable'
        $result = Wait-PipelineExecution -ExecutionId '22222222-2222-4222-8222-222222222222' -SourceVersionId 'source-version'
        Assert-True ([string]$result.CodeBuildId -eq 'cloudtasks-build:11111111-1111-4111-8111-111111111111')
    }
    Check 'conflicting S3 VersionId output variable must be rejected' {
        $env:CLOUDTASKS_TEST_CASE = 'source-conflict'
        $rejected = $false
        try { $null = Wait-PipelineExecution -ExecutionId '22222222-2222-4222-8222-222222222222' -SourceVersionId 'source-version' }
        catch { $rejected = $true }
        Assert-True $rejected
    }
    Check 'ECR create conflict is verified by exact lookup' {
        $env:CLOUDTASKS_TEST_CASE = 'ecr-race'
        Remove-Item -LiteralPath $env:CLOUDTASKS_TEST_COUNTER -Force -ErrorAction SilentlyContinue
        $null = & (Join-Path $dir 'create-ecr.ps1') 6>&1
    }
    Check 'database error never echoes supplied credential' {
        Import-TestFunctions (Join-Path $dir 'create-database.ps1') @('Invoke-AwsLocalRaw', 'Invoke-AwsLocalJson')
        $canary = 'CT_' + [Guid]::NewGuid().ToString('N')
        $rejected = $false
        try { $null = Invoke-AwsLocalJson @('rds', 'create-db-instance', '--master-user-password', $canary) }
        catch { $rejected = $true; Assert-True (-not $_.Exception.Message.Contains($canary)) }
        Assert-True $rejected
    }
    Import-TestFunctions (Join-Path $dir 'create-database.ps1') @('Get-SecretMetadataSafely', 'Get-SecretValueSafely')
    foreach ($secretReader in @('Get-SecretMetadataSafely', 'Get-SecretValueSafely')) {
        Check "$secretReader never echoes a credential from provider errors" {
            $env:CLOUDTASKS_TEST_CASE = 'secret-provider-failure'
            $env:CLOUDTASKS_TEST_DB_CANARY = 'CT_' + [Guid]::NewGuid().ToString('N')
            $rejected = $false
            try { $null = & $secretReader -SecretId 'cloudtasks/database' }
            catch { $rejected = $true; Assert-True (-not $_.Exception.Message.Contains($env:CLOUDTASKS_TEST_DB_CANARY)) }
            Assert-True $rejected
        }
    }

    $sourceRoot = Join-Path $testRoot 'source'
    $sourceScriptDir = Join-Path $sourceRoot 'scripts/localstack'
    New-Item -ItemType Directory -Path $sourceScriptDir -Force | Out-Null
    Copy-Item (Join-Path $dir 'publish-cicd-source.ps1') (Join-Path $sourceScriptDir 'publish-cicd-source.ps1')
    $sourceScript = Join-Path $sourceScriptDir 'publish-cicd-source.ps1'
    foreach ($relative in @('package.json', 'package-lock.json', 'Dockerfile', '.dockerignore', 'eslint.config.mjs', '.nvmrc',
        'buildspec.localstack.yml', 'buildspec.yml', 'apps/api/package.json', 'apps/api/tsconfig.json',
        'apps/api/src/server.ts', 'apps/web/package.json', 'apps/web/tsconfig.json',
        'apps/web/vite.config.ts', 'apps/web/index.html', 'apps/web/src/main.tsx',
        'secrets/credentials.txt', 'localstack-volume/state.json', 'certificate.pem')) {
        $path = Join-Path $sourceRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, 'fixture', $utf8)
    }
    $sourceCanary = 'CT_' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText((Join-Path $sourceRoot '.env.localstack'), "LOCALSTACK_AUTH_TOKEN=$sourceCanary", $utf8)
    $env:CLOUDTASKS_TEST_CASE = 'healthy'
    Check 'snapshot publication works in a fresh PowerShell process' {
        $freshProcessScript = @'
param([string]$SourceScript)
$ErrorActionPreference = 'Stop'
$published = & $SourceScript
if ([string]$published.VersionId -ne 'source-upload-version') { throw 'Source upload identity was not returned.' }
$archive = [IO.Compression.ZipFile]::OpenRead($env:CLOUDTASKS_TEST_ZIP)
try {
    $entry = $archive.GetEntry('apps/api/src/server.ts')
    if ($null -eq $entry) { throw 'Required source entry missing from ZIP.' }
    $reader = New-Object IO.StreamReader($entry.Open())
    try {
        if ($reader.ReadToEnd() -ne 'fixture') { throw 'Source contents did not survive ZIP publication.' }
    } finally { $reader.Dispose() }
} finally { $archive.Dispose() }
'@
        $freshProcessPath = Join-Path $testRoot 'publish-source-fresh.ps1'
        [IO.File]::WriteAllText($freshProcessPath, $freshProcessScript, $utf8)
        Remove-Item -LiteralPath $env:CLOUDTASKS_TEST_ZIP -Force -ErrorAction SilentlyContinue
        $powershellExecutable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $processOutput = @(& $powershellExecutable -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $freshProcessPath $sourceScript 2>&1)
            $processExit = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previous }
        if ($processExit -ne 0) { throw "Fresh process Source publication failed (exit=$processExit): $($processOutput -join ' ')" }
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Check 'snapshot excludes runtime, credentials and certificate files' {
        $null = & $sourceScript 6>&1
        $archive = [IO.Compression.ZipFile]::OpenRead($env:CLOUDTASKS_TEST_ZIP)
        try {
            $names = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
            foreach ($forbidden in @('secrets/credentials.txt', 'localstack-volume/state.json', 'certificate.pem', '.env.localstack')) {
                Assert-True (-not ($names -contains $forbidden))
            }
            Assert-True ($names -contains 'apps/api/src/server.ts')
            foreach ($requiredInput in @('Dockerfile', '.dockerignore', 'package-lock.json')) {
                Assert-True ($names -contains $requiredInput)
            }
        } finally { $archive.Dispose() }
    }
    Check 'source VersionId comes from this upload, not a later HEAD' {
        $published = & $sourceScript
        Assert-True ([string]$published.VersionId -eq 'source-upload-version')
    }
    Check 'snapshot hash does not change with file modification time' {
        $null = & $sourceScript 6>&1
        $firstHash = (Get-FileHash $env:CLOUDTASKS_TEST_ZIP -Algorithm SHA256).Hash
        (Get-Item (Join-Path $sourceRoot 'apps/api/src/server.ts')).LastWriteTime = [datetime]'2001-01-01'
        $null = & $sourceScript 6>&1
        Assert-True ($firstHash -eq (Get-FileHash $env:CLOUDTASKS_TEST_ZIP -Algorithm SHA256).Hash)
    }
    Check 'active local credential in source code blocks publication' {
        [IO.File]::WriteAllText((Join-Path $sourceRoot 'apps/api/src/leak.ts'), $sourceCanary, $utf8)
        $rejected = $false
        try { $null = & $sourceScript 6>&1 }
        catch { $rejected = $true; Assert-True (-not $_.Exception.Message.Contains($sourceCanary)) }
        Assert-True $rejected
    }
    Check 'active RDS credential in source code blocks publication' {
        Remove-Item (Join-Path $sourceRoot 'apps/api/src/leak.ts') -Force
        $env:CLOUDTASKS_TEST_DB_CANARY = 'CT_' + [Guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText((Join-Path $sourceRoot 'apps/api/src/leak.ts'), $env:CLOUDTASKS_TEST_DB_CANARY, $utf8)
        $rejected = $false
        try { $null = & $sourceScript 6>&1 }
        catch { $rejected = $true; Assert-True (-not $_.Exception.Message.Contains($env:CLOUDTASKS_TEST_DB_CANARY)) }
        Assert-True $rejected
    }

    $acceptanceRoot = Join-Path $testRoot 'acceptance'
    $acceptanceDir = Join-Path $acceptanceRoot 'scripts/localstack'
    New-Item -ItemType Directory -Path $acceptanceDir -Force | Out-Null
    foreach ($name in @('test-cicd.ps1','ecs-runtime-context.ps1','cicd-artifact-context.ps1')) { Copy-Item (Join-Path $dir $name) (Join-Path $acceptanceDir $name) }
    [IO.File]::WriteAllText((Join-Path $acceptanceDir 'test-https.ps1'), "Write-Host 'HTTPS dependency simulated by acceptance fixture'", $utf8)
    $stateDir = Join-Path $acceptanceRoot '.localstack/cicd'
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $env:CLOUDTASKS_TEST_SOURCE_BYTES = Join-Path $testRoot 'source-bytes.zip'
    [IO.File]::WriteAllText($env:CLOUDTASKS_TEST_SOURCE_BYTES, 'controlled-source-fixture', $utf8)
    $env:CLOUDTASKS_TEST_ARTIFACT_BYTES = Join-Path $testRoot 'build-artifact.zip'
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $artifactZip = [IO.Compression.ZipFile]::Open($env:CLOUDTASKS_TEST_ARTIFACT_BYTES, [IO.Compression.ZipArchiveMode]::Create)
    $writer = New-Object IO.StreamWriter($artifactZip.CreateEntry('imagedefinitions.json').Open())
    $writer.Write('[{"name":"cloudtasks-app","imageUri":"000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4566/cloudtasks:pipeline-11111111-1111-4111-8111-111111111111"}]')
    $writer.Dispose(); $artifactZip.Dispose()
    . (Join-Path $dir 'cicd-artifact-context.ps1')
    Check 'standard native artifact supplies an independent immutable image tag' {
        $artifact = Read-CloudTasksBuildArtifact -Path $env:CLOUDTASKS_TEST_ARTIFACT_BYTES -RepositoryUri '000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4566/cloudtasks' -Bucket 'bucket' -Key 'key'
        Assert-True ($artifact.ImageTag -ceq 'pipeline-11111111-1111-4111-8111-111111111111')
    }
    Check 'artifact cannot select an unrelated repository' {
        $rejected = $false
        try { $null = Read-CloudTasksBuildArtifact -Path $env:CLOUDTASKS_TEST_ARTIFACT_BYTES -RepositoryUri 'other-repository' } catch { $rejected = $true }
        Assert-True $rejected
    }
    Check 'artifact rejects a build not linked to the native action' {
        $rejected = $false
        try { $null = Get-CloudTasksNativeBuildImage -BuildAction ([pscustomobject]@{ output = @{ executionResult = @{ externalExecutionId = 'actual' } } }) -Build ([pscustomobject]@{ id = 'unrelated'; buildStatus = 'SUCCEEDED' }) -RepositoryUri 'repo' } catch { $rejected = $true }
        Assert-True $rejected
    }
    Check 'native output location must match the exact linked CodeBuild artifact' {
        $rejected = $false
        $action = [pscustomobject]@{ output = @{ executionResult = @{ externalExecutionId = 'actual' }; outputArtifacts = @(@{ name = 'BuildOutput'; s3location = @{bucket = 'bucket'; key = 'key'} }) } }
        $build = [pscustomobject]@{ id = 'actual'; buildStatus = 'SUCCEEDED'; artifacts = @{ location = 'arn:aws:s3:::other/key' } }
        try { $null = Get-CloudTasksNativeBuildImage -BuildAction $action -Build $build -RepositoryUri 'repo' } catch { $rejected = $true }
        Assert-True $rejected
    }
    $state = [ordered]@{
        executionMode = 'NativeCodePipeline'; executionId = '22222222-2222-4222-8222-222222222222'
        clusterName = 'cloudtasks-cluster-r20261001000000000'; serviceName = 'cloudtasks-service'
        codeBuildId = 'cloudtasks-build:11111111-1111-4111-8111-111111111111'
        sourceBucket = 'cloudtasks-pipeline-source'; sourceObjectKey = 'cloudtasks-source.zip'; sourceVersionId = 'source-version'
        buildArtifactBucket = 'cloudtasks-pipeline-artifacts'; buildArtifactKey = 'cloudtasks-pipeline/BuildOutput/native-artifact'
        buildArtifactSha256 = (Get-FileHash $env:CLOUDTASKS_TEST_ARTIFACT_BYTES -Algorithm SHA256).Hash.ToLowerInvariant()
        sourceSha256 = (Get-FileHash $env:CLOUDTASKS_TEST_SOURCE_BYTES -Algorithm SHA256).Hash.ToLowerInvariant()
        deployedTaskDefinition = 'arn:aws:ecs:us-east-1:000000000000:task-definition/cloudtasks:2'
        deployedImage = '000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4566/cloudtasks:pipeline-11111111-1111-4111-8111-111111111111'
        deployedImageDigest = 'sha256:' + ('1' * 64)
    }
    [IO.File]::WriteAllText((Join-Path $stateDir 'last-deploy.json'), ($state | ConvertTo-Json -Depth 5), $utf8)
    foreach ($case in @('acceptance-old-task','acceptance-unhealthy','acceptance-wrong-digest')) {
        Check "acceptance rejects $case despite healthy service counters" {
            $env:CLOUDTASKS_TEST_CASE = $case
            $rejected = $false
            try { $null = & (Join-Path $acceptanceDir 'test-cicd.ps1') 6>&1 }
            catch { $rejected = $true }
            Assert-True $rejected
        }
    }
    Check 'acceptance follows exact Source, CodeBuild, tasks and digest' {
        $env:CLOUDTASKS_TEST_CASE = 'acceptance-healthy'
        $null = & (Join-Path $acceptanceDir 'test-cicd.ps1') 6>&1
    }
    Check 'physical image alias accepted only when its ECR digest is confirmed' {
        $env:CLOUDTASKS_TEST_CASE = 'acceptance-image-alias'
        $null = & (Join-Path $acceptanceDir 'test-cicd.ps1') 6>&1
    }
    Check 'acceptance preserves short native build ID through ECR and task identity' {
        $env:CLOUDTASKS_TEST_CASE = 'acceptance-short-id'
        $state.codeBuildId = 'cloudtasks-build:4a3385dc'
        [IO.File]::WriteAllText((Join-Path $stateDir 'last-deploy.json'), ($state | ConvertTo-Json -Depth 5), $utf8)
        $null = & (Join-Path $acceptanceDir 'test-cicd.ps1') 6>&1
    }

    if ($failures.Count) { throw "$($failures.Count) regression(s) failed: $($failures -join ', ')" }
    Write-Host "$testCount regressions passed. External AWS/Docker services were simulated."
}
finally {
    Set-Location -LiteralPath $savedLocation
    $env:USERPROFILE = $savedProfile
    $env:PATH = $savedPath
    $env:CLOUDTASKS_TEST_CASE = $savedCase
    $env:CLOUDTASKS_TEST_COUNTER = $savedCounter
    $env:CLOUDTASKS_TEST_ZIP = $savedZip
    $env:CLOUDTASKS_TEST_DB_CANARY = $savedDbCanary
    $env:CLOUDTASKS_TEST_SOURCE_BYTES = $savedSourceBytes
    $env:CLOUDTASKS_TEST_ARTIFACT_BYTES = $savedArtifactBytes
    $env:CLOUDTASKS_TEST_NODE = $savedNode
    $env:CLOUDTASKS_TEST_FIXTURE = $savedFixture
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
