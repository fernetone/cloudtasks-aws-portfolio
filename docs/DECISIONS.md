# Decisões arquiteturais

## ADR-001 — Um único container de aplicação

O build do React é servido pelo Express em produção. Isso mantém um único serviço ECS e um único Target Group, aproximando o projeto do modelo demonstrativo que originou o portfólio e reduzindo complexidade operacional.

## ADR-002 — PostgreSQL separado da aplicação

Localmente o PostgreSQL roda em outro container. Na AWS ele será substituído pelo Amazon RDS. Dados não dependem do ciclo de vida das tasks ECS.

## ADR-003 — Health check consulta o banco

`GET /health` executa uma consulta simples no PostgreSQL. Assim, o ALB poderá detectar não apenas se o processo Node está vivo, mas se a aplicação está pronta para atender requisições dependentes do banco.

## ADR-004 — Testes de API sem PostgreSQL real

A camada HTTP depende de uma interface de repositório. Os testes usam uma implementação em memória, tornando o suite rápido e determinístico. A implementação PostgreSQL continua isolada na camada de infraestrutura.

## ADR-005 — Identidade imutável por build

A pipeline publica `pipeline-<UUID v4 gerado pelo próprio build>`, sem `latest`, no ECR imutável. Execution ID, Source VersionId/SHA256, CodeBuild ID, digest e task definition formam a cadeia de rastreabilidade. Builds repetidos do mesmo commit podem ter tags distintas; o artifact ECS usa a URI do build que o produziu.

## ADR-006 — ECS sobre EC2

A arquitetura alvo utilizará ECS com instâncias EC2, e não Fargate, para reproduzir o padrão visual e operacional do projeto de referência: cluster ECS com instâncias registradas, tasks distribuídas e Target Group apresentando targets associados às instâncias/portas dinâmicas.

## ADR — HTTPS local: separar plano de controle ACM do TLS do gateway

**Decisão:** representar o listener ALB `HTTPS :443` e a associação ACM no ELBv2, mas documentar que a conexão local `https://...:4566` é terminada pelo certificado do gateway LocalStack.

**Motivo:** isso preserva fidelidade arquitetural sem afirmar que o runtime local apresenta o mesmo certificado ACM no socket compartilhado. Em AWS real, o certificado ACM associado é efetivamente usado pelo listener do ALB.

**Segurança:** quando necessário, o certificado autoassinado de laboratório é gerado e importado inteiramente dentro do container LocalStack; PEM e chave privada temporários são apagados logo após o import.

## ADR — Runtime LocalStack efêmero com `/var/lib/localstack` em bind mount

**Decisão:** usar `PERSISTENCE=0` e criar um diretório de bind mount novo por sessão em `%USERPROFILE%\.cloudtasks\localstack-runtime\session-*`.

**Motivo:** o bind mount continua obrigatório para o executor Docker do CodeBuild, porém snapshots restaurados do LocalStack produziram referências runtime-bound inválidas em RDS/ECS/ECR. Em especial, ECR chegou a restaurar o repositório sem um endpoint interno válido para `DescribeImages`.

**Consequência:** a infraestrutura AWS emulada é recriada por scripts idempotentes a cada sessão. Isso sacrifica persistência local de dados do laboratório em troca de reprodutibilidade. A arquitetura AWS real não muda.

## D-008 — Não usar snapshots como fonte de verdade do laboratório

**Decisão:** tratar scripts declarativos/idempotentes como fonte de verdade do ambiente local.

**Motivo:** a persistência por snapshot do emulador não garante identidade do runtime Docker, endpoints internos ou portas entre sessões.

**Preservação:** nenhum reset destrutivo é aplicado a uma conta AWS real; essa decisão é restrita ao LocalStack.

## ADR — ECS local sem launch type EC2 explícito

**Decisão:** o laboratório LocalStack cria o service ECS sem `--launch-type EC2` explícito e sem `requiresCompatibilities=[EC2]` na task definition local.

**Motivo:** o runtime EC2 emulado usa recursos/IDs efêmeros que não têm a mesma persistência do control plane. Foram observados `InvalidInstanceID.NotFound` após restart e service preso em `PENDING` sem criação de container. O fluxo padrão documentado pelo LocalStack executa as tasks diretamente no Docker local sem exigir instâncias EC2 reais.

**Consequência:** a task definition local permanece `bridge` com `hostPort=0`, preservando portas dinâmicas e os testes existentes. A arquitetura AWS alvo continua explicitamente ECS sobre EC2; essa diferença é documentada como limite de paridade do laboratório.

## ADR-009 — Aprovação somente por execução nativa

**Decisão:** exigir Source, Build e Deploy bem-sucedidos nas APIs da CodePipeline, com CodeBuild vinculado e evidência do artefato nas tasks. Remover seleção por tag mais recente, aprovação por logs de runner e execução/deploy externos usados como fallback.

**Motivo:** testar componentes isolados não prova orquestração CI/CD. Divergência do emulador mantém a etapa pendente; não autoriza converter resultado incompleto em sucesso.

**Consequência:** uma versão do LocalStack cujo engine não complete o fluxo precisa ser investigada/corrigida antes de encerrar a etapa 8. O laboratório não promete eliminar uma falha de fornecedor por interpretação de logs.

## ADR-010 — Capturar processos nativos antes de filtrar

**Decisão:** consultar containers de tasks pelo helper comum, capturar toda a saída de `docker ps`, ler o exit code após término e só então interpretar os resultados.

**Motivo:** `Select-Object -First` em um pipeline ativo pode encerrar o produtor. O original rejeitava IDs encontrados por causa do exit code resultante, enquanto status ignorava esse código.

**Consequência:** falha Docker, resultado ambíguo e ausência de container continuam reprovados, com motivo explícito. Não se ignora `$LASTEXITCODE` para aceitar o ambiente.

## ADR-011 — Inputs permitidos e cadeia de identidade

**Decisão:** empacotar somente entradas requeridas do build, normalizar ZIP, guardar o VersionId retornado pelo upload e o SHA256. Usar esse Source na pipeline e ligar BuildId, tag UUID, digest ECR e tasks.

**Motivo:** exclusões parciais e identidade por `HEAD`/tag mais recente permitem vazamento ou seleção de outra execução.

**Consequência:** assets/configurações novos fora da lista precisam ser revisados e incorporados explicitamente. O lockfile é obrigatório. Não há expectativa de Source GitHub automático no laboratório, mas o alvo CodeConnections é preservado.

## Identidade da imagem no agente local

O agente observado em 03/10/2026 injetou `CODEBUILD_BUILD_ID` com UUID zerado, enquanto a API retornou um ID curto real. A tag não deriva desse valor reservado. CodeBuild gera um UUID v4; CodePipeline transporta `imagedefinitions.json` e o ECS nativo usa esse artifact. A aceitação verifica o build vinculado, a localização e o hash do artifact, o digest ECR e as tasks físicas. `pipeline-build.json` e o parser ID→tag foram removidos. Não há deploy por fallback.

## ADR-012 — Evidência de tráfego separada da homologação do controlador

**Estado:** a restrição operacional da versão 1.7.8 foi substituída pela ADR-013. A distinção entre prova de tráfego local e certificação do controlador AWS permanece válida.

Os ensaios nativos em LocalStack 2026.8.3 e 2026.9.0 aceitaram configuração BLUE_GREEN, mas não demonstraram isolamento e retenção requeridos; os controles bridge/IP e awsvpc/IP perderam blue diante da candidata inválida. O ensaio EXTERNAL posterior aceitou metadata STEADY_STATE, mas criou zero tasks executáveis. Esses resultados reprovados são preservados em [BLUE-GREEN.md](BLUE-GREEN.md#limites-do-fornecedor-e-testes-anteriores) e nas evidências históricas. Não justificam alterar a aplicação, migrar o serviço principal para Fargate/awsvpc ou aprovar CodeDeploy mockado.

## ADR-013 — Blue/Green local explícito dentro da CodePipeline/CodeBuild

**Decisão:** oferecer `-DeploymentMode BlueGreen` em `create-cicd.ps1`. Manter `Rolling` como padrão e adicionar uma ação CodeBuild de implantação que consome o artifact do build da imagem. Dois serviços ECS independentes mantêm blue e green executáveis; após bake aprovado, convergir o serviço/TG principal por uma transição 0→2 verificada enquanto green atende, e retirar os recursos temporários.

**Motivo:** o controlador nativo testado não manteve as revisões isoladas. As APIs ECS/ELB executáveis do laboratório permitem demonstrar tráfego real sem um fallback PowerShell externo e sem abandonar a orquestração nativa da CodePipeline. Não é uma certificação do mecanismo interno AWS; `nativeBlueGreenControllerCertified=false` é obrigatório no recibo.

**Consequência:** o adaptador exige capacidade temporária para duas candidatas, identidade física/digest/release, HTTP/HTTPS, CRUD entre revisões, bake mínimo de 60 segundos, rejeição/rollback, cleanup e CodeBuild/artifacts vinculados à execução. Imagens recebem `/release.json` público e label OCI, sem mudança visual na aplicação. Migrações precisam ser compatíveis entre revisões; a etapa não reverte dados RDS.

**Segurança e concorrência:** lock S3 condicional por execution ID, sem expiração inferida. Falha nativa continua falha. Recuperação incompleta retém lock e recursos que atendem, sem gravar novo sucesso. Ownership segue task group/cluster/definition e prefixo Docker exato, pois labels customizadas não foram preservadas pelo executor observado. Cleanup recaptura tasks depois de desiredCount=0 para cobrir startups em andamento.

Na AWS alvo, usar um controlador ECS Blue/Green ou CodeDeploy oficialmente suportado e revisar a topologia ECS/EC2/bridge/TG instance em uma implantação autorizada. Não transportar este adaptador LocalStack como substituto de infraestrutura produtiva AWS. [Fluxo e limites](BLUE-GREEN.md).

## ADR-014 — Ambos os Target Groups permanecem associados ao ALB

**Decisão:** manter rotas de teste temporárias para blue e green nos dois listeners até terminar promoção, bake, convergência ou rollback. Produção usa a ação padrão; os cabeçalhos não são autenticação.

**Motivo comprovado:** retirar a última referência ao TG principal fez suas tasks saudáveis receberem `unused/Target.NotInUse`. O código esperava healthy antes de reassociar, criando uma condição impossível tanto na convergência quanto na recuperação. Reassociar primeiro tornou o TG 2/2 healthy. A AWS documenta esse estado; não é uma deficiência ECS nem razão para mudar o deregistration delay principal.

**Consequência:** cada amostra do bake comprova blue via HTTP e HTTPS pela rota retida, além de conferir os mesmos containers blue e a candidata em produção. Quatro regras pertencem à execução e precisam ser removidas após validação final. Prioridades reservadas ocupadas são recusadas, não sobrescritas.

## ADR-015 — Convergência canônica com green atendendo

**Decisão:** depois do bake, verificar green, esvaziar o serviço principal nas APIs e no Docker em duas amostras e iniciar exatamente duas tasks da revisão aceita. O service/TG principal conserva seus nomes, rede e configuração. Se a convergência falhar, green permanece e a imagem anterior é restaurada usando a mesma fronteira, sem converter a execução falha em sucesso.

**Motivo observado:** a tentativa 971787fb passou promoção e bake, mas o rolling adicional de UpdateService criou três tasks físicas saudáveis para desiredCount=2, tanto na convergência quanto no rollback. O contador não foi ignorado. A causa interna do scheduler proprietário não foi afirmada; o adaptador pode controlar um ciclo de vida explícito sem depender desse overlap.

**Consequência:** blue permanece com suas identidades originais até o bake terminar; depois dessa janela é aposentado, enquanto green atende. Recursos aposentados pertencentes ao serviço são recapturados e removidos somente após a validação final. Não é o mecanismo do controlador AWS, nem uma mudança na etapa 8 Rolling padrão.

## ADR-016 — Recuperação conferida pelo destino físico

**Decisão:** antes de esvaziar o serviço principal, restabelecer os destinos padrão HTTP e HTTPS no TG da candidata saudável e ler as ações pela API. Depois da convergência, principal e candidata podem servir a mesma release; a identidade HTTP não substitui a comprovação da rota. Marcar a alteração do principal imediatamente antes da primeira requisição mutante, inclusive quando a resposta se perde.

**Recuperação:** tentar ambos os listeners mesmo se um comando falhar e conferir o resultado antes de alegar restauração. Respostas HTTP interrompidas falham e cada probe tem deadline total de oito segundos. Cleanup reconcilia regras da execução pelo listener, prioridade, cabeçalho e TG antes de apagar; não depende só de ARNs recebidos. O aceite exige a evidência da fronteira vazia com a candidata atendendo.

**Consequência:** erro não verificado conserva lock/recursos que atendem; recibos antigos sem `canonicalRetirement` não passam no aceite atual. Os testes da revisão foram observados falhando antes e passando depois. São regressões isoladas, separadas das execuções nativas de homologação.

## ADR-017 — Identidade da imagem inicial compatível com o Dockerfile

**Decisão:** aceitar `releaseId=local` no artifact público gerado pelo Dockerfile sem argumento de build, junto com as verificações de banco/bundle e digest físico já existentes. Preservar o UUID exato da pipeline como requisito de `readImageDefinition` e `validateCandidate`.

**Motivo comprovado:** a aplicação local era saudável, mas a condição nova em `application` aceitava apenas pipeline UUID e rejeitava o bootstrap antes de criar candidata. Três regressões distinguem local válido, candidato local inválido e metadata arbitrária inválida; duas tasks isoladas executaram a imagem default e as provas de aplicação sem mutar produção.

**Consequência:** a reconstrução do laboratório mantém seu bootstrap existente. Essa prova não é uma pipeline inicial ao vivo a partir de local, nem uma reconstrução fria completa da nova versão.
