# Arquitetura alvo

```text
GitHub
  |
  v
CodePipeline
  |
  v
CodeBuild ---> ECR
                |
                v
          ECS on EC2
          /        \
       Task A     Task B
          \        /
           Target Group
                |
               ALB
                |
           CloudFront
                |
              User

ECS ---> RDS PostgreSQL
```

## Objetivos

- Duas zonas de disponibilidade.
- ECS usando capacidade EC2.
- Múltiplas tasks da aplicação.
- Dynamic port mapping.
- Target Group com health check em `/health`.
- ALB como entrada da aplicação.
- RDS PostgreSQL separado do ciclo de vida das tasks.
- CloudFront como camada de distribuição.
- CloudWatch para logs, métricas e alarmes.
