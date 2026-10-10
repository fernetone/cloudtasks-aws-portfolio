# Etapa 8 — CodePipeline, CodeBuild, ECR e ECS

A pipeline específica da referência é GitHub → CodeBuild → ECS padrão; consulte [GITHUB-PIPELINE.md](GITHUB-PIPELINE.md). Este documento preserva o fluxo S3 e seu histórico de homologação.

## Decisão

A aprovação exige execução nativa da CodePipeline V1: Source S3 → CodeBuild → ECR → ação Deploy ECS. Na AWS alvo, a ação Source será GitHub por CodeConnections. O Source S3 local é uma adaptação do laboratório para usar os inputs autorizados do working tree; não substitui CodeBuild ou CodePipeline por PowerShell.

Não existe aprovação por runner Docker, tag ECR mais recente, build iniciado diretamente ou deploy externo quando a pipeline não completa suas ações. Uma execução futura sem Build ou Deploy nativos é recusada e a sessão é preservada para diagnóstico.

**Estado em 03/10/2026:** etapa 8 concluída tecnicamente no Windows/LocalStack, com duas entregas reais, alteração confirmada por HTTPS, quality gate falho sem iniciar Deploy e entrega limpa final. Os identificadores e resultados estão em [EVIDENCE-CICD.json](EVIDENCE-CICD.json). O código foi publicado com CI real do GitHub, registrado separadamente em [EVIDENCE-GITHUB.json](EVIDENCE-GITHUB.json). AWS real não foi executada.

## Responsabilidades

| Arquivo                                 | Responsabilidade                                                                              |
| --------------------------------------- | --------------------------------------------------------------------------------------------- |
| `resume-environment.ps1`                | Bootstrap explícito do laboratório e da aplicação                                             |
| `ecs-runtime-context.ps1`               | Identidade da sessão e consulta comum do runtime Docker                                       |
| `publish-cicd-source.ps1`               | Inputs permitidos, varredura de credenciais conhecidas, ZIP normalizado, upload/versionamento |
| `create-cicd.ps1`                       | Preflight, buckets/IAM, CodeBuild/CodePipeline, execução nativa e registro de identidade      |
| `cicd-artifact-context.ps1`             | Leitura e validação comum do artifact nativo e da imagem vinculada ao CodeBuild                |
| `buildspec.localstack.yml`              | `npm ci`, quality gate, Docker build, push ECR e artifacts                                    |
| `test-cicd.ps1`                         | Aceitação da execução registrada: Source/Build/Deploy, tasks, digest e HTTPS                  |
| `status-cicd.ps1` / `diagnose-cicd.ps1` | Estado e metadados para investigação                                                          |
| `buildspec.bluegreen.localstack.yml` | Executar implantação por adaptador local no CodeBuild nativo e publicar DeployOutput |
| `blue-green-controller.mjs` / `blue-green-localstack.mjs` | Máquina de estados e IO ECS/ELB/Docker, lock, identidade, bake, convergência e cleanup |
| `rollback-cicd.ps1`                     | Rollback operacional explícito; não representa Blue/Green nem rollback nativo da pipeline     |

O preflight não inicia LocalStack, não gira namespace ECS e não reconcilia o ambiente automaticamente. Ao falhar, informa a condição recusada.

## Identidade do Source e da imagem

O publisher exige manifests, lockfile, Dockerfile, `.dockerignore`, configuração de lint/Vite/TypeScript, buildspecs e código/testes da aplicação. Não empacota o repositório inteiro: documentação, scripts PowerShell operacionais, certificados, `.env`, runtime, logs e ZIPs ficam fora. A allowlist incorpora somente os dois módulos Node do adaptador, seus testes e o buildspec de deploy; eles são inputs da execução CodeBuild, não uma cópia geral da pasta de scripts.

Arquivos têm ordem ordinal e timestamp ZIP normalizado. O hash não varia apenas porque o mtime mudou; não se promete igualdade entre runtimes diferentes de compressão. O VersionId vem da resposta do próprio `PutObject`, junto ao SHA256 dos bytes publicados. Nenhum `HEAD` do objeto mais recente decide a identidade deste upload.

Execuções posteriores usam `StartPipelineExecution` com `S3_OBJECT_VERSION_ID`. Na primeira criação, o emulador inicia a execução automaticamente; a identidade da ação Source precisa confirmar a versão recém-publicada. A comparação usa `outputVariables.VersionId` quando presente; sem esse campo, exige `SourceOutput.revisionId` exatamente igual à versão. Um VersionId explícito divergente nunca é aprovado por outro metadado. O fluxo pressupõe um único publicador controlado: não publique manualmente outro Source durante a execução.

A tag é `pipeline-<UUID v4>`, gerada dentro do próprio CodeBuild e independente de `CODEBUILD_BUILD_ID`. O agente local observado injetou um ID reservado com UUID zerado, distinto do ID real da API; derivar a tag desse valor produzia uma identidade incorreta e repetível. O repositório continua `IMMUTABLE`. O artifact padrão `imagedefinitions.json` aponta `cloudtasks-app` para a URI exata, e no modo Rolling a ação ECS cria uma revisão da task definition do service. BlueGreen usa o mesmo BuildOutput para transportar a imagem e o controlador à ação CodeBuild de deploy; `DeployOutput` transporta o recibo.

`Get-CloudTasksNativeBuildImage`, compartilhado por criação e aceitação em `cicd-artifact-context.ps1`, exige o CodeBuild `SUCCEEDED` vinculado à ação nativa, a mesma localização S3 de BuildOutput na ação e na API CodeBuild, o container esperado, o repositório exato e uma tag UUID v4. O SHA256 do artifact é registrado e revalidado em `test-cicd.ps1`, junto ao digest ECR e às tasks físicas. Não escolhe imagem mais recente ou `latest`.

`CODEBUILD_BUILD_SUCCEEDING` é verificado antes do push em `post_build`, impedindo publicação após quality gate/build falho. A ação Deploy só recebe o artifact após Build bem-sucedido. O parser ID→tag e o metadado auxiliar `pipeline-build.json` foram removidos; o vínculo permanece nas APIs e no artifact padrão.

## Pré-requisitos do runner local

- Sessão `PERSISTENCE=0`, ECS desejado/executando 2 e pending 0; metadata da sessão atual.
- `/var/lib/localstack` montado por bind, com origem no host. Não trocar por named volume neste executor.
- `CODEBUILD_DOCKER_FLAGS` conecta o runner à rede `cloudtasks-localstack-network` e monta `/var/run/docker.sock`.
- Docker Desktop disponível no contexto correto, internet e licença ativa.
- Secret `cloudtasks/database` válido para verificar se a credencial ativa foi copiada para algum input. O valor é lido somente em memória.

CodeBuild usa o agente AWS no executor do LocalStack. A imagem efetivamente utilizada e o suporte a runtime Node devem ser conferidos na versão instalada; uma imagem declarada não é prova de que o executor a respeitou.

O compose efetivo recebido monta `/var/run/docker.sock` no serviço `build`; o wrapper não possui `DOCKER_HOST`, `DOCKER_CONTEXT` ou `DOCKER_CONFIG` personalizados. Neste runtime, as imagens usam o daemon do Docker Desktop. O preflight agora verifica a imagem Amazon Linux `public.ecr.aws/codebuild/amazonlinux-x86_64-standard:5.0`, a baixa somente quando ausente e exige um image ID verificável após o download. A preparação ocorre antes de criar/disparar a pipeline e não executa testes, build da aplicação, push ou deploy. A imagem do wrapper `localstack/aws-codebuild-local:2` já estava no cache observado; não foi substituída.

Essa preparação mitiga downloads dentro da janela de execução, mas não repara os defeitos anteriormente observados no monitor/wrapper do LocalStack `2026.8.3:02342ae2e`. A execução nativa foi homologada nessa sessão após a preparação dos pré-requisitos; não se afirma que o fornecedor corrigiu o defeito ou que a conectividade TLS/CDN ficou permanentemente resolvida. Uma nova falha deve ser recusada e investigada com `diagnose-cicd.ps1`, preservando a sessão. O digest efetivo homologado está em [EVIDENCE-CICD.json](EVIDENCE-CICD.json). Não atualizar nem resetar a sessão saudável por suposição de que `latest` corrige o problema. [Diagnóstico histórico](AUDIT.md#13-diagnóstico-do-executor-codebuild-e-entrega-172).

## Comandos mínimos e resultados

Execute na raiz de uma sessão já saudável; preserve o seu `.env.localstack` pessoal ao atualizar o código.

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
& {
    $ErrorActionPreference = 'Stop'
    .\scripts\localstack\create-cicd.ps1
    .\scripts\localstack\test-cicd.ps1
}
```

| Comando               | Resultado esperado                                                                                                                                                               |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Set-ExecutionPolicy` | Permissão de scripts apenas no processo PowerShell atual; não altera a política permanente                                                                                       |
| `create-cicd.ps1`     | Imagem CodeBuild disponível antes da execução; SourceSnapshot, BuildAndPush e DeployECS `Succeeded`; CodeBuild vinculado `SUCCEEDED`; nova imagem/revisão ECS e metadados locais |
| `test-cicd.ps1`       | VersionId/SHA256 exatos; build correto; duas tasks da nova revisão; dois containers `healthy` com o digest ECR; ALB/TG e HTTPS/CRUD/RDS aprovados                                |

O bloco usa `Stop` para não testar um registro anterior depois de uma falha do `create-cicd.ps1`. Em caso de erro, preserve a sessão e execute apenas `.\scripts\localstack\diagnose-cicd.ps1` para consultar os metadados sanitizados da tentativa.

Metadados ficam em `.localstack/cicd/last-deploy.json`, ignorado pelo Git, com execution ID, CodeBuild ID, Source VersionId/hash, imagens e revisões anterior/implantada e digest ECR. Não contêm senha/token. IDs do container e da imagem LocalStack também são registrados. O arquivo sozinho não aprova nada: o teste consulta as APIs e o Docker.

Se a imagem local não tiver `RepoDigests` verificáveis, o teste recusa a aprovação. Investigue o caminho pull/tag/cache do executor; não remova a checagem para obter resultado verde.

Há um lock local para impedir dois `create-cicd.ps1` simultâneos e uma recusa quando existe execução `InProgress`/`Stopping`. O LocalStack não reproduz todos os bloqueios de stages/concurrency da AWS. A serialização local não coordena outros usuários/host/processos que operem diretamente nas APIs.

## Critério de conclusão da etapa 8

1. Aprovar uma execução com as evidências acima.
2. Fazer uma pequena alteração real na aplicação, aprovar `npm run verify`, executar novamente `create-cicd.ps1` e `test-cicd.ps1` e demonstrar a alteração entregue. Registrar os dois execution IDs, VersionIds/hashes, build IDs, tags/digests e task definitions distintos.
3. Demonstrar bloqueio de Deploy por quality gate falho, conforme o procedimento abaixo. A imagem/task definition da versão saudável deve continuar em uso.
4. Registrar a versão/digest do LocalStack e as evidências sanitizadas da sessão.

Esses critérios foram cumpridos nesta homologação. Código e evidências foram publicados pela PR #1 com CI Ubuntu e Windows aprovado. Essa publicação não muda o Source S3 do laboratório nem representa GitHub/CodeConnections real integrado à sessão pessoal.

Nenhuma aprovação apenas por contadores ECS 2/2, existência de imagem ou logs de runner atende esse critério. Blue/Green, CloudFront e Q/MCP permanecem fora desta etapa.

## Teste negativo controlado

Após a segunda execução saudável, na mesma sessão, crie um teste temporário deliberadamente falho. Ele não altera dados nem configurações de infraestrutura; o `finally` remove o arquivo.

```powershell
$ctRoot = (Get-Location).Path
$ctFailure = Join-Path $ctRoot 'apps/api/test/cicd-negative-gate.test.ts'
if (Test-Path -LiteralPath $ctFailure) { throw 'Arquivo de teste ja existe; nao sera sobrescrito.' }
$ctRuntime = Get-Content -Raw (Join-Path $env:USERPROFILE '.cloudtasks/ecs-runtime.json') | ConvertFrom-Json
$ctBefore = (& docker exec cloudtasks-localstack awslocal ecs describe-services --cluster $ctRuntime.clusterName --services $ctRuntime.serviceName --query 'services[0].taskDefinition' --output text | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $ctBefore -notlike 'arn:aws:ecs:*:task-definition/*') { throw 'Consulta ECS anterior falhou.' }
try {
    [IO.File]::WriteAllText($ctFailure, "import { test, expect } from 'vitest'; test('CI blocks Deploy', () => expect(true).toBe(false));", (New-Object Text.UTF8Encoding($false)))
    $ctBlocked = $false
    try { .\scripts\localstack\create-cicd.ps1 }
    catch { $ctBlocked = $true; Write-Host 'Execucao recusada; confirme Build FAILED no status.' }
    if (-not $ctBlocked) { throw 'Falha: o quality gate negativo nao bloqueou a execucao.' }
}
finally { Remove-Item -LiteralPath $ctFailure -Force -ErrorAction SilentlyContinue }
$ctAfter = (& docker exec cloudtasks-localstack awslocal ecs describe-services --cluster $ctRuntime.clusterName --services $ctRuntime.serviceName --query 'services[0].taskDefinition' --output text | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $ctAfter -ne $ctBefore) { throw 'Falha: ECS mudou ou a consulta posterior falhou.' }
.\scripts\localstack\status-cicd.ps1
```

Esperado: **CodeBuild API `FAILED` por teste**, execução CodePipeline falha e nenhuma ação Deploy iniciada nessa execução; ECS mantém a task definition anterior. Uma falha de autenticação, Source, Docker ou preflight não prova o quality gate. Confirme as ações via consulta de diagnóstico; só depois marque o teste como aprovado.

O `test-cicd.ps1` pode validar a última execução saudável registrada. O status da execução negativa precisa ser examinado separadamente; não use essa validação antiga como evidência de que a tentativa negativa completou.

## Limitações e documentação oficial

- [LocalStack CodePipeline](https://docs.localstack.cloud/aws/services/codepipeline/): V1 executável, V2 mock; limitações de triggers, locks e stop/retry/rollback.
- [LocalStack CodeBuild](https://docs.localstack.cloud/aws/services/codebuild/): agente, bind mount, Docker flags, imagens, variáveis e ausência de persistência.
- [AWS Source S3](https://docs.aws.amazon.com/codepipeline/latest/userguide/action-reference-S3.html) e [StartPipelineExecution](https://docs.aws.amazon.com/codepipeline/latest/APIReference/API_StartPipelineExecution.html).
- [AWS Deploy ECS padrão](https://docs.aws.amazon.com/codepipeline/latest/userguide/action-reference-ECS.html) e [variáveis CodeBuild](https://docs.aws.amazon.com/codebuild/latest/userguide/build-env-ref-env-vars.html).

O monitor do build foi observado encerrando com `Container not yet started` antes do início do runner; houve ainda falha TLS de download e saída 0 indevida do wrapper. São comportamentos observados nessa versão, não limitações documentadas como inevitáveis nem características da AWS. A documentação informa ausência de granularidade das fases no LocalStack: `phases` vazio não comprova travamento. A explicação detalhada está na seção 13 de [AUDIT.md](AUDIT.md).

## Modo BlueGreen explícito — etapa 9

`create-cicd.ps1 -DeploymentMode BlueGreen` preserva Source/Build nativos e escolhe `DeployBlueGreen`, executado pelo CodeBuild `cloudtasks-bluegreen-deploy`. O `test-cicd.ps1` identifica o modo registrado e exige a ação/build/artifact de deploy vinculados, recibo SUCCEEDED e todas as verificações comuns de Source, digest, tasks e HTTPS/CRUD. Falha nativa nunca é substituída por um deploy externo. [Procedimento, critérios e controles negativos](BLUE-GREEN.md).

Declaração idêntica não gera UpdatePipeline desnecessário: comparação canônica ignora somente `version`, normaliza ordem de propriedades e o JSON das variáveis de ambiente. Isso preserva o histórico da revisão atual no emulador. Mudar de modo é uma mudança real; salvar evidências antes.

O estado atual da etapa 9 está em [EVIDENCE-BLUE-GREEN-ADAPTER.json](EVIDENCE-BLUE-GREEN-ADAPTER.json). A evidência da etapa 8 de 03/10 é histórica e não certifica uma tentativa Blue/Green falha.
