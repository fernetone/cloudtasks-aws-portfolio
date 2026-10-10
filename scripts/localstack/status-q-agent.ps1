$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'q-agent-localstack.mjs') status
if ($LASTEXITCODE -ne 0) { throw 'Estado Amazon Q indeterminado.' }
