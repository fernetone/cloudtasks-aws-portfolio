$ErrorActionPreference = "Stop"

$scriptDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$files = @(Get-ChildItem -Path $scriptDirectory -Filter "*.ps1" -Recurse -File | Sort-Object FullName)
if ($files.Count -lt 1) {
    throw "Nenhum script PowerShell foi encontrado em '$scriptDirectory'."
}

$totalErrors = 0
foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if (@($parseErrors).Count -gt 0) {
        Write-Host "ERRO: $($file.Name)" -ForegroundColor Red
        foreach ($parseError in @($parseErrors)) {
            Write-Host "  linha $($parseError.Extent.StartLineNumber), coluna $($parseError.Extent.StartColumnNumber): $($parseError.Message)" -ForegroundColor Red
        }
        $totalErrors += @($parseErrors).Count
    }
}

if ($totalErrors -gt 0) {
    throw "Foram encontrados $totalErrors erro(s) de parser nos scripts LocalStack."
}

Write-Host "PowerShell preflight: OK ($($files.Count) scripts analisados pelo parser nativo)." -ForegroundColor Green
