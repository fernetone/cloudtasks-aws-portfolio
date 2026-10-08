# DecisÃµes arquiteturais

## ADR-018 - ReferÃªncia BIA como requisito da entrega final

**DecisÃ£o em 08/10/2026:** a [matriz do vÃ­deo V01-V12](REFERENCE-VIDEO.md) define o escopo obrigatÃ³rio. Entregar aplicaÃ§Ã£o, comportamento e apresentaÃ§Ã£o fiÃ©is Ã  BIA demonstrada, com os serviÃ§os efetivos na AWS. LocalStack permanece um ambiente auxiliar; suas adaptaÃ§Ãµes e homologaÃ§Ãµes nÃ£o representam equivalÃªncia integral.

**Motivo:** a usuÃ¡ria reiterou reproduÃ§Ã£o literal. A documentaÃ§Ã£o anterior dispensava nome/interface, classificava AWS real como expansÃ£o possÃ­vel e chamava as 13 etapas de oficiais. Essas interpretaÃ§Ãµes foram corrigidas. A gravaÃ§Ã£o mostra Deploy Amazon ECS padrÃ£o; o Blue/Green solicitado depois Ã© trabalho adicional autorizado, com aceite prÃ³prio.

**ConsequÃªncia:** GitHub integrado Ã  CodePipeline, ECS/EC2 registrados, TG por instÃ¢ncia, ALB/TLS efetivos, PostgreSQL durÃ¡vel, CloudFront, Amazon Q/MCP e paridade visual/funcional deixam de ser opcionais. Aprovar o adaptador local nÃ£o encerra esses itens. Confirmar a revisÃ£o original e configuraÃ§Ãµes nÃ£o exibidas antes de alegar igualdade de cÃ³digo/configuraÃ§Ã£o; credenciais e domÃ­nio do autor nÃ£o sÃ£o entradas autorizadas da usuÃ¡ria.

**PreservaÃ§Ã£o:** decisÃµes e evidÃªncias locais histÃ³ricas abaixo continuam contextualizadas. A revisÃ£o inicial alterou documentaÃ§Ã£o e critÃ©rios durante a desconexÃ£o. ApÃ³s a reconexÃ£o, a versÃ£o 1.8.2 implementou as correÃ§Ãµes de aplicaÃ§Ã£o, com migraÃ§Ã£o aditiva, e o acesso pelo ALB exigiu uma nova sessÃ£o LocalStack com banco restaurado. Esses resultados sÃ£o registrados em [EVIDENCE-BIA-20261008.json](EVIDENCE-BIA-20261008.json).

## ADR-001 â€” Um Ãºnico container de aplicaÃ§Ã£o

O build do React Ã© servido pelo Express em produÃ§Ã£o. Isso mantÃ©m um Ãºnico serviÃ§o ECS e um Ãºnico Target Group, aproximando o projeto do modelo demonstrativo que originou o portfÃ³lio e reduzindo complexidade operacional.

## ADR-002 â€” PostgreSQL separado da aplicaÃ§Ã£o

Localmente o PostgreSQL roda em outro container. Na AWS ele serÃ¡ substituÃ­do pelo Amazon RDS. Dados nÃ£o dependem do ciclo de vida das tasks ECS.

## ADR-003 â€” Health check consulta o banco

`GET /health` executa uma consulta simples no PostgreSQL. Assim, o ALB poderÃ¡ detectar nÃ£o apenas se o processo Node estÃ¡ vivo, mas se a aplicaÃ§Ã£o estÃ¡ pronta para atender requisiÃ§Ãµes dependentes do banco.

## ADR-004 â€” Testes de API sem PostgreSQL real

A camada HTTP depende de uma interface de repositÃ³rio. Os testes usam uma implementaÃ§Ã£o em memÃ³ria, tornando o suite rÃ¡pido e determinÃ­stico. A implementaÃ§Ã£o PostgreSQL continua isolada na camada de infraestrutura.

## ADR-005 â€” Identidade imutÃ¡vel por build

A pipeline publica `pipeline-<UUID v4 gerado pelo prÃ³prio build>`, sem `latest`, no ECR imutÃ¡vel. Execution ID, Source VersionId/SHA256, CodeBuild ID, digest e task definition formam a cadeia de rastreabilidade. Builds repetidos do mesmo commit podem ter tags distintas; o artifact ECS usa a URI do build que o produziu.

## ADR-006 â€” ECS sobre EC2

A arquitetura alvo utilizarÃ¡ ECS com instÃ¢ncias EC2, e nÃ£o Fargate, para reproduzir o padrÃ£o visual e operacional do projeto de referÃªncia: cluster ECS com instÃ¢ncias registradas, tasks distribuÃ­das e Target Group apresentando targets associados Ã s instÃ¢ncias/portas dinÃ¢micas.

## ADR â€” HTTPS local: separar plano de controle ACM do TLS do gateway

**DecisÃ£o:** representar o listener ALB `HTTPS :443` e a associaÃ§Ã£o ACM no ELBv2, mas documentar que a conexÃ£o local `https://...:4566` Ã© terminada pelo certificado do gateway LocalStack.

**Motivo:** isso preserva fidelidade arquitetural sem afirmar que o runtime local apresenta o mesmo certificado ACM no socket compartilhado. Em AWS real, o certificado ACM associado Ã© efetivamente usado pelo listener do ALB.

**SeguranÃ§a:** quando necessÃ¡rio, o certificado autoassinado de laboratÃ³rio Ã© gerado e importado inteiramente dentro do container LocalStack; PEM e chave privada temporÃ¡rios sÃ£o apagados logo apÃ³s o import.

## ADR â€” Runtime LocalStack efÃªmero com `/var/lib/localstack` em bind mount

**DecisÃ£o:** usar `PERSISTENCE=0` e criar um diretÃ³rio de bind mount novo por sessÃ£o em `%USERPROFILE%\.cloudtasks\localstack-runtime\session-*`.

**Motivo:** o bind mount continua obrigatÃ³rio para o executor Docker do CodeBuild, porÃ©m snapshots restaurados do LocalStack produziram referÃªncias runtime-bound invÃ¡lidas em RDS/ECS/ECR. Em especial, ECR chegou a restaurar o repositÃ³rio sem um endpoint interno vÃ¡lido para `DescribeImages`.

**ConsequÃªncia:** a infraestrutura AWS emulada Ã© recriada por scripts idempotentes a cada sessÃ£o. Isso sacrifica persistÃªncia local de dados do laboratÃ³rio em troca de reprodutibilidade. A arquitetura AWS real nÃ£o muda.

## D-008 â€” NÃ£o usar snapshots como fonte de verdade do laboratÃ³rio

**DecisÃ£o:** tratar scripts declarativos/idempotentes como fonte de verdade do ambiente local.

**Motivo:** a persistÃªncia por snapshot do emulador nÃ£o garante identidade do runtime Docker, endpoints internos ou portas entre sessÃµes.

**PreservaÃ§Ã£o:** nenhum reset destrutivo Ã© aplicado a uma conta AWS real; essa decisÃ£o Ã© restrita ao LocalStack.

## ADR â€” ECS local sem launch type EC2 explÃ­cito

**DecisÃ£o:** o laboratÃ³rio LocalStack cria o service ECS sem `--launch-type EC2` explÃ­cito e sem `requiresCompatibilities=[EC2]` na task definition local.

**Motivo:** o runtime EC2 emulado usa recursos/IDs efÃªmeros que nÃ£o tÃªm a mesma persistÃªncia do control plane. Foram observados `InvalidInstanceID.NotFound` apÃ³s restart e service preso em `PENDING` sem criaÃ§Ã£o de container. O fluxo padrÃ£o documentado pelo LocalStack executa as tasks diretamente no Docker local sem exigir instÃ¢ncias EC2 reais.

**ConsequÃªncia:** a task definition local permanece `bridge` com `hostPort=0`, preservando portas dinÃ¢micas e os testes existentes. A arquitetura AWS alvo continua explicitamente ECS sobre EC2; essa diferenÃ§a Ã© documentada como limite de paridade do laboratÃ³rio.

## ADR-009 â€” AprovaÃ§Ã£o somente por execuÃ§Ã£o nativa

**DecisÃ£o:** exigir Source, Build e Deploy bem-sucedidos nas APIs da CodePipeline, com CodeBuild vinculado e evidÃªncia do artefato nas tasks. Remover seleÃ§Ã£o por tag mais recente, aprovaÃ§Ã£o por logs de runner e execuÃ§Ã£o/deploy externos usados como fallback.

**Motivo:** testar componentes isolados nÃ£o prova orquestraÃ§Ã£o CI/CD. DivergÃªncia do emulador mantÃ©m a etapa pendente; nÃ£o autoriza converter resultado incompleto em sucesso.

**ConsequÃªncia:** uma versÃ£o do LocalStack cujo engine nÃ£o complete o fluxo precisa ser investigada/corrigida antes de encerrar a etapa 8. O laboratÃ³rio nÃ£o promete eliminar uma falha de fornecedor por interpretaÃ§Ã£o de logs.

## ADR-010 â€” Capturar processos nativos antes de filtrar

**DecisÃ£o:** consultar containers de tasks pelo helper comum, capturar toda a saÃ­da de `docker ps`, ler o exit code apÃ³s tÃ©rmino e sÃ³ entÃ£o interpretar os resultados.

**Motivo:** `Select-Object -First` em um pipeline ativo pode encerrar o produtor. O original rejeitava IDs encontrados por causa do exit code resultante, enquanto status ignorava esse cÃ³digo.

**ConsequÃªncia:** falha Docker, resultado ambÃ­guo e ausÃªncia de container continuam reprovados, com motivo explÃ­cito. NÃ£o se ignora `$LASTEXITCODE` para aceitar o ambiente.

## ADR-011 â€” Inputs permitidos e cadeia de identidade

**DecisÃ£o:** empacotar somente entradas requeridas do build, normalizar ZIP, guardar o VersionId retornado pelo upload e o SHA256. Usar esse Source na pipeline e ligar BuildId, tag UUID, digest ECR e tasks.

**Motivo:** exclusÃµes parciais e identidade por `HEAD`/tag mais recente permitem vazamento ou seleÃ§Ã£o de outra execuÃ§Ã£o.

**ConsequÃªncia:** assets/configuraÃ§Ãµes novos fora da lista precisam ser revisados e incorporados explicitamente. O lockfile Ã© obrigatÃ³rio. NÃ£o hÃ¡ expectativa de Source GitHub automÃ¡tico no laboratÃ³rio, mas o alvo CodeConnections Ã© preservado.

## Identidade da imagem no agente local

O agente observado em 03/10/2026 injetou `CODEBUILD_BUILD_ID` com UUID zerado, enquanto a API retornou um ID curto real. A tag nÃ£o deriva desse valor reservado. CodeBuild gera um UUID v4; CodePipeline transporta `imagedefinitions.json` e o ECS nativo usa esse artifact. A aceitaÃ§Ã£o verifica o build vinculado, a localizaÃ§Ã£o e o hash do artifact, o digest ECR e as tasks fÃ­sicas. `pipeline-build.json` e o parser IDâ†’tag foram removidos. NÃ£o hÃ¡ deploy por fallback.

## ADR-012 â€” EvidÃªncia de trÃ¡fego separada da homologaÃ§Ã£o do controlador

**Estado:** a restriÃ§Ã£o operacional da versÃ£o 1.7.8 foi substituÃ­da pela ADR-013. A distinÃ§Ã£o entre prova de trÃ¡fego local e certificaÃ§Ã£o do controlador AWS permanece vÃ¡lida.

Os ensaios nativos em LocalStack 2026.8.3 e 2026.9.0 aceitaram configuraÃ§Ã£o BLUE_GREEN, mas nÃ£o demonstraram isolamento e retenÃ§Ã£o requeridos; os controles bridge/IP e awsvpc/IP perderam blue diante da candidata invÃ¡lida. O ensaio EXTERNAL posterior aceitou metadata STEADY_STATE, mas criou zero tasks executÃ¡veis. Esses resultados reprovados sÃ£o preservados em [BLUE-GREEN.md](BLUE-GREEN.md#limites-do-fornecedor-e-testes-anteriores) e nas evidÃªncias histÃ³ricas. NÃ£o justificam alterar a aplicaÃ§Ã£o, migrar o serviÃ§o principal para Fargate/awsvpc ou aprovar CodeDeploy mockado.

## ADR-013 â€” Blue/Green local explÃ­cito dentro da CodePipeline/CodeBuild

**DecisÃ£o:** oferecer `-DeploymentMode BlueGreen` em `create-cicd.ps1`. Manter `Rolling` como padrÃ£o e adicionar uma aÃ§Ã£o CodeBuild de implantaÃ§Ã£o que consome o artifact do build da imagem. Dois serviÃ§os ECS independentes mantÃªm blue e green executÃ¡veis; apÃ³s bake aprovado, convergir o serviÃ§o/TG principal por uma transiÃ§Ã£o 0â†’2 verificada enquanto green atende, e retirar os recursos temporÃ¡rios.

**Motivo:** o controlador nativo testado nÃ£o manteve as revisÃµes isoladas. As APIs ECS/ELB executÃ¡veis do laboratÃ³rio permitem demonstrar trÃ¡fego real sem um fallback PowerShell externo e sem abandonar a orquestraÃ§Ã£o nativa da CodePipeline. NÃ£o Ã© uma certificaÃ§Ã£o do mecanismo interno AWS; `nativeBlueGreenControllerCertified=false` Ã© obrigatÃ³rio no recibo.

**ConsequÃªncia:** o adaptador exige capacidade temporÃ¡ria para duas candidatas, identidade fÃ­sica/digest/release, HTTP/HTTPS, CRUD entre revisÃµes, bake mÃ­nimo de 60 segundos, rejeiÃ§Ã£o/rollback, cleanup e CodeBuild/artifacts vinculados Ã  execuÃ§Ã£o. Imagens recebem `/release.json` pÃºblico e label OCI, sem mudanÃ§a visual na aplicaÃ§Ã£o. MigraÃ§Ãµes precisam ser compatÃ­veis entre revisÃµes; a etapa nÃ£o reverte dados RDS.

**SeguranÃ§a e concorrÃªncia:** lock S3 condicional por execution ID, sem expiraÃ§Ã£o inferida. Falha nativa continua falha. RecuperaÃ§Ã£o incompleta retÃ©m lock e recursos que atendem, sem gravar novo sucesso. Ownership segue task group/cluster/definition e prefixo Docker exato, pois labels customizadas nÃ£o foram preservadas pelo executor observado. Cleanup recaptura tasks depois de desiredCount=0 para cobrir startups em andamento.

Na AWS alvo, usar um controlador ECS Blue/Green ou CodeDeploy oficialmente suportado e revisar a topologia ECS/EC2/bridge/TG instance em uma implantaÃ§Ã£o autorizada. NÃ£o transportar este adaptador LocalStack como substituto de infraestrutura produtiva AWS. [Fluxo e limites](BLUE-GREEN.md).

## ADR-014 â€” Ambos os Target Groups permanecem associados ao ALB

**DecisÃ£o:** manter rotas de teste temporÃ¡rias para blue e green nos dois listeners atÃ© terminar promoÃ§Ã£o, bake, convergÃªncia ou rollback. ProduÃ§Ã£o usa a aÃ§Ã£o padrÃ£o; os cabeÃ§alhos nÃ£o sÃ£o autenticaÃ§Ã£o.

**Motivo comprovado:** retirar a Ãºltima referÃªncia ao TG principal fez suas tasks saudÃ¡veis receberem `unused/Target.NotInUse`. O cÃ³digo esperava healthy antes de reassociar, criando uma condiÃ§Ã£o impossÃ­vel tanto na convergÃªncia quanto na recuperaÃ§Ã£o. Reassociar primeiro tornou o TG 2/2 healthy. A AWS documenta esse estado; nÃ£o Ã© uma deficiÃªncia ECS nem razÃ£o para mudar o deregistration delay principal.

**ConsequÃªncia:** cada amostra do bake comprova blue via HTTP e HTTPS pela rota retida, alÃ©m de conferir os mesmos containers blue e a candidata em produÃ§Ã£o. Quatro regras pertencem Ã  execuÃ§Ã£o e precisam ser removidas apÃ³s validaÃ§Ã£o final. Prioridades reservadas ocupadas sÃ£o recusadas, nÃ£o sobrescritas.

## ADR-015 â€” ConvergÃªncia canÃ´nica com green atendendo

**DecisÃ£o:** depois do bake, verificar green, esvaziar o serviÃ§o principal nas APIs e no Docker em duas amostras e iniciar exatamente duas tasks da revisÃ£o aceita. O service/TG principal conserva seus nomes, rede e configuraÃ§Ã£o. Se a convergÃªncia falhar, green permanece e a imagem anterior Ã© restaurada usando a mesma fronteira, sem converter a execuÃ§Ã£o falha em sucesso.

**Motivo observado:** a tentativa 971787fb passou promoÃ§Ã£o e bake, mas o rolling adicional de UpdateService criou trÃªs tasks fÃ­sicas saudÃ¡veis para desiredCount=2, tanto na convergÃªncia quanto no rollback. O contador nÃ£o foi ignorado. A causa interna do scheduler proprietÃ¡rio nÃ£o foi afirmada; o adaptador pode controlar um ciclo de vida explÃ­cito sem depender desse overlap.

**ConsequÃªncia:** blue permanece com suas identidades originais atÃ© o bake terminar; depois dessa janela Ã© aposentado, enquanto green atende. Recursos aposentados pertencentes ao serviÃ§o sÃ£o recapturados e removidos somente apÃ³s a validaÃ§Ã£o final. NÃ£o Ã© o mecanismo do controlador AWS, nem uma mudanÃ§a na etapa 8 Rolling padrÃ£o.

## ADR-016 â€” RecuperaÃ§Ã£o conferida pelo destino fÃ­sico

**DecisÃ£o:** antes de esvaziar o serviÃ§o principal, restabelecer os destinos padrÃ£o HTTP e HTTPS no TG da candidata saudÃ¡vel e ler as aÃ§Ãµes pela API. Depois da convergÃªncia, principal e candidata podem servir a mesma release; a identidade HTTP nÃ£o substitui a comprovaÃ§Ã£o da rota. Marcar a alteraÃ§Ã£o do principal imediatamente antes da primeira requisiÃ§Ã£o mutante, inclusive quando a resposta se perde.

**RecuperaÃ§Ã£o:** tentar ambos os listeners mesmo se um comando falhar e conferir o resultado antes de alegar restauraÃ§Ã£o. Respostas HTTP interrompidas falham e cada probe tem deadline total de oito segundos. Cleanup reconcilia regras da execuÃ§Ã£o pelo listener, prioridade, cabeÃ§alho e TG antes de apagar; nÃ£o depende sÃ³ de ARNs recebidos. O aceite exige a evidÃªncia da fronteira vazia com a candidata atendendo.

**ConsequÃªncia:** erro nÃ£o verificado conserva lock/recursos que atendem; recibos antigos sem `canonicalRetirement` nÃ£o passam no aceite atual. Os testes da revisÃ£o foram observados falhando antes e passando depois. SÃ£o regressÃµes isoladas, separadas das execuÃ§Ãµes nativas de homologaÃ§Ã£o.

## ADR-017 â€” Identidade da imagem inicial compatÃ­vel com o Dockerfile

**DecisÃ£o:** aceitar `releaseId=local` no artifact pÃºblico gerado pelo Dockerfile sem argumento de build, junto com as verificaÃ§Ãµes de banco/bundle e digest fÃ­sico jÃ¡ existentes. Preservar o UUID exato da pipeline como requisito de `readImageDefinition` e `validateCandidate`.

**Motivo comprovado:** a aplicaÃ§Ã£o local era saudÃ¡vel, mas a condiÃ§Ã£o nova em `application` aceitava apenas pipeline UUID e rejeitava o bootstrap antes de criar candidata. TrÃªs regressÃµes distinguem local vÃ¡lido, candidato local invÃ¡lido e metadata arbitrÃ¡ria invÃ¡lida; duas tasks isoladas executaram a imagem default e as provas de aplicaÃ§Ã£o sem mutar produÃ§Ã£o.

**ConsequÃªncia:** a reconstruÃ§Ã£o do laboratÃ³rio mantÃ©m seu bootstrap existente. Essa prova nÃ£o Ã© uma pipeline inicial ao vivo a partir de local, nem uma reconstruÃ§Ã£o fria completa da nova versÃ£o.
