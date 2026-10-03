# Qualidade e entrega contínua

## GitHub Actions

`.github/workflows/ci.yml` roda em push/PR para `main`, com permissão `contents: read`:

- Ubuntu/Node 24: `npm ci`, `npm run verify` e Docker build.
- Windows/PowerShell 5.1: parser de todos os scripts (39 nesta entrega) e regressões isoladas com executável nativo temporário simulando Docker/AWS.

As 37 regressões verificam captura do processo nativo, falhas de pipeline/build, identidade do Source e do artifact, proteção de credenciais e recusa de tasks antigas/sem saúde/digest errado. As dependências externas são simuladas; esse teste não certifica um deploy real. Ele foi executado no Windows PowerShell 5.1 e no Linux PowerShell 7.6.6. O job no GitHub ainda não foi executado nesta entrega.

Esse workflow é CI do repositório. A entrega da aplicação continua sendo responsabilidade da CodePipeline/CodeBuild.

## CodePipeline/CodeBuild

Alvo AWS: GitHub/CodeConnections → CodePipeline → CodeBuild → ECR → ECS.
Laboratório: Source S3 versionado → CodePipeline V1 → CodeBuild → ECR → ECS.

A ação ECS padrão consome `imagedefinitions.json`. Quality gate bloqueia publicação/deploy em caso de erro. `npm ci` e `package-lock.json` são obrigatórios em CI, buildspecs e Dockerfile.

A tag `pipeline-<UUID v4>` é gerada dentro do CodeBuild, independentemente de `CODEBUILD_BUILD_ID`, e publicada no ECR imutável. O helper `cicd-artifact-context.ps1` exige o CodeBuild vinculado, a mesma localização S3 do BuildOutput na ação e na API CodeBuild, o container/repositório corretos e o hash do artifact. A aceitação verifica também o Source VersionId/hash, digest ECR, task definition e tasks físicas. Não existe aprovação por fallback externo.

## Homologação nativa em 03/10/2026

A etapa 8 foi concluída tecnicamente no Windows/LocalStack: duas entregas reais, nova frase servida por HTTPS e CodeBuild `FAILED` por teste deliberado, sem nenhuma ação Deploy iniciada. O teste temporário foi removido e uma entrega limpa final terminou `Succeeded`, com duas tasks Docker e dois targets saudáveis. A evidência sanitizada está em [EVIDENCE-CICD.json](EVIDENCE-CICD.json).

Veja [PIPELINE.md](PIPELINE.md) para operação, teste negativo e critério de aceitação. [AUDIT.md](AUDIT.md#16-homologação-concluída-em-03102026) registra os resultados e separa o diagnóstico histórico da implementação final.

## Escopo e limites

`buildspec.yml` representa AWS real; `buildspec.localstack.yml` contém endpoint e credenciais fictícias do emulador. Não usar token LocalStack nem senha RDS como variável de build. O socket Docker do laboratório é compartilhado com o runner; execute apenas Source confiável nesse daemon.

Não foram executados AWS real, novo GitHub Actions nem reconstrução de uma sessão fria nesta homologação. Blue/Green, CloudFront e Amazon Q/MCP continuam nas etapas seguintes. Os defeitos e riscos observados do executor estão documentados na auditoria; o cache da imagem oficial não comprova correção permanente da conectividade TLS/CDN.
