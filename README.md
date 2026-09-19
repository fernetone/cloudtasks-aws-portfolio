# CloudTasks — AWS DevOps Portfolio Project

> **Versão consolidada da Etapa 2:** 1.1.3


Aplicação full stack criada para demonstrar, de ponta a ponta, uma arquitetura de produção baseada em containers e serviços AWS.

O objetivo do projeto não é apenas entregar um CRUD: é mostrar o caminho completo entre **código, qualidade, imagem Docker, CI/CD, execução no Amazon ECS, alta disponibilidade, banco gerenciado, CDN, observabilidade e operação assistida por IA**.

## Arquitetura alvo

```text
Developer
   |
   v
GitHub
   |
   v
AWS CodePipeline
   |
   +--> Source: GitHub via AWS CodeConnections
   |
   +--> Build: AWS CodeBuild
             |
             +--> npm install
             +--> lint + tests + build
             +--> docker build
             +--> push image
                     |
                     v
                  Amazon ECR
                     |
                     v
               Amazon ECS / EC2
                 /         \
              Task 1      Task 2
                 \         /
                  Target Group
                     |
                     v
          Application Load Balancer
                     |
                     v
               Amazon CloudFront
                     |
                     v
                   User

Amazon ECS ---> Amazon RDS PostgreSQL

Amazon Q Developer CLI ---> MCP servers ---> AWS / GitHub / tooling
```

## Stack

- React 19 + TypeScript + Vite
- Node.js 24 + Express 5 + TypeScript
- PostgreSQL 16
- Docker + Docker Compose
- Vitest + Supertest
- ESLint + Prettier
- GitHub Actions para quality gate
- AWS CodeBuild/CodePipeline preparado via `buildspec.yml`

## Estado atual

### Etapa 1 — aplicação local

- [x] CRUD completo de tarefas
- [x] API REST
- [x] PostgreSQL
- [x] Dockerfile multi-stage
- [x] Docker Compose
- [x] `/health` com verificação do banco
- [x] persistência local

### Etapa 2 — GitHub e qualidade

- [x] lint com ESLint
- [x] padronização com Prettier
- [x] testes automatizados da API
- [x] testes automatizados do frontend
- [ ] `package-lock.json` (será gerado no primeiro `npm install` local e então versionado)
- [x] workflow de CI para GitHub Actions
- [x] `buildspec.yml` preparado para ECR + ECS
- [x] encerramento gracioso para deploys no ECS
- [x] security headers com Helmet
- [ ] repositório GitHub publicado
- [ ] proteção da branch `main`

O restante está em [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Rodar com Docker Compose

Pré-requisito: Docker Desktop.

```bash
docker compose up --build
```

Acesse:

- Aplicação: `http://localhost:3000`
- Health check: `http://localhost:3000/health`
- API: `http://localhost:3000/api/tasks`

Para desligar sem apagar os dados:

```bash
docker compose down
```

> `docker compose down -v` remove também o volume do PostgreSQL e deve ser usado apenas quando a intenção for zerar o banco local.

## Qualidade

Instale as dependências:

```bash
npm install
```

Execute toda a validação:

```bash
npm run verify
```

O comando executa, em sequência:

```text
ESLint
   -> testes da API
   -> testes do frontend
   -> build de produção
```

Também é possível executar individualmente:

```bash
npm run lint
npm test
npm run build
npm run format
```

## API

| Método | Endpoint | Finalidade |
| --- | --- | --- |
| GET | `/health` | readiness/health check, incluindo PostgreSQL |
| GET | `/api/tasks` | listar tarefas |
| POST | `/api/tasks` | criar tarefa |
| PUT | `/api/tasks/:id` | atualizar tarefa |
| DELETE | `/api/tasks/:id` | excluir tarefa |

## CI local e GitHub

O workflow `.github/workflows/ci.yml` valida cada push/PR para `main` com:

1. `npm install`
2. `npm run verify`
3. `docker build`

Isso evita que código que não compila ou quebre testes avance para a etapa AWS.

## Preparação para AWS CodeBuild

O arquivo `buildspec.yml` já está preparado para a futura pipeline. O projeto CodeBuild deverá receber estas variáveis de ambiente não sensíveis:

```text
IMAGE_REPO_NAME=cloudtasks
CONTAINER_NAME=cloudtasks
```

`AWS_DEFAULT_REGION` é fornecida pelo ambiente AWS. O `buildspec.yml` descobre o Account ID em tempo de execução, autentica no ECR, gera uma tag baseada no commit, publica a imagem e produz `imagedefinitions.json` para a ação de deploy padrão do Amazon ECS.

O projeto CodeBuild precisará de **privileged mode** para executar builds Docker.

Detalhes: [`docs/CI-CD.md`](docs/CI-CD.md).

## Segurança já aplicada

- nenhuma credencial real versionada;
- `.env` ignorado pelo Git;
- payload JSON limitado a 100 KB;
- validação de entrada com Zod;
- IDs de tarefa validados como UUID;
- cabeçalhos de segurança com Helmet;
- imagem final executada com usuário não-root;
- banco não empacotado junto da aplicação;
- graceful shutdown para `SIGTERM`/`SIGINT`.

## Documentação

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — arquitetura alvo
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — etapas do projeto
- [`docs/CI-CD.md`](docs/CI-CD.md) — fluxo GitHub/CodeBuild/ECR/ECS
- [`docs/LOCAL-DEVELOPMENT.md`](docs/LOCAL-DEVELOPMENT.md) — ambiente local
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — decisões arquiteturais
- [`docs/DEPENDENCY-POLICY.md`](docs/DEPENDENCY-POLICY.md) — política de versões do toolchain frontend
- [`SECURITY.md`](SECURITY.md) — princípios de segurança

## Próximo marco

Publicar o código no GitHub e, em seguida, criar o **Amazon ECR**. Esse será o primeiro recurso AWS persistente do projeto.


## Preparacao do repositorio no Windows

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\prepare-repository.ps1
```

O script usa Node.js 24 dentro do Docker; nao e necessario instalar Node.js no Windows.


### Qualidade de código

