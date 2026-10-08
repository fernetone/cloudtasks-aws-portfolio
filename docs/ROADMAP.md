# Plano interno de etapas â€” referÃªncia BIA obrigatÃ³ria

A sequÃªncia de 13 etapas abaixo foi organizada para o trabalho; nÃ£o foi fornecida como sequÃªncia oficial no vÃ­deo. A [matriz da referÃªncia](REFERENCE-VIDEO.md) define o aceite obrigatÃ³rio: aplicaÃ§Ã£o fiel, pipeline com GitHub/CodeBuild/ECS padrÃ£o, infraestrutura AWS, CloudFront e Amazon Q/MCP. MarcaÃ§Ãµes locais anteriores nÃ£o sÃ£o aprovaÃ§Ã£o do projeto final.

## PendÃªncias de paridade que impedem o encerramento

- [x] Implementar os elementos de interface observÃ¡veis no vÃ­deo e verificar desktop/celular. A revisÃ£o filmada e os fluxos nÃ£o exibidos ainda impedem afirmar igualdade integral.
- [x] Substituir o indicador fixo por saÃºde real; aceitar prazo textual com migraÃ§Ã£o compatÃ­vel e permitir editar prioridade. Contratos ocultos do original continuam nÃ£o verificados.
- [ ] Provisionar infraestrutura AWS efetiva, capacidade ECS/EC2 registrada, ALB/TG por instÃ¢ncia e TLS efetivo.
- [ ] Integrar Source GitHub por conexÃ£o autorizada e provar commit -> CodeBuild -> aÃ§Ã£o ECS padrÃ£o -> aplicaÃ§Ã£o atualizada.
- [ ] Implantar e verificar CloudFront e Amazon Q com MCP ECS e PostgreSQL.
- [ ] Identificar a revisÃ£o original e registrar as configuraÃ§Ãµes nÃ£o observÃ¡veis no recorte; nÃ£o declarar igualdade integral sem essas fontes.
- [x] Reconectar o Windows, ler as sete etapas aprovadas da tentativa de 04/10 e verificar as sessÃµes de 08/10 separadamente. [EvidÃªncias atuais](EVIDENCE-BIA-20261008.json).

## 1. AplicaÃ§Ã£o local

- [x] React 19/TypeScript/Vite, Node 24/Express 5 e PostgreSQL.
- [x] CRUD e `/health` com verificaÃ§Ã£o do banco; Docker Compose.

## 2. Qualidade + GitHub

- [x] TypeScript, lint, testes API/frontend e GitHub Actions.
- [x] Lockfile e `npm ci` incluÃ­dos na versÃ£o 1.7.1.
- [x] Executar CI Ubuntu/Docker e o job Windows de regressÃµes PowerShell 5.1 no GitHub; [evidÃªncia](EVIDENCE-GITHUB.json).
- [ ] Resolver a dÃ­vida de formataÃ§Ã£o e revisar advisory das dependÃªncias de teste.

## 3. ECR

- [x] Build/push de imagem e repositÃ³rio com tags imutÃ¡veis.
- [x] Consulta exata e verificaÃ§Ã£o de criaÃ§Ã£o concorrente na versÃ£o 1.7.1.

## 4. Infraestrutura AWS

- [x] LaboratÃ³rio: VPC, seis subnets, duas AZs, route tables e Internet Gateway.
- [ ] Provisionamento AWS completo e reproduzÃ­vel, incluindo capacidade EC2, bootstrap e controles de rede/IAM. Ã‰ requisito da entrega final solicitada.

## 5. RDS

- [x] PostgreSQL executÃ¡vel, Secrets Manager e `SELECT 1`.
- [x] Banco compartilhado pelas duas rÃ©plicas.
- [x] Registrar via SQL PostgreSQL 17.11 (Debian 17.11-1.pgdg13+2). A API solicita engine 16; o emulador usa seu provider padrÃ£o.

## 6. ECS

- [x] Cluster, task definition, service e duas tasks saudÃ¡veis.
- [x] Alvo ECS/EC2 documentado; executor Docker local sem EC2 reais.
- [x] CloudWatch Logs bÃ¡sico jÃ¡ exercitado.

## 7. ALB

- [x] TG local `ip`, HTTP, health e 2/2 targets; failover exercitado.
- [x] HTTPS/ACM no control plane e trÃ¡fego TLS pelo gateway LocalStack.

## 8. CI/CD â€” HOMOLOGADA NO LABORATÃ“RIO EM 03/10/2026

- [x] CÃ³digo: Source S3 versionado, CodePipeline V1, CodeBuild, ECR e aÃ§Ã£o ECS padrÃ£o.
- [x] Captura nativa PowerShell corrigida; Source permitido/hash/VersionId; aceitaÃ§Ã£o sem fallback.
- [x] Executar Source/Build/Deploy nativos e `test-cicd.ps1` no laboratÃ³rio.
- [x] Repetir com alteraÃ§Ã£o real: novo Source, build, imagem/digest e revisÃ£o, visÃ­veis na aplicaÃ§Ã£o.
- [x] Demonstrar CodeBuild `FAILED` por quality gate e ausÃªncia de Deploy; manter revisÃ£o saudÃ¡vel.
- [x] Registrar versÃ£o/digest e evidÃªncia sanitizada em docs/EVIDENCE-CICD.json.
- [x] Publicar cÃ³digo e evidÃªncia no GitHub pela [PR #1](https://github.com/fernetone/cloudtasks-aws-portfolio/pull/1), com CI real aprovado.
- [x] Em 04/10/2026, reconstruir em LocalStack 2026.9.0 e aprovar uma execuÃ§Ã£o nativa distinta, com `test-cicd.ps1` e produÃ§Ã£o 2/2; registrar separadamente a primeira execuÃ§Ã£o rejeitada por excesso de task. A mudanÃ§a visÃ­vel e o quality gate negativo da homologaÃ§Ã£o anterior nÃ£o foram repetidos nesta sessÃ£o.

## 9. Blue/Green â€” laboratÃ³rio por adaptador explÃ­cito

- [x] Investigar documentaÃ§Ã£o/APIs e reprovar honestamente os ensaios nativos sem isolamento/retenÃ§Ã£o.
- [x] Preservar testes bridge/IP, awsvpc/IP e EXTERNAL no histÃ³rico; nÃ£o modificar a rede do serviÃ§o principal por esse bloqueio.
- [x] Implementar controlador/adaptador dentro de um segundo CodeBuild da CodePipeline V1; Source S3/artifacts/imagem/recibo correlacionados, sem fallback externo.
- [x] Testar estado/guards, health semÃ¢ntica, identidade, troca parcial, rollback, cleanup, retenÃ§Ã£o do lock e fronteira de convergÃªncia.
- [x] No Source final bb052, aprovar duas entregas consecutivas, rejeiÃ§Ã£o e rollback apÃ³s promoÃ§Ã£o; uma normal final distinta passou apÃ³s erro npm INSTALL registrado. ConvergÃªncia0â†’2, bake2+2, HTTPS/CRUD, digest, limpeza e lock foram comprovados na [evidÃªncia atual](EVIDENCE-BLUE-GREEN-ADAPTER.json).
- [ ] Certificar o controlador AWS nativo em uma implantaÃ§Ã£o AWS autorizada. O emulador testado nÃ£o demonstrou os requisitos; isso Ã© separado do aceite do adaptador local.

O adaptador Ã© `LocalStackBlueGreenAdapter`, selecionado com `-DeploymentMode BlueGreen`. Coexistem duas tasks blue e duas green; HTTP/HTTPS, CRUD entre revisÃµes e bake â‰¥60 s precedem a convergÃªncia canÃ´nica 0â†’2 enquanto green atende. O serviÃ§o/TG principal, UI e banco sÃ£o preservados. Candidata invÃ¡lida nÃ£o promove; falha apÃ³s promoÃ§Ã£o restaura blue e mantÃ©m a pipeline falha. [Desenho e limites](BLUE-GREEN.md).

As duas entregas nativas 1.8.1 e a entrega 1.8.2 anteriores Ã  troca CORS passaram no respectivo runtime. Na sessÃ£o nova, duas tentativas Blue/Green falharam: houve recuperaÃ§Ã£o manual de cleanup na primeira e rollback/cleanup automÃ¡tico na segunda. A homologaÃ§Ã£o Blue/Green dessa sessÃ£o continua pendente; a execuÃ§Ã£o nativa ECS padrÃ£o aprovada Ã© uma prova separada. A certificaÃ§Ã£o do controlador AWS nÃ£o foi executada. [Registro atual](EVIDENCE-BIA-20261008.json).

## 10. CloudFront

- [ ] Configurar distribuiÃ§Ã£o/origin ALB e regras para `/api/*`.
- [ ] Validar trÃ¡fego efetivo, cache e TLS da CDN.

## 11. Observabilidade / CloudWatch

- [ ] MÃ©tricas, alarmes, dashboard e falha controlada; ampliar logs jÃ¡ existentes.

## 12. Amazon Q + MCP

- [ ] IntegraÃ§Ã£o, permissÃµes, prompts e demonstraÃ§Ã£o segura.

## 13. ApresentaÃ§Ã£o e encerramento do projeto

- [ ] Diagrama, evidÃªncias, vÃ­deo curto e roteiro de entrevista.
- [ ] Resolver limitaÃ§Ãµes documentadas, revisar IAM/seguranÃ§a e diferenciar AWS alvo de emulaÃ§Ã£o.

A ordem histÃ³rica dos ensaios locais Ã© preservada. CloudFront e Q/MCP sÃ£o requisitos do vÃ­deo e precisam ser concluÃ­dos para o aceite final. Blue/Green foi solicitado em etapa posterior pela usuÃ¡ria; sua homologaÃ§Ã£o local nÃ£o substitui o Deploy ECS padrÃ£o mostrado na referÃªncia. MÃ©tricas/dashboard e material de apresentaÃ§Ã£o nÃ£o devem ampliar silenciosamente o escopo demonstrado.
