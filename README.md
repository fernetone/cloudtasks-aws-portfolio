# CloudTasks — projeto AWS/DevOps baseado na referência BIA

Versão 1.8.2. React 19 + TypeScript + Vite, Node 24 + Express 5 e PostgreSQL.

O objetivo solicitado é reproduzir o projeto BIA demonstrado no vídeo, incluindo aplicação, comportamento, interface e infraestrutura AWS efetiva. CloudTasks é o nome do repositório; a interface agora apresenta BIA. A igualdade integral com a versão filmada continua sem comprovação. LocalStack Pro/Student e Docker Desktop são ambientes auxiliares de desenvolvimento e testes.

**Referência obrigatória e execução:** [comparação V01-V12](docs/REFERENCE-VIDEO.md). A aplicação e os componentes do vídeo são requisitos do projeto funcional. A execução autorizada é Docker/LocalStack Student/Pro, sem provisionamento pago na AWS. As diferenças do emulador permanecem documentadas; aprovação local não certifica paridade AWS.

## Entrega atual — 10/10/2026

A BIA 1.8.2 está servida pelo [ALB local](http://cloudtasks-alb.elb.localhost.localstack.cloud:4566). Após o reinício do computador, o PostgreSQL existente foi preservado por cópia física verificada e restaurado antes da aplicação. Dois deployments distintos passaram Source, Build, Deploy e o teste oficial na CodePipeline emulada, sem fallback ou reset entre eles: `ff17f9a8-ce91-4929-bd22-228fc2656c53` e `c8430b70-1240-4fa0-a514-1220cf5aa9b5`. Ambos usaram o mesmo Source SHA256 e o adaptador Blue/Green explícito; bake, duas réplicas físicas saudáveis, limpeza e liberação do lock foram verificados.

A segunda imagem foi novamente verificada no PostgreSQL real e no navegador desktop/celular: CRUD, prazo textual, prioridade, conclusão, edição e recarga passaram; as tarefas criadas pelos testes foram excluídas. Source, Build, Deploy e todas as camadas das duas imagens foram examinados para a senha atual do banco e a licença LocalStack, sem ocorrências. [Evidências desta retomada](docs/EVIDENCE-REBOOT-20261010.json).

As duas tentativas Blue/Green falhas de 08/10 continuam reprovadas no [histórico](docs/EVIDENCE-BIA-20261008.json). As falhas antigas não foram reproduzidas nas duas entregas atuais e sua causa continua sem comprovação. Os novos diagnósticos registram somente operação, duração e motivo permitido, sem argumentos, stderr ou credenciais. CloudFront, observabilidade ampliada e Amazon Q/MCP seguem no plano autorizado; igualdade integral com a revisão filmada ainda não foi certificada.

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

Aplicação, GitHub Actions, Docker, ECR, rede, RDS/Secrets, duas réplicas compartilhando o banco, CloudWatch Logs, ALB/TG, failover, HTTP e HTTPS/ACM têm execução anterior relatada pelo responsável pelo laboratório. **A etapa 8, CI/CD, foi homologada neste laboratório em 03/10/2026.** Blue/Green local está descrito abaixo; CloudFront e Amazon Q/MCP são etapas posteriores.

A homologação da etapa 8 comprovou duas entregas, mudança visível por HTTPS e CodeBuild FAILED por quality gate sem iniciar Deploy. A imagem recebe UUID v4 gerado no build; o artifact nativo `imagedefinitions.json`, Source VersionId/SHA256, CodeBuild vinculado, digest e tasks físicas formam a cadeia de identidade. [Evidência CI/CD](docs/EVIDENCE-CICD.json); [CI no GitHub](docs/EVIDENCE-GITHUB.json).

Em 04/10/2026, após a higienização autorizada do Docker Desktop e reconstrução em LocalStack 2026.9.0, uma execução nativa distinta passou novamente em Source, Build, Deploy e `test-cicd.ps1`, com 2/2 réplicas, HTTPS e CRUD/RDS. A primeira execução foi corretamente rejeitada por Running 3 para Desired 2; a limpeza manual dessa sobra não foi contada como homologação. A aprovação pertence à execução seguinte, sem fallback. A mudança visível e o quality gate negativo da homologação de 03/10 não foram repetidos nesse novo runtime.

**Etapa 9 local:** o modo explícito `LocalStackBlueGreenAdapter` executa Blue/Green dentro de uma ação CodeBuild da CodePipeline nativa. Mantém duas tasks blue e duas green durante testes e bake, promove HTTP/HTTPS e, após a janela aprovada, converge o serviço principal enquanto green atende. A validação final e as evidências estão em [BLUE-GREEN.md](docs/BLUE-GREEN.md). A homologação do controlador AWS nativo continua separada e não é reivindicada; as tentativas nativas reprovadas ficam no histórico.

A versão 1.8.0 preserva UI/CRUD, RDS/Secrets, cluster principal, bridge, ALB/TG e HTTPS/ACM. Adiciona dois módulos Node sem dependências, um buildspec de deploy, testes e verificação de recibos/artifacts. `/release.json` é uma identidade pública imutável da imagem, sem mudança visual na interface. O modo padrão de CI/CD permanece Rolling. CloudFront (10), observabilidade ampliada (11) e Amazon Q/MCP (12) continuam posteriores.

A versão 1.8.1 serializa a criação do schema entre réplicas com transação e advisory lock. A versão 1.8.2 alinha os elementos observáveis da BIA: tela escura compacta, formulário vertical, textos, tema persistente, indicador de saúde real, prazo textual e alteração de prioridade. A migração adiciona `due_text` e preserva `due_date`; updates parciais evitam perder alterações concorrentes. [Compatibilidade e limites](docs/DATABASE.md).

A validação de 08/10 inclui 69 testes no CI, testes da aplicação no Windows, 11 cenários de interface isolada e 7 verificações no PostgreSQL compartilhado por duas réplicas. O acesso pelo ALB revelou um bloqueio de Origin que testes sem esse cabeçalho não detectavam. O Compose agora permite somente as origens HTTP/HTTPS desse ALB. Banco e nove artifacts foram guardados antes da nova sessão, e o banco foi restaurado antes do ECS; o relatório distingue cada tentativa e resultado.

No computador do projeto, a interface local está em [BIA pelo ALB](http://cloudtasks-alb.elb.localhost.localstack.cloud:4566). Esta URL depende do Docker/LocalStack desse computador e não é uma implantação pública AWS.

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

`verify` executa lint, 22 testes API, 8 frontend, 42 testes Node do controlador/adaptador e build dos dois componentes. Há mais 5 testes de integração PostgreSQL, executados no CI com banco real; sem `TEST_DATABASE_URL` eles ficam explicitamente skipped. A formatação possui comando próprio; consulte [DEPENDENCY-POLICY.md](docs/DEPENDENCY-POLICY.md).

## Execução do projeto no LocalStack

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

## Blue/Green da sessão saudável

```powershell
& {
    $ErrorActionPreference = 'Stop'
    .\scripts\localstack\create-cicd.ps1 -DeploymentMode BlueGreen
    .\scripts\localstack\test-cicd.ps1
}
```

Exige Source/Build/Deploy nativos, dois CodeBuilds vinculados, artifacts, digest e recibo exatos. O bake exige 2 blue + 2 green por pelo menos 60 segundos, HTTP/HTTPS e banco compartilhado. Rejeição e rollback mantêm a tentativa nativa falha; recuperação incompleta retém lock/recursos que atendem. O ALB conserva a associação com ambos os TGs durante a troca. Após o bake, a convergência esvazia o serviço principal antes de iniciar a revisão aceita, com green atendendo durante a transição.

O histórico e os controles negativos constam de [BLUE-GREEN.md](docs/BLUE-GREEN.md) e [EVIDENCE-BLUE-GREEN-ADAPTER.json](docs/EVIDENCE-BLUE-GREEN-ADAPTER.json). Alternar para o modo Rolling altera a declaração da pipeline; registrar evidências antes de mudar de modo. Não resetar a sessão ou apagar lock de recuperação para contornar uma falha.

## Scripts e documentação

- Preparação explícita: `resume-environment.ps1` e `create-*` em `scripts/localstack`.
- Leitura: `status-*` e `diagnose-*`; verificação executável: `test-*`.
- Manutenção excepcional: `repair-*`, `update-localstack.ps1` e `change-token.ps1`.
- Regressões isoladas: `.\scripts\localstack\validate-scripts.ps1` e `.\scripts\tests\test-regressions.ps1`. Não requerem AWS/LocalStack em execução; Node 24 é necessário para as fixtures.
- `scripts/aws` e `aws`: arquivos existentes da etapa 3 para uma conta AWS real, preservados separadamente. Não fazem parte dos comandos do laboratório e não foram executados nesta entrega.
- [Referência obrigatória](docs/REFERENCE-VIDEO.md), [arquitetura](docs/ARCHITECTURE.md), [decisões](docs/DECISIONS.md), [plano interno de etapas](docs/ROADMAP.md), [CI/CD](docs/CI-CD.md), [LocalStack](docs/LOCALSTACK.md), [runtime](docs/RUNTIME-RECOVERY.md).
- [Rede](docs/NETWORK.md), [banco](docs/DATABASE.md), [ECS](docs/ECS.md), [ALB](docs/LOAD-BALANCING.md), [HTTPS](docs/HTTPS.md), [segurança](SECURITY.md).

O desenho AWS é a referência arquitetural. O ambiente executável autorizado é local; infraestrutura faturável na AWS não foi provisionada e não é condição para concluir o trabalho local autorizado.
