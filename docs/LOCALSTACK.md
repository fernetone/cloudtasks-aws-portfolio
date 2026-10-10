# LocalStack Student — execução local do projeto BIA

O projeto usa Docker/LocalStack Student/Pro como ambiente executável autorizado, sem provisionar recursos faturáveis. Isso não dispensa componentes do vídeo nem validações funcionais. O laboratório local é **determinístico e efêmero**: a infraestrutura AWS emulada é reconstruída por scripts idempotentes em cada nova sessão, em vez de depender de snapshots de serviços com runtimes/ports internos.

## Por que a persistência AWS do emulador foi desativada

Durante a homologação, snapshots restaurados produziram estados de runtime inconsistentes em RDS, ECS e ECR. O caso decisivo foi um repositório ECR restaurado que existia no control plane, mas `DescribeImages` falhava internamente porque o endpoint do registry associado ao runtime anterior não estava mais materializado.

A arquitetura AWS real continua persistente. Esta decisão vale apenas para o laboratório LocalStack e melhora a reprodutibilidade do portfólio.

## Segurança do token

O Personal Auth Token fica em `.env.localstack`, ignorado pelo Git e pelo contexto Docker.

```powershell
.\scripts\localstack\change-token.ps1
```

## Subir o ambiente

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\localstack\start-localstack.ps1
```

Configuração principal:

- `localstack/localstack-pro:latest`;
- gateway `http://localhost:4566`;
- região `us-east-1`;
- `PERSISTENCE=0`;
- um bind mount **novo por sessão** em `%USERPROFILE%\.cloudtasks\localstack-runtime\session-*`;
- `/var/lib/localstack` continua sendo `type=bind`, requisito do executor Docker do CodeBuild;
- Docker socket montado;
- rede `cloudtasks-localstack-network`;
- `RDS_PG_CUSTOM_VERSIONS=0`;
- `EXTRA_CORS_ALLOWED_ORIGINS` restrito às origens HTTP/HTTPS `cloudtasks-alb.elb.localhost.localstack.cloud:4566`;
- containers com falha de ECS/CodeBuild preservados durante homologação.

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

O segundo comando manteve o nome por compatibilidade, mas agora valida que a **persistência está intencionalmente desativada** e que o bind mount necessário ao CodeBuild está correto.

## ECR

```powershell
.\scripts\localstack\create-ecr.ps1
.\scripts\localstack\push-ecr-image.ps1
```

URI típica:

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

A pipeline local usa Source S3 versionado, CodePipeline V1, CodeBuild, ECR e ECS. A aprovação exige Source/Build/Deploy nativos e CodeBuild vinculado; a versão 1.7.1 removeu os fallbacks de entrega externa. Se o execution engine não completa as ações, a etapa 8 permanece pendente. Consulte [PIPELINE.md](PIPELINE.md).

## Desligar

```powershell
.\scripts\localstack\stop-localstack.ps1
```

O estado AWS emulado da sessão é descartável por design. Código-fonte, Git, cache Docker e `.env.localstack` não são apagados.

## Acesso da interface pelo navegador

Em 08/10, HTML e probes sem Origin respondiam, mas JS/CSS com a origem do próprio ALB recebiam 403. A configuração restrita acima permite o carregamento da interface; a verificação mantém uma origem externa rejeitada. Não há wildcard nem desativação dos checks CORS/CSRF. Essa variável exige uma nova execução do serviço para ser carregada neste runtime.

Antes da troca de sessão, foram preservados banco e artifacts. O banco foi restaurado em transação antes de subir o ECS e teve quantidade de tabelas, tarefas e fingerprint conferidas. `resume-environment.ps1` sozinho continua sem restaurar dados de uma sessão anterior. [Registro desta manutenção](EVIDENCE-BIA-20261008.json).

## Paridade

LocalStack não é AWS real. No laboratório, ECS é Docker-backed e não existem container instances EC2 reais. A arquitetura alvo do portfólio continua ECS sobre EC2 com ALB, RDS, ECR, CodePipeline/CodeBuild e demais serviços documentados.

## Retomada validada em 10/10/2026

Com `PERSISTENCE=0`, iniciar até o mesmo container pode descartar estados emulados. A retomada preservou primeiro os arquivos físicos RDS, extraiu o banco anterior e restaurou seus dados antes do ECS. O container LocalStack foi mantido; duas novas entregas Blue/Green passaram sem reset entre elas. Não usar uma reconstrução indiscriminada como conferência de saúde. [Evidências](EVIDENCE-REBOOT-20261010.json).

## Componentes adicionais na sessão saudável

CloudFront, observabilidade e Amazon Q/MCP têm scripts próprios `create-*`, `status-*` e `test-*`. Não reconstruir a sessão para instalá-los. Consulte [CLOUDFRONT.md](CLOUDFRONT.md), [OBSERVABILITY.md](OBSERVABILITY.md) e [AMAZON-Q-MCP.md](AMAZON-Q-MCP.md) para comandos e limites verificados. O monitor precisa ser retomado após reiniciar Windows; dependências MCP dentro de `/opt/cloudtasks-mcp-tools` precisam ser reinstaladas se o container LocalStack for recriado. O perfil Q privado fica no computador e não entra no repositório.
