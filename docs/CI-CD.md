# Qualidade e entrega contínua

A pipeline específica da referência é GitHub → CodeBuild → ECS padrão; consulte [GITHUB-PIPELINE.md](GITHUB-PIPELINE.md). Este documento preserva o fluxo S3 e seu histórico de homologação.

## GitHub Actions

`.github/workflows/ci.yml` roda em push/PR para `main`, com permissão `contents: read`:

- Ubuntu/Node 24: `npm ci`, `npm run verify` e Docker build.
- Windows/PowerShell 5.1: parser de todos os scripts (41 após preservar os dois scripts AWS existentes) e regressões isoladas com executável nativo temporário simulando Docker/AWS.

As 56 regressões verificam captura do processo nativo, falhas de pipeline/build, identidade do Source e do artifact, proteção de credenciais e recusa de tasks antigas/sem saúde/digest errado. As dependências externas são simuladas; esse teste não certifica um deploy real. A suite atual foi executada no Windows PowerShell 5.1 e no Linux PowerShell 7.6.6. O run histórico [GitHub 37134970506](https://github.com/fernetone/cloudtasks-aws-portfolio/actions/runs/37134970506) concluiu os dois jobs com sucesso, incluindo parser/regressões no Windows e qualidade/Docker no Ubuntu. [EVIDENCE-GITHUB.json](EVIDENCE-GITHUB.json) registra o commit validado.

Esse workflow é CI do repositório. A entrega da aplicação continua sendo responsabilidade da CodePipeline/CodeBuild.

## CodePipeline/CodeBuild

Alvo AWS: GitHub/CodeConnections → CodePipeline → CodeBuild → ECR → ECS.
Laboratório: Source S3 versionado → CodePipeline V1 → CodeBuild → ECR → ECS.

A ação ECS padrão consome `imagedefinitions.json` no modo Rolling. BlueGreen seleciona um CodeBuild de implantação que consome o mesmo BuildOutput, executa o adaptador local e retorna o recibo no DeployOutput. Os 34 testes Node de estado/guards integram `npm run verify`, além dos 7 testes API e 4 frontend. Quality gate bloqueia publicação/deploy em caso de erro. `npm ci` e `package-lock.json` são obrigatórios em CI, buildspecs e Dockerfile.

A tag `pipeline-<UUID v4>` é gerada dentro do CodeBuild, independentemente de `CODEBUILD_BUILD_ID`, e publicada no ECR imutável. O helper `cicd-artifact-context.ps1` exige o CodeBuild vinculado, a mesma localização S3 do BuildOutput na ação e na API CodeBuild, o container/repositório corretos e o hash do artifact. A aceitação verifica também o Source VersionId/hash, digest ECR, task definition e tasks físicas. Não existe aprovação por fallback externo.

## Homologação nativa em 03/10/2026

A etapa 8 foi concluída tecnicamente no Windows/LocalStack: duas entregas reais, nova frase servida por HTTPS e CodeBuild `FAILED` por teste deliberado, sem nenhuma ação Deploy iniciada. O teste temporário foi removido e uma entrega limpa final terminou `Succeeded`, com duas tasks Docker e dois targets saudáveis. A evidência sanitizada está em [EVIDENCE-CICD.json](EVIDENCE-CICD.json).

Veja [PIPELINE.md](PIPELINE.md) para operação, teste negativo e critério de aceitação. [AUDIT.md](AUDIT.md#16-homologação-concluída-em-03102026) registra os resultados e separa o diagnóstico histórico da implementação final.

## Escopo e limites

`buildspec.yml` representa AWS real; `buildspec.localstack.yml` contém endpoint e credenciais fictícias do emulador. Não usar token LocalStack nem senha RDS como variável de build. O socket Docker do laboratório é compartilhado com o runner; execute apenas Source confiável nesse daemon.

Não foi executada AWS real. A homologação de 03/10 não reconstruiu sessão fria; a sessão 2026.9.0 de 04/10 foi reconstruída e validada separadamente. A publicação e o CI do GitHub foram executados separadamente e não representam um deploy no LocalStack ou na AWS real. Blue/Green local usa o adaptador explícito da etapa 9; a certificação do controlador AWS nativo permanece separada; CloudFront e Amazon Q/MCP continuam posteriores. Os defeitos e riscos observados do executor estão documentados na auditoria; o cache da imagem oficial não comprova correção permanente da conectividade TLS/CDN.

## Validação atual do Blue/Green

As provas nativas atuais e os ensaios reprovados ficam em [EVIDENCE-BLUE-GREEN-ADAPTER.json](EVIDENCE-BLUE-GREEN-ADAPTER.json). GitHub Actions testa código e Docker, não implanta no laboratório pessoal. Rejeição/rollback controlados precisam manter CodePipeline Failed e CodeBuild FAILED; a aprovação do comportamento negativo não aprova a entrega.
