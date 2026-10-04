# CloudTasks — portfólio AWS/DevOps

Versão 1.7.8. React 19 + TypeScript + Vite, Node 24 + Express 5 e PostgreSQL.

CloudTasks usa uma aplicação de tarefas para demonstrar entrega de software, containers, rede, dados e balanceamento. A arquitetura alvo é AWS; o laboratório executável usa LocalStack Pro/Student e Docker Desktop, sem provisionar recursos faturáveis em uma conta AWS.

## Arquitetura e estado

Alvo: GitHub/CodeConnections → CodePipeline → CodeBuild → Docker/ECR → ECS sobre EC2 → Target Group/ALB → CloudFront → usuário. RDS, Secrets Manager, IAM, CloudWatch e ACM complementam o desenho.

| Fronteira    | AWS alvo                             | Laboratório                                                              |
| ------------ | ------------------------------------ | ------------------------------------------------------------------------ |
| Source       | GitHub por CodeConnections           | Snapshot autorizado do working tree, em S3 versionado                    |
| Pipeline     | Source, CodeBuild, deploy ECS padrão | CodePipeline V1 com os mesmos provedores executáveis                     |
| Compute      | ECS/EC2, `bridge`, hostPort dinâmico | Executor Docker; não existem hosts EC2 reais                             |
| Target Group | `instance`                           | `ip`, sincronizado com as tasks locais                                   |
| HTTPS        | ALB termina TLS com ACM              | Listener/ACM no control plane; TLS efetivo no gateway LocalStack `:4566` |
| Estado       | Recursos e dados persistentes AWS    | `PERSISTENCE=0`, bind mount novo por sessão                              |

Aplicação, GitHub Actions, Docker, ECR, rede, RDS/Secrets, duas réplicas compartilhando o banco, CloudWatch Logs, ALB/TG, failover, HTTP e HTTPS/ACM têm execução anterior relatada pelo responsável pelo laboratório. **A etapa 8, CI/CD, foi homologada neste laboratório em 03/10/2026.** Blue/Green, CloudFront e Amazon Q/MCP são etapas posteriores.

A homologação da etapa 8 comprovou duas entregas, mudança visível por HTTPS e CodeBuild FAILED por quality gate sem iniciar Deploy. A imagem recebe UUID v4 gerado no build; o artifact nativo `imagedefinitions.json`, Source VersionId/SHA256, CodeBuild vinculado, digest e tasks físicas formam a cadeia de identidade. [Evidência CI/CD](docs/EVIDENCE-CICD.json); [CI no GitHub](docs/EVIDENCE-GITHUB.json).

Em 04/10/2026, após a higienização autorizada do Docker Desktop e reconstrução em LocalStack 2026.9.0, uma execução nativa distinta passou novamente em Source, Build, Deploy e `test-cicd.ps1`, com 2/2 réplicas, HTTPS e CRUD/RDS. A primeira execução foi corretamente rejeitada por Running 3 para Desired 2; a limpeza manual dessa sobra não foi contada como homologação. A aprovação pertence à execução seguinte, sem fallback. A mudança visível e o quality gate negativo da homologação de 03/10 não foram repetidos nesse novo runtime.

**A etapa 9 permanece bloqueada para o controlador nativo e sua integração CI/CD.** A prova manual temporária demonstrou tráfego, promoção e rollback em um ALB isolado. O ensaio nativo anterior, em LocalStack 2026.8.3, falhou em isolamento e bake. Em 2026.9.0, uma candidata deliberadamente inválida fez o controlador encerrar blue saudável, tanto em `bridge`/TG `ip` quanto em um service temporário `awsvpc`/TG `ip`. Trocar a rede do projeto não resolve esse bloqueio observado. A aplicação principal permaneceu em bridge, na mesma revisão, imagem e duas tasks. [Desenho e limites](docs/BLUE-GREEN.md); [evidência nativa](docs/EVIDENCE-BLUE-GREEN-NATIVE.json).

A versão 1.7.8 atualiza documentação, evidências e identificação do pacote. Aplicação, scripts, pipeline, infraestrutura e arquivos AWS existentes foram preservados. Os recursos temporários foram removidos; apenas LocalStack e as duas tasks atuais ficam ativos, com as imagens oficiais do CodeBuild mantidas como dependências da pipeline.

## Executar a aplicação local

```powershell
docker compose up --build
```

Interface: `http://localhost:3000`. Health: `http://localhost:3000/health`; verifica também o banco.

Desenvolvimento e qualidade com Node 24:

```powershell
npm ci
npm run verify
```

`verify` executa lint, testes da aplicação e build dos dois componentes. A formatação possui comando próprio; consulte [DEPENDENCY-POLICY.md](docs/DEPENDENCY-POLICY.md).

## Laboratório LocalStack

Pré-requisitos: Windows PowerShell 5.1 ou PowerShell 7, Docker Desktop em containers Linux, acesso à internet para imagens/dependências e licença LocalStack Pro/Student ativa. O arquivo pessoal `.env.localstack` não acompanha o projeto. O script de inicialização solicita o token sem exibi-lo quando necessário.

Para uma primeira sessão, ou para retomar uma sessão indisponível:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\scripts\localstack\resume-environment.ps1
```

`resume-environment.ps1` prepara a infraestrutura, ECS 2/2 e ALB/HTTPS. Uma nova sessão é descartável: **reconstruir recursos não restaura as tarefas de negócio do banco**. Não execute `start-localstack.ps1` ou uma atualização do emulador durante a homologação de uma sessão saudável.

## CI/CD da sessão já saudável

Na raiz do projeto:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
& {
    $ErrorActionPreference = 'Stop'
    .\scripts\localstack\create-cicd.ps1
    .\scripts\localstack\test-cicd.ps1
}
```

O primeiro script confere o cache da imagem Amazon Linux do CodeBuild e a baixa se necessário, antes de publicar o snapshot e iniciar CodePipeline. Na primeira vez, o download pode demorar e exige espaço em disco. Uma falha nesse download encerra o preflight sem nova execução. Depois, o script espera o build e o deploy dos serviços emulados. O segundo confere versão/hash do Source, CodeBuild vinculado, imagem/digest ECR, as duas tasks na revisão implantada, containers saudáveis e HTTPS/CRUD com banco.

A homologação desta entrega cumpriu o critério da etapa 8: duas entregas distintas, mudança visível e quality gate falho bloqueando Deploy. Os comandos acima servem para entregas futuras ou nova conferência. O procedimento completo e os resultados esperados estão em [PIPELINE.md](docs/PIPELINE.md).

Se houver falha, preserve a sessão e consulte:

```powershell
.\scripts\localstack\status-cicd.ps1
.\scripts\localstack\diagnose-cicd.ps1
```

O diagnóstico diferencia o build vinculado à ação de um candidato recente sem vínculo. Mostra horários/status do runner e nomes públicos das imagens quando disponíveis, sem despejar o ambiente ou logs. Código de saída 0 do wrapper não comprova sucesso do build. Se o monitor voltar a falhar mesmo com as imagens disponíveis, a etapa continua bloqueada pelo executor; preserve a sessão para investigar a versão do LocalStack. [Diagnóstico detalhado](docs/AUDIT.md#13-diagnóstico-do-executor-codebuild-e-entrega-172).

## Scripts e documentação

- Preparação explícita: `resume-environment.ps1` e `create-*` em `scripts/localstack`.
- Leitura: `status-*` e `diagnose-*`; verificação executável: `test-*`.
- Manutenção excepcional: `repair-*`, `update-localstack.ps1` e `change-token.ps1`.
- Regressões isoladas: `.\scripts\localstack\validate-scripts.ps1` e `.\scripts\tests\test-regressions.ps1`. Não requerem AWS/LocalStack em execução; Node 24 é necessário para as fixtures.
- `scripts/aws` e `aws`: arquivos existentes da etapa 3 para uma conta AWS real, preservados separadamente. Não fazem parte dos comandos do laboratório e não foram executados nesta entrega.
- [Arquitetura](docs/ARCHITECTURE.md), [decisões](docs/DECISIONS.md), [roadmap oficial de 13 etapas](docs/ROADMAP.md), [CI/CD](docs/CI-CD.md), [LocalStack](docs/LOCALSTACK.md), [runtime](docs/RUNTIME-RECOVERY.md).
- [Rede](docs/NETWORK.md), [banco](docs/DATABASE.md), [ECS](docs/ECS.md), [ALB](docs/LOAD-BALANCING.md), [HTTPS](docs/HTTPS.md), [segurança](SECURITY.md).

O desenho AWS é o alvo arquitetural, não uma declaração de que EC2, CloudFront ou toda a infraestrutura produtiva já foram implantados na AWS real.
