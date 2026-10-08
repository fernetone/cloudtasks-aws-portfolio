# LocalStack Student â€” laboratÃ³rio AWS local do CloudTasks

CloudTasks usa LocalStack para exercitar a arquitetura AWS sem provisionar recursos faturÃ¡veis. O laboratÃ³rio local Ã© **determinÃ­stico e efÃªmero**: a infraestrutura AWS emulada Ã© reconstruÃ­da por scripts idempotentes em cada nova sessÃ£o, em vez de depender de snapshots de serviÃ§os com runtimes/ports internos.

## Por que a persistÃªncia AWS do emulador foi desativada

Durante a homologaÃ§Ã£o, snapshots restaurados produziram estados de runtime inconsistentes em RDS, ECS e ECR. O caso decisivo foi um repositÃ³rio ECR restaurado que existia no control plane, mas `DescribeImages` falhava internamente porque o endpoint do registry associado ao runtime anterior nÃ£o estava mais materializado.

A arquitetura AWS real continua persistente. Esta decisÃ£o vale apenas para o laboratÃ³rio LocalStack e melhora a reprodutibilidade do portfÃ³lio.

## SeguranÃ§a do token

O Personal Auth Token fica em `.env.localstack`, ignorado pelo Git e pelo contexto Docker.

```powershell
.\scripts\localstack\change-token.ps1
```

## Subir o ambiente

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\localstack\start-localstack.ps1
```

ConfiguraÃ§Ã£o principal:

- `localstack/localstack-pro:latest`;
- gateway `http://localhost:4566`;
- regiÃ£o `us-east-1`;
- `PERSISTENCE=0`;
- um bind mount **novo por sessÃ£o** em `%USERPROFILE%\.cloudtasks\localstack-runtime\session-*`;
- `/var/lib/localstack` continua sendo `type=bind`, requisito do executor Docker do CodeBuild;
- Docker socket montado;
- rede `cloudtasks-localstack-network`;
- `RDS_PG_CUSTOM_VERSIONS=0`;
- `EXTRA_CORS_ALLOWED_ORIGINS` restrito Ã s origens HTTP/HTTPS `cloudtasks-alb.elb.localhost.localstack.cloud:4566`;
- containers com falha de ECS/CodeBuild preservados durante homologaÃ§Ã£o.

## Construir/reconciliar a infraestrutura completa

```powershell
.\scripts\localstack\resume-environment.ps1
```

Esse comando garante RDS/Secrets, ECR/imagem, ECS 2/2, ALB/Target Group e HTTPS/ACM no runtime atual.

## Verificar o modo de runtime

```powershell
.\scripts\localstack\status-localstack.ps1
.\scripts\localstack\status-persistence.ps1
```

O segundo comando manteve o nome por compatibilidade, mas agora valida que a **persistÃªncia estÃ¡ intencionalmente desativada** e que o bind mount necessÃ¡rio ao CodeBuild estÃ¡ correto.

## ECR

```powershell
.\scripts\localstack\create-ecr.ps1
.\scripts\localstack\push-ecr-image.ps1
```

URI tÃ­pica:

```text
000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4566/cloudtasks
```

## RDS / ECS / ALB / HTTPS

```powershell
.\scripts\localstack\test-database.ps1
.\scripts\localstack\test-ecs.ps1
.\scripts\localstack\test-alb.ps1
.\scripts\localstack\test-https.ps1
```

## CI/CD

```powershell
.\scripts\localstack\create-cicd.ps1
.\scripts\localstack\status-cicd.ps1
.\scripts\localstack\test-cicd.ps1
```

A pipeline local usa Source S3 versionado, CodePipeline V1, CodeBuild, ECR e ECS. A aprovaÃ§Ã£o exige Source/Build/Deploy nativos e CodeBuild vinculado; a versÃ£o 1.7.1 removeu os fallbacks de entrega externa. Se o execution engine nÃ£o completa as aÃ§Ãµes, a etapa 8 permanece pendente. Consulte [PIPELINE.md](PIPELINE.md).

## Desligar

```powershell
.\scripts\localstack\stop-localstack.ps1
```

O estado AWS emulado da sessÃ£o Ã© descartÃ¡vel por design. CÃ³digo-fonte, Git, cache Docker e `.env.localstack` nÃ£o sÃ£o apagados.

## Acesso da interface pelo navegador

Em 08/10, HTML e probes sem Origin respondiam, mas JS/CSS com a origem do prÃ³prio ALB recebiam 403. A configuraÃ§Ã£o restrita acima permite o carregamento da interface; a verificaÃ§Ã£o mantÃ©m uma origem externa rejeitada. NÃ£o hÃ¡ wildcard nem desativaÃ§Ã£o dos checks CORS/CSRF. Essa variÃ¡vel exige uma nova execuÃ§Ã£o do serviÃ§o para ser carregada neste runtime.

Antes da troca de sessÃ£o, foram preservados banco e artifacts. O banco foi restaurado em transaÃ§Ã£o antes de subir o ECS e teve quantidade de tabelas, tarefas e fingerprint conferidas. `resume-environment.ps1` sozinho continua sem restaurar dados de uma sessÃ£o anterior. [Registro desta manutenÃ§Ã£o](EVIDENCE-BIA-20261008.json).

## Paridade

LocalStack nÃ£o Ã© AWS real. No laboratÃ³rio, ECS Ã© Docker-backed e nÃ£o existem container instances EC2 reais. A arquitetura alvo do portfÃ³lio continua ECS sobre EC2 com ALB, RDS, ECR, CodePipeline/CodeBuild e demais serviÃ§os documentados.
