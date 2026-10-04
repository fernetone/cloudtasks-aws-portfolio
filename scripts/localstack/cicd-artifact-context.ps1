# Native artifact identity shared by creation and acceptance; no deployment fallback.
function Assert-CloudTasksBlueGreenReceipt {
    param([object]$Receipt, [string]$ExecutionId, [string]$ImageBuildId, [string]$ImageUri,
        [string]$ImageDigest, [string]$TaskDefinitionArn)
    if ([string]$Receipt.mode -cne 'LocalStackBlueGreenAdapter' -or [string]$Receipt.status -cne 'SUCCEEDED' -or
        $Receipt.nativeBlueGreenControllerCertified -isnot [bool] -or $Receipt.nativeBlueGreenControllerCertified -ne $false -or
        [string]$Receipt.executionId -cne $ExecutionId -or [string]$Receipt.provenance.imageBuildId -cne $ImageBuildId) {
        throw 'Recibo Blue/Green nao comprova esta execucao CodeBuild/CodePipeline.'
    }
    foreach ($phase in @('BLUE_VERIFIED','CANDIDATE_VERIFIED','TRAFFIC_PROMOTED','BAKE_PASSED','CANONICAL_VERIFIED')) {
        if (-not (@($Receipt.phases) -ccontains $phase)) { throw "Fase Blue/Green ausente: $phase" }
    }
    if ([string]$Receipt.green.image -cne $ImageUri -or [string]$Receipt.green.digest -cne $ImageDigest -or
        [string]$Receipt.blue.digest -ceq $ImageDigest -or [string]$Receipt.final.image -cne $ImageUri -or
        [string]$Receipt.final.digest -cne $ImageDigest -or [string]$Receipt.final.taskDefinition -cne $TaskDefinitionArn -or
        [string]$Receipt.green.releaseId -cne ($ImageUri -split ':')[-1] -or
        [string]$Receipt.final.releaseId -cne [string]$Receipt.green.releaseId) { throw 'Identidade Blue/Green diverge da imagem/revisao entregue.' }
    $retirement = $Receipt.final.canonicalRetirement
    if ($null -eq $retirement -or @($retirement.taskArns).Count -lt 2 -or
        $null -eq $retirement.emptySamples -or [int]$retirement.emptySamples -lt 2 -or
        $null -eq $retirement.physicalRunning -or [int]$retirement.physicalRunning -ne 0 -or
        [string]$retirement.productionHttp -cne 'green' -or [string]$retirement.productionHttps -cne 'green') {
        throw 'Transicao canonica sem runtime vazio e trafego HTTP/HTTPS na candidata nao comprovada.'
    }
    if ([int]$Receipt.bake.requiredSeconds -lt 60 -or [double]$Receipt.bake.elapsedSeconds -lt [int]$Receipt.bake.requiredSeconds -or
        @($Receipt.bake.samples).Count -lt 2) { throw 'Janela Blue/Green nao comprovada.' }
    foreach ($sample in @($Receipt.bake.samples)) {
        if ([int]$sample.blueHealthy -ne 2 -or [int]$sample.greenHealthy -ne 2 -or $sample.httpsPinned -ne $true -or
            [string]$sample.blueHttp -cne 'blue' -or [string]$sample.blueHttps -cne 'blue' -or
            [string]$sample.productionRelease -cne [string]$Receipt.green.releaseId) { throw 'Coexistencia/HTTPS na janela Blue/Green nao comprovados.' }
    }
    if ([double](@($Receipt.bake.samples)[-1].seconds) -lt [int]$Receipt.bake.requiredSeconds) { throw 'Amostra final Blue/Green anterior ao fim da janela.' }
    if ([string]$Receipt.isolation.productionHttp -ne 'blue' -or [string]$Receipt.isolation.productionHttps -ne 'blue' -or
        [string]$Receipt.isolation.testHttp -ne 'green' -or [string]$Receipt.isolation.testHttps -ne 'green' -or
        $Receipt.sharedData.createBlueReadGreen -ne $true -or $Receipt.sharedData.updateGreenReadBlue -ne $true -or
        $Receipt.sharedData.ownedTaskDeleted -ne $true) { throw 'Isolamento/CRUD compartilhado Blue/Green nao comprovado.' }
    foreach ($side in @('blue','green','final')) {
        $tasks = @($Receipt.$side.tasks)
        if ($tasks.Count -ne 2 -or @($tasks.containerId | Select-Object -Unique).Count -ne 2) { throw "Duas replicas fisicas nao comprovadas: $side" }
        foreach ($task in $tasks) { if ([string]$task.health -cne 'healthy') { throw "Replica Blue/Green nao saudavel: $side" } }
    }
    foreach ($property in @('temporaryServiceRemoved','temporaryRulesRemoved','temporaryGroupRemoved',
        'temporaryDefinitionDeregistered','temporaryContainersRemoved','temporaryLogsRemoved')) {
        if ($Receipt.cleanup.$property -ne $true) { throw 'Limpeza Blue/Green incompleta; deploy nao aprovado.' }
    }
}

function Get-CloudTasksBlueGreenReceipt {
    param([object]$DeployAction, [object]$Build)
    if ([string]$DeployAction.output.executionResult.externalExecutionId -cne [string]$Build.id -or
        [string]$Build.buildStatus -cne 'SUCCEEDED') { throw 'DeployOutput requer o CodeBuild vinculado e SUCCEEDED.' }
    $outputs = @($DeployAction.output.outputArtifacts | Where-Object { [string]$_.name -ceq 'DeployOutput' })
    if ($outputs.Count -ne 1) { throw 'DeployOutput nativo ausente ou ambiguo.' }
    $bucket = [string]$outputs[0].s3location.bucket
    $key = [string]$outputs[0].s3location.key
    if ([string]::IsNullOrWhiteSpace($bucket) -or [string]::IsNullOrWhiteSpace($key) -or
        [string]$Build.artifacts.location -cne "arn:aws:s3:::${bucket}/$key") { throw 'DeployOutput nao corresponde ao CodeBuild vinculado.' }
    $remote = '/tmp/cloudtasks-deploy-artifact-' + [guid]::NewGuid().ToString('N') + '.zip'
    $local = [IO.Path]::GetTempFileName()
    try {
        $null = Invoke-AwsLocalJson @('s3api','get-object','--bucket',$bucket,'--key',$key,$remote)
        $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $null = @(& docker cp "cloudtasks-localstack:$remote" $local 2>&1); $copyExit = $LASTEXITCODE }
        finally { $ErrorActionPreference = $previous }
        if ($copyExit -ne 0 -or (Get-Item -LiteralPath $local).Length -gt 2097152) { throw 'DeployOutput invalido ou excessivo.' }
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($local)
        try {
            $entries = @($zip.Entries | Where-Object { $_.FullName -ceq 'deployment-receipt.json' })
            if ($entries.Count -ne 1 -or $entries[0].Length -gt 1048576) { throw 'Recibo de deploy ausente, ambiguo ou excessivo.' }
            $reader = New-Object IO.StreamReader($entries[0].Open())
            try { $receipt = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop } finally { $reader.Dispose() }
        } finally { $zip.Dispose() }
        return [pscustomobject]@{ Receipt = $receipt; ArtifactBucket = $bucket; ArtifactKey = $key;
            ArtifactSha256 = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    finally {
        Remove-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue
        $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $null = & docker exec cloudtasks-localstack rm -f $remote 2>&1 } finally { $ErrorActionPreference = $previous }
    }
}

function Get-CloudTasksNativeBuildImage {
    param([object]$BuildAction, [object]$Build, [string]$RepositoryUri)
    if ([string]$BuildAction.output.executionResult.externalExecutionId -cne [string]$Build.id -or [string]$Build.buildStatus -ne 'SUCCEEDED') { throw 'Artifact requer o CodeBuild nativo vinculado e SUCCEEDED.' }
    $outputs = @($BuildAction.output.outputArtifacts | Where-Object { [string]$_.name -eq 'BuildOutput' })
    if ($outputs.Count -ne 1) { throw 'BuildOutput nativo ausente ou ambiguo.' }
    $bucket = [string]$outputs[0].s3location.bucket
    $key = [string]$outputs[0].s3location.key
    if ([string]::IsNullOrWhiteSpace($bucket) -or [string]::IsNullOrWhiteSpace($key) -or [string]$Build.artifacts.location -cne "arn:aws:s3:::${bucket}/$key") { throw 'Artifact S3 nao corresponde ao CodeBuild vinculado.' }
    $remote = '/tmp/cloudtasks-build-artifact-' + [guid]::NewGuid().ToString('N') + '.zip'
    $local = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
    try {
        $null = Invoke-AwsLocalJson @('s3api','get-object','--bucket',$bucket,'--key',$key,$remote)
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $null = @(& docker cp "cloudtasks-localstack:$remote" $local 2>&1); $copyExit = $LASTEXITCODE }
        finally { $ErrorActionPreference = $previous }
        if ($copyExit -ne 0) { throw 'Download do BuildOutput nativo falhou.' }
        return Read-CloudTasksBuildArtifact -Path $local -RepositoryUri $RepositoryUri -Bucket $bucket -Key $key
    }
    finally {
        Remove-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $null = & docker exec cloudtasks-localstack rm -f $remote 2>&1 }
        finally { $ErrorActionPreference = $previous }
    }
}

function Read-CloudTasksBuildArtifact {
    param([string]$Path, [string]$RepositoryUri, [string]$Bucket, [string]$Key)
    if ((Get-Item -LiteralPath $Path).Length -gt 2097152) { throw 'BuildOutput excede o limite esperado.' }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entries = @($zip.Entries | Where-Object { $_.FullName -ceq 'imagedefinitions.json' })
        if ($entries.Count -ne 1 -or $entries[0].Length -gt 8192) { throw 'imagedefinitions.json ausente, ambiguo ou excessivo.' }
        $reader = New-Object IO.StreamReader($entries[0].Open())
        try { $json = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if (-not $json.TrimStart().StartsWith('[')) { throw 'imagedefinitions.json deve ser um array.' }
        $definitions = [object[]]($json | ConvertFrom-Json -ErrorAction Stop)
        if ($definitions.Count -ne 1 -or [string]$definitions[0].name -cne 'cloudtasks-app') { throw 'Container inesperado no artifact.' }
        $uri = [string]$definitions[0].imageUri
        $prefix = $RepositoryUri + ':pipeline-'
        if (-not $uri.StartsWith($prefix, [StringComparison]::Ordinal)) { throw 'Repositorio inesperado no artifact.' }
        $uuid = $uri.Substring($prefix.Length)
        if ($uuid -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$') { throw 'Tag imutavel deve conter UUID v4 gerado pelo build.' }
        return [pscustomobject]@{ ImageUri = $uri; ImageTag = 'pipeline-' + $uuid; ArtifactBucket = $Bucket; ArtifactKey = $Key; ArtifactSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    finally { $zip.Dispose() }
}
