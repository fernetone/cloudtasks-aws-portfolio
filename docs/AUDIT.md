# CloudTasks — auditoria técnica e entrega 1.7.4

Atualização: 03/10/2026. Base auditada: projeto 1.7.0. Parecer: **preservar a arquitetura, corrigir o verificador e exigir CI/CD nativo; etapa 8 homologada no laboratório em 03/10/2026, com evidências na seção 16.**

Os bloqueios iniciais de consulta Docker e empacotamento ZIP foram corrigidos no projeto. A execução subsequente concluiu Source e expôs falhas no monitor/wrapper do executor CodeBuild. O diagnóstico dessa execução, a compatibilidade com IDs curtos e os limites da mitigação estão na seção 13.

**Como ler o histórico:** as seções 1–14 registram o diagnóstico e as validações disponíveis em cada entrega anterior. Referências a etapa pendente, contagens antigas ou derivação da tag pelo ID descrevem aquele momento. A implementação final está na seção 15 e a homologação concluída, na seção 16. Para operação atual, consulte [PIPELINE.md](PIPELINE.md).

A leitura do projeto e o diagnóstico precederam as modificações. O original permanece intacto. A entrega modifica uma cópia e exclui a credencial pessoal que estava no ZIP recebido.

## 1. Material, método e limites

Foram examinados os dois ZIPs fornecidos, os 93 arquivos originais, aplicação, testes, manifests, Docker/Compose, workflow GitHub, buildspecs, 37 scripts PowerShell e documentação. O segundo ZIP tem organização externa diferente, mas os mesmos 93 conteúdos; não contém uma revisão nova do `create-cicd.ps1`.

| Material                   | Identidade                                                                                                             |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| ZIP inicialmente fornecido | SHA256 `3ebf38deafe1b491f25fa588632108e89327fc5cedad398f655fe5f177c49bea`                                              |
| ZIP mais recente fornecido | SHA256 `9658cdf9c87b1857879dd36226edcf25f8725f20164a53d06703ebe1d3f7e7f8`                                              |
| `create-cicd.ps1` original | SHA256 `d575e73aa5158f97c74156c09c394117e66aac9fe8bb971fb5436b220d00f1bd` — corresponde ao hash apresentado no Windows |
| Vídeo original             | Aproximadamente 57,6 s, 720 × 1600; quadros distribuídos por todo o recorte                                            |
| PowerShell                 | Transcript enviado e resultados subsequentes, inclusive o preflight de 01/10 com sessão igual e `DockerExit=-1`        |

A análise do vídeo usa telas e legendas visualmente legíveis; não foi produzida transcrição do áudio. O recorte não é uma auditoria do repositório/configuração completa do autor. Até a entrega 1.7.2, a execução própria ocorreu em Linux. Em 02/10/2026, iniciou-se a homologação remota autorizada no Windows/LocalStack do responsável, registrada na seção 14. O histórico Git não acompanha o projeto.

Tipos de evidência usados neste relatório:

- **Código:** condição/responsabilidade encontrada no projeto original ou na implementação.
- **Transcript Windows:** resultado enviado pelo responsável.
- **Execução remota própria:** operação efetivamente executada na máquina do laboratório, quando indicada nas seções 14–16.
- **Teste isolado executado:** processo nativo e fixtures sintéticas em Linux/PowerShell 7 ou Windows/PowerShell 5.1, conforme identificado.
- **Documentado:** comportamento oficial do fornecedor.
- **Inferência/pendência:** conclusão que exige resposta do ambiente real para ser fechada.

## 2. Causa-raiz do bloqueio ECS inicial

### Ramo efetivamente recusado

A coleta mais recente mostra `SessaoIgual=True`, duas tasks consultadas, `DockerExit=-1`, uma linha para cada consulta e zero containers aceitos. A execução chegou ao bloco Docker; não parou na identidade da sessão. Não há justificativa para afirmar que o ECS realmente perdeu suas duas tasks.

No **arquivo original**, `Test-CicdEcsRuntimeReady` contém:

```powershell
$dockerId = @(& docker ps --filter "name=$taskId" --filter "status=running" --format "{{.ID}}" 2>$null | Select-Object -First 1)
$dockerExit = $LASTEXITCODE
# ...
if ($dockerExit -eq 0 -and $dockerId.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$dockerId[0])) {
    $dockerRuntimeCount++
}
```

| Referência original                          | Efeito                                                                                  |
| -------------------------------------------- | --------------------------------------------------------------------------------------- |
| `create-cicd.ps1`, linha 213                 | Liga o processo nativo ativo a `Select-Object -First 1`                                 |
| Linha 214                                    | Lê `$LASTEXITCODE` desse pipeline interrompível                                         |
| Linhas 220–221                               | Rejeita o ID quando o exit code não é zero; ambas as tasks foram rejeitadas com `-1`    |
| Linha 225                                    | Retorna falso porque aceitos=0, esperado=2                                              |
| `Ensure-CicdEcsRuntimeReady`, linhas 228–247 | Trata qualquer falso como runtime stale, chama resume e repete o mesmo teste defeituoso |
| Linha 243                                    | Lança a mensagem genérica de ausência de duas tasks Docker RUNNING                      |

A Microsoft documenta que `Select-Object` com `First`/`Index` interrompe o produtor assim que obtém a quantidade requerida. Portanto, ter recebido um ID não prova término normal de `docker.exe`. A consulta precisa terminar antes de filtrar e interpretar seu exit code. [Microsoft, Select-Object/PowerShell 5.1](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/select-object?view=powershell-5.1).

A explicação da contradição está no código: `status-ecs.ps1`, função `Get-TaskDockerRuntime` original (linha 42), também obtém a primeira linha, mas não aplica a mesma rejeição por exit code. `resume-environment.ps1`, `Test-EcsRuntimeReady` original (linha 101), conta IDs encontrados sem validar esse término. Status pode mostrar ECS RUNNING/Docker healthy enquanto o preflight aceita zero resultados.

`ecs-runtime-context.ps1` originalmente captura o `docker inspect` antes de selecionar a primeira linha. Essa seleção sobre saída já armazenada não é o defeito. O contexto relê os metadados e o CI/CD atualiza nomes; não foi encontrada prova de variável antiga em memória como causa desta execução. `create-ecs.ps1` conseguiu preparar o runtime; reconstruir novamente não corrige a consulta defeituosa do CI/CD.

### Prova executada e limite Windows

As funções originais foram extraídas pela AST, sem executar seu bootstrap, e chamadas com um processo externo Node que imprime um ID e só termina depois. No Linux/PowerShell 7, o pipeline original pode ler um exit code anterior/sem atualização: chegou a aceitar uma consulta cujo processo terminaria com código 7. Capturar toda a saída primeiro permite observar 7 e recusar corretamente.

Isso comprova o defeito de ordem/encerramento na fronteira nativa. O valor numérico `-1` específico foi **observado no Windows fornecido**, não reproduzido aqui. A combinação de comportamento documentado, condição original e ramo instrumentado explica a rejeição atual. Confirmar a correção nesse PowerShell 5.1 permanece parte da homologação.

A implementação **não ignora `$LASTEXITCODE`**. `Get-CloudTasksTaskDockerRuntime` captura o processo inteiro, guarda seu exit code e só depois interpreta linhas. Falha nativa, saída inválida, nenhum container ou resultado ambíguo continuam sendo recusados. CI/CD, resume, status, teste ECS e sincronização de targets reutilizam essa leitura.

### Problemas distintos no histórico

- Scripts desabilitados eram política do processo PowerShell, resolvida com `Set-ExecutionPolicy -Scope Process`; não eram falha ECS.
- A coleta anterior parou na linha 165, sem ID atual disponível. A sequência incluiu Docker Desktop/daemon indisponível e container LocalStack parado. Isso é um evento diferente do resultado atual, que confirmou sessão igual.
- Listagem ECR posterior e consulta exata retornaram o repositório `cloudtasks`, com exit 0 e parsing correto. A resposta da listagem no instante da criação anterior não está disponível: não é possível provar corrida, parsing ou outra causa histórica. Está provado o defeito de idempotência de tentar criar e abortar em `RepositoryAlreadyExistsException` sem verificar o recurso exato.
- O resume de 01/10 teve RDS `creating`, duas rotações e disponibilidade posterior. Tempo excedido não comprova recurso stale. A causa de provisioning lento não foi determinada por este material.

## 3. Arquitetura e comparação com o vídeo

| Componente         | AWS alvo                               | Laboratório                                           | Decisão                                              |
| ------------------ | -------------------------------------- | ----------------------------------------------------- | ---------------------------------------------------- |
| Aplicação          | React/Express/TypeScript/PostgreSQL    | Mesmo domínio CRUD; React servido pelo Express        | Preservar                                            |
| Source             | GitHub/CodeConnections                 | Snapshot permitido do working tree em S3 versionado   | Manter adaptação e identidade exata                  |
| Orquestração       | CodePipeline → CodeBuild → ECS padrão  | Mesmos serviços emulados, V1 executável               | Exigir fluxo nativo                                  |
| Build/registry     | Docker e ECR                           | Docker do host e ECR local                            | Preservar; lockfile e digest                         |
| Compute            | ECS/EC2, `bridge`, hostPort dinâmico   | Tasks Docker sem EC2 reais                            | Preservar diferença explícita                        |
| ALB/TG             | `instance`, instância/hostPort         | `ip`, IP Docker/3000                                  | Preservar adaptação                                  |
| RDS/Secrets        | Dados persistentes e secret de runtime | PostgreSQL executável e APIs locais                   | Preservar; sessão descartável não é durabilidade AWS |
| HTTPS/ACM          | ALB termina TLS com ACM                | Associação no control plane; TLS pelo gateway `:4566` | Preservar explicação                                 |
| Logs               | CloudWatch                             | `awslogs` e APIs locais já exercitados                | Preservar                                            |
| Etapas posteriores | Blue/Green, CloudFront, Q/MCP          | Ainda não entregues pelo projeto                      | Não antecipar                                        |

A [AWS documenta ECS/ALB](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/alb.html) com portas dinâmicas e registro instância/porta no desenho EC2/bridge; TG `ip` é requerido para `awsvpc`. O [executor ECS do LocalStack](https://docs.localstack.cloud/aws/services/ecs/) não cria capacidade EC2 real apenas porque a API apresenta `launchType=EC2`. Zero container instances registradas é esperado neste laboratório.

| Trecho do vídeo | Evidência visual                                           | Conclusão                                                                     |
| --------------- | ---------------------------------------------------------- | ----------------------------------------------------------------------------- |
| 0–2 s           | Build/CodeBuild e Deploy/ECS em verde                      | Entrega por serviços AWS é central                                            |
| 4–8 s           | Amazon Q CLI e MCP PostgreSQL                              | Q/MCP fazem parte da demonstração; permissões não são auditáveis pelo recorte |
| 10–18 s         | ALB HTTP/HTTPS e dois targets por instância/porta dinâmica | Compatível com ECS/EC2, duas réplicas e TG `instance`                         |
| 18–20 s         | Node/React e PostgreSQL                                    | Mesma categoria de aplicação                                                  |
| 22–32 s         | Distribuição CloudFront em estado `Disabled`               | Configuração existe; tráfego funcional pela CDN não é provado                 |
| 34–57 s         | Interface simples de tarefas BIA                           | CRUD é veículo da demonstração; CloudTasks não precisa copiar nome/interface  |

A fidelidade conceitual permanece. CloudTasks fornece evidência explícita de Zod, SQL parametrizado, testes, health com banco, não-root, graceful shutdown e documentação de paridade. Esses cuidados não são visíveis no vídeo; isso não prova que o projeto do autor não os tenha.

Desvios encontrados: recuperação acumulada no caminho de entrega, aprovação por fallback externo, seleção por tag mais recente e roadmap recebido com apenas 11 etapas/CI/CD na posição 7. A entrega remove a aprovação alternativa e restaura a sequência oficial de 13 etapas. A emulação continua sem provisionamento produtivo AWS completo: capacidade EC2/ASG, bootstrap, controles de rede/IAM e IaC precisariam ser concretizados para uma implantação real.

## 4. Organização e fluxo dos scripts

O original possui 37 PowerShells, aproximadamente 6.403 linhas e 22 wrappers `Invoke-AwsLocalJson`. A quantidade de arquivos não é, sozinha, o problema; os pontos frágeis são responsabilidades sobrepostas, leitura nativa divergente e recuperação no caminho normal.

| Grupo original      | Arquivos/responsabilidade                                                   |
| ------------------- | --------------------------------------------------------------------------- |
| Ciclo local         | start, stop, resume, update, change-token                                   |
| Contexto/manutenção | ecs/rds-runtime-context e repair-ecs/rds-runtime                            |
| Infraestrutura      | create-network/database/ecr/ecs/alb/https, push-ecr-image, sync-alb-targets |
| CI/CD               | publisher, create-cicd, status/test/diagnose-cicd, rollback operacional     |
| Estado/teste        | status/test por camada e validate-scripts                                   |
| Preparação          | prepare-repository fora do diretório localstack                             |

Fluxo normal corrigido: bootstrap explícito pelo resume quando necessário → sessão saudável → publisher → CodePipeline/CodeBuild → ECR → Deploy ECS nativo → sincronização IP/TG local → aceitação HTTPS/RDS. A sincronização local de IPs não substitui a ação ECS Deploy; ela adapta o balanceamento ao executor Docker.

Na entrega 1.7.1, `create-cicd.ps1` caiu de 1.233 para 684 linhas. Foram removidos os caminhos de CodeBuild direto, seleção de tags/runners novos e deploy externo para converter pipeline incompleta em sucesso. Na entrega 1.7.2 há preparação explícita de imagem e uma validação compatível com IDs curtos, descritas na seção 13. Não foram criados scripts novos de recuperação; os dois novos arquivos são regressões isoladas.

Os wrappers AWS continuam duplicados entre scripts. Consolidá-los em um módulo pequeno, com contrato de captura/JSON/redaction, é uma melhoria futura razoável. Uma migração ampla de módulos/framework de IaC nesta correção aumentaria o risco sem ser necessária para resolver o bloqueio comprovado.

## 5. Defeitos adicionais e tratamento

| Achado original                                                            | Solução ou limite                                                                          |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Qualquer falso do preflight aciona resume e perde a causa                  | Preflight informa motivo; não inicia/reset/repara ambiente                                 |
| Logs de runner podem sobrepor falha na API CodeBuild                       | Falha API/action reprova; sem aprovação por log                                            |
| Fallback termina ECS fora da pipeline e teste diz ponta a ponta            | Removido do fluxo e do critério; somente modo nativo aceito                                |
| Tag `pipeline-*` mais nova pode pertencer a outro build                    | Tag do ID exato do CodeBuild vinculado, URI/digest e tasks correlacionados                 |
| `HEAD` após upload/start sem revisão pode selecionar outro Source          | VersionId do PutObject, SHA256, revisão explícita e conferência da revisão consumida       |
| Contadores 2/2 não provam atualização de cada task                         | DescribeTasks, revisão/imagem de cada task, Docker health e RepoDigests                    |
| Listagem ECR seguida de criação não tolera AlreadyExists                   | Consulta exata por nome/conta/região; conflito é seguido de nova consulta/verificação      |
| Dependências sem lockfile/fallback npm install                             | Lockfile incluído; npm ci obrigatório em CI/buildspecs/Docker/preparação                   |
| Publisher exclui alguns nomes, mas admite runtime/certificados/credentials | Inputs positivos e bloqueio de credenciais ativas conhecidas                               |
| Docker COPY amplo com contexto incompletamente ignorado                    | Contexto positivo de inputs necessários, sem runtime/secrets/scripts/logs                  |
| Recursão de create-ecs não preserva ImageUriOverride                       | Argumento propagado em todos os retornos recursivos; caminho não usado como fallback CI/CD |
| change-token usa encoding não suportado no PS5.1                           | Escrita UTF8 via .NET compatível; valor não exibido                                        |
| Diagnósticos e exceções despejam argumentos/provider/logs brutos           | Operação/exit code e metadados, com erros JSON genéricos em caminhos sensíveis             |

Serialização usa lock local e recusa execução em andamento. CodePipeline V1 declara Source S3, CodeBuild e ECS; ambos os buildspecs produzem `imagedefinitions.json`. Um quality gate negativo deve interromper antes do push/deploy. [AWS ação ECS padrão](https://docs.aws.amazon.com/codepipeline/latest/userguide/action-reference-ECS.html), [revisões no StartPipelineExecution](https://docs.aws.amazon.com/codepipeline/latest/APIReference/API_StartPipelineExecution.html).

## 6. Segurança

**O ZIP original continha `.env.localstack` com credencial preenchida.** O valor não foi usado, testado quanto à validade ou reproduzido. Foi excluído da entrega. Se a credencial continua ativa e foi distribuída, revogar/substituir no provedor; o pacote novo não revoga o valor antigo.

Foi reproduzido vazamento de senha fictícia na exceção do wrapper RDS, que incluía `--master-user-password`. Também foram reproduzidas exceções de leitura de secret que ecoavam texto sensível do provider apesar de se denominarem “Safely”. Os testes passaram após retirar argumentos/respostas brutas e proteger parsing. Não se afirma que a senha real apareceu em um log histórico específico.

O publisher original, executado com upload simulado, incluía `localstack-volume/state.json`, `certificate.pem` e `secrets/credentials.txt`. Isso prova o defeito de seleção; não prova que esses arquivos estavam no S3 real. O publisher corrigido os exclui e bloqueia credenciais ativas conhecidas inseridas em código. Snapshot contém Dockerfile/ignore/manifests/config/código/testes, sem material de operação.

Git, Source S3, contexto Docker e ZIP são fronteiras independentes. `.gitignore` não remove arquivos já rastreados e não protege empacotamento manual. Foram adicionados runtime fallback e metadado de build ao ignore. Sem `.git`, não foi possível verificar histórico remoto nem demonstrar ausência histórica de secrets.

O Dockerfile permanece multi-stage e não-root. Contexto restrito reduz exposição inclusive em estágios/cache, e não apenas na imagem final. Não foi executado Docker aqui: a ausência de secrets nos layers da imagem real ainda deve ser confirmada no laboratório.

Logs do provider/env de containers podem conter credenciais injetadas em runtime. As ferramentas corrigidas evitam despejo automático, mas não “purificam” o armazenamento do provider. Temporários possuem limpeza em `finally`; interrupções abruptas e permissões efetivas de Windows precisam de verificação local. O socket compartilhado só é adequado a Source confiável no laboratório pessoal.

Permanecem limites para produção: IAM com wildcards/PassRole amplo, SSL do banco com validação de certificado desativada quando esse modo é usado, CRUD sem autorização de usuários e infraestrutura produtiva incompleta. Não apresentar isso como configuração produtiva já endurecida.

## 7. LocalStack e PERSISTENCE=0

O modelo é adequado para um laboratório descartável que sofreu restauração de control plane sem processos/endpoints correspondentes. O bind por sessão atende ao executor CodeBuild mesmo com snapshots desativados. A exigência de bind neste laboratório se apoia no erro do executor anteriormente observado, não em um requisito da AWS real. Reconstrução de recursos não é recuperação de dados cadastrados: as tarefas do banco não são um backup persistente entre sessões.

Não se deve atribuir à AWS real essa durabilidade local ou ausência de hosts EC2. Sessão nova, inputs rastreáveis e reprodução binária completa são propriedades diferentes. Lockfile e ZIP normalizado foram incorporados, mas tags `localstack/localstack-pro:latest` e `node:24-alpine` seguem móveis. Registrar versão/digest efetivos e só então congelar a versão homologada; não inventar uma versão nem atualizar o runtime ativo para tentar corrigir o preflight.

| Documentação oficial                                                             | Implicação                                                                                  |
| -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Persistência opcional e compatibilidade de snapshots                             | P0 é uma escolha válida, não prova de que todo recurso persistido sempre falhará            |
| CodePipeline V1 executável; V2 mock; sem triggers/locks/retry/rollback completos | Manter V1, início explícito e serialização; não transportar essas limitações para AWS       |
| CodeBuild com agente AWS e limitações de imagens/variáveis/persistência          | Verificar ambiente real do runner e APIs, não presumir imagem ou sucesso por declaração/log |
| ECS pelo executor Docker                                                         | Control plane e runtime devem ser verificados separadamente                                 |
| RDS engine local pode usar versão padrão com custom versions desativadas         | EngineVersion API não substitui consulta SQL da versão efetiva                              |

Fontes: [persistência](https://docs.localstack.cloud/aws/developer-tools/snapshots/persistence/), [CodePipeline](https://docs.localstack.cloud/aws/services/codepipeline/), [CodeBuild](https://docs.localstack.cloud/aws/services/codebuild/), [ECS](https://docs.localstack.cloud/aws/services/ecs/), [RDS](https://docs.localstack.cloud/aws/services/rds/).

A documentação atual inclui Source CodeConnections; portanto não é correto afirmar indisponibilidade universal de GitHub Source. O S3 é mantido por rastreabilidade do working tree e foco da etapa, não por uma proibição geral. Disponibilidade de serviços/recursos depende da licença e versão instaladas; validar no plano efetivo do laboratório.

A ausência/travamento de Build foi relatada em sessões anteriores. Não está documentada como falha inevitável do serviço e não foi reproduzida no LocalStack desta auditoria. Se persistir após corrigir o preflight, registrar versão/digest, declaração e respostas Source/Build/Deploy para investigar/reproduzir no fornecedor. Até então, execução incompleta é reprovação/inconclusão, não CI/CD aprovado.

## 8. O que permanece como dívida técnica

- Bootstrap RDS ainda gira identificador após timeout. `creating` lento não prova stale; o material não explica o provisioning. Não ampliar essa política para CI/CD.
- `sync-alb-targets` remove e registra targets em bloco, podendo criar janela sem targets. Não há promessa de deploy sem interrupção na etapa 8; implementar convergência por delta pode ser melhoria posterior, preservando TG `ip`.
- `create-ecs` ainda força implantação e pode rotacionar namespace em manutenção. A invocação normal do CI/CD foi desacoplada disso; não foi feita certificação de todos os caminhos de repair.
- IAM, TLS RDS, autenticação, ASG/bootstrap e IaC requerem trabalho antes de produção AWS real.
- Advisory moderado no grafo Vitest/mocker de desenvolvimento e dívida de formatação continuam explícitos. A instalação também emitiu aviso de deprecação do ESLint 9.39.5; o tooling merece atualização planejada. Não houve atualização major nem reformatação funcional em massa da aplicação.
- Rollback operacional existente permanece fora do caminho de aprovação e precisa de teste real se for demonstrado. Não é Blue/Green nem rollback nativo CodePipeline.

Isso não justifica refazer VPC/RDS/ECS/ALB/HTTPS comprovados. A redução prioritária foi retirar a recuperação da entrega e usar um único contrato de consulta Docker para as tasks.

## 9. Respostas às dez perguntas

| Pergunta                              | Resposta                                                                                                                                                     |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1. Fiel ao vídeo?                     | Sim no conceito CRUD + AWS build/deploy/container/dados/balanceamento; emulação e etapas futuras devem ser explicitadas                                      |
| 2. Melhor em quê?                     | Evidência disponível de testes, Zod, SQL parametrizado, health com banco, não-root e documentação de paridade; sem afirmar ausência desses cuidados no autor |
| 3. Onde desviou?                      | Aprovação por fallback externo e acúmulo de recuperação, além do roadmap incorreto; corrigidos no caminho normal/documentação                                |
| 4. Complexidade desnecessária?        | Sim: inferência por runners/tags novas, CodeBuild direto e reconciliação automática para toda falha de preflight                                             |
| 5. Estratégia LocalStack correta?     | Sim como emulação, com APIs/runtime verificados e diferenças explícitas; não é certificação de infraestrutura AWS real                                       |
| 6. P0 + reconstrução adequada?        | Sim para laboratório descartável; sacrifica dados locais e exige versões/inputs registrados                                                                  |
| 7. CI/CD local faz sentido?           | S3 → CodePipeline V1 → CodeBuild → ECR → ECS faz; um deploy externo não prova a pipeline                                                                     |
| 8. Conclusão profissional da etapa 8? | Duas entregas nativas rastreáveis, mudança real demonstrada e quality gate falho bloqueando Deploy; guardar evidência sanitizada                             |
| 9. Simplificar o quê?                 | Entrega sem repair/fallback, captura comum Docker, inputs permitidos, lockfile e documentação atual; consolidar wrappers depois                              |
| 10. Não alterar o quê?                | Stack, domínio/endpoints, duas réplicas, banco/secret, rede, ECR, TG/ALB/ACM/HTTPS, logs e diferenças intencionais do laboratório                            |

## 10. Validação da entrega 1.7.1

Ambiente de execução: Linux, Node 24.19.0/npm 11.9.0 e PowerShell 7.6.6 portátil. Docker/AWS/LocalStack/Windows não estavam disponíveis.

| VALIDADO NESTA AUDITORIA   | Evidência e limite                                                                                                                                                                                                    |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Integridade dos originais  | Dois ZIPs comparados; mesmos 93 conteúdos, original sem modificação                                                                                                                                                   |
| Dependências               | npm ci com lockfile; grafo fixado. Instalação de verificação usou `--ignore-scripts`; build posterior executou ferramentas instaladas                                                                                 |
| Aplicação                  | npm run verify: lint sem avisos, 7 testes API + 4 frontend e build TypeScript/Vite                                                                                                                                    |
| Regressões                 | 25 testes isolados: processo nativo, rejeição de falhas, Source/hash, ECR, redaction, tasks/revisão/health/digest e publicação em processo PowerShell novo. AWS/Docker simulados; HTTPS foi stubado nessas fixtures   |
| Prova negativa do original | 14 dos 19 testes iniciais falharam contra funções originais; dois testes adicionais de readers de secret e dois de identidade canônica S3 e um de alias da imagem física falharam antes das proteções correspondentes |
| PowerShell                 | Parser nativo nos 38 scripts em PowerShell 7; não prova por si só execução em 5.1                                                                                                                                     |
| JSON/YAML                  | 6 JSONs e 5 YAMLs parseados; comandos de buildspec e referências/caminhos examinados; 32 blocos PowerShell da documentação parseados sem executar seus comandos                                                       |
| Dockerfile/contexto        | Inspeção estática de stages, inputs, lockfile, usuário/healthcheck e seleção de contexto; sem Docker build executado aqui                                                                                             |
| Snapshot                   | Publisher executado com upload simulado; inputs, exclusões, VersionId do upload, hash estável ante mtime e bloqueio de credenciais fictícias verificados                                                              |
| Segurança da entrega       | Busca por credencial original sem exibir seu valor, padrões de secrets e exclusão de runtime/env/logs/certificados/temporários                                                                                        |
| ZIP completo               | CRC, caminhos seguros, raiz única cloudtasks-aws e inventário conferidos no empacotamento final                                                                                                                       |
| Advisory                   | npm audit: 2 moderados (Vitest/mocker), 0 altos/críticos; audit omit=dev retornou 0 advisories. Não equivale a 2 vulnerabilidades produtivas; dependências de teste fora do runner prod-deps                          |
| Formatação                 | Resultado registrado abaixo; checagem separada de verify, sem fingir aprovação de dívida existente                                                                                                                    |

`npm run format:check` reprovou 22 arquivos remanescentes, principalmente código/configuração da aplicação e documentação não reformatados nesta correção. Documentos/configurações alterados e a fixture nova foram formatados. Essa dívida não foi ocultada nem tratada como check aprovado.

| PRECISA SER VALIDADO NA MÁQUINA DO LABORATÓRIO | Critério                                                                                                              |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| PowerShell 5.1                                 | Parser/regressões e captura Docker sem encerramento prematuro; job Windows GitHub ainda não executado nesta auditoria |
| Docker                                         | Build real e inspeção de contexto/layers; native fixture não substitui Docker Desktop                                 |
| CodePipeline/CodeBuild                         | Source/Build/Deploy nativos e BuildId API SUCCEEDED; versão efetiva e suporte a revisão S3 exata                      |
| Runtime ECS                                    | Cada task nova com revisão/imagem corretas e Docker healthy; RepoDigests igual ao digest ECR                          |
| ALB/HTTPS/RDS                                  | 2/2 targets, HTTPS health/CRUD e banco; fornecido como histórico anterior, não repetido aqui                          |
| Etapa 8 completa                               | Segunda mudança real entregue e teste negativo de quality gate sem avançar ECS/Deploy                                 |
| Segurança operacional                          | ACLs de temporários, Git/histórico, logs/layers reais e substituição da credencial original se ativa                  |

## 11. Comandos e resultados esperados

O pacote contém uma pasta `cloudtasks-aws` completa. Atualize o código mantendo o `.env.localstack` pessoal fora da distribuição. Como o runtime atual foi relatado saudável, não iniciar/parar/resetar/reconciliar antes apenas por causa deste erro.

Na raiz:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
& {
    $ErrorActionPreference = 'Stop'
    .\scripts\localstack\create-cicd.ps1
    .\scripts\localstack\test-cicd.ps1
}
```

Esperado no primeiro comando: scripts permitidos somente nessa janela/processo. No segundo: preflight aceita o runtime válido, prepara a imagem CodeBuild; Source/Build/Deploy nativos completam; nova imagem ligada ao ID do build/digest, nova revisão e metadados da execução. No terceiro: identidade exata do Source/build/imagem, duas tasks da revisão, Docker healthy/digest e HTTPS/CRUD/RDS. São resultados esperados de uma execução saudável, ainda dependentes da validação no emulador.

Se CodePipeline parar em Source ou CodeBuild/API não comprovar sucesso, isso é falha/inconclusão real. Preservar a sessão e executar `status-cicd.ps1`/`diagnose-cicd.ps1`, sem aprovar por runner ou resetar recursos para esconder o problema.

A primeira aprovação não encerra sozinha a etapa. [PIPELINE.md](PIPELINE.md) contém os comandos do teste negativo, resultados e registro das duas entregas. Critério final: dois Sources/builds/imagens/revisões rastreáveis, mudança visível e uma falha real do quality gate mantendo a versão saudável. Nenhum estágio 9–13 foi implementado ou declarado concluído.

## 12. Compatibilidade do empacotamento com Windows PowerShell 5.1

Na execução subsequente enviada pelo responsável, o `create-cicd.ps1` do pacote auditado passou pelo preflight do runtime, confirmou o ECR existente e avançou à publicação do Source. A interrupção ocorreu em `publish-cicd-source.ps1`, linha 77 da entrega anterior, ao resolver `[IO.Compression.ZipArchiveMode]`.

**Causa no código:** carregava-se apenas `System.IO.Compression.FileSystem`. `ZipArchiveMode`, `ZipArchive` e `CompressionLevel` pertencem a `System.IO.Compression`. O Windows PowerShell 5.1/.NET Framework não encontrou o enum antes da chamada a `ZipFile.Open`; a biblioteca precisa ser carregada explicitamente. A documentação da Microsoft identifica os assemblies de [ZipArchiveMode](https://learn.microsoft.com/en-us/dotnet/api/system.io.compression.ziparchivemode) e [ZipFile](https://learn.microsoft.com/en-us/dotnet/api/system.io.compression.zipfile).

**Correção localizada:** adicionar `Add-Type -AssemblyName System.IO.Compression` antes do carregamento de `System.IO.Compression.FileSystem` e do primeiro uso dos tipos ZIP. Nenhuma alteração de ECS, RDS, ALB, Source permitido, determinismo do ZIP ou arquitetura de CI/CD foi necessária. A ausência de `last-deploy.json` no `test-cicd.ps1` é consequência da execução interrompida antes da entrega; não deve ser suprida criando metadados artificialmente.

**Regressão:** `test-regressions.ps1` agora publica o Source também em um processo novo do mesmo executável PowerShell, com `-NoProfile`. Verifica o resultado do upload e reabre o ZIP real para conferir uma entrada e seu conteúdo. Docker/AWS continuam sendo fixtures externas; a compressão e o processo PowerShell são reais. Esse teste já passava no PowerShell 7 antes da correção, portanto não foi uma reprodução do erro do Windows; a prova da falha em 5.1 é o transcript recebido. O job Windows existente executará o teste nesse runtime quando o workflow for acionado.

**Validação após a mudança:** 25 regressões isoladas, `npm run verify` (lint, 7 testes API, 4 frontend e builds), parser dos 38 scripts, JSON/YAML, caminhos, segurança e integridade do pacote. A execução própria continua limitada a Linux/PowerShell 7.6.6: não houve teste em Windows 5.1, Docker ou LocalStack reais. As pendências de advisory e formatação da seção 10 permanecem.

Para continuar, atualizar o código preservando o `.env.localstack` pessoal e executar os mesmos comandos da seção 11 na sessão saudável existente. Esta falha de empacotamento não requer reinicialização ou reconciliação da infraestrutura.

## 13. Diagnóstico do executor CodeBuild e entrega 1.7.2

### Evidência recebida depois do empacotamento corrigido

A publicação Source completou no Windows PowerShell 5.1, com VersionId e SHA256 registrados. A execução CodePipeline `3c948a5a-283c-4824-b188-2a12d1919915` concluiu Source e falhou em Build com mensagem `Build timed out`. A ação não forneceu `externalExecutionId`; o build `cloudtasks-build:4a3385dc` foi consultado como candidato e permaneceu `IN_PROGRESS` na API. O traceback do monitor cita esse mesmo build, mas a falta de vínculo da ação continua impedindo sua aprovação como entrega rastreável.

Versão informada: LocalStack `2026.8.3:02342ae2e`. Imagem em uso: `localstack/localstack-pro:latest`; runner: `localstack/aws-codebuild-local:2`. O runner preservado terminou com exit 0 e sem OOM. Apenas a imagem do wrapper estava no cache CodeBuild mostrado no transcript. Não foi executada atualização ou reset nessa investigação.

| Horário UTC de 01/10/2026 | Evento observado                                                                                      |
| ------------------------- | ----------------------------------------------------------------------------------------------------- |
| 22:09:34                  | Ação Build e build candidato registrados na API, separados por aproximadamente 0,14 segundo           |
| 22:09:45                  | Thread `BuildManager._check_build(cloudtasks-build:4a3385dc)` encerra com `Container not yet started` |
| 22:39:57                  | Ação Build falha por timeout, aproximadamente 30 min 23 s depois do início                            |
| 22:40:20                  | Container externo finalmente inicia, depois de a ação já ter falhado                                  |
| 22:40:47                  | Download de camada falha com `TLS handshake timeout`; wrapper encerra com código 0                    |

Os horários Docker e os timestamps de API foram convertidos para UTC. A demora no início está comprovada; atribuir os 31 minutos inteiros ao download inicial da imagem é **inferência**, não algo quantificado pelos logs recebidos. Também não se determinou se o timeout TLS veio de proxy, firewall, conexão, registry ou outro componente de rede. Não desabilitar TLS por causa dessa incerteza.

### Causa do estado contraditório da API

O traceback mostra o monitor em `localstack/pro/core/services/codebuild/build.py.enc`, função `_check_build`, chamando `is_build_complete`. Essa função tenta ler `server.container.logs()`. Em `localstack/utils/container/container.py`, o acesso aos logs exige `is_started()`; a condição falha e levanta `ContainerStateError('Container not yet started.')`.

O monitor consulta um container ainda não iniciado e a exceção encerra a thread. Essa falha ocorre **antes do buildspec da aplicação** e explica por que o build continua `IN_PROGRESS` enquanto a ação CodePipeline termina por timeout. Aumentar `timeoutInMinutes`, reconciliar ECS ou modificar React/Express não corrige essa condição do provider. O projeto não pode reparar esse código do emulador apenas alterando seus buildspecs.

### Saída 0 indevida do wrapper

O `local_build.sh` recebido é o entrypoint da imagem do executor. Na linha 171, executa `docker-compose up --abort-on-container-exit ... | tee build_logs`. Não há `pipefail` nem verificação do exit code do Compose. Nas linhas 173–180, o resultado depende apenas de encontrar `Phase complete: ... State: FAILED` no log. Uma falha de pull/startup anterior às fases não produz essa linha e cai em `exit 0`.

Isso foi reproduzido aqui com o trecho exato do wrapper e um comando Compose controlado: erro 17 sem log de fase FAILED resultou em saída 0; erro com fase FAILED resultou em 1; execução saudável resultou em 0. Bash e o trecho do wrapper foram reais; Compose/Docker foram simulados. O script do fornecedor não foi alterado, copiado para a aplicação ou substituído por uma imagem disfarçada.

O timeout da ação e o estado incorreto da API não devem ser sobrepostos pelo exit 0 desse container. Mesmo se o provider reportar sucesso indevido, são necessários artifacts, ação Deploy e imagem/tasks corretas para a aceitação.

### O compose efetivo fecha a questão do daemon

Foi recebido `docker-compose-localstack.yml`, efetivamente selecionado pelo wrapper, e não apenas o Compose base da Amazon. Ele declara `dns_health` e `agent` com `${LOCAL_AGENT_IMAGE}` e `build` com `${IMAGE_FOR_CODEBUILD_LOCAL_BUILD}`. Na linha 82, `build` monta `/var/run/docker.sock:/var/run/docker.sock`; não existe serviço `dockerd` separado. O wrapper usa `LOCAL_AGENT_IMAGE_NAME` e `IMAGE_NAME` para definir essas imagens. Sem `LOCAL_AGENT_IMAGE_NAME`, o próprio wrapper adota `amazon/aws-codebuild-local:latest`; **o valor efetivo desse parâmetro não foi fornecido**, portanto não se presume qual agente interno foi usado.

A inspeção recebida não encontrou `DOCKER_HOST`, `DOCKER_CONTEXT` ou `DOCKER_CONFIG` no wrapper. Com o socket montado, o CLI Linux usa o daemon do Docker Desktop. Um volume `/var/lib/docker` no wrapper, isoladamente, não prova Docker-in-Docker. A documentação do [Docker CLI](https://docs.docker.com/reference/cli/docker/) explica a seleção do socket/contexto padrão. Preparar imagens nesse daemon atende a este runtime; não é requisito da AWS real.

### Incompatibilidade adicional comprovada no projeto

Na entrega anterior, o bloco de aceitação em `create-cicd.ps1` extraía o sufixo de `$codeBuildId` e exigia um UUID completo. O ID `4a3385dc`, de oito caracteres hexadecimais, visto na API desse LocalStack, era rejeitado com `CodeBuild retornou ID sem UUID validavel`. A condição antiga foi executada aqui: aceita UUID e rejeita exatamente o ID curto observado. Isso é um bloqueio posterior independente do timeout; não foi a causa da falha de Build já recebida.

`Get-CicdBuildImageTag` agora exige o projeto `cloudtasks-build` e aceita UUID ou oito hexadecimais, preservando o sufixo exato na tag. IDs de outro projeto, formatos arbitrários, barras, espaços e sufixos adicionais são recusados. Não escolhe `latest` ou uma tag candidata. Os buildspecs já usam `${CODEBUILD_BUILD_ID##*:}`; não precisam mudar por essa compatibilidade. Se o agente injetar um ID diferente do registrado na API, a comparação da imagem recusará a entrega; o ID estático de exemplo presente no template Compose não comprova o valor efetivo injetado no build.

### Solução aplicada e seus limites

- `Ensure-CicdBuildImage` verifica o cache da imagem Amazon Linux x86 usada por este projeto e pelo ambiente padrão documentado do LocalStack; baixa somente quando ausente e reinspeciona o image ID. Acontece no preflight, antes do Source/execução. Falha de registry encerra o fluxo e a resposta bruta é omitida, pois pode incluir URLs assinadas. Não executa o build da aplicação no PowerShell.
- O wrapper observado já estava em cache e permanece sob controle do LocalStack. A preparação do ambiente Amazon Linux reduz downloads durante a execução, mas não é garantia de correção do monitor nem de cache de um agente interno diferente. Não foram inventadas configurações privadas do provider, alterados timeouts, reescritas respostas de API ou introduzido fallback.
- `Get-CicdBuildImageTag` resolve o bloqueio comprovado por UUID obrigatório, mantendo a identidade nativa.
- `diagnose-cicd.ps1` prioriza o ID vinculado à ação; se ele falta, identifica explicitamente o último build como candidato. Mostra ações, horários/estado do runner e nomes públicos conhecidos das imagens, sem despejar env, mensagens livres de provider ou logs. Exit 0 permanece insuficiente.
- Nenhuma mudança em VPC, RDS, Secrets, ECS, réplica, TG, ALB, ACM/HTTPS ou `PERSISTENCE=0`. Nenhum script novo de recuperação. Código/documentação são reunidos em um único ZIP completo, com raiz `cloudtasks-aws` e sem arquivos pessoais.

Preparação de cache é uma **mitigação de pré-requisito**, não um reparo dos defeitos comprovados do fornecedor. Se a falha do monitor voltar a ocorrer com os pré-requisitos disponíveis, a solução sustentável exige correção/homologação do executor e uma versão/digest comprovadamente funcional. Não foi encontrada ou executada uma release que autorize afirmar que esse defeito já foi corrigido. Não marcar a etapa 8 como concluída por bypass, nem atualizar `latest` às cegas na sessão saudável. Relato ao fornecedor deve conter versão/digest, sequência de API/container e reprodução sanitizada; não compartilhar logs originais ou env do runner.

### Documentado, observado e inferido

| Classificação   | Afirmação                                                                                                                                                           |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Documentado     | LocalStack CodeBuild usa o agente AWS/Compose, aceita Source S3/NO_SOURCE/CODEPIPELINE, possui limitações de imagens/variáveis e não fornece granularidade de fases |
| Documentado     | Ambiente padrão x86 Amazon Linux 2023 `public.ecr.aws/codebuild/amazonlinux-x86_64-standard:5.0`; variáveis de buildspec não são suportadas nessa emulação          |
| Observado       | Monitor encerrando antes do container, TLS timeout, wrapper exit 0, build API `IN_PROGRESS` e ação Build `Failed` na versão instalada                               |
| Observado       | Socket compartilhado, ausência dos overrides Docker e sufixo de build com oito hexadecimais                                                                         |
| Inferido        | Cache preparado pode reduzir a demora/race de startup; é preciso executar novamente para medir e confirmar                                                          |
| Não determinado | Motivo preciso da lentidão e do timeout TLS; imagens internas efetivas sem os parâmetros resolvidos; versão do provider que elimina os defeitos                     |

Referências oficiais consultadas: [LocalStack CodeBuild](https://docs.localstack.cloud/aws/services/codebuild/), [configuração CodeBuild](https://docs.localstack.cloud/aws/customization/configuration-options/), [Docker CLI](https://docs.docker.com/reference/cli/docker/) e [AWS ação ECS padrão](https://docs.aws.amazon.com/codepipeline/latest/userguide/action-reference-ECS.html). A documentação não descreve os dois defeitos observados como comportamento inevitável. `phases` vazio, isoladamente, corresponde a uma limitação documentada; não foi usado como prova de travamento.

### Validação desta entrega

Os resultados próprios após a alteração são registrados abaixo. A suíte inclui captura nativa PowerShell, Source seguro e casos de ID curto/UUID, download falho/ausente, candidatos sem vínculo e recusa de tasks/revisão/saúde/digest divergentes. Foram usados apenas canários fictícios para credenciais.

| VALIDADO NESTA ENTREGA 1.7.2 | Resultado e limite                                                                                                                                                                      |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Aplicação                    | `npm run verify` passou: lint sem avisos do ESLint, 7 testes API, 4 frontend e build TypeScript/Vite; Node 24.19.0 em Linux                                                             |
| PowerShell                   | 35 regressões isoladas e parser dos 38 scripts passaram em PowerShell 7.6.6; Docker/AWS simulados                                                                                       |
| Prova negativa nova          | Condição antiga recusou o ID curto observado; diagnóstico antigo falhou nos dois casos de vínculo; novas regressões ficaram verdes após as mudanças                                     |
| Wrapper do fornecedor        | Trecho exato reproduzido em três cenários Bash; falha de startup sem fase FAILED devolve 0; Compose simulado                                                                            |
| JSON/YAML e shell            | 6 JSONs e 5 YAMLs válidos; comandos dos buildspecs e proteção antes do push examinados                                                                                                  |
| Referências e contexto       | Links locais, caminhos de scripts, inputs do publisher e seleção estática Docker aprovados; nenhum Docker build real aqui                                                               |
| Segurança e pacote           | Inputs excluem ambiente pessoal/runtime/logs; valores conhecidos e padrões de credenciais conferidos sem exibição; ZIP completo com raiz única/CRC/conteúdo conferidos antes da entrega |
| Formatação                   | `npm run format:check` segue reprovando os 22 arquivos históricos; os arquivos editados desta entrega foram formatados                                                                  |

A documentação atual da [AWS sobre runtimes](https://docs.aws.amazon.com/codebuild/latest/userguide/available-runtimes.html) lista Node.js 24 para Amazon Linux 2023 x86 standard 5.0. Isso sustenta a escolha do ambiente; não substitui a medição de `node --version` no agente efetivamente usado pelo LocalStack. O npm desta estação emitiu aviso sobre uma configuração de proxy do ambiente, distinto de avisos do lint do projeto.

**Ainda precisa executar no laboratório:** download real, CodeBuild/CodePipeline e ação ECS nativa; correspondência das imagens efetivas; Windows PowerShell 5.1; health/digest de todas as tasks e HTTPS/CRUD/RDS. A prova histórica de ECS/ALB saudável pertence às execuções recebidas, não a uma execução deste ambiente Linux. A etapa 8 exige duas entregas reais rastreáveis e o quality gate negativo descrito em [PIPELINE.md](PIPELINE.md).

**Comandos na sessão saudável existente:** os três da seção 11. Não executar `test-cicd.ps1` depois de `create-cicd.ps1` falhar. Se houver falha, executar `diagnose-cicd.ps1` e preservar a sessão. O pacote não inclui token, senha, logs de diagnóstico ou estado anterior; mantenha o seu `.env.localstack` pessoal no diretório de trabalho, sem publicá-lo.

## 14. Homologação remota no Windows — entrega 1.7.3

Em 02/10/2026, o responsável autorizou acesso pelo Remote Desktop Commander. A versão instalada 1.7.2 foi conferida por hashes antes de qualquer edição. As limitações de execução própria nas seções anteriores descrevem aquelas entregas; os resultados abaixo registram o trabalho efetivamente executado depois, na máquina do laboratório.

### Causas encontradas na homologação

- O processo remoto não fornece `OS=Windows_NT`, embora `[Environment]::OSVersion.Platform` retorne `Win32NT`. O harness escolhia a fixture Unix e tentava executar `chmod`. A detecção passou a usar o runtime .NET.
- O launcher `.cmd` interpretava os caracteres `|` do Go template Docker. Isso produzia uma falsa falha nos testes positivos. A fixture Windows agora é um executável temporário compilado com o compilador .NET Framework do Windows PowerShell; encaminha argumentos ao Node e preserva o exit code nativo. Não altera Docker, PATH ou metadados fora do processo de teste.
- Em `test-cicd.ps1`, o PowerShell 5.1 podia coletar o array JSON como um único item `System.Object[]`. A instrumentação isolada confirmou que o JSON continha o digest esperado, enquanto o operador `-contains` o recusava. A conversão agora produz explicitamente um `[string[]]` depois do parsing. Digest incorreto, task antiga e container sem saúde continuam reprovando.

### Evidências próprias no Windows

| Verificação           | Resultado e limite                                                                                                                                                                                                                                                               |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Plataforma            | PowerShell 5.1.26100.9549; Node 24.21.0; Docker Engine 29.6.2, contexto `desktop-linux`                                                                                                                                                                                          |
| Runtime real          | Preflight CI/CD retornou `True`; status ECS confirmou desired/running 2/2, pending 0 e duas tasks Docker healthy, sem reconciliação                                                                                                                                              |
| Qualidade             | `npm ci` e `npm run verify` terminaram com exit 0: lint, 7 testes API, 4 frontend e builds TypeScript/Vite                                                                                                                                                                       |
| Scripts               | Parser nativo aprovou os 38 scripts; 35 regressões passaram no PowerShell 5.1                                                                                                                                                                                                    |
| Limite das regressões | O processo nativo é real; respostas Docker/AWS e a dependência HTTPS dessas fixtures são simuladas                                                                                                                                                                               |
| Compatibilidade Linux | As mesmas 35 regressões também passaram no PowerShell 7.6.6 após as alterações                                                                                                                                                                                                   |
| Source S3 real        | Snapshot VersionId `AaD5g8pjgcWoxTXWdHbzZ7ypUL3TU1I1`, SHA256 `88ac1177f6da1e1ea75a490a8f535c20248ad9126c3d4b0fc80effbcae37b837`; 32 entradas, sem arquivos proibidos ou valores ativos de token/senha detectados                                                                |
| Imagem atual          | Metadados e histórico sem os valores ativos conhecidos; varredura adicional de 4255 arquivos legíveis do filesystem em container temporário, sem rede e read-only, também não os encontrou. Cinco caminhos ficaram ilegíveis; links e filesystems virtuais não foram percorridos |
| Logs existentes       | Buscados apenas em memória: logs disponíveis do LocalStack, do runner anterior e das duas tasks, com limite de 3000 linhas por container; não foram encontrados os dois valores ativos conhecidos                                                                                |
| Histórico Git         | Não acompanha esta pasta; estas verificações não certificam o histórico remoto do GitHub                                                                                                                                                                                         |

### Pré-requisito de rede da imagem CodeBuild

O `docker pull` real falhou em cerca de 25 segundos com `TLS handshake timeout` em uma CDN CloudFront. Não houve mensagem explícita de limite de uso, falha de autenticação, certificado, DNS ou disco. O proxy `http.docker.internal:3128` encontrado é o proxy interno padrão do Docker Desktop.

O Windows e um processo Python dentro do LocalStack completaram TLS contra o registro e o domínio da CDN, diretamente e pelo proxy. Os códigos HTTP 401/403 desses testes de raiz provam a conexão TLS, não o acesso às camadas da imagem. A CDN do download pertence ao fornecedor da imagem; isso não implementa CloudFront na aplicação nem antecipa a etapa 10.

A [documentação do Docker](https://docs.docker.com/engine/release-notes/29/#2970) registra que os limites de transferências do image store containerd não eram respeitados antes da versão 29.7.0. A máquina usa 29.6.2. A contribuição dessa condição para o timeout desta conexão é uma inferência; não foi provada apenas pelos testes de raiz.

Para preparar o cache sem reiniciar o ambiente saudável, foi instalada fora do projeto a ferramenta oficial [`crane` 0.22.1](https://github.com/google/go-containerregistry/releases/tag/v0.22.1). O SHA256 do pacote Windows foi conferido com o digest publicado pela release. A transferência usa autenticação anônima, TLS verificado e a referência exata do manifesto Linux/amd64. Não houve alteração de daemon, proxy, firewall, credenciais ou configuração do emulador.

- Manifesto: `sha256:eb5100a2ca720e158a6644932312d4eca71c6ca70641579640ef03341d8f6f53`.
- Configuração/imagem esperada: `sha256:3dfed5bd5418bb6a5c1607b48f41a90fb1c9b78292047692b50324ecb18f55c4`.
- Camadas: 57; aproximadamente 6881 MiB compactados.

Preparar o cache não executa o build da aplicação, não aprova CodeBuild/CodePipeline e não corrige o defeito do monitor do fornecedor. O sucesso de uma transferência por outro cliente também não comprova que `docker pull` foi reparado.

**Em homologação:** concluir a importação com identidade verificada, executar Source/Build/Deploy nativos, validar as tasks novas e HTTPS/CRUD, entregar uma segunda mudança real e executar o quality gate negativo. Até essas provas, a etapa 8 continua pendente. Não reiniciar uma sessão `PERSISTENCE=0` para experimentar configurações de rede.

## 15. Correção da identidade nativa — entrega 1.7.4

As observações anteriores sobre derivar a tag do ID foram superadas pela execução real de 03/10/2026. A execução `95135ac1-70ec-47f6-a9ad-6c1e8f26d92b` concluiu Source, Build e Deploy nativos. O CodeBuild real `cloudtasks-build:c25b541c` foi SUCCEEDED, executou 11 testes e publicou a imagem. Entretanto o agente usou um `CODEBUILD_BUILD_ID` com UUID zerado e gerou uma tag repetível. A aceitação recusou corretamente a divergência; essa execução não aprova a etapa 8.

O ECS entregou a nova task definition 2, com duas tasks Docker saudáveis, e o ALB manteve dois targets saudáveis. Portanto essa falha de identidade não demonstra quebra do ECS.

A correção usa UUID v4 gerado no próprio CodeBuild e o artifact padrão `imagedefinitions.json`. O helper compartilhado confirma o ID real vinculado, a localização S3 exata do BuildOutput na ação e na API CodeBuild, o nome do container, o repositório e a tag. Registra o hash do artifact para a aceitação revalidar. Foram removidos o parser ID→tag e `pipeline-build.json`; nenhum StartBuild externo ou deploy PowerShell foi introduzido.

O teste que mantém o ID curto real e usa uma tag independente falhou antes da correção e passou depois. As 37 regressões passaram no PowerShell 7.6.6 e no Windows PowerShell 5.1, com respostas externas simuladas. A homologação nativa concluída está registrada na seção 16.

Na preparação da imagem oficial, o Docker/containerd desta máquina reportou `.Id` igual ao digest do descriptor, distinto do digest da configuração. A hipótese anterior de arquivo corrompido não foi comprovada: manifesto, configuração, 57 DiffIDs e configuração efetiva foram verificados. A imagem oficial ficou em cache; isso não comprova correção da conectividade TLS do CDN.

## 16. Homologação concluída em 03/10/2026

A etapa 8 foi comprovada em execução própria no Windows/LocalStack. Nenhum StartBuild externo, deploy PowerShell alternativo, alteração artificial de status ou reset do ambiente foi usado.

| Prova | CodePipeline | CodeBuild | Resultado |
| --- | --- | --- | --- |
| Primeira entrega | 8a9496c7-f589-4f22-9c7b-a8c983ae4f04 | cloudtasks-build:f189be5b | Source/Build/Deploy Succeeded; test-cicd aprovado |
| Segunda entrega | a63eecaa-49f5-48bf-9556-b41a22106a95 | cloudtasks-build:436bddc5 | Novo Source, digest, task definition e texto confirmado no bundle HTTPS |
| Quality gate negativo | eb3d9c58-e46f-40b6-bbd9-b28aaf971ea9 | cloudtasks-build:a360ec3f | FAILED em PRE_BUILD por teste deliberado; zero ações Deploy iniciadas; revisão saudável mantida |
| Entrega limpa final | 7a72fc01-9484-4ca6-9a2d-f8a3c550b6f1 | cloudtasks-build:6208b6e3 | Succeeded; test-cicd aprovado; duas tasks Docker e dois targets saudáveis |

O teste negativo foi removido em finally. O snapshot final voltou ao conteúdo limpo da segunda entrega, com SHA256 aedbf8c1851dc0d354dcebd04ff0448f92c78438bafa4615b221f9993f8a08c9, e recebeu outro VersionId. A revisão final é arn:aws:ecs:us-east-1:000000000000:task-definition/cloudtasks:5, com digest ECR sha256:54c00b84108349344904c734728a8ad9f8b7deacb507c89aae49aca51f3e5acb.

Causa da falha de identidade: o agente usou CODEBUILD_BUILD_ID com UUID zerado, distinto do ID real da API. A solução gera UUID v4 no build e verifica o artifact padrão ligado ao CodeBuild nativo. O parser ID→tag e pipeline-build.json foram removidos.

Uma tentativa corrigida anterior falhou no INSTALL por ECONNRESET em npm ci. Ela foi recusada e não conta como prova de quality gate. Uma consulta ao registry npm na mesma imagem/rede passou antes da repetição. Não se afirma que a conectividade TLS/CDN do Docker foi corrigida permanentemente.

A consulta de ações antigas do LocalStack devolveu ações de outra execução, mesmo com filtro. Os scripts filtram novamente pelo execution ID; a homologação foi capturada durante cada execução e congelada em EVIDENCE-CICD.json. Não se aceitou uma ação de outro run.

### VALIDADO POR MIM

- Windows PowerShell 5.1: parser dos 39 scripts e 37 regressões com respostas externas simuladas.
- Linux PowerShell 7.6.6: as mesmas regressões; teste novo falhou antes da correção e passou depois.
- npm verify: lint, 7 testes API, 4 frontend, TypeScript e Vite; também executado nos CodeBuilds reais.
- Docker build/push reais, ECR imutável, artifacts nativos/hash, ECS físico, ALB e CRUD HTTPS/RDS.
- Duas entregas distintas, mudança visível e falha deliberada que bloqueou Deploy.
- Entrega final limpa, sem arquivo de teste negativo.

### NÃO VALIDADO / PRÓXIMAS VALIDAÇÕES

- Novo job GitHub Actions e histórico Git: não houve publicação ou repositório Git nesta pasta.
- AWS real: EC2/ASG, TG instance, CodeConnections, IAM e TLS de ALB reais não foram executados.
- Reconstrução fria de uma nova sessão LocalStack não foi repetida nesta homologação, para preservar o runtime saudável. PERSISTENCE=0 continua sendo a decisão do laboratório.
- Blue/Green, CloudFront, observabilidade ampliada e Amazon Q/MCP permanecem nas etapas seguintes.
- Dívida global de formatação e advisories de dependências de teste continuam documentados; não se declarou format:check global aprovado.

### Operação após esta entrega

Nenhuma cópia ou correção manual é necessária: o projeto foi aplicado na máquina. Para conferir novamente, a partir de qualquer pasta:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Users\barro\Downloads\cloudtasks-aws\scripts\localstack\test-cicd.ps1"
```

Resultado esperado: execução nativa Succeeded, Source/Build/Deploy Succeeded, artifact/hash/digest corretos, 2/2 tasks e targets saudáveis e CRUD HTTPS/RDS aprovado. Se houver uma nova sessão LocalStack, os recursos precisam ser reconstruídos antes de usar metadados dessa sessão anterior.

A etapa 8 está concluída tecnicamente no laboratório porque as três provas exigidas foram obtidas sem bypass. A publicação das evidências no GitHub permanece uma atividade de portfólio, não um resultado já executado.
