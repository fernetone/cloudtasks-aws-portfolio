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
