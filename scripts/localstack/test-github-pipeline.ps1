$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'github-pipeline-localstack.mjs') test
if ($LASTEXITCODE -ne 0) { throw 'Pipeline GitHub nao aprovada; consulte a evidencia da falha.' }
