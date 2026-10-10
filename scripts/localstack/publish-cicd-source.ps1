param(
    [string]$BucketName = 'cloudtasks-pipeline-source',
    [string]$ObjectKey = 'cloudtasks-source.zip'
)
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

function Invoke-AwsLocalJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = @(& docker exec cloudtasks-localstack awslocal @Arguments --output json 2>&1)
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    if ($exitCode -ne 0) { throw "awslocal $($Arguments[0]) $($Arguments[1]) falhou (exit=$exitCode)." }
    $text = (($raw | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { return ($text | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw "JSON de awslocal $($Arguments[0]) $($Arguments[1]) invalido." }
}

# Explicit build inputs: no repository-wide recursive copy and no Git-index dependency.
$relativePaths = New-Object 'System.Collections.Generic.List[string]'
foreach ($relative in @('package.json','package-lock.json','Dockerfile','.dockerignore','eslint.config.mjs','.nvmrc',
    'buildspec.yml','buildspec.localstack.yml','buildspec.bluegreen.localstack.yml',
    'scripts/localstack/blue-green-controller.mjs','scripts/localstack/blue-green-localstack.mjs',
    'scripts/tests/blue-green.test.mjs','scripts/tests/blue-green-guards.test.mjs',
    'scripts/localstack/cloudfront-config.mjs','scripts/localstack/localstack-tools.mjs',
    'scripts/localstack/observability-config.mjs','scripts/mcp/mcp-config.mjs','scripts/mcp/mcp-session-lifecycle.mjs',
    'scripts/mcp/mcp-aws-input.mjs',
    'scripts/tests/cloudfront.test.mjs','scripts/tests/observability.test.mjs','scripts/tests/mcp.test.mjs',
    'scripts/localstack/github-pipeline-config.mjs','scripts/tests/github-pipeline.test.mjs',
    'apps/api/package.json','apps/api/tsconfig.json',
    'apps/web/package.json','apps/web/tsconfig.json','apps/web/vite.config.ts','apps/web/index.html')) {
    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot $relative) -PathType Leaf)) { throw "Source requerido ausente: $relative" }
    $relativePaths.Add($relative)
}
foreach ($relativeRoot in @('apps/api/src','apps/api/test','apps/web/src','apps/web/test')) {
    $directory = Join-Path $projectRoot $relativeRoot
    if (-not (Test-Path -LiteralPath $directory)) { continue }
    $items = @(Get-Item -LiteralPath $directory -Force) + @(Get-ChildItem -LiteralPath $directory -Recurse -Force)
    foreach ($item in $items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Link/junction nao permitido no Source: $relativeRoot" }
        if ($item.PSIsContainer) { continue }
        $relative = $item.FullName.Substring($projectRoot.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
        $segments = $relative -split '/'
        if (@($segments | Where-Object { $_ -in @('node_modules','dist','coverage','secrets','credentials','.git','.aws','.ssh','.localstack','.localstack-runtime','.localstack-volume','localstack-volume') }).Count) { continue }
        if ($item.Name -like '.env*' -or $item.Extension -notin @('.ts','.tsx','.js','.mjs','.json','.css','.html','.svg','.png','.jpg','.jpeg','.webp','.ico','.woff','.woff2')) { continue }
        $relativePaths.Add($relative)
    }
}
$relativePaths.Sort([StringComparer]::Ordinal)
$knownCredentials = @()
# Read the active RDS credential only in memory; neither response nor value is logged.
$databaseSecret = Invoke-AwsLocalJson @('secretsmanager','get-secret-value','--secret-id','cloudtasks/database')
try { $databaseCredential = [string]$databaseSecret.SecretString | ConvertFrom-Json -ErrorAction Stop }
catch { throw 'Secret do banco invalido; o Source nao foi publicado.' }
if ([string]::IsNullOrWhiteSpace([string]$databaseCredential.password)) { throw 'Secret do banco sem credencial; o Source nao foi publicado.' }
$knownCredentials += [string]$databaseCredential.password
foreach ($envFile in @(Get-ChildItem -LiteralPath $projectRoot -File -Force | Where-Object { $_.Name -like '.env*' -and $_.Name -ne '.env.example' })) {
    foreach ($line in @(Get-Content -LiteralPath $envFile.FullName)) {
        if ([string]$line -match '^\s*(?:LOCALSTACK_AUTH_TOKEN|AWS_SECRET_ACCESS_KEY|DATABASE_PASSWORD|DB_PASSWORD)\s*=\s*(.+?)\s*$') {
            $value = $Matches[1].Trim([char[]]@('"',"'"))
            if ($value.Length -ge 8) { $knownCredentials += $value }
        }
    }
}
# Block known local values and recognizable private keys/provider credentials.
foreach ($relative in $relativePaths) {
    $path = Join-Path $projectRoot $relative
    if (((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Link nao permitido no Source: $relative" }
    $contents = [IO.File]::ReadAllText($path)
    if ($contents -match '(?m)-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----|\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|\bgh[pousr]_[A-Za-z0-9]{30,}\b|\bls-[A-Za-z0-9_-]{20,}\b') { throw "Possivel credencial no Source: $relative. Publicacao bloqueada." }
    foreach ($value in $knownCredentials) {
        if ($contents.Contains($value)) { throw "Credencial local detectada no Source: $relative. Publicacao bloqueada." }
    }
}

$zipPath = Join-Path ([IO.Path]::GetTempPath()) ('cloudtasks-source-' + [Guid]::NewGuid().ToString('N') + '.zip')
$containerZip = '/tmp/cloudtasks-source-' + [Guid]::NewGuid().ToString('N') + '.zip'
try {
    Write-Host '[1/4] Empacotando inputs autorizados do working tree...' -ForegroundColor Cyan
    # Windows PowerShell 5.1 resolves archive enums from this separate assembly.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($relative in $relativePaths) {
            $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::Parse('1980-01-01T00:00:00+00:00')
            $source = [IO.File]::OpenRead((Join-Path $projectRoot $relative))
            $destination = $entry.Open()
            try { $source.CopyTo($destination) }
            finally { $destination.Dispose(); $source.Dispose() }
        }
    } finally { $archive.Dispose() }
    $sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()

    Write-Host '[2/4] Garantindo bucket versionado...' -ForegroundColor Cyan
    $buckets = Invoke-AwsLocalJson @('s3api','list-buckets')
    if (-not (@($buckets.Buckets.Name) -contains $BucketName)) { $null = Invoke-AwsLocalJson @('s3api','create-bucket','--bucket',$BucketName) }
    $null = Invoke-AwsLocalJson @('s3api','put-bucket-versioning','--bucket',$BucketName,'--versioning-configuration','Status=Enabled')
    $versioning = Invoke-AwsLocalJson @('s3api','get-bucket-versioning','--bucket',$BucketName)
    if ([string]$versioning.Status -ne 'Enabled') { throw 'Versionamento Source S3 nao confirmado.' }

    Write-Host '[3/4] Publicando snapshot...' -ForegroundColor Cyan
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $copyOutput = @(& docker cp $zipPath "cloudtasks-localstack:$containerZip" 2>&1); $copyExit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    if ($copyExit -ne 0) { throw "Copia do Source ZIP falhou (exit=$copyExit)." }
    $uploaded = Invoke-AwsLocalJson @('s3api','put-object','--bucket',$BucketName,'--key',$ObjectKey,'--body',$containerZip,
        '--metadata',"source-sha256=$sha256")
    if ([string]::IsNullOrWhiteSpace([string]$uploaded.VersionId) -or [string]$uploaded.VersionId -eq 'null') { throw 'PutObject nao retornou VersionId valido.' }
    Write-Host '[4/4] Identidade do upload registrada.' -ForegroundColor Green
    Write-Host "Source: s3://$BucketName/$ObjectKey / version=$($uploaded.VersionId) / sha256=$sha256"
    return [pscustomobject]@{ BucketName = $BucketName; ObjectKey = $ObjectKey; VersionId = [string]$uploaded.VersionId; Sha256 = $sha256; FileCount = $relativePaths.Count }
}
finally {
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $null = & docker exec cloudtasks-localstack rm -f $containerZip 2>&1 }
    finally { $ErrorActionPreference = $previous }
}
