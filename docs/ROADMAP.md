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
- [x] Em 04/10/2026, reconstruir em LocalStack 2026.9.0 e aprovar uma execução nativa distinta, com `test-cicd.ps1` e produção 2/2; registrar separadamente a primeira execução rejeitada por excesso de task. A mudança visível e o quality gate negativo da homologação anterior não foram repetidos nesta sessão.

## 9. Blue/Green — laboratório por adaptador explícito

- [x] Investigar documentação/APIs e reprovar honestamente os ensaios nativos sem isolamento/retenção.
- [x] Preservar testes bridge/IP, awsvpc/IP e EXTERNAL no histórico; não modificar a rede do serviço principal por esse bloqueio.
- [x] Implementar controlador/adaptador dentro de um segundo CodeBuild da CodePipeline V1; Source S3/artifacts/imagem/recibo correlacionados, sem fallback externo.
- [x] Testar estado/guards, health semântica, identidade, troca parcial, rollback, cleanup, retenção do lock e fronteira de convergência.
- [x] No Source final bb052, aprovar duas entregas consecutivas, rejeição e rollback após promoção; uma normal final distinta passou após erro npm INSTALL registrado. Convergência0→2, bake2+2, HTTPS/CRUD, digest, limpeza e lock foram comprovados na [evidência atual](EVIDENCE-BLUE-GREEN-ADAPTER.json).
- [ ] Certificar o controlador AWS nativo em uma implantação AWS autorizada. O emulador testado não demonstrou os requisitos; isso é separado do aceite do adaptador local.

O adaptador é `LocalStackBlueGreenAdapter`, selecionado com `-DeploymentMode BlueGreen`. Coexistem duas tasks blue e duas green; HTTP/HTTPS, CRUD entre revisões e bake ≥60 s precedem a convergência canônica 0→2 enquanto green atende. O serviço/TG principal, UI e banco são preservados. Candidata inválida não promove; falha após promoção restaura blue e mantém a pipeline falha. [Desenho e limites](BLUE-GREEN.md).

As provas manuais e nativas anteriores são históricas. Não aprovam esta implementação ou CodeDeploy mockado. A certificação AWS nativa não foi executada e não bloqueia o uso honesto do laboratório por adaptador.

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

A etapa 8 foi concluída antes de iniciar a etapa 9. Não antecipar CloudFront, observabilidade ampliada ou Q/MCP para aprovar Blue/Green.
