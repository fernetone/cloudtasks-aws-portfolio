# CloudTasks â€” auditoria tÃ©cnica e evoluÃ§Ã£o validada do laboratÃ³rio

AtualizaÃ§Ã£o: 08/10/2026; entrega 1.8.2. Base auditada: projeto 1.7.0. Parecer: **preservar a arquitetura, corrigir o verificador e exigir CI/CD nativo; etapa 8 homologada no laboratÃ³rio em 03/10/2026, com evidÃªncias na seÃ§Ã£o 16.**

Os bloqueios iniciais de consulta Docker e empacotamento ZIP foram corrigidos no projeto. A execuÃ§Ã£o subsequente concluiu Source e expÃ´s falhas no monitor/wrapper do executor CodeBuild. O diagnÃ³stico dessa execuÃ§Ã£o, a compatibilidade com IDs curtos e os limites da mitigaÃ§Ã£o estÃ£o na seÃ§Ã£o 13.

**Como ler o histÃ³rico:** as seÃ§Ãµes 1â€“14 registram o diagnÃ³stico e as validaÃ§Ãµes disponÃ­veis em cada entrega anterior. ReferÃªncias a etapa pendente, contagens antigas ou derivaÃ§Ã£o da tag pelo ID descrevem aquele momento. A implementaÃ§Ã£o final estÃ¡ na seÃ§Ã£o 15 e a homologaÃ§Ã£o da etapa 8, na seÃ§Ã£o 16. A seÃ§Ã£o 18 registra a implementaÃ§Ã£o e a validaÃ§Ã£o atual de Blue/Green por adaptador; nÃ£o Ã© certificaÃ§Ã£o do controlador AWS nativo. A seÃ§Ã£o 25 e [EVIDENCE-BIA-20261008.json](EVIDENCE-BIA-20261008.json) registram o alinhamento atual da aplicaÃ§Ã£o. Para operaÃ§Ã£o da pipeline, consulte [PIPELINE.md](PIPELINE.md).

A leitura do projeto e o diagnÃ³stico precederam as modificaÃ§Ãµes. O original permanece intacto. A entrega modifica uma cÃ³pia e exclui a credencial pessoal que estava no ZIP recebido.

## 1. Material, mÃ©todo e limites

Foram examinados os dois ZIPs fornecidos, os 93 arquivos originais, aplicaÃ§Ã£o, testes, manifests, Docker/Compose, workflow GitHub, buildspecs, 37 scripts PowerShell e documentaÃ§Ã£o. O segundo ZIP tem organizaÃ§Ã£o externa diferente, mas os mesmos 93 conteÃºdos; nÃ£o contÃ©m uma revisÃ£o nova do `create-cicd.ps1`.

| Material                   | Identidade                                                                                                               |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| ZIP inicialmente fornecido | SHA256 `3ebf38deafe1b491f25fa588632108e89327fc5cedad398f655fe5f177c49bea`                                                |
| ZIP mais recente fornecido | SHA256 `9658cdf9c87b1857879dd36226edcf25f8725f20164a53d06703ebe1d3f7e7f8`                                                |
| `create-cicd.ps1` original | SHA256 `d575e73aa5158f97c74156c09c394117e66aac9fe8bb971fb5436b220d00f1bd` â€” corresponde ao hash apresentado no Windows |
| VÃ­deo original            | Aproximadamente 57,6 s, 720 Ã— 1600; quadros distribuÃ­dos por todo o recorte                                            |
| PowerShell                 | Transcript enviado e resultados subsequentes, inclusive o preflight de 01/10 com sessÃ£o igual e `DockerExit=-1`         |

A anÃ¡lise do vÃ­deo usa telas e legendas visualmente legÃ­veis; nÃ£o foi produzida transcriÃ§Ã£o do Ã¡udio. O recorte nÃ£o Ã© uma auditoria do repositÃ³rio/configuraÃ§Ã£o completa do autor. AtÃ© a entrega 1.7.2, a execuÃ§Ã£o prÃ³pria ocorreu em Linux. Em 02/10/2026, iniciou-se a homologaÃ§Ã£o remota autorizada no Windows/LocalStack do responsÃ¡vel, registrada na seÃ§Ã£o 14. O histÃ³rico Git nÃ£o acompanha o projeto.

Tipos de evidÃªncia usados neste relatÃ³rio:

- **CÃ³digo:** condiÃ§Ã£o/responsabilidade encontrada no projeto original ou na implementaÃ§Ã£o.
- **Transcript Windows:** resultado enviado pelo responsÃ¡vel.
- **ExecuÃ§Ã£o remota prÃ³pria:** operaÃ§Ã£o efetivamente executada na mÃ¡quina do laboratÃ³rio, quando indicada nas seÃ§Ãµes 14â€“16.
- **Teste isolado executado:** processo nativo e fixtures sintÃ©ticas em Linux/PowerShell 7 ou Windows/PowerShell 5.1, conforme identificado.
- **Documentado:** comportamento oficial do fornecedor.
- **InferÃªncia/pendÃªncia:** conclusÃ£o que exige resposta do ambiente real para ser fechada.

## 2. Causa-raiz do bloqueio ECS inicial

### Ramo efetivamente recusado

A coleta mais recente mostra `SessaoIgual=True`, duas tasks consultadas, `DockerExit=-1`, uma linha para cada consulta e zero containers aceitos. A execuÃ§Ã£o chegou ao bloco Docker; nÃ£o parou na identidade da sessÃ£o. NÃ£o hÃ¡ justificativa para afirmar que o ECS realmente perdeu suas duas tasks.

No **arquivo original**, `Test-CicdEcsRuntimeReady` contÃ©m:

```powershell
$dockerId = @(& docker ps --filter "name=$taskId" --filter "status=running" --format "{{.ID}}" 2>$null | Select-Object -First 1)
$dockerExit = $LASTEXITCODE
# ...
if ($dockerExit -eq 0 -and $dockerId.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$dockerId[0])) {
    $dockerRuntimeCount++
}
```

| ReferÃªncia original                           | Efeito                                                                                  |
| ---------------------------------------------- | --------------------------------------------------------------------------------------- |
| `create-cicd.ps1`, linha 213                   | Liga o processo nativo ativo a `Select-Object -First 1`                                 |
| Linha 214                                      | LÃª `$LASTEXITCODE` desse pipeline interrompÃ­vel                                       |
| Linhas 220â€“221                               | Rejeita o ID quando o exit code nÃ£o Ã© zero; ambas as tasks foram rejeitadas com `-1`  |
| Linha 225                                      | Retorna falso porque aceitos=0, esperado=2                                              |
| `Ensure-CicdEcsRuntimeReady`, linhas 228â€“247 | Trata qualquer falso como runtime stale, chama resume e repete o mesmo teste defeituoso |
| Linha 243                                      | LanÃ§a a mensagem genÃ©rica de ausÃªncia de duas tasks Docker RUNNING                   |

A Microsoft documenta que `Select-Object` com `First`/`Index` interrompe o produtor assim que obtÃ©m a quantidade requerida. Portanto, ter recebido um ID nÃ£o prova tÃ©rmino normal de `docker.exe`. A consulta precisa terminar antes de filtrar e interpretar seu exit code. [Microsoft, Select-Object/PowerShell 5.1](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/select-object?view=powershell-5.1).

A explicaÃ§Ã£o da contradiÃ§Ã£o estÃ¡ no cÃ³digo: `status-ecs.ps1`, funÃ§Ã£o `Get-TaskDockerRuntime` original (linha 42), tambÃ©m obtÃ©m a primeira linha, mas nÃ£o aplica a mesma rejeiÃ§Ã£o por exit code. `resume-environment.ps1`, `Test-EcsRuntimeReady` original (linha 101), conta IDs encontrados sem validar esse tÃ©rmino. Status pode mostrar ECS RUNNING/Docker healthy enquanto o preflight aceita zero resultados.

`ecs-runtime-context.ps1` originalmente captura o `docker inspect` antes de selecionar a primeira linha. Essa seleÃ§Ã£o sobre saÃ­da jÃ¡ armazenada nÃ£o Ã© o defeito. O contexto relÃª os metadados e o CI/CD atualiza nomes; nÃ£o foi encontrada prova de variÃ¡vel antiga em memÃ³ria como causa desta execuÃ§Ã£o. `create-ecs.ps1` conseguiu preparar o runtime; reconstruir novamente nÃ£o corrige a consulta defeituosa do CI/CD.

### Prova executada e limite Windows

As funÃ§Ãµes originais foram extraÃ­das pela AST, sem executar seu bootstrap, e chamadas com um processo externo Node que imprime um ID e sÃ³ termina depois. No Linux/PowerShell 7, o pipeline original pode ler um exit code anterior/sem atualizaÃ§Ã£o: chegou a aceitar uma consulta cujo processo terminaria com cÃ³digo 7. Capturar toda a saÃ­da primeiro permite observar 7 e recusar corretamente.

Isso comprova o defeito de ordem/encerramento na fronteira nativa. O valor numÃ©rico `-1` especÃ­fico foi **observado no Windows fornecido**, nÃ£o reproduzido aqui. A combinaÃ§Ã£o de comportamento documentado, condiÃ§Ã£o original e ramo instrumentado explica a rejeiÃ§Ã£o atual. Confirmar a correÃ§Ã£o nesse PowerShell 5.1 permanece parte da homologaÃ§Ã£o.

A implementaÃ§Ã£o **nÃ£o ignora `$LASTEXITCODE`**. `Get-CloudTasksTaskDockerRuntime` captura o processo inteiro, guarda seu exit code e sÃ³ depois interpreta linhas. Falha nativa, saÃ­da invÃ¡lida, nenhum container ou resultado ambÃ­guo continuam sendo recusados. CI/CD, resume, status, teste ECS e sincronizaÃ§Ã£o de targets reutilizam essa leitura.

### Problemas distintos no histÃ³rico

- Scripts desabilitados eram polÃ­tica do processo PowerShell, resolvida com `Set-ExecutionPolicy -Scope Process`; nÃ£o eram falha ECS.
- A coleta anterior parou na linha 165, sem ID atual disponÃ­vel. A sequÃªncia incluiu Docker Desktop/daemon indisponÃ­vel e container LocalStack parado. Isso Ã© um evento diferente do resultado atual, que confirmou sessÃ£o igual.
- Listagem ECR posterior e consulta exata retornaram o repositÃ³rio `cloudtasks`, com exit 0 e parsing correto. A resposta da listagem no instante da criaÃ§Ã£o anterior nÃ£o estÃ¡ disponÃ­vel: nÃ£o Ã© possÃ­vel provar corrida, parsing ou outra causa histÃ³rica. EstÃ¡ provado o defeito de idempotÃªncia de tentar criar e abortar em `RepositoryAlreadyExistsException` sem verificar o recurso exato.
- O resume de 01/10 teve RDS `creating`, duas rotaÃ§Ãµes e disponibilidade posterior. Tempo excedido nÃ£o comprova recurso stale. A causa de provisioning lento nÃ£o foi determinada por este material.

## 3. Arquitetura e comparaÃ§Ã£o com o vÃ­deo

| Componente         | AWS alvo                                   | LaboratÃ³rio                                            | DecisÃ£o                                                 |
| ------------------ | ------------------------------------------ | ------------------------------------------------------- | -------------------------------------------------------- |
| AplicaÃ§Ã£o        | React/Express/TypeScript/PostgreSQL        | Mesmo domÃ­nio CRUD; React servido pelo Express         | Preservar                                                |
| Source             | GitHub/CodeConnections                     | Snapshot permitido do working tree em S3 versionado     | Manter adaptaÃ§Ã£o e identidade exata                    |
| OrquestraÃ§Ã£o     | CodePipeline â†’ CodeBuild â†’ ECS padrÃ£o | Mesmos serviÃ§os emulados, V1 executÃ¡vel               | Exigir fluxo nativo                                      |
| Build/registry     | Docker e ECR                               | Docker do host e ECR local                              | Preservar; lockfile e digest                             |
| Compute            | ECS/EC2, `bridge`, hostPort dinÃ¢mico      | Tasks Docker sem EC2 reais                              | Preservar diferenÃ§a explÃ­cita                          |
| ALB/TG             | `instance`, instÃ¢ncia/hostPort            | `ip`, IP Docker/3000                                    | Preservar adaptaÃ§Ã£o                                    |
| RDS/Secrets        | Dados persistentes e secret de runtime     | PostgreSQL executÃ¡vel e APIs locais                    | Preservar; sessÃ£o descartÃ¡vel nÃ£o Ã© durabilidade AWS |
| HTTPS/ACM          | ALB termina TLS com ACM                    | AssociaÃ§Ã£o no control plane; TLS pelo gateway `:4566` | Preservar explicaÃ§Ã£o                                   |
| Logs               | CloudWatch                                 | `awslogs` e APIs locais jÃ¡ exercitados                 | Preservar                                                |
| Etapas posteriores | Blue/Green, CloudFront, Q/MCP              | Ainda nÃ£o entregues pelo projeto                       | NÃ£o antecipar                                           |

A [AWS documenta ECS/ALB](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/alb.html) com portas dinÃ¢micas e registro instÃ¢ncia/porta no desenho EC2/bridge; TG `ip` Ã© requerido para `awsvpc`. O [executor ECS do LocalStack](https://docs.localstack.cloud/aws/services/ecs/) nÃ£o cria capacidade EC2 real apenas porque a API apresenta `launchType=EC2`. Zero container instances registradas Ã© esperado neste laboratÃ³rio.

| Trecho do vÃ­deo | EvidÃªncia visual                                            | ConclusÃ£o                                                                                                          |
| ---------------- | ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| 0â€“2 s          | Build/CodeBuild e Deploy/ECS em verde                        | Entrega por serviÃ§os AWS Ã© central                                                                                |
| 4â€“8 s          | Amazon Q CLI e MCP PostgreSQL                                | Q/MCP fazem parte da demonstraÃ§Ã£o; permissÃµes nÃ£o sÃ£o auditÃ¡veis pelo recorte                                 |
| 10â€“18 s        | ALB HTTP/HTTPS e dois targets por instÃ¢ncia/porta dinÃ¢mica | CompatÃ­vel com ECS/EC2, duas rÃ©plicas e TG `instance`                                                             |
| 18â€“20 s        | Node/React e PostgreSQL                                      | Mesma categoria de aplicaÃ§Ã£o                                                                                      |
| 22â€“32 s        | DistribuiÃ§Ã£o CloudFront em estado `Disabled`               | ConfiguraÃ§Ã£o existe; trÃ¡fego funcional pela CDN nÃ£o Ã© provado                                                  |
| 34â€“57 s        | Interface simples de tarefas BIA                             | A revisÃ£o de 08/10 exige reproduzir nome, interface e comportamento observÃ¡veis; a dispensa anterior foi retirada |

A revisÃ£o de escopo de 08/10/2026 corrigiu a interpretaÃ§Ã£o anterior: fidelidade conceitual nÃ£o atende Ã  reproduÃ§Ã£o literal solicitada. A [matriz V01-V12](REFERENCE-VIDEO.md) registra as diferenÃ§as de interface, comportamento, Source, compute, TLS, CDN e Q/MCP. CloudTasks fornece evidÃªncia explÃ­cita de Zod, SQL parametrizado, testes, health com banco, nÃ£o-root e graceful shutdown; esses cuidados sÃ£o preservados, sem substituir os requisitos do vÃ­deo nem inferir que faltam ao projeto do autor.

Desvios tÃ©cnicos histÃ³ricos encontrados: recuperaÃ§Ã£o acumulada no caminho de entrega, aprovaÃ§Ã£o por fallback externo e seleÃ§Ã£o por tag mais recente. O fluxo local corrigido removeu a aprovaÃ§Ã£o alternativa. A sequÃªncia de 13 etapas Ã© um plano interno, nÃ£o uma sequÃªncia oficial extraÃ­da do vÃ­deo. Capacidade EC2, bootstrap, controles de rede/IAM e provisionamento AWS completo sÃ£o pendÃªncias obrigatÃ³rias da entrega, e nÃ£o apenas uma possÃ­vel migraÃ§Ã£o futura.

## 4. OrganizaÃ§Ã£o e fluxo dos scripts

O original possui 37 PowerShells, aproximadamente 6.403 linhas e 22 wrappers `Invoke-AwsLocalJson`. A quantidade de arquivos nÃ£o Ã©, sozinha, o problema; os pontos frÃ¡geis sÃ£o responsabilidades sobrepostas, leitura nativa divergente e recuperaÃ§Ã£o no caminho normal.

| Grupo original        | Arquivos/responsabilidade                                                   |
| --------------------- | --------------------------------------------------------------------------- |
| Ciclo local           | start, stop, resume, update, change-token                                   |
| Contexto/manutenÃ§Ã£o | ecs/rds-runtime-context e repair-ecs/rds-runtime                            |
| Infraestrutura        | create-network/database/ecr/ecs/alb/https, push-ecr-image, sync-alb-targets |
| CI/CD                 | publisher, create-cicd, status/test/diagnose-cicd, rollback operacional     |
| Estado/teste          | status/test por camada e validate-scripts                                   |
| PreparaÃ§Ã£o          | prepare-repository fora do diretÃ³rio localstack                            |

Fluxo normal corrigido: bootstrap explÃ­cito pelo resume quando necessÃ¡rio â†’ sessÃ£o saudÃ¡vel â†’ publisher â†’ CodePipeline/CodeBuild â†’ ECR â†’ Deploy ECS nativo â†’ sincronizaÃ§Ã£o IP/TG local â†’ aceitaÃ§Ã£o HTTPS/RDS. A sincronizaÃ§Ã£o local de IPs nÃ£o substitui a aÃ§Ã£o ECS Deploy; ela adapta o balanceamento ao executor Docker.

Na entrega 1.7.1, `create-cicd.ps1` caiu de 1.233 para 684 linhas. Foram removidos os caminhos de CodeBuild direto, seleÃ§Ã£o de tags/runners novos e deploy externo para converter pipeline incompleta em sucesso. Na entrega 1.7.2 hÃ¡ preparaÃ§Ã£o explÃ­cita de imagem e uma validaÃ§Ã£o compatÃ­vel com IDs curtos, descritas na seÃ§Ã£o 13. NÃ£o foram criados scripts novos de recuperaÃ§Ã£o; os dois novos arquivos sÃ£o regressÃµes isoladas.

Os wrappers AWS continuam duplicados entre scripts. ConsolidÃ¡-los em um mÃ³dulo pequeno, com contrato de captura/JSON/redaction, Ã© uma melhoria futura razoÃ¡vel. Uma migraÃ§Ã£o ampla de mÃ³dulos/framework de IaC nesta correÃ§Ã£o aumentaria o risco sem ser necessÃ¡ria para resolver o bloqueio comprovado.

## 5. Defeitos adicionais e tratamento

| Achado original                                                            | SoluÃ§Ã£o ou limite                                                                         |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Qualquer falso do preflight aciona resume e perde a causa                  | Preflight informa motivo; nÃ£o inicia/reset/repara ambiente                                 |
| Logs de runner podem sobrepor falha na API CodeBuild                       | Falha API/action reprova; sem aprovaÃ§Ã£o por log                                           |
| Fallback termina ECS fora da pipeline e teste diz ponta a ponta            | Removido do fluxo e do critÃ©rio; somente modo nativo aceito                                |
| Tag `pipeline-*` mais nova pode pertencer a outro build                    | Tag do ID exato do CodeBuild vinculado, URI/digest e tasks correlacionados                  |
| `HEAD` apÃ³s upload/start sem revisÃ£o pode selecionar outro Source        | VersionId do PutObject, SHA256, revisÃ£o explÃ­cita e conferÃªncia da revisÃ£o consumida    |
| Contadores 2/2 nÃ£o provam atualizaÃ§Ã£o de cada task                      | DescribeTasks, revisÃ£o/imagem de cada task, Docker health e RepoDigests                    |
| Listagem ECR seguida de criaÃ§Ã£o nÃ£o tolera AlreadyExists                | Consulta exata por nome/conta/regiÃ£o; conflito Ã© seguido de nova consulta/verificaÃ§Ã£o   |
| DependÃªncias sem lockfile/fallback npm install                            | Lockfile incluÃ­do; npm ci obrigatÃ³rio em CI/buildspecs/Docker/preparaÃ§Ã£o                |
| Publisher exclui alguns nomes, mas admite runtime/certificados/credentials | Inputs positivos e bloqueio de credenciais ativas conhecidas                                |
| Docker COPY amplo com contexto incompletamente ignorado                    | Contexto positivo de inputs necessÃ¡rios, sem runtime/secrets/scripts/logs                  |
| RecursÃ£o de create-ecs nÃ£o preserva ImageUriOverride                     | Argumento propagado em todos os retornos recursivos; caminho nÃ£o usado como fallback CI/CD |
| change-token usa encoding nÃ£o suportado no PS5.1                          | Escrita UTF8 via .NET compatÃ­vel; valor nÃ£o exibido                                       |
| DiagnÃ³sticos e exceÃ§Ãµes despejam argumentos/provider/logs brutos        | OperaÃ§Ã£o/exit code e metadados, com erros JSON genÃ©ricos em caminhos sensÃ­veis          |

SerializaÃ§Ã£o usa lock local e recusa execuÃ§Ã£o em andamento. CodePipeline V1 declara Source S3, CodeBuild e ECS; ambos os buildspecs produzem `imagedefinitions.json`. Um quality gate negativo deve interromper antes do push/deploy. [AWS aÃ§Ã£o ECS padrÃ£o](https://docs.aws.amazon.com/codepipeline/latest/userguide/action-reference-ECS.html), [revisÃµes no StartPipelineExecution](https://docs.aws.amazon.com/codepipeline/latest/APIReference/API_StartPipelineExecution.html).

## 6. SeguranÃ§a

**O ZIP original continha `.env.localstack` com credencial preenchida.** O valor nÃ£o foi usado, testado quanto Ã  validade ou reproduzido. Foi excluÃ­do da entrega. Se a credencial continua ativa e foi distribuÃ­da, revogar/substituir no provedor; o pacote novo nÃ£o revoga o valor antigo.

Foi reproduzido vazamento de senha fictÃ­cia na exceÃ§Ã£o do wrapper RDS, que incluÃ­a `--master-user-password`. TambÃ©m foram reproduzidas exceÃ§Ãµes de leitura de secret que ecoavam texto sensÃ­vel do provider apesar de se denominarem â€œSafelyâ€. Os testes passaram apÃ³s retirar argumentos/respostas brutas e proteger parsing. NÃ£o se afirma que a senha real apareceu em um log histÃ³rico especÃ­fico.

O publisher original, executado com upload simulado, incluÃ­a `localstack-volume/state.json`, `certificate.pem` e `secrets/credentials.txt`. Isso prova o defeito de seleÃ§Ã£o; nÃ£o prova que esses arquivos estavam no S3 real. O publisher corrigido os exclui e bloqueia credenciais ativas conhecidas inseridas em cÃ³digo. Snapshot contÃ©m Dockerfile/ignore/manifests/config/cÃ³digo/testes, sem material de operaÃ§Ã£o.

Git, Source S3, contexto Docker e ZIP sÃ£o fronteiras independentes. `.gitignore` nÃ£o remove arquivos jÃ¡ rastreados e nÃ£o protege empacotamento manual. Foram adicionados runtime fallback e metadado de build ao ignore. Sem `.git`, nÃ£o foi possÃ­vel verificar histÃ³rico remoto nem demonstrar ausÃªncia histÃ³rica de secrets.

O Dockerfile permanece multi-stage e nÃ£o-root. Contexto restrito reduz exposiÃ§Ã£o inclusive em estÃ¡gios/cache, e nÃ£o apenas na imagem final. NÃ£o foi executado Docker aqui: a ausÃªncia de secrets nos layers da imagem real ainda deve ser confirmada no laboratÃ³rio.

Logs do provider/env de containers podem conter credenciais injetadas em runtime. As ferramentas corrigidas evitam despejo automÃ¡tico, mas nÃ£o â€œpurificamâ€ o armazenamento do provider. TemporÃ¡rios possuem limpeza em `finally`; interrupÃ§Ãµes abruptas e permissÃµes efetivas de Windows precisam de verificaÃ§Ã£o local. O socket compartilhado sÃ³ Ã© adequado a Source confiÃ¡vel no laboratÃ³rio pessoal.

Permanecem limites para produÃ§Ã£o: IAM com wildcards/PassRole amplo, SSL do banco com validaÃ§Ã£o de certificado desativada quando esse modo Ã© usado, CRUD sem autorizaÃ§Ã£o de usuÃ¡rios e infraestrutura produtiva incompleta. NÃ£o apresentar isso como configuraÃ§Ã£o produtiva jÃ¡ endurecida.

## 7. LocalStack e PERSISTENCE=0

O modelo Ã© adequado para um laboratÃ³rio descartÃ¡vel que sofreu restauraÃ§Ã£o de control plane sem processos/endpoints correspondentes. O bind por sessÃ£o atende ao executor CodeBuild mesmo com snapshots desativados. A exigÃªncia de bind neste laboratÃ³rio se apoia no erro do executor anteriormente observado, nÃ£o em um requisito da AWS real. ReconstruÃ§Ã£o de recursos nÃ£o Ã© recuperaÃ§Ã£o de dados cadastrados: as tarefas do banco nÃ£o sÃ£o um backup persistente entre sessÃµes.

NÃ£o se deve atribuir Ã  AWS real essa durabilidade local ou ausÃªncia de hosts EC2. SessÃ£o nova, inputs rastreÃ¡veis e reproduÃ§Ã£o binÃ¡ria completa sÃ£o propriedades diferentes. Lockfile e ZIP normalizado foram incorporados, mas tags `localstack/localstack-pro:latest` e `node:24-alpine` seguem mÃ³veis. Registrar versÃ£o/digest efetivos e sÃ³ entÃ£o congelar a versÃ£o homologada; nÃ£o inventar uma versÃ£o nem atualizar o runtime ativo para tentar corrigir o preflight.

| DocumentaÃ§Ã£o oficial                                                            | ImplicaÃ§Ã£o                                                                                   |
| --------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| PersistÃªncia opcional e compatibilidade de snapshots                             | P0 Ã© uma escolha vÃ¡lida, nÃ£o prova de que todo recurso persistido sempre falharÃ¡           |
| CodePipeline V1 executÃ¡vel; V2 mock; sem triggers/locks/retry/rollback completos | Manter V1, inÃ­cio explÃ­cito e serializaÃ§Ã£o; nÃ£o transportar essas limitaÃ§Ãµes para AWS   |
| CodeBuild com agente AWS e limitaÃ§Ãµes de imagens/variÃ¡veis/persistÃªncia       | Verificar ambiente real do runner e APIs, nÃ£o presumir imagem ou sucesso por declaraÃ§Ã£o/log |
| ECS pelo executor Docker                                                          | Control plane e runtime devem ser verificados separadamente                                    |
| RDS engine local pode usar versÃ£o padrÃ£o com custom versions desativadas        | EngineVersion API nÃ£o substitui consulta SQL da versÃ£o efetiva                               |

Fontes: [persistÃªncia](https://docs.localstack.cloud/aws/developer-tools/snapshots/persistence/), [CodePipeline](https://docs.localstack.cloud/aws/services/codepipeline/), [CodeBuild](https://docs.localstack.cloud/aws/services/codebuild/), [ECS](https://docs.localstack.cloud/aws/services/ecs/), [RDS](https://docs.localstack.cloud/aws/services/rds/).

A documentaÃ§Ã£o atual inclui Source CodeConnections; portanto nÃ£o Ã© correto afirmar indisponibilidade universal de GitHub Source. O S3 Ã© mantido por rastreabilidade do working tree e foco da etapa, nÃ£o por uma proibiÃ§Ã£o geral. Disponibilidade de serviÃ§os/recursos depende da licenÃ§a e versÃ£o instaladas; validar no plano efetivo do laboratÃ³rio.

A ausÃªncia/travamento de Build foi relatada em sessÃµes anteriores. NÃ£o estÃ¡ documentada como falha inevitÃ¡vel do serviÃ§o e nÃ£o foi reproduzida no LocalStack desta auditoria. Se persistir apÃ³s corrigir o preflight, registrar versÃ£o/digest, declaraÃ§Ã£o e respostas Source/Build/Deploy para investigar/reproduzir no fornecedor. AtÃ© entÃ£o, execuÃ§Ã£o incompleta Ã© reprovaÃ§Ã£o/inconclusÃ£o, nÃ£o CI/CD aprovado.

## 8. O que permanece como dÃ­vida tÃ©cnica

- Bootstrap RDS ainda gira identificador apÃ³s timeout. `creating` lento nÃ£o prova stale; o material nÃ£o explica o provisioning. NÃ£o ampliar essa polÃ­tica para CI/CD.
- `sync-alb-targets` remove e registra targets em bloco, podendo criar janela sem targets. NÃ£o hÃ¡ promessa de deploy sem interrupÃ§Ã£o na etapa 8; implementar convergÃªncia por delta pode ser melhoria posterior, preservando TG `ip`.
- `create-ecs` ainda forÃ§a implantaÃ§Ã£o e pode rotacionar namespace em manutenÃ§Ã£o. A invocaÃ§Ã£o normal do CI/CD foi desacoplada disso; nÃ£o foi feita certificaÃ§Ã£o de todos os caminhos de repair.
- IAM, TLS RDS, autenticaÃ§Ã£o, ASG/bootstrap e IaC requerem trabalho antes de produÃ§Ã£o AWS real.
- Advisory moderado no grafo Vitest/mocker de desenvolvimento e dÃ­vida de formataÃ§Ã£o continuam explÃ­citos. A instalaÃ§Ã£o tambÃ©m emitiu aviso de deprecaÃ§Ã£o do ESLint 9.39.5; o tooling merece atualizaÃ§Ã£o planejada. NÃ£o houve atualizaÃ§Ã£o major nem reformataÃ§Ã£o funcional em massa da aplicaÃ§Ã£o.
- Rollback operacional existente permanece fora do caminho de aprovaÃ§Ã£o e precisa de teste real se for demonstrado. NÃ£o Ã© Blue/Green nem rollback nativo CodePipeline.

Isso nÃ£o justifica refazer VPC/RDS/ECS/ALB/HTTPS comprovados. A reduÃ§Ã£o prioritÃ¡ria foi retirar a recuperaÃ§Ã£o da entrega e usar um Ãºnico contrato de consulta Docker para as tasks.

## 9. Respostas Ã s dez perguntas

| Pergunta                               | Resposta                                                                                                                                                           |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1. Fiel ao vÃ­deo?                     | Sim no conceito CRUD + AWS build/deploy/container/dados/balanceamento; emulaÃ§Ã£o e etapas futuras devem ser explicitadas                                          |
| 2. Melhor em quÃª?                     | EvidÃªncia disponÃ­vel de testes, Zod, SQL parametrizado, health com banco, nÃ£o-root e documentaÃ§Ã£o de paridade; sem afirmar ausÃªncia desses cuidados no autor |
| 3. Onde desviou?                       | AprovaÃ§Ã£o por fallback externo e acÃºmulo de recuperaÃ§Ã£o, alÃ©m do roadmap incorreto; corrigidos no caminho normal/documentaÃ§Ã£o                              |
| 4. Complexidade desnecessÃ¡ria?        | Sim: inferÃªncia por runners/tags novas, CodeBuild direto e reconciliaÃ§Ã£o automÃ¡tica para toda falha de preflight                                               |
| 5. EstratÃ©gia LocalStack correta?     | Sim como emulaÃ§Ã£o, com APIs/runtime verificados e diferenÃ§as explÃ­citas; nÃ£o Ã© certificaÃ§Ã£o de infraestrutura AWS real                                     |
| 6. P0 + reconstruÃ§Ã£o adequada?       | Sim para laboratÃ³rio descartÃ¡vel; sacrifica dados locais e exige versÃµes/inputs registrados                                                                     |
| 7. CI/CD local faz sentido?            | S3 â†’ CodePipeline V1 â†’ CodeBuild â†’ ECR â†’ ECS faz; um deploy externo nÃ£o prova a pipeline                                                                  |
| 8. ConclusÃ£o profissional da etapa 8? | Duas entregas nativas rastreÃ¡veis, mudanÃ§a real demonstrada e quality gate falho bloqueando Deploy; guardar evidÃªncia sanitizada                                |
| 9. Simplificar o quÃª?                 | Entrega sem repair/fallback, captura comum Docker, inputs permitidos, lockfile e documentaÃ§Ã£o atual; consolidar wrappers depois                                  |
| 10. NÃ£o alterar o quÃª?               | Stack, domÃ­nio/endpoints, duas rÃ©plicas, banco/secret, rede, ECR, TG/ALB/ACM/HTTPS, logs e diferenÃ§as intencionais do laboratÃ³rio                              |

## 10. ValidaÃ§Ã£o da entrega 1.7.1

Ambiente de execuÃ§Ã£o: Linux, Node 24.19.0/npm 11.9.0 e PowerShell 7.6.6 portÃ¡til. Docker/AWS/LocalStack/Windows nÃ£o estavam disponÃ­veis.

| VALIDADO NESTA AUDITORIA   | EvidÃªncia e limite                                                                                                                                                                                                         |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Integridade dos originais  | Dois ZIPs comparados; mesmos 93 conteÃºdos, original sem modificaÃ§Ã£o                                                                                                                                                      |
| DependÃªncias              | npm ci com lockfile; grafo fixado. InstalaÃ§Ã£o de verificaÃ§Ã£o usou `--ignore-scripts`; build posterior executou ferramentas instaladas                                                                                   |
| AplicaÃ§Ã£o                | npm run verify: lint sem avisos, 7 testes API + 4 frontend e build TypeScript/Vite                                                                                                                                          |
| RegressÃµes                | 25 testes isolados: processo nativo, rejeiÃ§Ã£o de falhas, Source/hash, ECR, redaction, tasks/revisÃ£o/health/digest e publicaÃ§Ã£o em processo PowerShell novo. AWS/Docker simulados; HTTPS foi stubado nessas fixtures    |
| Prova negativa do original | 14 dos 19 testes iniciais falharam contra funÃ§Ãµes originais; dois testes adicionais de readers de secret e dois de identidade canÃ´nica S3 e um de alias da imagem fÃ­sica falharam antes das proteÃ§Ãµes correspondentes |
| PowerShell                 | Parser nativo nos 38 scripts em PowerShell 7; nÃ£o prova por si sÃ³ execuÃ§Ã£o em 5.1                                                                                                                                       |
| JSON/YAML                  | 6 JSONs e 5 YAMLs parseados; comandos de buildspec e referÃªncias/caminhos examinados; 32 blocos PowerShell da documentaÃ§Ã£o parseados sem executar seus comandos                                                          |
| Dockerfile/contexto        | InspeÃ§Ã£o estÃ¡tica de stages, inputs, lockfile, usuÃ¡rio/healthcheck e seleÃ§Ã£o de contexto; sem Docker build executado aqui                                                                                             |
| Snapshot                   | Publisher executado com upload simulado; inputs, exclusÃµes, VersionId do upload, hash estÃ¡vel ante mtime e bloqueio de credenciais fictÃ­cias verificados                                                                 |
| SeguranÃ§a da entrega      | Busca por credencial original sem exibir seu valor, padrÃµes de secrets e exclusÃ£o de runtime/env/logs/certificados/temporÃ¡rios                                                                                           |
| ZIP completo               | CRC, caminhos seguros, raiz Ãºnica cloudtasks-aws e inventÃ¡rio conferidos no empacotamento final                                                                                                                           |
| Advisory                   | npm audit: 2 moderados (Vitest/mocker), 0 altos/crÃ­ticos; audit omit=dev retornou 0 advisories. NÃ£o equivale a 2 vulnerabilidades produtivas; dependÃªncias de teste fora do runner prod-deps                             |
| FormataÃ§Ã£o               | Resultado registrado abaixo; checagem separada de verify, sem fingir aprovaÃ§Ã£o de dÃ­vida existente                                                                                                                       |

`npm run format:check` reprovou 22 arquivos remanescentes, principalmente cÃ³digo/configuraÃ§Ã£o da aplicaÃ§Ã£o e documentaÃ§Ã£o nÃ£o reformatados nesta correÃ§Ã£o. Documentos/configuraÃ§Ãµes alterados e a fixture nova foram formatados. Essa dÃ­vida nÃ£o foi ocultada nem tratada como check aprovado.

| PRECISA SER VALIDADO NA MÃQUINA DO LABORATÃ“RIO | CritÃ©rio                                                                                                               |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| PowerShell 5.1                                  | Parser/regressÃµes e captura Docker sem encerramento prematuro; job Windows GitHub ainda nÃ£o executado nesta auditoria |
| Docker                                          | Build real e inspeÃ§Ã£o de contexto/layers; native fixture nÃ£o substitui Docker Desktop                                |
| CodePipeline/CodeBuild                          | Source/Build/Deploy nativos e BuildId API SUCCEEDED; versÃ£o efetiva e suporte a revisÃ£o S3 exata                      |
| Runtime ECS                                     | Cada task nova com revisÃ£o/imagem corretas e Docker healthy; RepoDigests igual ao digest ECR                           |
| ALB/HTTPS/RDS                                   | 2/2 targets, HTTPS health/CRUD e banco; fornecido como histÃ³rico anterior, nÃ£o repetido aqui                          |
| Etapa 8 completa                                | Segunda mudanÃ§a real entregue e teste negativo de quality gate sem avanÃ§ar ECS/Deploy                                 |
| SeguranÃ§a operacional                          | ACLs de temporÃ¡rios, Git/histÃ³rico, logs/layers reais e substituiÃ§Ã£o da credencial original se ativa                |

## 11. Comandos e resultados esperados

O pacote contÃ©m uma pasta `cloudtasks-aws` completa. Atualize o cÃ³digo mantendo o `.env.localstack` pessoal fora da distribuiÃ§Ã£o. Como o runtime atual foi relatado saudÃ¡vel, nÃ£o iniciar/parar/resetar/reconciliar antes apenas por causa deste erro.

Na raiz:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
& {
    $ErrorActionPreference = 'Stop'
    .\scripts\localstack\create-cicd.ps1
    .\scripts\localstack\test-cicd.ps1
}
```

Esperado no primeiro comando: scripts permitidos somente nessa janela/processo. No segundo: preflight aceita o runtime vÃ¡lido, prepara a imagem CodeBuild; Source/Build/Deploy nativos completam; nova imagem ligada ao ID do build/digest, nova revisÃ£o e metadados da execuÃ§Ã£o. No terceiro: identidade exata do Source/build/imagem, duas tasks da revisÃ£o, Docker healthy/digest e HTTPS/CRUD/RDS. SÃ£o resultados esperados de uma execuÃ§Ã£o saudÃ¡vel, ainda dependentes da validaÃ§Ã£o no emulador.

Se CodePipeline parar em Source ou CodeBuild/API nÃ£o comprovar sucesso, isso Ã© falha/inconclusÃ£o real. Preservar a sessÃ£o e executar `status-cicd.ps1`/`diagnose-cicd.ps1`, sem aprovar por runner ou resetar recursos para esconder o problema.

A primeira aprovaÃ§Ã£o nÃ£o encerra sozinha a etapa. [PIPELINE.md](PIPELINE.md) contÃ©m os comandos do teste negativo, resultados e registro das duas entregas. CritÃ©rio final: dois Sources/builds/imagens/revisÃµes rastreÃ¡veis, mudanÃ§a visÃ­vel e uma falha real do quality gate mantendo a versÃ£o saudÃ¡vel. Nenhum estÃ¡gio 9â€“13 foi implementado ou declarado concluÃ­do.

## 12. Compatibilidade do empacotamento com Windows PowerShell 5.1

Na execuÃ§Ã£o subsequente enviada pelo responsÃ¡vel, o `create-cicd.ps1` do pacote auditado passou pelo preflight do runtime, confirmou o ECR existente e avanÃ§ou Ã  publicaÃ§Ã£o do Source. A interrupÃ§Ã£o ocorreu em `publish-cicd-source.ps1`, linha 77 da entrega anterior, ao resolver `[IO.Compression.ZipArchiveMode]`.

**Causa no cÃ³digo:** carregava-se apenas `System.IO.Compression.FileSystem`. `ZipArchiveMode`, `ZipArchive` e `CompressionLevel` pertencem a `System.IO.Compression`. O Windows PowerShell 5.1/.NET Framework nÃ£o encontrou o enum antes da chamada a `ZipFile.Open`; a biblioteca precisa ser carregada explicitamente. A documentaÃ§Ã£o da Microsoft identifica os assemblies de [ZipArchiveMode](https://learn.microsoft.com/en-us/dotnet/api/system.io.compression.ziparchivemode) e [ZipFile](https://learn.microsoft.com/en-us/dotnet/api/system.io.compression.zipfile).

**CorreÃ§Ã£o localizada:** adicionar `Add-Type -AssemblyName System.IO.Compression` antes do carregamento de `System.IO.Compression.FileSystem` e do primeiro uso dos tipos ZIP. Nenhuma alteraÃ§Ã£o de ECS, RDS, ALB, Source permitido, determinismo do ZIP ou arquitetura de CI/CD foi necessÃ¡ria. A ausÃªncia de `last-deploy.json` no `test-cicd.ps1` Ã© consequÃªncia da execuÃ§Ã£o interrompida antes da entrega; nÃ£o deve ser suprida criando metadados artificialmente.

**RegressÃ£o:** `test-regressions.ps1` agora publica o Source tambÃ©m em um processo novo do mesmo executÃ¡vel PowerShell, com `-NoProfile`. Verifica o resultado do upload e reabre o ZIP real para conferir uma entrada e seu conteÃºdo. Docker/AWS continuam sendo fixtures externas; a compressÃ£o e o processo PowerShell sÃ£o reais. Esse teste jÃ¡ passava no PowerShell 7 antes da correÃ§Ã£o, portanto nÃ£o foi uma reproduÃ§Ã£o do erro do Windows; a prova da falha em 5.1 Ã© o transcript recebido. O job Windows existente executarÃ¡ o teste nesse runtime quando o workflow for acionado.

**ValidaÃ§Ã£o apÃ³s a mudanÃ§a:** 25 regressÃµes isoladas, `npm run verify` (lint, 7 testes API, 4 frontend e builds), parser dos 38 scripts, JSON/YAML, caminhos, seguranÃ§a e integridade do pacote. A execuÃ§Ã£o prÃ³pria continua limitada a Linux/PowerShell 7.6.6: nÃ£o houve teste em Windows 5.1, Docker ou LocalStack reais. As pendÃªncias de advisory e formataÃ§Ã£o da seÃ§Ã£o 10 permanecem.

Para continuar, atualizar o cÃ³digo preservando o `.env.localstack` pessoal e executar os mesmos comandos da seÃ§Ã£o 11 na sessÃ£o saudÃ¡vel existente. Esta falha de empacotamento nÃ£o requer reinicializaÃ§Ã£o ou reconciliaÃ§Ã£o da infraestrutura.

## 13. DiagnÃ³stico do executor CodeBuild e entrega 1.7.2

### EvidÃªncia recebida depois do empacotamento corrigido

A publicaÃ§Ã£o Source completou no Windows PowerShell 5.1, com VersionId e SHA256 registrados. A execuÃ§Ã£o CodePipeline `3c948a5a-283c-4824-b188-2a12d1919915` concluiu Source e falhou em Build com mensagem `Build timed out`. A aÃ§Ã£o nÃ£o forneceu `externalExecutionId`; o build `cloudtasks-build:4a3385dc` foi consultado como candidato e permaneceu `IN_PROGRESS` na API. O traceback do monitor cita esse mesmo build, mas a falta de vÃ­nculo da aÃ§Ã£o continua impedindo sua aprovaÃ§Ã£o como entrega rastreÃ¡vel.

VersÃ£o informada: LocalStack `2026.8.3:02342ae2e`. Imagem em uso: `localstack/localstack-pro:latest`; runner: `localstack/aws-codebuild-local:2`. O runner preservado terminou com exit 0 e sem OOM. Apenas a imagem do wrapper estava no cache CodeBuild mostrado no transcript. NÃ£o foi executada atualizaÃ§Ã£o ou reset nessa investigaÃ§Ã£o.

| HorÃ¡rio UTC de 01/10/2026 | Evento observado                                                                                      |
| -------------------------- | ----------------------------------------------------------------------------------------------------- |
| 22:09:34                   | AÃ§Ã£o Build e build candidato registrados na API, separados por aproximadamente 0,14 segundo         |
| 22:09:45                   | Thread `BuildManager._check_build(cloudtasks-build:4a3385dc)` encerra com `Container not yet started` |
| 22:39:57                   | AÃ§Ã£o Build falha por timeout, aproximadamente 30 min 23 s depois do inÃ­cio                         |
| 22:40:20                   | Container externo finalmente inicia, depois de a aÃ§Ã£o jÃ¡ ter falhado                               |
| 22:40:47                   | Download de camada falha com `TLS handshake timeout`; wrapper encerra com cÃ³digo 0                   |

Os horÃ¡rios Docker e os timestamps de API foram convertidos para UTC. A demora no inÃ­cio estÃ¡ comprovada; atribuir os 31 minutos inteiros ao download inicial da imagem Ã© **inferÃªncia**, nÃ£o algo quantificado pelos logs recebidos. TambÃ©m nÃ£o se determinou se o timeout TLS veio de proxy, firewall, conexÃ£o, registry ou outro componente de rede. NÃ£o desabilitar TLS por causa dessa incerteza.

### Causa do estado contraditÃ³rio da API

O traceback mostra o monitor em `localstack/pro/core/services/codebuild/build.py.enc`, funÃ§Ã£o `_check_build`, chamando `is_build_complete`. Essa funÃ§Ã£o tenta ler `server.container.logs()`. Em `localstack/utils/container/container.py`, o acesso aos logs exige `is_started()`; a condiÃ§Ã£o falha e levanta `ContainerStateError('Container not yet started.')`.

O monitor consulta um container ainda nÃ£o iniciado e a exceÃ§Ã£o encerra a thread. Essa falha ocorre **antes do buildspec da aplicaÃ§Ã£o** e explica por que o build continua `IN_PROGRESS` enquanto a aÃ§Ã£o CodePipeline termina por timeout. Aumentar `timeoutInMinutes`, reconciliar ECS ou modificar React/Express nÃ£o corrige essa condiÃ§Ã£o do provider. O projeto nÃ£o pode reparar esse cÃ³digo do emulador apenas alterando seus buildspecs.

### SaÃ­da 0 indevida do wrapper

O `local_build.sh` recebido Ã© o entrypoint da imagem do executor. Na linha 171, executa `docker-compose up --abort-on-container-exit ... | tee build_logs`. NÃ£o hÃ¡ `pipefail` nem verificaÃ§Ã£o do exit code do Compose. Nas linhas 173â€“180, o resultado depende apenas de encontrar `Phase complete: ... State: FAILED` no log. Uma falha de pull/startup anterior Ã s fases nÃ£o produz essa linha e cai em `exit 0`.

Isso foi reproduzido aqui com o trecho exato do wrapper e um comando Compose controlado: erro 17 sem log de fase FAILED resultou em saÃ­da 0; erro com fase FAILED resultou em 1; execuÃ§Ã£o saudÃ¡vel resultou em 0. Bash e o trecho do wrapper foram reais; Compose/Docker foram simulados. O script do fornecedor nÃ£o foi alterado, copiado para a aplicaÃ§Ã£o ou substituÃ­do por uma imagem disfarÃ§ada.

O timeout da aÃ§Ã£o e o estado incorreto da API nÃ£o devem ser sobrepostos pelo exit 0 desse container. Mesmo se o provider reportar sucesso indevido, sÃ£o necessÃ¡rios artifacts, aÃ§Ã£o Deploy e imagem/tasks corretas para a aceitaÃ§Ã£o.

### O compose efetivo fecha a questÃ£o do daemon

Foi recebido `docker-compose-localstack.yml`, efetivamente selecionado pelo wrapper, e nÃ£o apenas o Compose base da Amazon. Ele declara `dns_health` e `agent` com `${LOCAL_AGENT_IMAGE}` e `build` com `${IMAGE_FOR_CODEBUILD_LOCAL_BUILD}`. Na linha 82, `build` monta `/var/run/docker.sock:/var/run/docker.sock`; nÃ£o existe serviÃ§o `dockerd` separado. O wrapper usa `LOCAL_AGENT_IMAGE_NAME` e `IMAGE_NAME` para definir essas imagens. Sem `LOCAL_AGENT_IMAGE_NAME`, o prÃ³prio wrapper adota `amazon/aws-codebuild-local:latest`; **o valor efetivo desse parÃ¢metro nÃ£o foi fornecido**, portanto nÃ£o se presume qual agente interno foi usado.

A inspeÃ§Ã£o recebida nÃ£o encontrou `DOCKER_HOST`, `DOCKER_CONTEXT` ou `DOCKER_CONFIG` no wrapper. Com o socket montado, o CLI Linux usa o daemon do Docker Desktop. Um volume `/var/lib/docker` no wrapper, isoladamente, nÃ£o prova Docker-in-Docker. A documentaÃ§Ã£o do [Docker CLI](https://docs.docker.com/reference/cli/docker/) explica a seleÃ§Ã£o do socket/contexto padrÃ£o. Preparar imagens nesse daemon atende a este runtime; nÃ£o Ã© requisito da AWS real.

### Incompatibilidade adicional comprovada no projeto

Na entrega anterior, o bloco de aceitaÃ§Ã£o em `create-cicd.ps1` extraÃ­a o sufixo de `$codeBuildId` e exigia um UUID completo. O ID `4a3385dc`, de oito caracteres hexadecimais, visto na API desse LocalStack, era rejeitado com `CodeBuild retornou ID sem UUID validavel`. A condiÃ§Ã£o antiga foi executada aqui: aceita UUID e rejeita exatamente o ID curto observado. Isso Ã© um bloqueio posterior independente do timeout; nÃ£o foi a causa da falha de Build jÃ¡ recebida.

`Get-CicdBuildImageTag` agora exige o projeto `cloudtasks-build` e aceita UUID ou oito hexadecimais, preservando o sufixo exato na tag. IDs de outro projeto, formatos arbitrÃ¡rios, barras, espaÃ§os e sufixos adicionais sÃ£o recusados. NÃ£o escolhe `latest` ou uma tag candidata. Os buildspecs jÃ¡ usam `${CODEBUILD_BUILD_ID##*:}`; nÃ£o precisam mudar por essa compatibilidade. Se o agente injetar um ID diferente do registrado na API, a comparaÃ§Ã£o da imagem recusarÃ¡ a entrega; o ID estÃ¡tico de exemplo presente no template Compose nÃ£o comprova o valor efetivo injetado no build.

### SoluÃ§Ã£o aplicada e seus limites

- `Ensure-CicdBuildImage` verifica o cache da imagem Amazon Linux x86 usada por este projeto e pelo ambiente padrÃ£o documentado do LocalStack; baixa somente quando ausente e reinspeciona o image ID. Acontece no preflight, antes do Source/execuÃ§Ã£o. Falha de registry encerra o fluxo e a resposta bruta Ã© omitida, pois pode incluir URLs assinadas. NÃ£o executa o build da aplicaÃ§Ã£o no PowerShell.
- O wrapper observado jÃ¡ estava em cache e permanece sob controle do LocalStack. A preparaÃ§Ã£o do ambiente Amazon Linux reduz downloads durante a execuÃ§Ã£o, mas nÃ£o Ã© garantia de correÃ§Ã£o do monitor nem de cache de um agente interno diferente. NÃ£o foram inventadas configuraÃ§Ãµes privadas do provider, alterados timeouts, reescritas respostas de API ou introduzido fallback.
- `Get-CicdBuildImageTag` resolve o bloqueio comprovado por UUID obrigatÃ³rio, mantendo a identidade nativa.
- `diagnose-cicd.ps1` prioriza o ID vinculado Ã  aÃ§Ã£o; se ele falta, identifica explicitamente o Ãºltimo build como candidato. Mostra aÃ§Ãµes, horÃ¡rios/estado do runner e nomes pÃºblicos conhecidos das imagens, sem despejar env, mensagens livres de provider ou logs. Exit 0 permanece insuficiente.
- Nenhuma mudanÃ§a em VPC, RDS, Secrets, ECS, rÃ©plica, TG, ALB, ACM/HTTPS ou `PERSISTENCE=0`. Nenhum script novo de recuperaÃ§Ã£o. CÃ³digo/documentaÃ§Ã£o sÃ£o reunidos em um Ãºnico ZIP completo, com raiz `cloudtasks-aws` e sem arquivos pessoais.

PreparaÃ§Ã£o de cache Ã© uma **mitigaÃ§Ã£o de prÃ©-requisito**, nÃ£o um reparo dos defeitos comprovados do fornecedor. Se a falha do monitor voltar a ocorrer com os prÃ©-requisitos disponÃ­veis, a soluÃ§Ã£o sustentÃ¡vel exige correÃ§Ã£o/homologaÃ§Ã£o do executor e uma versÃ£o/digest comprovadamente funcional. NÃ£o foi encontrada ou executada uma release que autorize afirmar que esse defeito jÃ¡ foi corrigido. NÃ£o marcar a etapa 8 como concluÃ­da por bypass, nem atualizar `latest` Ã s cegas na sessÃ£o saudÃ¡vel. Relato ao fornecedor deve conter versÃ£o/digest, sequÃªncia de API/container e reproduÃ§Ã£o sanitizada; nÃ£o compartilhar logs originais ou env do runner.

### Documentado, observado e inferido

| ClassificaÃ§Ã£o  | AfirmaÃ§Ã£o                                                                                                                                                             |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Documentado      | LocalStack CodeBuild usa o agente AWS/Compose, aceita Source S3/NO_SOURCE/CODEPIPELINE, possui limitaÃ§Ãµes de imagens/variÃ¡veis e nÃ£o fornece granularidade de fases |
| Documentado      | Ambiente padrÃ£o x86 Amazon Linux 2023 `public.ecr.aws/codebuild/amazonlinux-x86_64-standard:5.0`; variÃ¡veis de buildspec nÃ£o sÃ£o suportadas nessa emulaÃ§Ã£o        |
| Observado        | Monitor encerrando antes do container, TLS timeout, wrapper exit 0, build API `IN_PROGRESS` e aÃ§Ã£o Build `Failed` na versÃ£o instalada                                |
| Observado        | Socket compartilhado, ausÃªncia dos overrides Docker e sufixo de build com oito hexadecimais                                                                            |
| Inferido         | Cache preparado pode reduzir a demora/race de startup; Ã© preciso executar novamente para medir e confirmar                                                             |
| NÃ£o determinado | Motivo preciso da lentidÃ£o e do timeout TLS; imagens internas efetivas sem os parÃ¢metros resolvidos; versÃ£o do provider que elimina os defeitos                      |

ReferÃªncias oficiais consultadas: [LocalStack CodeBuild](https://docs.localstack.cloud/aws/services/codebuild/), [configuraÃ§Ã£o CodeBuild](https://docs.localstack.cloud/aws/customization/configuration-options/), [Docker CLI](https://docs.docker.com/reference/cli/docker/) e [AWS aÃ§Ã£o ECS padrÃ£o](https://docs.aws.amazon.com/codepipeline/latest/userguide/action-reference-ECS.html). A documentaÃ§Ã£o nÃ£o descreve os dois defeitos observados como comportamento inevitÃ¡vel. `phases` vazio, isoladamente, corresponde a uma limitaÃ§Ã£o documentada; nÃ£o foi usado como prova de travamento.

### ValidaÃ§Ã£o desta entrega

Os resultados prÃ³prios apÃ³s a alteraÃ§Ã£o sÃ£o registrados abaixo. A suÃ­te inclui captura nativa PowerShell, Source seguro e casos de ID curto/UUID, download falho/ausente, candidatos sem vÃ­nculo e recusa de tasks/revisÃ£o/saÃºde/digest divergentes. Foram usados apenas canÃ¡rios fictÃ­cios para credenciais.

| VALIDADO NESTA ENTREGA 1.7.2 | Resultado e limite                                                                                                                                                                           |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| AplicaÃ§Ã£o                  | `npm run verify` passou: lint sem avisos do ESLint, 7 testes API, 4 frontend e build TypeScript/Vite; Node 24.19.0 em Linux                                                                  |
| PowerShell                   | 35 regressÃµes isoladas e parser dos 38 scripts passaram em PowerShell 7.6.6; Docker/AWS simulados                                                                                           |
| Prova negativa nova          | CondiÃ§Ã£o antiga recusou o ID curto observado; diagnÃ³stico antigo falhou nos dois casos de vÃ­nculo; novas regressÃµes ficaram verdes apÃ³s as mudanÃ§as                                   |
| Wrapper do fornecedor        | Trecho exato reproduzido em trÃªs cenÃ¡rios Bash; falha de startup sem fase FAILED devolve 0; Compose simulado                                                                               |
| JSON/YAML e shell            | 6 JSONs e 5 YAMLs vÃ¡lidos; comandos dos buildspecs e proteÃ§Ã£o antes do push examinados                                                                                                    |
| ReferÃªncias e contexto      | Links locais, caminhos de scripts, inputs do publisher e seleÃ§Ã£o estÃ¡tica Docker aprovados; nenhum Docker build real aqui                                                                 |
| SeguranÃ§a e pacote          | Inputs excluem ambiente pessoal/runtime/logs; valores conhecidos e padrÃµes de credenciais conferidos sem exibiÃ§Ã£o; ZIP completo com raiz Ãºnica/CRC/conteÃºdo conferidos antes da entrega |
| FormataÃ§Ã£o                 | `npm run format:check` segue reprovando os 22 arquivos histÃ³ricos; os arquivos editados desta entrega foram formatados                                                                      |

A documentaÃ§Ã£o atual da [AWS sobre runtimes](https://docs.aws.amazon.com/codebuild/latest/userguide/available-runtimes.html) lista Node.js 24 para Amazon Linux 2023 x86 standard 5.0. Isso sustenta a escolha do ambiente; nÃ£o substitui a mediÃ§Ã£o de `node --version` no agente efetivamente usado pelo LocalStack. O npm desta estaÃ§Ã£o emitiu aviso sobre uma configuraÃ§Ã£o de proxy do ambiente, distinto de avisos do lint do projeto.

**Ainda precisa executar no laboratÃ³rio:** download real, CodeBuild/CodePipeline e aÃ§Ã£o ECS nativa; correspondÃªncia das imagens efetivas; Windows PowerShell 5.1; health/digest de todas as tasks e HTTPS/CRUD/RDS. A prova histÃ³rica de ECS/ALB saudÃ¡vel pertence Ã s execuÃ§Ãµes recebidas, nÃ£o a uma execuÃ§Ã£o deste ambiente Linux. A etapa 8 exige duas entregas reais rastreÃ¡veis e o quality gate negativo descrito em [PIPELINE.md](PIPELINE.md).

**Comandos na sessÃ£o saudÃ¡vel existente:** os trÃªs da seÃ§Ã£o 11. NÃ£o executar `test-cicd.ps1` depois de `create-cicd.ps1` falhar. Se houver falha, executar `diagnose-cicd.ps1` e preservar a sessÃ£o. O pacote nÃ£o inclui token, senha, logs de diagnÃ³stico ou estado anterior; mantenha o seu `.env.localstack` pessoal no diretÃ³rio de trabalho, sem publicÃ¡-lo.

## 14. HomologaÃ§Ã£o remota no Windows â€” entrega 1.7.3

Em 02/10/2026, o responsÃ¡vel autorizou acesso pelo Remote Desktop Commander. A versÃ£o instalada 1.7.2 foi conferida por hashes antes de qualquer ediÃ§Ã£o. As limitaÃ§Ãµes de execuÃ§Ã£o prÃ³pria nas seÃ§Ãµes anteriores descrevem aquelas entregas; os resultados abaixo registram o trabalho efetivamente executado depois, na mÃ¡quina do laboratÃ³rio.

### Causas encontradas na homologaÃ§Ã£o

- O processo remoto nÃ£o fornece `OS=Windows_NT`, embora `[Environment]::OSVersion.Platform` retorne `Win32NT`. O harness escolhia a fixture Unix e tentava executar `chmod`. A detecÃ§Ã£o passou a usar o runtime .NET.
- O launcher `.cmd` interpretava os caracteres `|` do Go template Docker. Isso produzia uma falsa falha nos testes positivos. A fixture Windows agora Ã© um executÃ¡vel temporÃ¡rio compilado com o compilador .NET Framework do Windows PowerShell; encaminha argumentos ao Node e preserva o exit code nativo. NÃ£o altera Docker, PATH ou metadados fora do processo de teste.
- Em `test-cicd.ps1`, o PowerShell 5.1 podia coletar o array JSON como um Ãºnico item `System.Object[]`. A instrumentaÃ§Ã£o isolada confirmou que o JSON continha o digest esperado, enquanto o operador `-contains` o recusava. A conversÃ£o agora produz explicitamente um `[string[]]` depois do parsing. Digest incorreto, task antiga e container sem saÃºde continuam reprovando.

### EvidÃªncias prÃ³prias no Windows

| VerificaÃ§Ã£o          | Resultado e limite                                                                                                                                                                                                                                                                      |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Plataforma             | PowerShell 5.1.26100.9549; Node 24.21.0; Docker Engine 29.6.2, contexto `desktop-linux`                                                                                                                                                                                                 |
| Runtime real           | Preflight CI/CD retornou `True`; status ECS confirmou desired/running 2/2, pending 0 e duas tasks Docker healthy, sem reconciliaÃ§Ã£o                                                                                                                                                   |
| Qualidade              | `npm ci` e `npm run verify` terminaram com exit 0: lint, 7 testes API, 4 frontend e builds TypeScript/Vite                                                                                                                                                                              |
| Scripts                | Parser nativo aprovou os 38 scripts; 35 regressÃµes passaram no PowerShell 5.1                                                                                                                                                                                                          |
| Limite das regressÃµes | O processo nativo Ã© real; respostas Docker/AWS e a dependÃªncia HTTPS dessas fixtures sÃ£o simuladas                                                                                                                                                                                   |
| Compatibilidade Linux  | As mesmas 35 regressÃµes tambÃ©m passaram no PowerShell 7.6.6 apÃ³s as alteraÃ§Ãµes                                                                                                                                                                                                     |
| Source S3 real         | Snapshot VersionId `AaD5g8pjgcWoxTXWdHbzZ7ypUL3TU1I1`, SHA256 `88ac1177f6da1e1ea75a490a8f535c20248ad9126c3d4b0fc80effbcae37b837`; 32 entradas, sem arquivos proibidos ou valores ativos de token/senha detectados                                                                       |
| Imagem atual           | Metadados e histÃ³rico sem os valores ativos conhecidos; varredura adicional de 4255 arquivos legÃ­veis do filesystem em container temporÃ¡rio, sem rede e read-only, tambÃ©m nÃ£o os encontrou. Cinco caminhos ficaram ilegÃ­veis; links e filesystems virtuais nÃ£o foram percorridos |
| Logs existentes        | Buscados apenas em memÃ³ria: logs disponÃ­veis do LocalStack, do runner anterior e das duas tasks, com limite de 3000 linhas por container; nÃ£o foram encontrados os dois valores ativos conhecidos                                                                                    |
| HistÃ³rico Git         | NÃ£o acompanha esta pasta; estas verificaÃ§Ãµes nÃ£o certificam o histÃ³rico remoto do GitHub                                                                                                                                                                                           |

### PrÃ©-requisito de rede da imagem CodeBuild

O `docker pull` real falhou em cerca de 25 segundos com `TLS handshake timeout` em uma CDN CloudFront. NÃ£o houve mensagem explÃ­cita de limite de uso, falha de autenticaÃ§Ã£o, certificado, DNS ou disco. O proxy `http.docker.internal:3128` encontrado Ã© o proxy interno padrÃ£o do Docker Desktop.

O Windows e um processo Python dentro do LocalStack completaram TLS contra o registro e o domÃ­nio da CDN, diretamente e pelo proxy. Os cÃ³digos HTTP 401/403 desses testes de raiz provam a conexÃ£o TLS, nÃ£o o acesso Ã s camadas da imagem. A CDN do download pertence ao fornecedor da imagem; isso nÃ£o implementa CloudFront na aplicaÃ§Ã£o nem antecipa a etapa 10.

A [documentaÃ§Ã£o do Docker](https://docs.docker.com/engine/release-notes/29/#2970) registra que os limites de transferÃªncias do image store containerd nÃ£o eram respeitados antes da versÃ£o 29.7.0. A mÃ¡quina usa 29.6.2. A contribuiÃ§Ã£o dessa condiÃ§Ã£o para o timeout desta conexÃ£o Ã© uma inferÃªncia; nÃ£o foi provada apenas pelos testes de raiz.

Para preparar o cache sem reiniciar o ambiente saudÃ¡vel, foi instalada fora do projeto a ferramenta oficial [`crane` 0.22.1](https://github.com/google/go-containerregistry/releases/tag/v0.22.1). O SHA256 do pacote Windows foi conferido com o digest publicado pela release. A transferÃªncia usa autenticaÃ§Ã£o anÃ´nima, TLS verificado e a referÃªncia exata do manifesto Linux/amd64. NÃ£o houve alteraÃ§Ã£o de daemon, proxy, firewall, credenciais ou configuraÃ§Ã£o do emulador.

- Manifesto: `sha256:eb5100a2ca720e158a6644932312d4eca71c6ca70641579640ef03341d8f6f53`.
- ConfiguraÃ§Ã£o/imagem esperada: `sha256:3dfed5bd5418bb6a5c1607b48f41a90fb1c9b78292047692b50324ecb18f55c4`.
- Camadas: 57; aproximadamente 6881 MiB compactados.

Preparar o cache nÃ£o executa o build da aplicaÃ§Ã£o, nÃ£o aprova CodeBuild/CodePipeline e nÃ£o corrige o defeito do monitor do fornecedor. O sucesso de uma transferÃªncia por outro cliente tambÃ©m nÃ£o comprova que `docker pull` foi reparado.

**Em homologaÃ§Ã£o:** concluir a importaÃ§Ã£o com identidade verificada, executar Source/Build/Deploy nativos, validar as tasks novas e HTTPS/CRUD, entregar uma segunda mudanÃ§a real e executar o quality gate negativo. AtÃ© essas provas, a etapa 8 continua pendente. NÃ£o reiniciar uma sessÃ£o `PERSISTENCE=0` para experimentar configuraÃ§Ãµes de rede.

## 15. CorreÃ§Ã£o da identidade nativa â€” entrega 1.7.4

As observaÃ§Ãµes anteriores sobre derivar a tag do ID foram superadas pela execuÃ§Ã£o real de 03/10/2026. A execuÃ§Ã£o `95135ac1-70ec-47f6-a9ad-6c1e8f26d92b` concluiu Source, Build e Deploy nativos. O CodeBuild real `cloudtasks-build:c25b541c` foi SUCCEEDED, executou 11 testes e publicou a imagem. Entretanto o agente usou um `CODEBUILD_BUILD_ID` com UUID zerado e gerou uma tag repetÃ­vel. A aceitaÃ§Ã£o recusou corretamente a divergÃªncia; essa execuÃ§Ã£o nÃ£o aprova a etapa 8.

O ECS entregou a nova task definition 2, com duas tasks Docker saudÃ¡veis, e o ALB manteve dois targets saudÃ¡veis. Portanto essa falha de identidade nÃ£o demonstra quebra do ECS.

A correÃ§Ã£o usa UUID v4 gerado no prÃ³prio CodeBuild e o artifact padrÃ£o `imagedefinitions.json`. O helper compartilhado confirma o ID real vinculado, a localizaÃ§Ã£o S3 exata do BuildOutput na aÃ§Ã£o e na API CodeBuild, o nome do container, o repositÃ³rio e a tag. Registra o hash do artifact para a aceitaÃ§Ã£o revalidar. Foram removidos o parser IDâ†’tag e `pipeline-build.json`; nenhum StartBuild externo ou deploy PowerShell foi introduzido.

O teste que mantÃ©m o ID curto real e usa uma tag independente falhou antes da correÃ§Ã£o e passou depois. As 37 regressÃµes passaram no PowerShell 7.6.6 e no Windows PowerShell 5.1, com respostas externas simuladas. A homologaÃ§Ã£o nativa concluÃ­da estÃ¡ registrada na seÃ§Ã£o 16.

Na preparaÃ§Ã£o da imagem oficial, o Docker/containerd desta mÃ¡quina reportou `.Id` igual ao digest do descriptor, distinto do digest da configuraÃ§Ã£o. A hipÃ³tese anterior de arquivo corrompido nÃ£o foi comprovada: manifesto, configuraÃ§Ã£o, 57 DiffIDs e configuraÃ§Ã£o efetiva foram verificados. A imagem oficial ficou em cache; isso nÃ£o comprova correÃ§Ã£o da conectividade TLS do CDN.

## 16. HomologaÃ§Ã£o concluÃ­da em 03/10/2026

A etapa 8 foi comprovada em execuÃ§Ã£o prÃ³pria no Windows/LocalStack. Nenhum StartBuild externo, deploy PowerShell alternativo, alteraÃ§Ã£o artificial de status ou reset do ambiente foi usado.

| Prova                 | CodePipeline                         | CodeBuild                 | Resultado                                                                                           |
| --------------------- | ------------------------------------ | ------------------------- | --------------------------------------------------------------------------------------------------- |
| Primeira entrega      | 8a9496c7-f589-4f22-9c7b-a8c983ae4f04 | cloudtasks-build:f189be5b | Source/Build/Deploy Succeeded; test-cicd aprovado                                                   |
| Segunda entrega       | a63eecaa-49f5-48bf-9556-b41a22106a95 | cloudtasks-build:436bddc5 | Novo Source, digest, task definition e texto confirmado no bundle HTTPS                             |
| Quality gate negativo | eb3d9c58-e46f-40b6-bbd9-b28aaf971ea9 | cloudtasks-build:a360ec3f | FAILED em PRE_BUILD por teste deliberado; zero aÃ§Ãµes Deploy iniciadas; revisÃ£o saudÃ¡vel mantida |
| Entrega limpa final   | 7a72fc01-9484-4ca6-9a2d-f8a3c550b6f1 | cloudtasks-build:6208b6e3 | Succeeded; test-cicd aprovado; duas tasks Docker e dois targets saudÃ¡veis                          |

O teste negativo foi removido em finally. O snapshot final voltou ao conteÃºdo limpo da segunda entrega, com SHA256 aedbf8c1851dc0d354dcebd04ff0448f92c78438bafa4615b221f9993f8a08c9, e recebeu outro VersionId. A revisÃ£o final Ã© arn:aws:ecs:us-east-1:000000000000:task-definition/cloudtasks:5, com digest ECR sha256:54c00b84108349344904c734728a8ad9f8b7deacb507c89aae49aca51f3e5acb.

Causa da falha de identidade: o agente usou CODEBUILD_BUILD_ID com UUID zerado, distinto do ID real da API. A soluÃ§Ã£o gera UUID v4 no build e verifica o artifact padrÃ£o ligado ao CodeBuild nativo. O parser IDâ†’tag e pipeline-build.json foram removidos.

Uma tentativa corrigida anterior falhou no INSTALL por ECONNRESET em npm ci. Ela foi recusada e nÃ£o conta como prova de quality gate. Uma consulta ao registry npm na mesma imagem/rede passou antes da repetiÃ§Ã£o. NÃ£o se afirma que a conectividade TLS/CDN do Docker foi corrigida permanentemente.

A consulta de aÃ§Ãµes antigas do LocalStack devolveu aÃ§Ãµes de outra execuÃ§Ã£o, mesmo com filtro. Os scripts filtram novamente pelo execution ID; a homologaÃ§Ã£o foi capturada durante cada execuÃ§Ã£o e congelada em EVIDENCE-CICD.json. NÃ£o se aceitou uma aÃ§Ã£o de outro run.

### VALIDADO POR MIM

- Windows PowerShell 5.1: parser dos 39 scripts e 37 regressÃµes com respostas externas simuladas.
- Linux PowerShell 7.6.6: as mesmas regressÃµes; teste novo falhou antes da correÃ§Ã£o e passou depois.
- npm verify: lint, 7 testes API, 4 frontend, TypeScript e Vite; tambÃ©m executado nos CodeBuilds reais.
- Docker build/push reais, ECR imutÃ¡vel, artifacts nativos/hash, ECS fÃ­sico, ALB e CRUD HTTPS/RDS.
- Duas entregas distintas, mudanÃ§a visÃ­vel e falha deliberada que bloqueou Deploy.
- Entrega final limpa, sem arquivo de teste negativo.

### NÃƒO VALIDADO / PRÃ“XIMAS VALIDAÃ‡Ã•ES

- Ã€ Ã©poca desta homologaÃ§Ã£o nativa, o novo job GitHub Actions ainda nÃ£o havia sido executado. A consolidaÃ§Ã£o posterior estÃ¡ na seÃ§Ã£o 17; nÃ£o houve auditoria exaustiva de todos os commits histÃ³ricos.
- AWS real: EC2/ASG, TG instance, CodeConnections, IAM e TLS de ALB reais nÃ£o foram executados.
- ReconstruÃ§Ã£o fria de uma nova sessÃ£o LocalStack nÃ£o foi repetida nesta homologaÃ§Ã£o, para preservar o runtime saudÃ¡vel. PERSISTENCE=0 continua sendo a decisÃ£o do laboratÃ³rio.
- Blue/Green, CloudFront, observabilidade ampliada e Amazon Q/MCP permanecem nas etapas seguintes.
- DÃ­vida global de formataÃ§Ã£o e advisories de dependÃªncias de teste continuam documentados; nÃ£o se declarou format:check global aprovado.

### OperaÃ§Ã£o apÃ³s esta entrega

Nenhuma cÃ³pia ou correÃ§Ã£o manual Ã© necessÃ¡ria: o projeto foi aplicado na mÃ¡quina. Para conferir novamente, a partir de qualquer pasta:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Users\barro\Downloads\cloudtasks-aws\scripts\localstack\test-cicd.ps1"
```

Resultado esperado: execuÃ§Ã£o nativa Succeeded, Source/Build/Deploy Succeeded, artifact/hash/digest corretos, 2/2 tasks e targets saudÃ¡veis e CRUD HTTPS/RDS aprovado. Se houver uma nova sessÃ£o LocalStack, os recursos precisam ser reconstruÃ­dos antes de usar metadados dessa sessÃ£o anterior.

A etapa 8 estÃ¡ concluÃ­da tecnicamente no laboratÃ³rio porque as trÃªs provas exigidas foram obtidas sem bypass. A publicaÃ§Ã£o posterior do cÃ³digo e das evidÃªncias estÃ¡ registrada a seguir.

## 17. PublicaÃ§Ã£o e viabilidade Blue/Green â€” entrega 1.7.5

O repositÃ³rio `fernetone/cloudtasks-aws-portfolio` estava na versÃ£o 1.1.3. A PR #1 publicou os 98 arquivos revisados da entrega 1.7.4 e preservou cinco arquivos AWS existentes ausentes do ZIP fornecido: duas polÃ­ticas, dois scripts e o documento ECR. Os scripts AWS foram apenas preservados e analisados, sem executar operaÃ§Ãµes numa conta AWS real.

O run GitHub `37134970506`, ligado ao commit `a97b045da0a5b7131137975005f45544e6793755`, terminou `success`: Ubuntu executou instalaÃ§Ã£o, `npm run verify` e Docker build; Windows executou parser e regressÃµes PowerShell 5.1. A evidÃªncia desse run estÃ¡ em [EVIDENCE-GITHUB.json](EVIDENCE-GITHUB.json). Runs de commits posteriores podem ser consultados na mesma PR. O job GitHub usa fixtures para os serviÃ§os externos; nÃ£o substitui a evidÃªncia nativa do laboratÃ³rio.

Na etapa 9, foram consultadas as documentaÃ§Ãµes oficiais e executadas apenas APIs de leitura na sessÃ£o existente. `DescribeTaskSets` retornou cinco registros, que nÃ£o comprovam duas revisÃµes simultÃ¢neas atendendo trÃ¡fego. `ListServiceDeployments` falhou com exit 255 e cÃ³digo `InternalFailure`, tanto com nomes quanto com ARNs completos. A CLI reconheceu a operaÃ§Ã£o; nÃ£o se observou uma resposta 501 nem uma mensagem explÃ­cita de API nÃ£o implementada.

A documentaÃ§Ã£o informa separadamente que CodeDeploy Ã© mockado e que a aÃ§Ã£o CodePipeline Blue/Green sÃ³ atualiza o service e aguarda estabilidade. A cobertura ECS registra as APIs de service deployments como nÃ£o implementadas. InferÃªncia: o ambiente atual nÃ£o fornece evidÃªncia suficiente para homologar um controlador Blue/Green nativo. O erro observado nÃ£o foi atribuÃ­do a um defeito no ECS da aplicaÃ§Ã£o; o service continuou Desired 2 / Running 2 / Pending 0, na revisÃ£o 5.

[BLUE-GREEN.md](BLUE-GREEN.md) separa AWS alvo, comportamento documentado, observaÃ§Ã£o local e critÃ©rio objetivo de aceite. Nenhum service, Target Group, listener ou controlador de deploy foi alterado por essa investigaÃ§Ã£o. A etapa 9 permanece pendente; nÃ£o foram antecipadas as etapas seguintes.

## 18. Blue/Green executÃ¡vel por adaptador â€” entrega 1.8.0

### DiagnÃ³stico e decisÃ£o

Os ensaios nativos bridge/IP e awsvpc/IP reprovaram retenÃ§Ã£o de blue diante de candidata invÃ¡lida. EXTERNAL retornou STEADY_STATE no control plane, mas zero tasks executÃ¡veis durante 65 segundos. CodeDeployToECS Ã© documentado como atualizaÃ§Ã£o/espera sem emulaÃ§Ã£o correta Blue/Green. NÃ£o se atribuiu o bloqueio Ã  aplicaÃ§Ã£o ou Ã  AWS real, nem se migrou a rede principal por esse resultado.

DecisÃ£o: dois serviÃ§os ECS independentes durante validaÃ§Ã£o, promoÃ§Ã£o e bake, com controlador dentro de um CodeBuild de deploy da CodePipeline V1. Source, quality gate/build/push ECR e artifacts permanecem nativos. Rolling segue padrÃ£o; BlueGreen Ã© explÃ­cito. Dois mÃ³dulos Node sem dependÃªncia nova e um buildspec de implantaÃ§Ã£o concentram a implementaÃ§Ã£o; nÃ£o hÃ¡ fallback PowerShell externo ou nova coleÃ§Ã£o de scripts de recuperaÃ§Ã£o.

### Causas encontradas na implementaÃ§Ã£o e no executor

- `LocalStackDeployment.createCandidate`, `converge` e `rollback`: a primeira versÃ£o retirava a Ãºltima associaÃ§Ã£o do TG principal ao promover produÃ§Ã£o. O TG ficava unused/Target.NotInUse enquanto o cÃ³digo esperava healthy antes de restaurar o listener. Manter regras de teste blue e green nos dois listeners resolve a ordem impossÃ­vel; cada amostra verifica blue HTTP/HTTPS. NÃ£o se alterou o deregistration delay principal.
- `LocalStackDeployment.converge`/`rollback`: sobrepor rolling UpdateService Ã  promoÃ§Ã£o deixou trÃªs tasks fÃ­sicas da mesma revisÃ£o para desiredCount=2. Foi observado nas APIs e Docker, nÃ£o confundido com parser/contador. A causa interna do scheduler proprietÃ¡rio nÃ£o foi afirmada. A convergÃªncia final agora esvazia/verifica o principal e inicia duas tasks da revisÃ£o aceita enquanto green atende.
- `CODEBUILD_BUILD_ID` reservado do agente Ã© placeholder; o vÃ­nculo real Ã© aÃ§Ã£o/API/build/artifact nativos. Labels Docker customizadas foram omitidas pelo executor; ownership usa group/cluster/definition/task e prefixo exato. OperaÃ§Ãµes AWS bem-sucedidas sem stdout retornam objeto vazio; JSON nÃ£o vazio invÃ¡lido continua recusado.
- A retirada recaptura tasks apÃ³s desiredCount=0 e antes de apagar registros, para nÃ£o omitir uma startup que termine durante cleanup. A comparaÃ§Ã£o canÃ´nica evita UpdatePipeline sem mudanÃ§a e perda desnecessÃ¡ria de consultas histÃ³ricas.
- `Get-CodeBuildStartTime`: converter o double JSON para string no PowerShell 7 arredondava a fraÃ§Ã£o do epoch. O caminho numÃ©rico preserva o valor; ISO, texto numÃ©rico e entradas invÃ¡lidas tambÃ©m foram testados. Ã‰ diagnÃ³stico, sem alteraÃ§Ã£o de Source/deploy.

As regressÃµes relevantes foram vistas falhar antes das correÃ§Ãµes e passar depois. As tentativas falhas permanecem sem aprovaÃ§Ã£o em suas APIs/recibos; recuperaÃ§Ãµes administrativas nÃ£o foram contadas como entregas.

### Resultado histÃ³rico anterior Ã  revisÃ£o final

Duas entregas nativas consecutivas com a convergÃªncia 0â†’2 passaram: `3da7a16d-8987-4cbf-949e-99719808b810` (bake 72,529 s) e `7a77b36e-d308-437f-9bdf-72844efd4bc1` (76,115 s), ambas com Source/Build/Deploy e dois CodeBuilds aprovados, test-cicd HTTPS/CRUD/digest, final 2/2 e cleanup/lock ausente. Processo Windows exit 0, 1147,17 s para o bloco das duas entregas, sem recuperaÃ§Ã£o entre elas. RejeiÃ§Ã£o `658bbdc4...` e rollback `de4b471a...` passaram como controles negativos antes desse refinamento; os caminhos exercitados foram comparados idÃªnticos, e essa ordem estÃ¡ explicitada. NÃ£o se afirma que executaram novamente o Source refinado. Resultados completos em [EVIDENCE-BLUE-GREEN-ADAPTER.json](EVIDENCE-BLUE-GREEN-ADAPTER.json). As evidÃªncias histÃ³ricas nativas/manuais continuam separadas.

### Escopo preservado, simplificaÃ§Ã£o e limites

UI/CRUD, RDS/Secrets, rede, ECS/EC2 conceptual/bridge, TG ip local, ALB/ACM e gateway TLS existentes foram preservados. A imagem recebe uma identidade pÃºblica de build, sem mudanÃ§a visual. Source contÃ©m somente inputs autorizados; controles do adaptador entram por artifact, sem expor configuraÃ§Ã£o pessoal. A arquitetura mantÃ©m o conceito do vÃ­deo, acrescentando identidade verificÃ¡vel, testes negativos e limites explÃ­citos da emulaÃ§Ã£o. Desvio deliberado: Source S3 e adaptador local; CodeConnections/controlador AWS continuam o alvo.

PERSISTENCE=0 + bind novo por sessÃ£o continua adequado ao laboratÃ³rio descartÃ¡vel e ao executor CodeBuild. NÃ£o Ã© backup ou durabilidade RDS. O teste nÃ£o elimina problemas de conectividade, tags mÃ³veis, scheduler ou metadata stale do fornecedor. AWS real, EC2/ASG, TG instance, CodeConnections, migraÃ§Ãµes incompatÃ­veis de banco, CloudFront e Q/MCP nÃ£o foram executados nesta entrega. DÃ­vida global de formataÃ§Ã£o e advisory de dependÃªncias de teste nÃ£o foram escondidos nem corrigidos em massa.

As operaÃ§Ãµes administrativas foram direcionadas, nÃ£o resetaram a base nem forÃ§aram status de sucesso. Docker Ã© limpo depois das provas, preservando somente o runtime atual e as imagens oficiais necessÃ¡rias Ã  pipeline.

### VALIDADO POR MIM nesta entrega

- Windows PowerShell 5.1: 41 scripts pelo parser, 56 regressÃµes isoladas; npm verify com lint, API7/frontend4/Node34 e TypeScript/Vite, exit0.
- Linux: npm ci e verify completos exit0; PowerShell7 56 regressÃµes; 39 blocos PowerShell da documentaÃ§Ã£o analisados, sem executar seus comandos. A primeira tentativa Linux sem dependÃªncias falhou por ESLint ausente; foi resolvida por npm ci, nÃ£o por ignorar lint.
- Dois ciclos positivos nativos consecutivos: build/push/artifacts reais, isolamento/CRUD, promoÃ§Ã£o HTTP/HTTPS, bake 2+2, convergÃªncia0â†’2, digest/revisÃ£o/container fÃ­sicos e cleanup. Controles negativos e recuperaÃ§Ãµes administrativas separados conforme acima.
- JSON/YAML, trÃªs buildspecs e seus gates, referÃªncias/caminhos e seleÃ§Ã£o do contexto Docker; Source da revisÃ£o refinada comparado em memÃ³ria com token e senha ativos: zero matches, sem exibir valores.

### NÃƒO VALIDADO nesta entrega

Controlador AWS nativo, deploy numa conta AWS real, hosts EC2/ASG, TG instance, CodeConnections, migraÃ§Ãµes incompatÃ­veis de banco, CloudFront e Q/MCP. Format:check global nÃ£o foi aprovado; advisory de dependÃªncias de teste permanece como dÃ­vida documentada. A varredura do ZIP e das camadas da imagem corrente Ã© registrada separadamente da homologaÃ§Ã£o funcional.

## 19. RevisÃ£o final e caminhos de erro

A revisÃ£o independente do diff completo encontrou cinco problemas de impacto relevante em `LocalStackDeployment`, reproduzidos com IO isolado sem mutar o laboratÃ³rio. NÃ£o considerou o branch pronto para merge. A implementaÃ§Ã£o tratou os cinco na Ãºnica rodada de correÃ§Ã£o, com testes REDâ†’GREEN; nÃ£o houve segunda revisÃ£o.

| Causa comprovada                                                                                        | CorreÃ§Ã£o                                                                                                |
| ------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Rollback podia zerar o principal que jÃ¡ respondia Ã  release green, com defaults ainda no TG principal | Restabelecer e conferir HTTP/HTTPS no TG da candidata antes de qualquer retirement.                       |
| `canonicalChanged` era definido antes de mutar o principal                                              | Definir imediatamente antes do primeiro UpdateService mutante; falha anterior recupera blue intacta.      |
| Body HTTP truncado apÃ³s headers podia deixar a Promise pendente                                        | Tratar aborted/error/close incompleto e usar deadline total de oito segundos, removido ao terminar.       |
| Erro no primeiro listener impedia tentar o segundo                                                      | Tentar as duas restauraÃ§Ãµes e ler as aÃ§Ãµes antes de aprovar recuperaÃ§Ã£o.                            |
| CreateRule aplicado com resposta perdida deixava regra fora do ledger e falso cleanup                   | Reconciliar listener/prioridade/cabeÃ§alho/TG exatos e verificar regras nÃ£o presentes no ledger de ARNs. |

A lacuna de `canonicalRetirement` no aceite foi elevada de minor para importante: uma evidÃªncia sem a fronteira vazia nÃ£o deve aprovar o ciclo anunciado. Seis regressÃµes de recibo foram observadas falhando antes e passando depois. Oito regressÃµes Node iniciais reproduziram as falhas e um caso adicional cobriu inventÃ¡rio indisponÃ­vel antes de cleanup. O conjunto dessa revisÃ£o tinha 31 testes Node e 56 regressÃµes PowerShell; Linux e Windows `npm run verify` terminaram exit0. Windows: parser41 e processo20232 exit0,136,28s. A compatibilidade posterior da imagem inicial adicionou trÃªs testes, totalizando 34, com uma nova verificaÃ§Ã£o Windows17916 exit0,89,17s. Os testes isolados de falhas de fronteira nÃ£o sÃ£o descritos como execuÃ§Ãµes nativas injetadas.

**Minor adiado:** acrescentar contexto seguro de operaÃ§Ã£o/fase, recovery code, execuÃ§Ã£o e journal ao console. O journal atual continua disponÃ­vel; erros brutos do provider e credenciais nÃ£o sÃ£o exibidos.

A varredura preliminar comparou o token e a senha ativos apenas em memÃ³ria no LocalStack contra Source37 arquivos, ZIP114 e dez camadas da imagem (188.427.746 bytes descomprimidos): zero matches. O scanner externo inicialmente falhou ao fechar um stream OCI pequeno antes da comparaÃ§Ã£o; a falha foi reproduzida, corrigida e a varredura completa repetida com exit0. Essa prova tem o Source/ZIP histÃ³rico exato registrado; nÃ£o substitui a varredura final depois da publicaÃ§Ã£o.

## 20. Compatibilidade com a imagem inicial do laboratÃ³rio

`Dockerfile` define `APP_RELEASE=local`; `push-ecr-image.ps1` constrÃ³i sem alterar esse argumento. O novo `LocalStackDeployment.application()` aceitava JSON apenas com UUID de pipeline e rejeitava a primeira imagem com `APP_RELEASE_INVALID`. A condiÃ§Ã£o foi corrigida para aceitar exatamente `local` ou uma release de pipeline estruturalmente vÃ¡lida. `readImageDefinition()` continua exigindo tag UUID v4, e `validateCandidate()` compara a release servida ao artifact exato: `local` nÃ£o aprova uma candidata.

A regressÃ£o observou RED (34 testes, 32 aprovados e 2 falhos) antes da correÃ§Ã£o; depois `npm run verify` passou com 34 testes do controlador, 7 API e 4 frontend. Windows17916 exit0,89,17s: parser41, regressÃµes56 e verify completo. Linux verify exit0 e PowerShell7 parser41/regressÃµes56.

Uma imagem realmente construÃ­da sem APP_RELEASE foi publicada no ECR e executada em duas tasks ECS Docker isoladas. O adaptador leu health/banco, tarefas, frontend, bundle e release `local` reais nas duas rÃ©plicas; o digest e label OCI foram conferidos. Tasks, imagens e definiÃ§Ã£o do serviÃ§o principal ficaram idÃªnticos antes/depois. ServiÃ§o, definiÃ§Ã£o, containers e logs temporÃ¡rios foram removidos. Windows19316 exit0,70,49s tambÃ©m executou test-cicd no principal e deixou trÃªs containers saudÃ¡veis. Isso nÃ£o afirma que uma reconstruÃ§Ã£o fria inteira ou uma primeira pipeline partindo dessa imagem foi executada.

O primeiro operador de investigaÃ§Ã£o foi interrompido ao redirecionar stderr Docker no PowerShell com ErrorActionPreference=Stop. Era o operador descartÃ¡vel, nÃ£o uma entrega nativa; a captura seguinte tratou stdout/stderr e exit code fora desse modo e executou a prova completa. Nenhum erro desse operador foi convertido em sucesso.

## 21. DecisÃµes de escopo, motivos e custos

| DecisÃ£o                                                                     | Motivo                                                                                 | Custo ou limite se a premissa falhar                                                        |
| ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Dois serviÃ§os ECS independentes na janela Blue/Green                        | Os task sets/controladores nativos testados nÃ£o executaram o isolamento exigido       | Ã‰ adaptaÃ§Ã£o de laboratÃ³rio; nÃ£o homologa o controlador AWS.                            |
| Rolling padrÃ£o e BlueGreen explÃ­cito, com deploy dentro do CodeBuild       | Preservar etapa 8 e orquestraÃ§Ã£o nativa sem uma coleÃ§Ã£o de recuperaÃ§Ã£o           | Aceite precisa conferir modo, aÃ§Ã£o e recibo vinculados.                                   |
| release.json pÃºblico e bundle, sem alterar UI                               | Identificar a versÃ£o que atende por HTTP/HTTPS                                        | Imagem legacy sÃ³ usa bootstrap estritamente conferido; nenhum candidato sem release exata. |
| Um BuildOutput com imagem, deployspec e controlador                          | Evitar ambiguidade de sources secundÃ¡rios na emulaÃ§Ã£o                               | Inputs novos exigem revisÃ£o da allowlist e do artifact.                                    |
| ID reservado do agente apenas informativo                                    | A API/build/artifact nativos fornecem o vÃ­nculo verdadeiro                            | Nunca escolher latest build ou placeholder para aprovar.                                    |
| Ownership por group/cluster/definition/task e prefixo Docker exato           | Labels customizadas nÃ£o foram preservadas pelo executor                               | Ambiguidade de identidade Ã© recusada; nÃ£o hÃ¡ exclusÃ£o de container desconhecido.        |
| Resposta AWS vazia exit0 vira objeto vazio                                   | Algumas operaÃ§Ãµes legÃ­timas nÃ£o tÃªm payload                                       | JSON nÃ£o vazio invÃ¡lido permanece erro.                                                   |
| Recapturar tasks e exigir quiescÃªncia antes de cleanup                      | Uma startup pode terminar durante retirada                                             | Custo de duas amostras; falha preserva recursos e lock.                                     |
| Quatro rotas temporÃ¡rias, blue e green em HTTP/HTTPS                        | Evitar TG principal Target.NotInUse durante promoÃ§Ã£o                                 | Prioridades ocupadas bloqueiam o deploy; cabeÃ§alhos nÃ£o sÃ£o autenticaÃ§Ã£o.              |
| ConvergÃªncia canÃ´nica verificada de 0â†’2 enquanto green atende            | Evitar rolling sobreposto que deixou trÃªs tasks no executor                           | Blue original Ã© aposentado sÃ³ depois do bake; ciclo especÃ­fico do laboratÃ³rio.          |
| EvidÃªncia canonicalRetirement obrigatÃ³ria, lacuna elevada a importante     | Provar a fronteira fÃ­sica anunciada                                                   | Recibos antigos sem essa prova nÃ£o passam no aceite atual.                                 |
| Corrigir as cinco falhas da revisÃ£o e nÃ£o fazer segunda rodada de revisÃ£o | RegressÃµes reproduziram rotas, flags, deadline, listeners e resposta de regra perdida | As injeÃ§Ãµes isoladas nÃ£o homologam essas falhas ao vivo no emulador.                     |
| AWS real/IAM produtivo/controlador nativo fora desta homologaÃ§Ã£o           | LaboratÃ³rio privado sem execuÃ§Ã£o AWS autorizada                                     | EvidÃªncia local nÃ£o aprova produÃ§Ã£o AWS.                                                |
| Manter Source footprints histÃ³ricos exatos                                  | MudanÃ§as nÃ£o reescrevem execuÃ§Ãµes anteriores                                       | Caminhos alterados exigem nova prova; resultados antigos nÃ£o viram runs atuais.            |
| SeguranÃ§a e CI finais independentes da opiniÃ£o do reviewer                 | Evitar aprovaÃ§Ã£o por inferÃªncia                                                     | PublicaÃ§Ã£o exige comparaÃ§Ã£o real de bytes e checks do commit correto.                   |
| Repetir qualidade em Windows/Linux apÃ³s as correÃ§Ãµes                      | O reviewer executou somente a suite Node                                               | RegressÃµes de plataforma continuam limite de testes que nÃ£o executamos.                   |
| Adiar formataÃ§Ã£o global, advisory de testes, tags mÃ³veis e etapas futuras | NÃ£o expandir a correÃ§Ã£o Blue/Green para outro roadmap                               | DÃ­vida permanece explÃ­cita; nenhuma aprovaÃ§Ã£o de format:check global.                   |
| Source privado/confiÃ¡vel e APIs nativas como modelo de confianÃ§a           | O laboratÃ³rio compartilha socket Docker                                               | Um ator hostil com o socket pode invalidar as garantias; nÃ£o Ã© multi tenant.              |
| Publicar e integrar na main pela autorizaÃ§Ã£o anterior                      | O usuÃ¡rio jÃ¡ solicitou autonomia de publicaÃ§Ã£o                                     | Exigir head exato e CI verde; autorizaÃ§Ã£o nÃ£o Ã© presumida para outro repositÃ³rio.      |
| Aceitar `local` somente como identidade inicial compatÃ­vel                  | Bootstrap padrÃ£o do Dockerfile Ã© vÃ¡lido                                             | Uma candidata `local` continua rejeitada pela release/artifact exatos.                      |
| Repetir pipeline inteira em uma execuÃ§Ã£o distinta apÃ³s INSTALL ECONNRESET | Fase/cÃ³digo exatos mostram falha antes dos testes/deploy; Source idÃªntico jÃ¡ passou | A falha original permanece reprovada e conectividade permanente nÃ£o Ã© certificada.        |

**Minor adiado:** contexto seguro de operaÃ§Ã£o/fase/recovery-code/execuÃ§Ã£o/journal no console. O journal atual fornece diagnÃ³stico; nÃ£o exibir erro bruto do provider. O custo Ã© investigar alguns erros pelo journal em vez de apenas pelo console.

## 22. Provas do Source final e falha externa registrada

Source SHA256 `bb052c1f7bb8c6e5678f60ccede6a555eab45d918738ecf9639b61af3249e330`: duas entregas consecutivas `e1df4102...` e `6a6da575...` passaram Source/build/deploy, artifacts/recibo/digest, bake64,005/75,995s e test-cicd HTTPS/CRUD, sem reset/recuperaÃ§Ã£o entre elas. RejeiÃ§Ã£o `d98e462b...` e rollback `04028128...` foram executados nesse mesmo Source final e comprovaram as mesmas identidades blue e metadata saudÃ¡vel, HTTPS/CRUD e cleanup/lock; continuam Failed/FAILED nas APIs.

O bloco Windows18396 terminou exit1,2202,47s porque a tentativa normal final `fa681b24...`, build5b259ccc, recebeu `npm ECONNRESET` em INSTALL. DOWNLOAD_SOURCE tinha passado; nenhum teste/deploy/recibo foi iniciado. Todos os OOMKilled eram false; exit137 de filhos durante encerramento nÃ£o foi chamado de OOM. Uma classificaÃ§Ã£o inicial ampla de texto foi substituÃ­da pela fase/cÃ³digo exatos, sem publicar logs brutos. A tentativa falha foi preservada; repetir em uma execuÃ§Ã£o nova nÃ£o a aprova e nÃ£o afirma que a conectividade foi corrigida permanentemente.

A execuÃ§Ã£o normal distinta `1ce971ba-8851-4ba8-aced-e0df1470c462` passou Source/build/deploy, os dois CodeBuilds, bake61,348s, convergÃªncia para cloudtasks:16, digest ECR/containers, HTTPS/CRUD e test-cicd. Processo17224 exit0,646,47s; cleanup deixou LocalStack e duas tasks atuais saudÃ¡veis, sem recursos green ou lock. Source/cÃ³digo permaneceram iguais; `fa681b24` continua falha.

O CI do cÃ³digo final `0bcb8ad56a945a7620e28c3c36813522c7c8ca73`, run37227517503, aprovou todos os passos de qualidade/Docker no Ubuntu e parser/regressÃµes PowerShell5.1 no Windows. O CI da documentaÃ§Ã£o final/merge permanece associado aos seus commits prÃ³prios no GitHub; nÃ£o embutir um SHA autorreferente no pacote.

## 23. Varredura do pacote e imagem corrente

O Source final37 arquivos, projeto completo114 arquivos e imagem aceita na execuÃ§Ã£o1ce971ba foram comparados ao token LocalStack e senha RDS ativos apenas em memÃ³ria no LocalStack: zero matches; valores nÃ£o foram exibidos. A imagem corrente `fad7dde...` teve todas as dez camadas salvas comparadas,188.427.746 bytes descomprimidos. ZIP: CRC, allowlist, exclusÃ£o de paths pessoais e uma Ãºnica raiz cloudtasks-aws. Windows13892 exit0,27,78s.

O hash exato do arquivo final fica fora do prÃ³prio arquivo para evitar autorreferÃªncia; os bytes finais sÃ£o varridos novamente apÃ³s esta evidÃªncia. NÃ£o se afirma varredura exaustiva de todo o histÃ³rico Git, ausÃªncia de toda vulnerabilidade ou rotaÃ§Ã£o de credenciais. ConfiguraÃ§Ã£o pessoal e banco da sessÃ£o sÃ£o preservados fora do pacote.

As seis versÃµes Source finais â€” trÃªs positivas, dois controles negativos e a tentativa npm reprovada â€” foram comparadas ao SHA bb052 e Ã s credenciais ativas em memÃ³ria:37 arquivos autorizados por versÃ£o, CRC e zero matches; Windows2220 exit0,9,43s.

Limpeza final Windows16328 exit0,26,81s: sÃ³ trÃªs containers saudÃ¡veis, LocalStack e as duas tasks atuais. Runners/recursos descartÃ¡veis foram removidos apÃ³s cada ciclo; caches/build history, volumes e redes sem uso foram podados no encerramento. Imagens oficiais necessÃ¡rias Ã  pipeline e imagem atual foram preservadas. O registro CodeBuild antigo3150e0db ainda IN_PROGRESS na API Ã© correlacionado Ã  pipeline Stopped/aÃ§Ã£o Failed, sem runner fÃ­sico, e permanece CANCELLED_NOT_APPROVED; seu status nÃ£o foi alterado. Nenhuma sessÃ£o/banco saudÃ¡vel foi resetada para esconder esse registro.

## 24. ReconstruÃ§Ã£o fria e corrida de schema â€” histÃ³rico 1.8.1 e resoluÃ§Ã£o

A prova adicional comeÃ§ou apÃ³s a entrega1.8.0, preservando seu histÃ³rico. A primeira sessÃ£o realmente vazia passou no start e em nove APIs vazias, mas o bootstrap oficial falhou em `create-ecs.ps1:529`, com apenas uma task RUNNING. O Docker comprovou a causa na aplicaÃ§Ã£o: `ensureSchema()` (`apps/api/src/db.ts`), chamado por cada `server.ts` antes do listen, executava DDL simultÃ¢neo. PostgreSQL23505 em `pg_type_typname_nsp_index` encerrou uma startup. Tasks de reposiÃ§Ã£o posteriores saudÃ¡veis nÃ£o aprovam essa execuÃ§Ã£o.

Em schema isolado no PostgreSQL real, oito rodadas de duas inicializaÃ§Ãµes reproduziram quatro falhas de catÃ¡logo. Sete regressÃµes unitÃ¡rias falharam no cÃ³digo antigo. A correÃ§Ã£o mÃ­nima usa um Ãºnico client, BEGIN, advisory lock transacional, DDL original e COMMIT. Rollback propaga o erro original; falha de rollback descarta a conexÃ£o. Depois:16 inicializaÃ§Ãµes reais sem falha e sete regressÃµes GREEN, sem tocar a tabela da aplicaÃ§Ã£o. Linux e Windows verify passaram com API14/frontend4/Node34; parser41/regressÃµes56 em ambas as plataformas. O ensaio real carregou o mÃ³dulo compilado novo separadamente, nÃ£o substituiu o servidor produtivo da sessÃ£o antiga.

A segunda sessÃ£o vazia1.8.1 falhou **antes do ECS**: o provider instalou PostgreSQL17.11 e apt retornou100; dpkg reportou `Cannot allocate memory` ao ler o arquivo para descompactaÃ§Ã£o, seguido de erro lzma/EOF. Container OOMKilled=false e cgroup oom/oom_kill=0; Docker VM4048142336bytes. NÃ£o se afirma OOMKill, falha TLS ou pacote corrompido. O pacote16667232bytes foi conferido contra SHA256 do apt; descompactaÃ§Ãµes padrÃ£o/uma thread/padrÃ£o passaram. A hipÃ³tese de limitar threads nÃ£o foi confirmada e nÃ£o gerou alteraÃ§Ã£o de Compose/RAM. A causa interna permanente desse erro do provider nÃ£o foi demonstrada.

`RDS_PG_CUSTOM_VERSIONS=0` seleciona o padrÃ£o do fornecedor; nÃ£o garante engine16 executÃ¡vel nem ausÃªncia de instalaÃ§Ã£o. A documentaÃ§Ã£o e a mensagem de console foram corrigidas para nÃ£o declarar o contrÃ¡rio. A versÃ£o efetiva ainda deve ser consultada por SQL. NÃ£o foi adicionada recuperaÃ§Ã£o, prÃ©-criaÃ§Ã£o manual de tabela ou dependÃªncia.

A terceira tentativa distinta passou start e nove APIs vazias, mas o Desktop Commander ficou offline durante `resume-environment.ps1`. Esse foi o Ãºltimo estado observado em 04/10. Na reconexÃ£o de 08/10, as sete etapas preservadas foram lidas: stop, start, bootstrap e quatro testes tiveram exit code 0. As duas entregas nativas foram executadas depois em uma nova sessÃ£o, com Source SHA35a82a, CodeBuilds e artifacts vinculados, bake2+2, convergÃªncia e cleanup/lock conferidos. As tentativas anteriores falhas continuam reprovadas. [Registro atualizado](EVIDENCE-BIA-20261008.json). [EvidÃªncia, identidades e pendÃªncias](EVIDENCE-COLD-REBUILD.json).

**Estado histÃ³rico ao perder a conexÃ£o em 04/10:** correÃ§Ã£o/REDâ†’GREEN, concorrÃªncia real isolada, lint/testes/TypeScript e parser/regressÃµes estavam validados. O resultado da terceira tentativa, bootstrap e testes completos, duas entregas nativas, varreduras e publicaÃ§Ã£o ainda estavam pendentes naquela observaÃ§Ã£o. A reconexÃ£o de 08/10 resolveu esses registros de execuÃ§Ã£o conforme o parÃ¡grafo anterior e a seÃ§Ã£o 25; nÃ£o converte as tentativas falhas em aprovaÃ§Ãµes. A mensagem de console e esta documentaÃ§Ã£o ainda nÃ£o haviam sido sincronizadas ao Windows naquela perda de conexÃ£o.

## 25. Alinhamento BIA e acesso real pelo ALB â€” 1.8.2

A [matriz V01-V12](REFERENCE-VIDEO.md) mantÃ©m AWS real, GitHub/CodeBuild/ECS padrÃ£o, ECS/EC2, ALB/TG por instÃ¢ncia, CloudFront e Q/MCP no escopo obrigatÃ³rio. A aplicaÃ§Ã£o recebeu layout/textos BIA, tema persistente, prazo textual, prioridade editÃ¡vel e indicador baseado em saÃºde da API/banco. A migraÃ§Ã£o adiciona TEXT sem retirar DATE; o trigger compatibiliza atualizaÃ§Ãµes legadas. Updates parciais atÃ´micos e bloqueio de operaÃ§Ãµes pendentes protegem mudanÃ§as concorrentes.

CI executou 69 testes, incluindo 5 integraÃ§Ãµes PostgreSQL, Docker e regressÃµes PowerShell5.1. A aplicaÃ§Ã£o foi aplicada no Windows apÃ³s comparaÃ§Ã£o dos Git blobs e backup. Uma entrega nativa BIA e sete checks no banco real passaram na primeira sessÃ£o. A verificaÃ§Ã£o pelo navegador revelou a tela vazia: assets respondiam200 sem Origin e403 com a prÃ³pria origem do ALB. O health/CRUD nativo nÃ£o havia detectado essa fronteira.

O Compose recebeu apenas duas origens adicionais (HTTP/HTTPS do ALB do projeto). Antes de reconstruir LocalStack, foram guardados banco e nove ZIPs nativos com hashes conferidos; os ZIPs foram comparados Ã s credenciais ativas em memÃ³ria. O ECS foi esvaziado e o fingerprint do banco reconferido. O provider PostgreSQL exigiu duas rotaÃ§Ãµes de namespace durante a instalaÃ§Ã£o. A primeira restauraÃ§Ã£o foi revertida por colisÃ£o dos schemas padrÃ£o AWS; a restauraÃ§Ã£o completa em transaÃ§Ã£o no banco novo repÃ´s somente objetos do arquivo e conferiu o fingerprint antes do ECS.

Os testes oficiais ECS/ALB/HTTPS passaram, e o navegador exibiu BIA com saÃºde online em desktop/celular. As duas origens prÃ³prias respondem200, enquanto uma origem externa Ã© rejeitada403. Assets304 de navegaÃ§Ã£o com cache sÃ£o respostas vÃ¡lidas; o probe sem cache confirmou200. O conteÃºdo da rota Sobre a BIA nÃ£o foi mostrado no vÃ­deo e continua nÃ£o verificado como original.

A primeira pipeline dessa sessÃ£o, dada3b9a, passou Source/Build, bake e CANONICAL_VERIFIED, mas terminou FAILED/RECOVERY_REQUIRED em uma chamada AWS durante cleanup. NÃ£o foi homologada. O recibo e os recursos retidos foram examinados; a recuperaÃ§Ã£o manual reutilizou a limpeza do adaptador depois de conferir principal2/2, rotas e ownership. A pipeline continuou Failed, e o lock sÃ³ foi retirado apÃ³s cleanup conferido. A causa permanente do erro genÃ©rico AWS_COMMAND_FAILED nÃ£o foi demonstrada; leituras pela mesma AWSCLI do runner passaram depois.

As trÃªs imagens anteriores tiveram as 30 camadas gzip descomprimidas e comparadas Ã s credenciais da nova sessÃ£o: zero matches. Essa comparaÃ§Ã£o nÃ£o reavaliou a senha histÃ³rica do banco jÃ¡ substituÃ­do. As varreduras dos nove ZIPs haviam usado as credenciais entÃ£o ativas antes da troca. [Identidades, resultados finais e limites](EVIDENCE-BIA-20261008.json).

A segunda tentativa Blue/Green da sessÃ£o CORS, `f3612059-310b-4963-a96d-78e8e1359d9a`, falhou depois de TRAFFIC_PROMOTED e antes do bake, com AWS_COMMAND_FAILED. O recibo Ã© ROLLED_BACK: ambas as rotas voltaram a blue, duas rÃ©plicas saudÃ¡veis foram preservadas e os seis checks de limpeza automÃ¡tica passaram. O lock foi conferido ausente. A causa permanente nÃ£o foi demonstrada; nÃ£o se atribui essa segunda falha ao cleanup da primeira.

Para conferir o mecanismo mostrado no vÃ­deo, uma execuÃ§Ã£o nativa distinta usou o modo Rolling e a aÃ§Ã£o ECS padrÃ£o: `ae3eeaa9-8a5a-4bd8-b2bb-16c04d67a0e1`. Source, Build e Deploy terminaram Succeeded; o CodeBuild vinculado `cloudtasks-build:1591ca0a` terminou SUCCEEDED. Source VersionId `AaEcKf_I25Lcws0evTQ9C7w8oNRwgjZU` e SHA256 `f10dc20daf01853eb2ef0e8567f42aded0fd6454167bb96a21f94176d0d1a6ac` identificam o cÃ³digo executado. A imagem `sha256:6949752ca2cf5963f7361e98dcfd57c5bee46be8e92c3ff95a12e604e90cf902` pertence Ã  release `pipeline-9a523db2-ed39-4b3a-8a3d-23410e9dab33`, task definition `cloudtasks:3`, com duas rÃ©plicas fÃ­sicas saudÃ¡veis. `test-cicd.ps1` passou sem fallback externo. os metadados sÃ£o locais, nÃ£o prova de Source GitHub ou infraestrutura AWS real.

Depois dessa entrega, sete verificaÃ§Ãµes foram repetidas no PostgreSQL17.11 compartilhado pelas duas rÃ©plicas, incluindo texto/timestamp/ISO/null, trigger legado e updates independentes concorrentes. O navegador Edge exercitou pelo ALB criaÃ§Ã£o, prioridade por estrela e duplo clique, conclusÃ£o, ediÃ§Ã£o, recarga e exclusÃ£o. As tarefas criadas para os testes foram removidas, sem tocar outras tarefas. Desktop/celular e navegaÃ§Ã£o passaram, sem pageErrors; origens prÃ³prias200 e externa403.

A imagem final teve as dez camadas gzip descomprimidas, config e identidade OCI verificadas e varredura contra senha atual/licenÃ§a em memÃ³ria: zero matches. Os ZIPs Source e Build exatos da execuÃ§Ã£o aprovada passaram CRC/leitura, hashes e a mesma comparaÃ§Ã£o em memÃ³ria; as cÃ³pias preservadas tiveram hashes reconferidos. Isso nÃ£o revalida senhas de sessÃµes histÃ³ricas. As falhas Blue/Green continuam reprovadas; a entrega ECS padrÃ£o aprovada nÃ£o homologa o adaptador na sessÃ£o nova. A revisÃ£o original, telas/fluxos ocultos e os itens AWS da matriz continuam pendentes para a equivalÃªncia integral.
