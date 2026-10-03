# Amazon ECR — Etapa 3

Este documento e os scripts em `scripts/aws` descrevem a etapa 3 para uma conta AWS real. Foram preservados do repositório existente; não foram executados nesta consolidação. Para o laboratório LocalStack, use [PIPELINE.md](PIPELINE.md) e os scripts de `scripts/localstack`.

## Decisões adotadas

- Região padrão do projeto: `us-east-1`.
- Nome do repositório: `cloudtasks`.
- Repositório privado.
- Tags imutáveis: cada build da pipeline recebe `pipeline-<UUID v4>`, e a tag não pode ser sobrescrita. Commit, Source e digest completam a identidade; a primeira publicação manual usa uma tag própria.
- Scan on push habilitado para verificar vulnerabilidades ao enviar novas imagens.
- Criptografia AES-256 gerenciada pelo ECR.
- Sem tag `latest` na pipeline: o deploy usa a URI exata produzida pelo build e registrada no artifact.
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

## CodeBuild e artifact ECS

O `buildspec.yml` usa estas variáveis de ambiente:

```text
IMAGE_REPO_NAME=cloudtasks
CONTAINER_NAME=cloudtasks-app
```

Na AWS, o `buildspec.yml` descobre o Account ID, autentica no ECR e publica a tag imutável `pipeline-<UUID v4>`, gerada dentro do build. Não deriva a tag de `CODEBUILD_BUILD_ID`. O buildspec local explicita os endpoints do emulador.

O artifact `imagedefinitions.json` usa exatamente a mesma URI e o nome do container `cloudtasks-app`. A ação ECS padrão da etapa 8 o consome na CodePipeline; a homologação local e seus limites estão em [EVIDENCE-CICD.json](EVIDENCE-CICD.json).

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
