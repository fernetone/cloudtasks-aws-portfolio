# Pipeline BIA: GitHub → CodeBuild → ECS standard

A referência mostra Source GitHub (via GitHub App), Build CodeBuild e Deploy Amazon ECS. O projeto oferece uma pipeline local específica, `cloudtasks-github-pipeline`, com os provedores `CodeStarSourceConnection`, `CodeBuild` e `ECS`. Os scripts e as provas S3/Blue-Green anteriores são preservados; a parada com PERSISTENCE=0 descartou a configuração nas APIs da sessão anterior.

A origem é o repositório público `fernetone/cloudtasks-aws-portfolio`, branch `docs/video-reference-20261008`. O SHA esperado deve ter 40 caracteres e já estar publicado. Na ação Build, `SourceVariables.CommitId` chega ao CodeBuild como `SOURCE_COMMIT_ID`; o primeiro comando compara essa revisão com o SHA esperado. Divergência interrompe o build antes da instalação de dependências e da construção/push da imagem. O recibo entregue junto a `imagedefinitions.json` registra commit e ID da execução CodePipeline. O ID real do CodeBuild vem da ação nativa; sua API e a localização do artifact comprovam o vínculo, sem depender do ID reservado do agente local.

## Executar na sessão saudável

Pré-requisitos: Docker/LocalStack já online, ECS 2/2, ECR imutável, ALB/HTTPS/RDS e MCP PostgreSQL configurados. O script recusa outra pipeline ativa e usa exclusivamente o endpoint local, a conta 000000000000 e os nomes do projeto. Não reiniciar o emulador para iniciar uma entrega.

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\scripts\localstack\create-github-pipeline.ps1 -ExpectedCommit '<SHA completo já publicado>'
.\scripts\localstack\status-github-pipeline.ps1
```

A criação inicia a primeira execução nativa automaticamente. Em configurações existentes, o script confere a propriedade dos recursos, rejeita outra execução ativa e inicia uma única nova execução. `STARTED` confirma início, sem homologar a entrega. Quando o status for `Succeeded`, executar:

```powershell
.\scripts\localstack\test-github-pipeline.ps1
```

O teste liga as três ações à mesma execução, confere CommitId e externalExecutionId nativos da ação Source e, quando fornecido, artifactRevisions. Compara todos os arquivos e hashes Git blob do ZIP Source com o Git tree completo do commit público. Confere, a localização/hash/recibo do artifact CodeBuild e a imagem/digest ECR. Exige nova task definition, duas tasks da revisão e dois containers distintos, healthy, com o digest esperado; rejeita containers excedentes. Os dois targets ALB devem pertencer às réplicas atuais. HTTPS com pin deve servir a release do build e saúde do banco. Contagem e fingerprint SQL, consultados pela role de leitura, devem coincidir antes/depois. Não há fallback, reparo silencioso de réplicas ou aprovação baseada apenas em status verde.

Falhas ficam em registros separados. O script não apaga entregas anteriores nem substitui uma falha por evidência de sucesso. Recurso existente sem tags do projeto/sessão é recusado.

## Limites da execução local

A documentação oficial do LocalStack descreve [Source CodeConnections para GitHub](https://docs.localstack.cloud/aws/services/codepipeline/#codeconnections-source). Repositórios públicos dispensam o token usado para acesso a repositórios privados. [CodeConnections](https://docs.localstack.cloud/aws/services/codeconnections/) oferece controle de conexões emulado; isso não certifica instalação/OAuth de um GitHub App real na AWS.

[Triggers não são implementados](https://docs.localstack.cloud/aws/services/codepipeline/#limitations): a execução ocorre por CreatePipeline/StartPipelineExecution. Um push no GitHub pode executar o CI do repositório, mas não se declara que esse push dispara esta CodePipeline emulada. O deploy usa a ação ECS standard; a topologia EC2/TG instance, portas 80/443 e TLS do ALB filmado continuam diferenças descritas em REFERENCE-VIDEO.md. A revisão original abreviada `8089357` ainda não foi identificada.

## Homologação

A primeira execução `628c012e-f077-45c7-9596-6bd8f336fe7a` concluiu Source no commit `bad8add37210cc332586f9a1d7115106248cada3`. O agente reprovou a exigência de formato do seu ID reservado em INSTALL, antes de npm ci/build/push/deploy. A revisão existente e as duas réplicas healthy foram preservadas. [Falha original](EVIDENCE-GITHUB-FIRST-FAILURE-20261010.json). Um teste reproduziu a rejeição; a correção liga o recibo à variável nativa PipelineExecutionId e conserva a validação do ID/artifact CodeBuild nas APIs.

A retomada foi inicialmente bloqueada: CreateConnection não persistiu as tags enviadas. TagResource, aplicado somente à conexão cujo ARN foi guardado na sua criação nesta sessão, persistiu as duas tags. A resposta foi reinspecionada e confirmou Project/LocalStackId. A criação futura faz esse passo explicitamente e exige leitura das tags persistidas. As exigências de propriedade não foram relaxadas.

A execução `de81dbc8-35a9-4da8-a8c6-739792bfd93d`, no commit `c09122f5a8556f6bb5d040638d27a552b53d1801`, foi reprovada no Docker build: faltou `@rollup/rollup-linux-x64-musl`, apesar de constar no lockfile. O Docker agora exige carregar o Rollup imediatamente após npm ci, impedindo reutilizar uma camada incompleta. O teste negativo reproduziu a ausência do módulo; o build completo no Windows e o CI do commit `48e5924fdd83a29cc3e1b91c22f2e94e605fb74e` passaram. As versões e o lockfile foram preservados. A causa específica da omissão no primeiro download não foi certificada.

O LocalStack parou em 10/10 às 17:27:52 UTC. Antes de iniciar o mesmo container, 1.276 arquivos físicos RDS tiveram cópia e hashes conferidos. O banco foi extraído de uma cópia e restaurado em transação, com a mesma contagem/fingerprint, antes do ECS. PERSISTENCE=0 descartou os estados das APIs: o histórico preservado não é apresentado como histórico vivo da nova execução. A imagem anteriormente aprovada foi republicada com o mesmo digest para recuperar o serviço.

A execução `70ff9038-3f41-43b7-b2a9-90d8480cb19c`, Source no commit `48e5924fdd83a29cc3e1b91c22f2e94e605fb74e`, passou no guard e no quality gate. O Docker npm ci foi interrompido por ECONNRESET; CodeBuild FAILED e CodePipeline Failed, sem iniciar Deploy. Os 171 arquivos do Source coincidiram com o Git tree; isso não aprova uma entrega com build falho. A repetição preserva essa falha e só recebe PASSED após a aceitação completa.

A repetição `d97f277d-b9c3-426f-86dc-afa8209b4874` concluiu Source, Build e Deploy nativos. O CodeBuild `cloudtasks-github-build:86c18273` terminou SUCCEEDED. O ZIP contém exatamente 171 arquivos do tree `7ff2b8d325c989954b28c5883fa7450ecb63e55a`, todos com o mesmo hash de conteúdo; não há arquivos extras.

O teste inicial dessa entrega falhou em GITHUB_NATIVE_REVISION_MISMATCH: o LocalStack omitiu artifactRevisions mesmo em Succeeded. Esse campo é [opcional na API AWS](https://docs.aws.amazon.com/codepipeline/latest/APIReference/API_PipelineExecution.html). A correção exige concordância entre CommitId e externalExecutionId da ação Source e conserva a checagem de artifactRevisions quando fornecido. A comparação integral do ZIP com o [Git tree público](https://docs.github.com/en/rest/git/trees) foi incorporada ao aceite; commit divergente, truncamento, arquivo alterado, ausente, extra ou duplicado são rejeitados. As regressões passaram, assim como lint/testes/build locais (109 aprovados e cinco integrações PostgreSQL puladas nessa execução).

O Desktop Commander sofreu timeout antes de aplicar essa correção no Windows e conferir a revisão física. O aceite permanece PENDING: não se afirma que o novo deploy já passou réplicas/ALB/HTTPS/banco. A captura anterior das duas tasks, feita às 18:20:38 UTC e preservada no metadata, é histórica; a tentativa de recapturar após o Deploy foi corretamente bloqueada por DEPLOY_ALREADY_STARTED. [Evidência da execução](EVIDENCE-GITHUB-PIPELINE-20261010.json).
