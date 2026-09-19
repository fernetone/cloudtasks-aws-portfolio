# Roadmap

## Concluído

- Aplicação React/Node/PostgreSQL.
- Docker Compose local.
- Health check.
- Testes automatizados.
- Lint e formatação.
- GitHub Actions com CI aprovado.
- Repositório público publicado no GitHub.
- Preparação inicial do CodeBuild.
- Automação e documentação do Amazon ECR.

## Em andamento

### Etapa 3 — Amazon ECR

- [x] Script idempotente para criação/configuração do repositório `cloudtasks`.
- [x] Tags imutáveis definidas como padrão do projeto.
- [x] Scan on push preparado.
- [x] Lifecycle policy para manter as 20 imagens mais recentes.
- [x] Script para publicar a primeira imagem Docker.
- [x] `buildspec.yml` ajustado para usar tags imutáveis por commit.
- [x] Política IAM mínima de push preparada para o futuro CodeBuild.
- [ ] Criar o repositório dentro da conta AWS.
- [ ] Publicar e confirmar a primeira imagem no ECR.

Veja [`AWS-ECR.md`](AWS-ECR.md).

## Próximas etapas

1. Concluir Amazon ECR com a primeira imagem publicada.
2. Criar VPC, subnets, route tables e security groups.
3. Criar RDS PostgreSQL.
4. Criar cluster ECS sobre EC2.
5. Criar task definition e service.
6. Criar Target Group e Application Load Balancer.
7. Validar duas tasks saudáveis.
8. Criar CodePipeline GitHub → CodeBuild → ECS.
9. Configurar HTTPS com ACM.
10. Adicionar CloudFront.
11. Adicionar observabilidade no CloudWatch.
12. Integrar Amazon Q Developer e MCP.
13. Consolidar screenshots, diagrama e demonstração final do portfólio.
