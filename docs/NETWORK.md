# Rede CloudTasks no LocalStack

A topologia local foi desenhada como uma VPC de três camadas em duas Availability Zones. Isso deixa explícita a arquitetura que seria usada na AWS real, mesmo quando algum detalhe de enforcement é limitado pelo emulador.

## Topologia

```text
VPC cloudtasks-vpc — 10.20.0.0/16
|
+-- us-east-1a
|   +-- public-a       10.20.1.0/24
|   +-- app-private-a  10.20.11.0/24
|   +-- data-private-a 10.20.21.0/24
|
+-- us-east-1b
    +-- public-b       10.20.2.0/24
    +-- app-private-b  10.20.12.0/24
    +-- data-private-b 10.20.22.0/24
```

As subnets públicas usam uma route table com rota `0.0.0.0/0` para o Internet Gateway. As subnets privadas de aplicação e dados possuem route tables próprias sem rota pública nesta etapa.

## Uso planejado

- `public-*`: Application Load Balancer.
- `app-private-*`: capacidade ECS/EC2 e containers da aplicação.
- `data-private-*`: RDS PostgreSQL.

## Security groups

Na AWS real, o desenho é separado em três grupos:

- `cloudtasks-alb-sg`: entrada HTTP/HTTPS a partir dos clientes;
- `cloudtasks-ecs-sg`: entrada da aplicação somente a partir do ALB;
- `cloudtasks-rds-sg`: PostgreSQL 5432 somente a partir da camada ECS.

No LocalStack, o EC2 Docker VM Manager documenta que o security group `default` é o grupo efetivamente suportado para exposição de portas das instâncias Docker. Por isso o ambiente local mantém o `default` como grupo de runtime e preserva a segmentação acima como desenho de produção. Essa diferença deve permanecer explícita no portfólio, em vez de fingir paridade que o emulador não oferece.

## Criar e validar

```powershell
.\scripts\localstack\create-network.ps1
.\scripts\localstack\status-network.ps1
```

Os scripts são idempotentes: uma segunda execução reutiliza VPC, subnets, Internet Gateway e route tables existentes.


## Estado validado

A topologia foi validada localmente com uma VPC `10.20.0.0/16`, seis subnets em `us-east-1a`/`us-east-1b`, Internet Gateway, route table pública e route tables privadas separadas para aplicação e dados.
