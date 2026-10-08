# CloudTasks â€” projeto AWS/DevOps baseado na referÃªncia BIA

VersÃ£o 1.8.2. React 19 + TypeScript + Vite, Node 24 + Express 5 e PostgreSQL.

O objetivo solicitado Ã© reproduzir o projeto BIA demonstrado no vÃ­deo, incluindo aplicaÃ§Ã£o, comportamento, interface e infraestrutura AWS efetiva. CloudTasks Ã© o nome do repositÃ³rio; a interface agora apresenta BIA. A igualdade integral com a versÃ£o filmada continua sem comprovaÃ§Ã£o. LocalStack Pro/Student e Docker Desktop sÃ£o ambientes auxiliares de desenvolvimento e testes.

**ReferÃªncia obrigatÃ³ria e estado:** [comparaÃ§Ã£o V01-V12](docs/REFERENCE-VIDEO.md). AWS real, ECS sobre EC2, origem GitHub da CodePipeline, ALB/TG/TLS, CloudFront e Amazon Q/MCP fazem parte da entrega final. As homologaÃ§Ãµes locais abaixo preservam seu valor histÃ³rico e nÃ£o encerram esses requisitos. O Windows foi reconectado em 08/10/2026. O resultado preservado do bootstrap anterior e a sessÃ£o atual foram conferidos separadamente. [Resultados atuais e limites](docs/EVIDENCE-BIA-20261008.json).

## Entrega local atual â€” 08/10/2026

A versÃ£o 1.8.2 estÃ¡ servida pelo [ALB local](http://cloudtasks-alb.elb.localhost.localstack.cloud:4566), acessÃ­vel no computador com Docker. A execuÃ§Ã£o `ae3eeaa9-8a5a-4bd8-b2bb-16c04d67a0e1` passou Source S3 versionado, CodeBuild e a aÃ§Ã£o ECS padrÃ£o, com duas rÃ©plicas saudÃ¡veis, sem fallback externo. O teste oficial de CI/CD, sete checks no PostgreSQL compartilhado e CRUD real pelo navegador passaram. Prazo textual, prioridade, conclusÃ£o, ediÃ§Ã£o, recarga e exclusÃ£o foram exercitados; apenas tarefas de teste desta revisÃ£o foram removidas.

Na sessÃ£o reconstruÃ­da para corrigir CORS, duas tentativas Blue/Green falharam e permanecem reprovadas: uma exigiu finalizar manualmente a limpeza apÃ³s validar o serviÃ§o principal; a outra fez rollback e limpeza automaticamente. A aprovaÃ§Ã£o ECS padrÃ£o Ã© uma execuÃ§Ã£o separada. A homologaÃ§Ã£o Blue/Green atual continua pendente. [EvidÃªncias e limites](docs/EVIDENCE-BIA-20261008.json).

## Arquitetura e estado

Alvo: GitHub/CodeConnections â†’ CodePipeline â†’ CodeBuild â†’ Docker/ECR â†’ ECS sobre EC2 â†’ Target Group/ALB â†’ CloudFront â†’ usuÃ¡rio. RDS, Secrets Manager, IAM, CloudWatch e ACM complementam o desenho.

| Fronteira    | AWS alvo                              | LaboratÃ³rio                                                             |
| ------------ | ------------------------------------- | ------------------------------------------------------------------------ |
| Source       | GitHub por CodeConnections            | Snapshot autorizado do working tree, em S3 versionado                    |
| Pipeline     | Source, CodeBuild, deploy ECS padrÃ£o | CodePipeline V1 com os mesmos provedores executÃ¡veis                    |
| Compute      | ECS/EC2, `bridge`, hostPort dinÃ¢mico | Executor Docker; nÃ£o existem hosts EC2 reais                            |
| Target Group | `instance`                            | `ip`, sincronizado com as tasks locais                                   |
| HTTPS        | ALB termina TLS com ACM               | Listener/ACM no control plane; TLS efetivo no gateway LocalStack `:4566` |
| Estado       | Recursos e dados persistentes AWS     | `PERSISTENCE=0`, bind mount novo por sessÃ£o                             |

AplicaÃ§Ã£o, GitHub Actions, Docker, ECR, rede, RDS/Secrets, duas rÃ©plicas compartilhando o banco, CloudWatch Logs, ALB/TG, failover, HTTP e HTTPS/ACM tÃªm execuÃ§Ã£o anterior relatada pelo responsÃ¡vel pelo laboratÃ³rio. **A etapa 8, CI/CD, foi homologada neste laboratÃ³rio em 03/10/2026.** Blue/Green local estÃ¡ descrito abaixo; CloudFront e Amazon Q/MCP sÃ£o etapas posteriores.

A homologaÃ§Ã£o da etapa 8 comprovou duas entregas, mudanÃ§a visÃ­vel por HTTPS e CodeBuild FAILED por quality gate sem iniciar Deploy. A imagem recebe UUID v4 gerado no build; o artifact nativo `imagedefinitions.json`, Source VersionId/SHA256, CodeBuild vinculado, digest e tasks fÃ­sicas formam a cadeia de identidade. [EvidÃªncia CI/CD](docs/EVIDENCE-CICD.json); [CI no GitHub](docs/EVIDENCE-GITHUB.json).

Em 04/10/2026, apÃ³s a higienizaÃ§Ã£o autorizada do Docker Desktop e reconstruÃ§Ã£o em LocalStack 2026.9.0, uma execuÃ§Ã£o nativa distinta passou novamente em Source, Build, Deploy e `test-cicd.ps1`, com 2/2 rÃ©plicas, HTTPS e CRUD/RDS. A primeira execuÃ§Ã£o foi corretamente rejeitada por Running 3 para Desired 2; a limpeza manual dessa sobra nÃ£o foi contada como homologaÃ§Ã£o. A aprovaÃ§Ã£o pertence Ã  execuÃ§Ã£o seguinte, sem fallback. A mudanÃ§a visÃ­vel e o quality gate negativo da homologaÃ§Ã£o de 03/10 nÃ£o foram repetidos nesse novo runtime.

**Etapa 9 local:** o modo explÃ­cito `LocalStackBlueGreenAdapter` executa Blue/Green dentro de uma aÃ§Ã£o CodeBuild da CodePipeline nativa. MantÃ©m duas tasks blue e duas green durante testes e bake, promove HTTP/HTTPS e, apÃ³s a janela aprovada, converge o serviÃ§o principal enquanto green atende. A validaÃ§Ã£o final e as evidÃªncias estÃ£o em [BLUE-GREEN.md](docs/BLUE-GREEN.md). A homologaÃ§Ã£o do controlador AWS nativo continua separada e nÃ£o Ã© reivindicada; as tentativas nativas reprovadas ficam no histÃ³rico.

A versÃ£o 1.8.0 preserva UI/CRUD, RDS/Secrets, cluster principal, bridge, ALB/TG e HTTPS/ACM. Adiciona dois mÃ³dulos Node sem dependÃªncias, um buildspec de deploy, testes e verificaÃ§Ã£o de recibos/artifacts. `/release.json` Ã© uma identidade pÃºblica imutÃ¡vel da imagem, sem mudanÃ§a visual na interface. O modo padrÃ£o de CI/CD permanece Rolling. CloudFront (10), observabilidade ampliada (11) e Amazon Q/MCP (12) continuam posteriores.

A versÃ£o 1.8.1 serializa a criaÃ§Ã£o do schema entre rÃ©plicas com transaÃ§Ã£o e advisory lock. A versÃ£o 1.8.2 alinha os elementos observÃ¡veis da BIA: tela escura compacta, formulÃ¡rio vertical, textos, tema persistente, indicador de saÃºde real, prazo textual e alteraÃ§Ã£o de prioridade. A migraÃ§Ã£o adiciona `due_text` e preserva `due_date`; updates parciais evitam perder alteraÃ§Ãµes concorrentes. [Compatibilidade e limites](docs/DATABASE.md).

A validaÃ§Ã£o de 08/10 inclui 69 testes no CI, testes da aplicaÃ§Ã£o no Windows, 11 cenÃ¡rios de interface isolada e 7 verificaÃ§Ãµes no PostgreSQL compartilhado por duas rÃ©plicas. O acesso pelo ALB revelou um bloqueio de Origin que testes sem esse cabeÃ§alho nÃ£o detectavam. O Compose agora permite somente as origens HTTP/HTTPS desse ALB. Banco e nove artifacts foram guardados antes da nova sessÃ£o, e o banco foi restaurado antes do ECS; o relatÃ³rio distingue cada tentativa e resultado.

No computador do projeto, a interface local estÃ¡ em [BIA pelo ALB](http://cloudtasks-alb.elb.localhost.localstack.cloud:4566). Esta URL depende do Docker/LocalStack desse computador e nÃ£o Ã© uma implantaÃ§Ã£o pÃºblica AWS.

## Executar a aplicaÃ§Ã£o local

```powershell
docker compose up --build
```

Interface: `http://localhost:3000`. Health: `http://localhost:3000/health`; verifica tambÃ©m o banco.

Desenvolvimento e qualidade com Node 24:

```powershell
npm ci
npm run verify
```

`verify` executa lint, 22 testes API, 8 frontend, 34 testes Node do controlador/adaptador e build dos dois componentes. HÃ¡ mais 5 testes de integraÃ§Ã£o PostgreSQL, executados no CI com banco real; sem `TEST_DATABASE_URL` eles ficam explicitamente skipped. A formataÃ§Ã£o possui comando prÃ³prio; consulte [DEPENDENCY-POLICY.md](docs/DEPENDENCY-POLICY.md).

## LaboratÃ³rio LocalStack

PrÃ©-requisitos: Windows PowerShell 5.1 ou PowerShell 7, Docker Desktop em containers Linux, acesso Ã  internet para imagens/dependÃªncias e licenÃ§a LocalStack Pro/Student ativa. O arquivo pessoal `.env.localstack` nÃ£o acompanha o projeto. O script de inicializaÃ§Ã£o solicita o token sem exibi-lo quando necessÃ¡rio.

Para uma primeira sessÃ£o, ou para retomar uma sessÃ£o indisponÃ­vel:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\scripts\localstack\resume-environment.ps1
```

`resume-environment.ps1` prepara a infraestrutura, ECS 2/2 e ALB/HTTPS. Uma nova sessÃ£o Ã© descartÃ¡vel: **reconstruir recursos nÃ£o restaura as tarefas de negÃ³cio do banco**. NÃ£o execute `start-localstack.ps1` ou uma atualizaÃ§Ã£o do emulador durante a homologaÃ§Ã£o de uma sessÃ£o saudÃ¡vel.

## CI/CD da sessÃ£o jÃ¡ saudÃ¡vel

Na raiz do projeto:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
& {
    $ErrorActionPreference = 'Stop'
    .\scripts\localstack\create-cicd.ps1
    .\scripts\localstack\test-cicd.ps1
}
```

O primeiro script confere o cache da imagem Amazon Linux do CodeBuild e a baixa se necessÃ¡rio, antes de publicar o snapshot e iniciar CodePipeline. Na primeira vez, o download pode demorar e exige espaÃ§o em disco. Uma falha nesse download encerra o preflight sem nova execuÃ§Ã£o. Depois, o script espera o build e o deploy dos serviÃ§os emulados. O segundo confere versÃ£o/hash do Source, CodeBuild vinculado, imagem/digest ECR, as duas tasks na revisÃ£o implantada, containers saudÃ¡veis e HTTPS/CRUD com banco.

A homologaÃ§Ã£o desta entrega cumpriu o critÃ©rio da etapa 8: duas entregas distintas, mudanÃ§a visÃ­vel e quality gate falho bloqueando Deploy. Os comandos acima servem para entregas futuras ou nova conferÃªncia. O procedimento completo e os resultados esperados estÃ£o em [PIPELINE.md](docs/PIPELINE.md).

Se houver falha, preserve a sessÃ£o e consulte:

```powershell
.\scripts\localstack\status-cicd.ps1
.\scripts\localstack\diagnose-cicd.ps1
```

O diagnÃ³stico diferencia o build vinculado Ã  aÃ§Ã£o de um candidato recente sem vÃ­nculo. Mostra horÃ¡rios/status do runner e nomes pÃºblicos das imagens quando disponÃ­veis, sem despejar o ambiente ou logs. CÃ³digo de saÃ­da 0 do wrapper nÃ£o comprova sucesso do build. Se o monitor voltar a falhar mesmo com as imagens disponÃ­veis, a etapa continua bloqueada pelo executor; preserve a sessÃ£o para investigar a versÃ£o do LocalStack. [DiagnÃ³stico detalhado](docs/AUDIT.md#13-diagnÃ³stico-do-executor-codebuild-e-entrega-172).

## Blue/Green da sessÃ£o saudÃ¡vel

```powershell
& {
    $ErrorActionPreference = 'Stop'
    .\scripts\localstack\create-cicd.ps1 -DeploymentMode BlueGreen
    .\scripts\localstack\test-cicd.ps1
}
```

Exige Source/Build/Deploy nativos, dois CodeBuilds vinculados, artifacts, digest e recibo exatos. O bake exige 2 blue + 2 green por pelo menos 60 segundos, HTTP/HTTPS e banco compartilhado. RejeiÃ§Ã£o e rollback mantÃªm a tentativa nativa falha; recuperaÃ§Ã£o incompleta retÃ©m lock/recursos que atendem. O ALB conserva a associaÃ§Ã£o com ambos os TGs durante a troca. ApÃ³s o bake, a convergÃªncia esvazia o serviÃ§o principal antes de iniciar a revisÃ£o aceita, com green atendendo durante a transiÃ§Ã£o.

O histÃ³rico e os controles negativos constam de [BLUE-GREEN.md](docs/BLUE-GREEN.md) e [EVIDENCE-BLUE-GREEN-ADAPTER.json](docs/EVIDENCE-BLUE-GREEN-ADAPTER.json). Alternar para o modo Rolling altera a declaraÃ§Ã£o da pipeline; registrar evidÃªncias antes de mudar de modo. NÃ£o resetar a sessÃ£o ou apagar lock de recuperaÃ§Ã£o para contornar uma falha.

## Scripts e documentaÃ§Ã£o

- PreparaÃ§Ã£o explÃ­cita: `resume-environment.ps1` e `create-*` em `scripts/localstack`.
- Leitura: `status-*` e `diagnose-*`; verificaÃ§Ã£o executÃ¡vel: `test-*`.
- ManutenÃ§Ã£o excepcional: `repair-*`, `update-localstack.ps1` e `change-token.ps1`.
- RegressÃµes isoladas: `.\scripts\localstack\validate-scripts.ps1` e `.\scripts\tests\test-regressions.ps1`. NÃ£o requerem AWS/LocalStack em execuÃ§Ã£o; Node 24 Ã© necessÃ¡rio para as fixtures.
- `scripts/aws` e `aws`: arquivos existentes da etapa 3 para uma conta AWS real, preservados separadamente. NÃ£o fazem parte dos comandos do laboratÃ³rio e nÃ£o foram executados nesta entrega.
- [ReferÃªncia obrigatÃ³ria](docs/REFERENCE-VIDEO.md), [arquitetura](docs/ARCHITECTURE.md), [decisÃµes](docs/DECISIONS.md), [plano interno de etapas](docs/ROADMAP.md), [CI/CD](docs/CI-CD.md), [LocalStack](docs/LOCALSTACK.md), [runtime](docs/RUNTIME-RECOVERY.md).
- [Rede](docs/NETWORK.md), [banco](docs/DATABASE.md), [ECS](docs/ECS.md), [ALB](docs/LOAD-BALANCING.md), [HTTPS](docs/HTTPS.md), [seguranÃ§a](SECURITY.md).

O desenho AWS Ã© o alvo arquitetural, nÃ£o uma declaraÃ§Ã£o de que EC2, CloudFront ou toda a infraestrutura produtiva jÃ¡ foram implantados na AWS real.
