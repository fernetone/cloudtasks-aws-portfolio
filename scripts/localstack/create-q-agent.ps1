$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'install-q-agent.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Instalacao Amazon Q nao verificada.' }
