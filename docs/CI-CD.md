# CI/CD

## GitHub Actions

Cada push e pull request para `main` executa:

```text
install
  -> lint
  -> tests
  -> application build
  -> Docker build
```

## AWS CodePipeline

Arquitetura alvo:

```text
GitHub
  -> CodeConnections
  -> CodePipeline Source
  -> CodeBuild
  -> Amazon ECR
  -> ECS Deploy
```

## CodeBuild

O `buildspec.yml` foi preparado para:

1. autenticar no ECR;
2. rodar `npm install`;
3. executar `npm run verify`;
4. construir a imagem Docker;
5. gerar tag baseada no SHA do commit;
6. publicar `latest` e a tag imutável no ECR;
7. produzir `imagedefinitions.json`.

Variáveis esperadas:

```text
IMAGE_REPO_NAME=cloudtasks
CONTAINER_NAME=cloudtasks
```

O projeto CodeBuild precisará de privileged mode para usar o Docker daemon.
