# Application Load Balancer local — duas réplicas ECS

A versão 1.4.1 consolida ELBv2 no CloudTasks: Application Load Balancer, Target Group, listener HTTP e health check `/health` sobre as duas réplicas ECS já validadas.

No runtime LocalStack atual, o listener é criado logicamente como HTTP `:80`, mas `describe-listeners` pode expor `Port=4566` porque o tráfego passa pelo gateway compartilhado do LocalStack. Por isso os scripts validam o listener pelo protocolo e pela ação `forward` para `cloudtasks-tg`, em vez de exigir que a API local devolva literalmente `Port=80`.

## Arquitetura desta etapa

```text
User/teste local
    |
    v
cloudtasks-alb
HTTP listener :80
(acesso LocalStack :4566)
    |
    v
cloudtasks-tg
health /health
    |
    +--> task ECS 1 / container IP :3000
    |
    +--> task ECS 2 / container IP :3000
              |
              v
       RDS PostgreSQL 16
```

## Por que o Target Group local usa `ip`

No desenho AWS real pretendido, ECS sobre EC2 com `networkMode=bridge` e `hostPort=0` normalmente trabalha com Target Group do tipo `instance`: o ECS registra o ID da container instance EC2 junto com a porta dinâmica do host.

No LocalStack em Windows, o Docker executor executa as tasks diretamente como containers e não registra hosts EC2 reais como ECS container instances. Para não fingir uma paridade inexistente, o adapter local usa Target Group `ip` e registra os IPs dos containers ECS na rede `cloudtasks-localstack-network`, porta 3000.

Essa diferença é deliberada e documentada. O objetivo local continua sendo validar o comportamento arquitetural ALB -> Target Group -> duas réplicas -> RDS.

## Listener lógico `:80` x gateway LocalStack `:4566`

O projeto cria o listener com `--protocol HTTP --port 80`, preservando o desenho AWS. No LocalStack, a URL local padrão entra pelo gateway compartilhado em `:4566`. Na versão atual do runtime usada neste projeto, `describe-listeners` pode devolver `Port=4566` para esse listener.

Isso não significa que o listener AWS foi projetado em `:4566`; é um detalhe da emulação local. Por esse motivo, `create-alb.ps1` e `test-alb.ps1` identificam o listener pelo **protocolo HTTP + ação `forward` para `cloudtasks-tg`**, não por uma comparação rígida do campo `Port` com `80`. O `status-alb.ps1` exibe separadamente a porta reportada pelo runtime e a porta lógica do desenho.

## Persistência do ELB no LocalStack

O laboratório usa `PERSISTENCE=0`: recursos da sessão inteira são reconstruídos, sem depender de snapshots de VPC/RDS/ECS ou ELB. `create-alb.ps1` reconcilia ALB, listener e Target Group na sessão atual. A sincronização manual dos IPs Docker é uma adaptação local; ainda existe uma janela de remoção/registro na rotina de targets, descrita em [AUDIT.md](AUDIT.md), sem promessa de deploy sem interrupção nesta etapa.

## Criar ou reconstruir

```powershell
.\scripts\localstack\create-alb.ps1
```

O script:

1. confirma o ECS em 2/2 RUNNING;
2. localiza VPC e duas subnets públicas;
3. cria o Target Group `cloudtasks-tg`;
4. sincroniza os IPs atuais das duas tasks;
5. cria o ALB `cloudtasks-alb`;
6. cria listener HTTP :80;
7. espera os dois targets ficarem `healthy`.

## Sincronizar targets após um novo deploy ECS

Como novas tasks Docker recebem novos IPs, rode:

```powershell
.\scripts\localstack\sync-alb-targets.ps1
```

O script remove targets antigos e registra exatamente as duas tasks RUNNING atuais.

## Status

```powershell
.\scripts\localstack\status-alb.ps1
```

## Teste ponta a ponta

```powershell
.\scripts\localstack\test-alb.ps1
```

O teste exige:

- 2/2 targets `healthy`;
- cinco requests `/health` com `database=ok`;
- POST e GET do CRUD através do ALB;
- continuidade do serviço ao remover temporariamente um dos dois targets;
- retorno do target removido para `healthy` ao final.

## URL local

O DNS retornado pelo ELBv2 pode ser acessado pelo gateway compartilhado do LocalStack:

```text
http://cloudtasks-alb.elb.localhost.localstack.cloud:4566
```

O listener lógico continua sendo HTTP :80; `:4566` é a porta de gateway do runtime LocalStack.

## Próximo marco

Depois do ALB HTTP validado, o próximo passo é HTTPS com ACM/certificado local e listener 443; depois seguimos para CodePipeline/CodeBuild e deploy automatizado do ECS.

## Referência técnica

Documentação oficial LocalStack ELB: https://docs.localstack.cloud/aws/services/elb/

## HTTPS na versão 1.5.0

A camada HTTP já foi validada ponta a ponta no computador do projeto, incluindo CRUD e continuidade com um dos dois targets temporariamente removido. A versão 1.5.0 acrescenta ACM + listener HTTPS lógico `:443`.

Consulte [`HTTPS.md`](HTTPS.md) para a diferença entre a associação ACM do listener e o certificado TLS apresentado pelo gateway `:4566` do LocalStack.
