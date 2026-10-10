param([Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{40}$')][string]$ExpectedCommit)
$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'github-pipeline-localstack.mjs') create $ExpectedCommit
if ($LASTEXITCODE -ne 0) { throw 'Pipeline GitHub nao foi iniciada; consulte a evidencia da falha.' }
