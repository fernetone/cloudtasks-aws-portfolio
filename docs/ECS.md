# ECS local — duas réplicas CloudTasks

A versão 1.3.1 consolidou o marco de compute do projeto: ECS com duas réplicas da aplicação, imagem vinda do ECR local, credencial do banco injetada pelo Secrets Manager e logs enviados ao CloudWatch Logs emulado.

## Recursos

> **Compatibilidade Windows PowerShell 5.1:** o health check da task usa a forma ECS `CMD` (exec form), sem `CMD-SHELL` nem aspas aninhadas. Isso evita erros de parser antes mesmo da criação do cluster.
```text
ECR cloudtasks
   |
   v
ECS cluster cloudtasks-cluster
   |
   +--> task definition cloudtasks:N
   |      |
   |      +--> image imutável do ECR
   |      +--> DATABASE_SECRET_JSON <- Secrets Manager
   |      +--> bridge / containerPort 3000 / hostPort 0
   |      +--> awslogs -> /cloudtasks/ecs
   |
   v
ECS service cloudtasks-service
   |
   +--> task 1 -> porta dinâmica no host
   +--> task 2 -> porta dinâmica no host
          |
          v
     RDS PostgreSQL 16
```

## Segurança do banco

O valor do secret `cloudtasks/database` não é gravado em arquivo de task definition. A task definition contém apenas o ARN do secret. O ECS injeta o SecretString inteiro em `DATABASE_SECRET_JSON`, e a aplicação monta a connection string somente em memória.

O ambiente LocalStack usa `DATABASE_HOST_OVERRIDE=cloudtasks-localstack` porque as tasks Docker e o container LocalStack compartilham a rede `cloudtasks-localstack-network`. Em AWS real esse override não é necessário; o host do RDS viria diretamente do secret.

## EC2 e paridade do LocalStack

No laboratório, a task definition usa `networkMode=bridge` e o service é criado sem `--launch-type EC2` explícito, seguindo o fluxo Docker-backed padrão do LocalStack. As tasks são containers Docker criados diretamente pelo emulador e o cluster pode mostrar `registeredContainerInstancesCount=0`. O contrato de produção documentado continua ECS sobre EC2.

Isso é uma diferença explícita de runtime, não uma falha do projeto. No portfólio, descreva esta etapa como:

> ECS service executado localmente pelo caminho Docker-backed padrão do LocalStack. O alvo AWS real continua ECS sobre EC2.

Não afirmar que existem hosts EC2 reais por trás dessas tasks no ambiente Windows local.

## Criar

```powershell
.\scripts\localstack\create-ecs.ps1
```

O script é idempotente e:

1. valida RDS e Secrets Manager;
2. garante ECR e imagem;
3. cria/atualiza a role de execução;
4. cria o log group `/cloudtasks/ecs`;
5. cria o cluster;
6. registra nova revisão da task definition;
7. cria ou atualiza o service com `desiredCount=2`;
8. espera duas tasks `RUNNING`;
9. confirma os containers Docker do runtime.

## Status

```powershell
.\scripts\localstack\status-ecs.ps1
```

O status mostra cluster, service, task definition, imagem, desired/running/pending e as portas dinâmicas de cada task sem revelar segredo.

## Teste ponta a ponta

```powershell
.\scripts\localstack\test-ecs.ps1
```

O teste exige:

- duas tasks `RUNNING`;
- duas portas host distintas;
- `/health` com `database=ok` nas duas réplicas;
- tarefa criada na réplica 1 visível na réplica 2, provando estado compartilhado no RDS;
- eventos no CloudWatch Logs.

A tarefa temporária do teste é removida ao final.

## Próximo marco consolidado na v1.4.1

ELBv2 foi consolidado na v1.4.1 com Target Group + Application Load Balancer + health check `/health` e validação compatível com o gateway compartilhado `:4566` do LocalStack. Veja `docs/LOAD-BALANCING.md`.

## Preflight de scripts no Windows

Antes do marco ECS, pode-se validar todos os scripts LocalStack com o parser nativo do PowerShell 5.1:

```powershell
.\scripts\localstack\validate-scripts.ps1
```

O comando não cria nem altera recursos; apenas bloqueia a execução se existir erro sintático em algum `.ps1`.

## Auto-reparo após snapshot

A partir da v1.6.4, o reconciliador trata a diferença entre estado persistido do ECS e runtime Docker. Se o service existir, mas nenhum container Docker correspondente estiver em execução, o estado é considerado inconsistente para o laboratório local. Em vez de tentar apagar estado interno do LocalStack, o projeto rotaciona para um novo namespace de cluster ECS e recria service/tasks ali, preservando rede, banco, secrets, imagens e pipeline.

O erro `InvalidInstanceID.NotFound` durante `UpdateService` também aciona esse reparo automaticamente uma única vez.


## Modo de execução local v1.6.7

A execução local não passa mais `--launch-type EC2` explicitamente. O fluxo segue o padrão documentado pelo LocalStack: cluster + task definition `bridge` + `create-service` sem launch type forçado, permitindo que o executor Docker local crie as tasks diretamente. Isso evita acoplar o laboratório à persistência de instâncias EC2 emuladas, cujos containers/IDs são efêmeros entre reinícios.

A arquitetura de produção documentada permanece ECS/EC2. Portanto, o projeto distingue explicitamente **paridade de APIs/serviço** de **runtime físico local**.


## Runtime ECS por sessao (v1.6.7)

O control plane ECS pode ser persistido pelo LocalStack, mas as tasks sao containers Docker externos. Por isso o laboratorio nao reutiliza um service restaurado entre recriacoes do container LocalStack. Cada ID novo de `cloudtasks-localstack` recebe um cluster `cloudtasks-cluster-r...` novo. O valor `launchType=EC2` que pode aparecer na API local nao implica a existencia de uma EC2 real; a documentacao oficial do LocalStack mostra esse valor inclusive no exemplo que executa a task diretamente no Docker local.
