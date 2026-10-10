# Plano interno de etapas — referência BIA obrigatória

A sequência de 13 etapas abaixo foi organizada para o trabalho; não foi fornecida como sequência oficial no vídeo. A [matriz da referência](REFERENCE-VIDEO.md) define o aceite obrigatório: aplicação fiel, pipeline com GitHub/CodeBuild/ECS padrão, infraestrutura AWS, CloudFront e Amazon Q/MCP. A execução autorizada é local, em Docker/LocalStack Student/Pro. Cada componente requer prova funcional atual; limitações do emulador não podem ser apresentadas como paridade AWS.

## Pendências de paridade que impedem o encerramento

- [x] Implementar os elementos de interface observáveis no vídeo e verificar desktop/celular. A revisão filmada e os fluxos não exibidos ainda impedem afirmar igualdade integral.
- [x] Substituir o indicador fixo por saúde real; aceitar prazo textual com migração compatível e permitir editar prioridade. Contratos ocultos do original continuam não verificados.
- [x] Preservar e verificar rede, banco, duas réplicas ECS, ALB/TG e transporte TLS no LocalStack. ECS/EC2 e TG instance permanecem diferenças arquiteturais explícitas do executor Docker, sem provisionamento pago.
- [ ] Integrar Source GitHub por conexão autorizada e provar commit -> CodeBuild -> ação ECS padrão -> aplicação atualizada.
- [x] Configurar e testar o proxy CloudFront; preservar Disabled e documentar limites de cache/redirect/alias/bloqueio.
- [ ] Concluir a validação e demonstração do agente Amazon Q após login Builder ID; testar os dois MCPs independentemente.
- [ ] Identificar a revisão original e registrar as configurações não observáveis no recorte; não declarar igualdade integral sem essas fontes.
- [x] Reconectar o Windows, ler as sete etapas aprovadas da tentativa de 04/10 e verificar as sessões de 08/10 separadamente. [Evidências atuais](EVIDENCE-BIA-20261008.json).

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
- [x] Infraestrutura local reproduzível por scripts. Provisionamento faturável na AWS está fora da autorização atual; não bloqueia a entrega local.

## 5. RDS

- [x] PostgreSQL executável, Secrets Manager e `SELECT 1`.
- [x] Banco compartilhado pelas duas réplicas.
- [x] Registrar via SQL PostgreSQL 17.11 (Debian 17.11-1.pgdg13+2). A API solicita engine 16; o emulador usa seu provider padrão.

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
- [x] Após o reinício de 10/10, aprovar duas execuções distintas do mesmo Source sem reset: bake 74,229 s e 96,229 s, duas réplicas finais saudáveis, seis flags de cleanup e lock ausente. [Evidência](EVIDENCE-REBOOT-20261010.json).
- [ ] Certificação do controlador AWS nativo permanece não demonstrada pelo emulador; não autoriza provisionamento pago nem é tratada como conclusão da arquitetura AWS.

O adaptador é `LocalStackBlueGreenAdapter`, selecionado com `-DeploymentMode BlueGreen`. Coexistem duas tasks blue e duas green; HTTP/HTTPS, CRUD entre revisões e bake ≥60 s precedem a convergência canônica 0→2 enquanto green atende. O serviço/TG principal, UI e banco são preservados. Candidata inválida não promove; falha após promoção restaura blue e mantém a pipeline falha. [Desenho e limites](BLUE-GREEN.md).

As duas entregas nativas 1.8.1 e a entrega 1.8.2 anteriores à troca CORS passaram no respectivo runtime. Na sessão nova, duas tentativas Blue/Green falharam: houve recuperação manual de cleanup na primeira e rollback/cleanup automático na segunda. Essas falhas de 08/10 permanecem reprovadas; a execução ECS padrão aprovada é uma prova separada. Em 10/10, duas novas execuções Blue/Green passaram no runtime retomado, sem reset entre elas; não foi comprovada a causa das falhas antigas. A certificação do controlador AWS não foi executada. [Registro atual](EVIDENCE-BIA-20261008.json).

## 10. CloudFront

- [x] Configurar distribuição/origin ALB, métodos CRUD e TTL zero para rotas dinâmicas; assets com política separada.
- [x] Verificar proxy HTTPS, bytes dos assets, CRUD/banco e restauração de Disabled por ETag.
- [ ] Cache de edge, redirect, alias alternativo e bloqueio de tráfego Disabled não são aplicados como na AWS pelo provider. [Resultado verificado](CLOUDFRONT.md).

## 11. Observabilidade / CloudWatch

- [x] Métricas reais Docker/ALB/health, logs sanitizados, dashboard lido de volta e monitor contínuo.
- [x] Alarme avaliado por HTTP isolado 200/503/200, sem SetAlarmState nem indisponibilidade induzida na BIA. [Operação e evidência](OBSERVABILITY.md).

## 12. Amazon Q + MCP

- [x] Instalar Amazon Q 1.19.7 com integridade conferida, perfil privado e configuração do agente bia limitada a duas ferramentas de leitura.
- [x] Criar role PostgreSQL somente leitura, preservar tarefas e provar negação real de escrita pelo banco.
- [x] Inicializar os dois servidores pelo protocolo MCP e consultar ECS/schema/banco reais, negar escrita e preservar tarefas.
- [ ] Validar o agente e demonstrar o chat autenticado após login Builder ID. [Operação](AMAZON-Q-MCP.md).

## 13. Apresentação e encerramento do projeto

- [ ] Diagrama, evidências, vídeo curto e roteiro de entrevista.
- [ ] Resolver limitações documentadas, revisar IAM/segurança e diferenciar AWS alvo de emulação.

A ordem histórica dos ensaios locais é preservada. CloudFront e Q/MCP são requisitos do vídeo e precisam ser concluídos para o aceite final. Blue/Green foi solicitado em etapa posterior pela usuária; sua homologação local não substitui o Deploy ECS padrão mostrado na referência. Métricas/dashboard e material de apresentação não devem ampliar silenciosamente o escopo demonstrado.
