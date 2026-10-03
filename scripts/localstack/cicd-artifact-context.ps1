# Native artifact identity shared by creation and acceptance; no deployment fallback.
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
