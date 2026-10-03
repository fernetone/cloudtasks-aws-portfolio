# Roadmap oficial — 13 etapas

A ordem abaixo segue o escopo do portfólio. Marcações anteriores de infraestrutura representam execução relatada na máquina do laboratório, não um deploy produtivo AWS certificado pela auditoria.

## 1. Aplicação local

- [x] React 19/TypeScript/Vite, Node 24/Express 5 e PostgreSQL.
- [x] CRUD e `/health` com verificação do banco; Docker Compose.

## 2. Qualidade + GitHub

- [x] TypeScript, lint, testes API/frontend e GitHub Actions.
- [x] Lockfile e `npm ci` incluídos na versão 1.7.1.
- [x] Executar CI Ubuntu/Docker e o job Windows de regressões PowerShell 5.1 no GitHub; [evidência](EVIDENCE-GITHUB.json).
- [ ] Resolver a dívida de formatação e revisar advisory das dependências de teste.

## 3. ECR

- [x] Build/push de imagem e repositório com tags imutáveis.
- [x] Consulta exata e verificação de criação concorrente na versão 1.7.1.

## 4. Infraestrutura AWS

- [x] Laboratório: VPC, seis subnets, duas AZs, route tables e Internet Gateway.
- [ ] Provisionamento produtivo AWS completo por IaC, se for incluído no escopo futuro; não é pré-requisito para refazer a etapa 8 local.

## 5. RDS

- [x] PostgreSQL executável, Secrets Manager e `SELECT 1`.
- [x] Banco compartilhado pelas duas réplicas.
- [ ] Registrar versão PostgreSQL efetiva via SQL; `EngineVersion` da API não prova o engine do emulador.

## 6. ECS

- [x] Cluster, task definition, service e duas tasks saudáveis.
- [x] Alvo ECS/EC2 documentado; executor Docker local sem EC2 reais.
- [x] CloudWatch Logs básico já exercitado.

## 7. ALB

- [x] TG local `ip`, HTTP, health e 2/2 targets; failover exercitado.
- [x] HTTPS/ACM no control plane e tráfego TLS pelo gateway LocalStack.

## 8. CI/CD — HOMOLOGADA NO LABORATÓRIO EM 03/10/2026

- [x] Código: Source S3 versionado, CodePipeline V1, CodeBuild, ECR e ação ECS padrão.
- [x] Captura nativa PowerShell corrigida; Source permitido/hash/VersionId; aceitação sem fallback.
- [x] Executar Source/Build/Deploy nativos e `test-cicd.ps1` no laboratório.
- [x] Repetir com alteração real: novo Source, build, imagem/digest e revisão, visíveis na aplicação.
- [x] Demonstrar CodeBuild `FAILED` por quality gate e ausência de Deploy; manter revisão saudável.
- [x] Registrar versão/digest e evidência sanitizada em docs/EVIDENCE-CICD.json.
- [x] Publicar código e evidência no GitHub pela [PR #1](https://github.com/fernetone/cloudtasks-aws-portfolio/pull/1), com CI real aprovado.

## 9. Blue/Green

- [x] Consultar documentação oficial e testar APIs de leitura na versão instalada, preservando ECS/ALB.
- [x] Registrar desenho AWS, alternativas e limites do laboratório em [BLUE-GREEN.md](BLUE-GREEN.md).
- [x] Prova temporária manual: duas imagens simultâneas, rota de teste, promoção e rollback reais em um ALB isolado, com produção preservada; [evidência de tráfego](EVIDENCE-BLUE-GREEN-TRAFFIC.json).
- [x] Rejeitar a candidata sem targets/health válido mesmo quando a resposta do emulador é HTTP 200; registrar a divergência de paridade.
- [ ] Implementar o fluxo repetível de Blue/Green pelo controlador, com janela de observação, teste de candidata inválida e integração de entrega.
- [ ] Provar o controlador AWS nativo e sua integração CI/CD. Bloqueado no laboratório atual: CodeDeploy mockado, ação sem troca Blue/Green e APIs de service deployments ECS não implementadas na cobertura documentada.

A prova manual foi executada em 03/10/2026 e não conclui a etapa 9 nativa. Usou uma task candidata temporária e dois targets blue existentes, sem novo build, migração, janela automática de observação ou controlador de implantação. Nenhum script de promoção próprio foi incorporado. CloudFront continua na etapa 10.

## 10. CloudFront

- [ ] Configurar distribuição/origin ALB e regras para `/api/*`.
- [ ] Validar tráfego efetivo, cache e TLS da CDN.

## 11. Observabilidade / CloudWatch

- [ ] Métricas, alarmes, dashboard e falha controlada; ampliar logs já existentes.

## 12. Amazon Q + MCP

- [ ] Integração, permissões, prompts e demonstração segura.

## 13. Polimento final do portfólio

- [ ] Diagrama, evidências, vídeo curto e roteiro de entrevista.
- [ ] Resolver limitações documentadas, revisar IAM/segurança e diferenciar AWS alvo de emulação.

Não antecipar as etapas 9–13 para declarar a etapa 8 concluída.
