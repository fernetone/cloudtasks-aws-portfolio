$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'github-pipeline-localstack.mjs') status
if ($LASTEXITCODE -ne 0) { throw 'Estado da pipeline GitHub nao foi confirmado.' }
