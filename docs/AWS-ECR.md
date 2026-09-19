# Amazon ECR — Etapa 3

Esta etapa cria o primeiro recurso AWS persistente do CloudTasks: um repositório privado no Amazon Elastic Container Registry (ECR) para armazenar as imagens Docker da aplicação.

## Decisões adotadas

- Região padrão do projeto: `us-east-1`.
- Nome do repositório: `cloudtasks`.
- Repositório privado.
- Tags imutáveis: cada imagem será identificada pelo SHA do commit e não poderá ser sobrescrita.
- Scan on push habilitado para verificar vulnerabilidades ao enviar novas imagens.
- Criptografia AES-256 gerenciada pelo ECR.
- Sem tag `latest` na pipeline: o deploy usa a imagem exata associada ao commit.
- Lifecycle policy mantém as 20 imagens mais recentes e expira as anteriores.

## Criar o ECR via PowerShell

Pré-requisitos: AWS CLI configurada e Docker Desktop em execução.

```powershell
.\scripts\aws\create-ecr.ps1
```

Por padrão o script usa:

```text
Region=us-east-1
RepositoryName=cloudtasks
```

Outra região pode ser informada explicitamente:

```powershell
.\scripts\aws\create-ecr.ps1 -Region sa-east-1
```

O script é idempotente: se o repositório já existir, ele apenas confirma a configuração e aplica a lifecycle policy.

## Publicar a primeira imagem manualmente

Depois que o repositório existir:

```powershell
.\scripts\aws\push-ecr-image.ps1
```

A imagem recebe uma tag única no formato `manual-YYYYMMDDHHmmss`, evitando colisões em um repositório com tags imutáveis.

No final o script imprime a URI completa da imagem, por exemplo:

```text
123456789012.dkr.ecr.us-east-1.amazonaws.com/cloudtasks:manual-20260919230000
```

## Futuro CodeBuild

O `buildspec.yml` usa estas variáveis de ambiente:

```text
IMAGE_REPO_NAME=cloudtasks
CONTAINER_NAME=cloudtasks
```

O CodeBuild descobre o Account ID automaticamente, autentica no ECR, cria uma tag com os 12 primeiros caracteres do commit e publica somente essa tag imutável.

O artefato `imagedefinitions.json` usa exatamente a mesma URI e será consumido posteriormente pela etapa de deploy do Amazon ECS no CodePipeline.

## Permissões do CodeBuild

O arquivo [`../aws/iam/codebuild-ecr-policy.json`](../aws/iam/codebuild-ecr-policy.json) contém as permissões mínimas de push para o repositório `cloudtasks`. A role do CodeBuild também terá as permissões operacionais normais de logs/artifacts configuradas quando criarmos o projeto CodeBuild.

## Critério de conclusão da Etapa 3

A etapa está concluída quando:

1. o repositório privado `cloudtasks` existir no ECR;
2. tag immutability estiver habilitada;
3. scan on push estiver habilitado;
4. a primeira imagem CloudTasks aparecer no ECR;
5. a imagem puder ser identificada por uma tag única;
6. a URI da imagem estiver registrada para uso futuro no ECS.
