# Decisões arquiteturais

## Monorepo com npm workspaces

Frontend e backend permanecem no mesmo repositório para simplificar CI/CD e rastreabilidade de versões.

## Imagem única de aplicação

Em produção, o Express entrega os arquivos compilados do React. Isso reduz a quantidade de serviços necessária para a demonstração e concentra o foco na infraestrutura AWS.

## PostgreSQL externo em produção

O banco local roda em Docker, mas em AWS será substituído por Amazon RDS PostgreSQL.

## ECS sobre EC2

A arquitetura alvo usa ECS com capacidade EC2 para se aproximar do projeto de referência e permitir demonstração de instances, dynamic port mapping e Target Group.

## Health check dependente do banco

`/health` executa `SELECT 1`. Dessa forma, uma task incapaz de acessar o banco não deve ser considerada pronta para receber tráfego.
