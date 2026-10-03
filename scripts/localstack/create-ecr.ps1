param([string]$RepositoryName = 'cloudtasks')
$ErrorActionPreference = 'Stop'

function Invoke-EcrRaw {
    param([string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = @(& docker exec cloudtasks-localstack awslocal ecr @Arguments --region us-east-1 --output json 2>&1)
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ ExitCode = $exitCode; Text = (($raw | ForEach-Object { $_.ToString() }) -join "`n") }
}

function Get-EcrRepository {
    $result = Invoke-EcrRaw @('describe-repositories','--registry-id','000000000000','--repository-names',$RepositoryName)
    if ($result.ExitCode -ne 0) {
        if ($result.Text -match 'RepositoryNotFoundException') { return $null }
        throw "Consulta exata do ECR falhou (exit=$($result.ExitCode))."
    }
    try { $payload = $result.Text | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'JSON da consulta exata do ECR invalido.' }
    $items = @($payload.repositories | Where-Object { [string]$_.repositoryName -eq $RepositoryName })
    if ($items.Count -ne 1) { throw 'Consulta exata do ECR nao retornou um unico repositorio esperado.' }
    return $items[0]
}

Write-Host 'Consultando ECR local pelo nome...' -ForegroundColor Cyan
$repository = Get-EcrRepository
if ($null -eq $repository) {
    $created = Invoke-EcrRaw @('create-repository','--repository-name',$RepositoryName,
        '--image-tag-mutability','IMMUTABLE','--image-scanning-configuration','scanOnPush=true')
    if ($created.ExitCode -eq 0) {
        try { $repository = ($created.Text | ConvertFrom-Json -ErrorAction Stop).repository }
        catch { throw 'JSON CreateRepository invalido.' }
    } elseif ($created.Text -match 'RepositoryAlreadyExistsException') {
        # A concurrent create is accepted only after verifying the actual resource.
        $repository = Get-EcrRepository
        if ($null -eq $repository) { throw 'ECR informou AlreadyExists, mas a consulta exata nao confirmou o recurso.' }
    } else { throw "CreateRepository falhou (exit=$($created.ExitCode))." }
} else { Write-Host "Repositorio '$RepositoryName' ja existe." -ForegroundColor Yellow }

if ($null -eq $repository -or [string]$repository.repositoryName -ne $RepositoryName -or
    [string]$repository.registryId -ne '000000000000' -or
    [string]$repository.repositoryArn -notlike 'arn:aws:ecr:us-east-1:000000000000:repository/*' -or
    [string]$repository.imageTagMutability -ne 'IMMUTABLE' -or -not $repository.imageScanningConfiguration.scanOnPush) {
    throw 'O repositorio ECR nao possui identidade/configuracao esperadas (conta, regiao, IMMUTABLE, scanOnPush).'
}
Write-Host 'ECR local pronto.' -ForegroundColor Green
Write-Host "Repository: $($repository.repositoryName)"
Write-Host "URI: $($repository.repositoryUri)"
