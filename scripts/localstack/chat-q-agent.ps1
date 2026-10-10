$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'q-agent-localstack.mjs') chat
if ($LASTEXITCODE -ne 0) { throw 'Sessao Amazon Q nao concluida.' }
