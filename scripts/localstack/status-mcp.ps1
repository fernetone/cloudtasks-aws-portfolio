$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'mcp-localstack.mjs') status
if ($LASTEXITCODE -ne 0) { throw 'Evidencia MCP nao verificada.' }
