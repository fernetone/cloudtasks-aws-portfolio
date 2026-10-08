# Arquitetura AWS alvo e laboratÃ³rio executÃ¡vel

O projeto deve reproduzir a referÃªncia BIA com aplicaÃ§Ã£o e infraestrutura AWS efetivas. LocalStack Ã© o ambiente auxiliar de emulaÃ§Ã£o. A arquitetura final ainda nÃ£o estÃ¡ implementada nem homologada integralmente; a [matriz V01-V12](REFERENCE-VIDEO.md) registra as diferenÃ§as e as provas obrigatÃ³rias.

## Entrega

GitHub Ã© a origem do portfÃ³lio. GitHub Actions valida o repositÃ³rio. Na AWS alvo, CodeConnections alimenta a CodePipeline; localmente, o publisher fornece um snapshot S3 versionado. CodeBuild roda qualidade e Docker build/push, e o Deploy consome o artifact: ECS padrÃ£o no modo Rolling, ou CodeBuild com o adaptador explÃ­cito no modo BlueGreen.

```mermaid
flowchart TD
  source["GitHub/CodeConnections â€” AWS alvo"] --> cp["CodePipeline V1"]
  s3["Source S3 versionado â€” laboratÃ³rio"] --> cp
  cp --> cb["CodeBuild: qualidade e Docker"]
  cb --> ecr["ECR: tag imutÃ¡vel e digest"]
  cb --> artifact["imagedefinitions.json"]
  artifact --> deploy["Deploy da CodePipeline"]
  deploy --> rolling["Rolling: aÃ§Ã£o ECS padrÃ£o"]
  deploy --> bg["BlueGreen: CodeBuild com adaptador local"]
  ecr --> deploy
  rolling --> ecs["Service ECS principal: duas tasks"]
  bg --> ecs
```

Os dois Source nodes sÃ£o alternativas de ambiente, nÃ£o duas aÃ§Ãµes simultÃ¢neas. `create-cicd.ps1` configura e acompanha os serviÃ§os; nÃ£o substitui sua execuÃ§Ã£o com um deploy externo.

## TrÃ¡fego e dados

```mermaid
flowchart TD
  user["UsuÃ¡rio"] --> cf["CloudFront â€” etapa 10"]
  cf --> alb["ALB + HTTPS/ACM"]
  alb --> tg["Target Group /health"]
  tg --> t1["Task 1: React + Express"]
  tg --> t2["Task 2: React + Express"]
  t1 --> db["PostgreSQL / RDS"]
  t2 --> db
  sm["Secrets Manager"] --> t1
  sm --> t2
  t1 --> logs["CloudWatch Logs"]
  t2 --> logs
```

CloudFront ainda nÃ£o estÃ¡ implementado; o acesso atual entra pelo ALB/gateway LocalStack. O React compilado Ã© servido pelo Express no mesmo container. `GET /health` verifica o PostgreSQL; `/api/tasks` implementa CRUD com validaÃ§Ã£o e SQL parametrizado.

## Rede e compute

Alvo: duas AZs e subnets pÃºblicas, aplicaÃ§Ã£o privada e dados privados; ECS sobre capacidade EC2 real, task definition `bridge`, containerPort 3000, hostPort dinÃ¢mico. O ECS registra instÃ¢ncia/hostPort no TG `instance`.

LaboratÃ³rio: VPC/subnets/rotas no control plane emulado, tasks pelo executor Docker e conectividade na `cloudtasks-localstack-network`. NÃ£o existem container instances EC2 reais. `launchType=EC2` na API e `registeredContainerInstancesCount=0` nÃ£o contradizem esse executor. O TG local Ã© `ip`, com IP Docker/porta 3000 e sincronizaÃ§Ã£o apÃ³s deploy.

Docker network nÃ£o equivale ao isolamento fÃ­sico de VPC/subnets/security groups. Capacidade EC2, bootstrap e provisionamento AWS completo sÃ£o requisitos pendentes da entrega final. A base local pode ser preservada e usada em testes; sua homologaÃ§Ã£o de CI/CD nÃ£o implementa esses requisitos.

## TLS e segredos

No control plane, listener ALB HTTPS `:443` recebe ACM. No socket local compartilhado `:4566`, TLS Ã© terminado pelo gateway LocalStack. Na AWS real, o ALB termina TLS com o certificado ACM associado.

A task definition referencia `cloudtasks/database` no Secrets Manager. `DATABASE_SECRET_JSON` Ã© injetado em runtime; configuraÃ§Ã£o e senha nÃ£o entram no Source, imagem ou metadados de deploy. Consulte [SECURITY.md](../SECURITY.md) para limites da verificaÃ§Ã£o e proteÃ§Ã£o dos logs.

## Estado, observabilidade e etapas

`PERSISTENCE=0` e bind por sessÃ£o permitem reconstruir recursos, sem restaurar snapshots antigos. Isso descarta dados locais e nÃ£o representa durabilidade RDS da AWS real. O bind permanece necessÃ¡rio ao executor CodeBuild.

CloudWatch Logs bÃ¡sico jÃ¡ foi exercitado; mÃ©tricas, alarmes e dashboard pertencem Ã  etapa 11. A etapa 8 foi homologada no Windows/LocalStack e publicada com CI real do GitHub. A etapa atual Ã© 9, Blue/Green: o adaptador local usa dois serviÃ§os independentes durante validaÃ§Ã£o/bake e converge o principal 0â†’2 enquanto green atende. A homologaÃ§Ã£o do controlador AWS nativo continua separada, pelas limitaÃ§Ãµes observadas/documentadas do emulador. CloudFront (10), Amazon Q/MCP (12) e polimento (13) permanecem posteriores; consulte [BLUE-GREEN.md](BLUE-GREEN.md).

[PIPELINE.md](PIPELINE.md), [DECISIONS.md](DECISIONS.md), [ROADMAP.md](ROADMAP.md) e [AUDIT.md](AUDIT.md) registram decisÃµes e evidÃªncias.

## Fronteira do adaptador Blue/Green

Durante promoÃ§Ã£o/bake, o TG principal e o TG temporÃ¡rio green continuam associados ao ALB por rotas de teste nos dois listeners. A aÃ§Ã£o padrÃ£o define produÃ§Ã£o; cabeÃ§alhos de teste nÃ£o sÃ£o autenticaÃ§Ã£o. ApÃ³s validaÃ§Ã£o e bake, green mantÃ©m trÃ¡fego durante a retirada controlada/recriaÃ§Ã£o das duas tasks principais. SÃ³ apÃ³s validar imagem, digest e HTTP/HTTPS finais sÃ£o removidos recursos temporÃ¡rios e lock. [Fluxo completo](BLUE-GREEN.md).

## AplicaÃ§Ã£o e runtime verificados em 08/10/2026

A versÃ£o 1.8.2 implementa os elementos observÃ¡veis da BIA, com prazo textual compatÃ­vel, prioridade editÃ¡vel e saÃºde real. [EvidÃªncias atuais](EVIDENCE-BIA-20261008.json) distinguem testes isolados, PostgreSQL compartilhado, browser pelo ALB e cada execuÃ§Ã£o da pipeline.

O script solicita listener HTTP 80; o provider deste runtime reporta HTTP 4566. HTTPS aparece como listener lÃ³gico 443, com TLS efetivo no gateway 4566. Esses valores locais nÃ£o reproduzem a terminaÃ§Ã£o de trÃ¡fego HTTP 80/HTTPS 443 em um ALB AWS. A configuraÃ§Ã£o CORS permite somente as duas origens desse ALB local.
