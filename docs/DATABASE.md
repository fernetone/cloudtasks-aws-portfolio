# RDS PostgreSQL e Secrets Manager no LocalStack

O CloudTasks usa uma instância RDS PostgreSQL emulada para representar a camada de dados gerenciada da arquitetura AWS. A versão alvo é PostgreSQL 16.

## Recursos

- RDS identifier inicial: `cloudtasks-postgres`
- identificador ativo pode ser rotacionado para `cloudtasks-postgres-r<timestamp>` quando um runtime local ficar preso
- engine: `postgres`
- engine version: `16`
- database: `cloudtasks`
- master user: `cloudtasks_admin`
- Secrets Manager: `cloudtasks/database`
- DB subnet group lógico: `cloudtasks-db-subnet-group`
- subnets de dados: `cloudtasks-data-private-a` e `cloudtasks-data-private-b`

A senha é gerada na primeira criação e armazenada no Secrets Manager. Os scripts não imprimem o valor no terminal.

## Criar

```powershell
.\scripts\localstack\create-database.ps1
```

O script é idempotente: reutiliza o secret e a instância quando já existem e estão saudáveis. O laboratório usa `RDS_PG_CUSTOM_VERSIONS=0`, evitando instalação dinâmica de pacotes PostgreSQL dentro do container LocalStack. A API RDS continua declarando `engine-version=16`, mas o PostgreSQL efetivamente executado localmente é a versão padrão embarcada do LocalStack. Em AWS real, o alvo permanece PostgreSQL 16.

## Recuperação automática de RDS preso

O bootstrap ainda possui timeout e rotação para instância presa fora de `available`, herdados da fase de snapshots. Isso também foi observado em uma sessão limpa: `creating` não prova estado stale. A política permanece como dívida operacional; ela não é acionada automaticamente pelo CI/CD. O identificador atual fica em `%USERPROFILE%\.cloudtasks\rds-runtime.json`. Consulte [RUNTIME-RECOVERY.md](RUNTIME-RECOVERY.md) e [AUDIT.md](AUDIT.md).

O Secret `cloudtasks/database` continua sendo a referência estável usada pela aplicação. Quando o novo RDS fica disponível, o secret é atualizado com host/porta/identificador correntes sem imprimir a senha.

## Conferir metadados

```powershell
.\scripts\localstack\status-database.ps1
```

O status mostra identificador, engine, endpoint e ARN do secret, mas nunca a senha.

## Testar conexão de verdade

```powershell
.\scripts\localstack\test-database.ps1
```

O teste usa `postgres:16-alpine` como cliente temporário e executa `SELECT 1` contra a porta RDS exposta pelo LocalStack. A senha é lida do Secrets Manager e passada ao container por variável de ambiente, sem ser escrita no terminal.

## Paridade e limitações

O LocalStack inicia um PostgreSQL local acessível pelo endpoint/porta retornados pela API RDS. A documentação atual suporta versões principais PostgreSQL 13 a 17. O suporte de persistência RDS é limitado e algumas propriedades são representadas para compatibilidade de API sem reproduzir integralmente o comportamento físico da AWS.

A topologia de duas subnets privadas de dados é mantida como desenho AWS. Se o provider RDS local não disponibilizar `DBSubnetGroup` na versão instalada, o script registra essa limitação e continua com o runtime local, em vez de fingir que o isolamento de rede foi aplicado fisicamente.

Em AWS real, o banco deve ficar sem acesso público, em DB subnet group privado e com security group aceitando PostgreSQL apenas da camada ECS.

## Compatibilidade com Windows PowerShell 5.1 — v1.2.9

A v1.2.9 deixou de enviar o JSON sensível diretamente em `--secret-string`. No Windows PowerShell 5.1, aspas internas de argumentos nativos podem ser alteradas ao atravessar `docker.exe`, o que pode transformar um JSON válido em texto inválido.

Agora o script grava o JSON em um arquivo temporário UTF-8 sem BOM, copia esse arquivo para o container LocalStack e usa `--secret-string file://...`, seguindo o fluxo suportado pela AWS CLI. O arquivo temporário é removido ao final e a senha não é impressa.

Se um secret criado por uma versão anterior estiver malformado, `create-database.ps1` detecta a situação e tenta recuperar a senha original em memória. Se conseguir, apenas regrava `cloudtasks/database` em JSON válido; se não conseguir, gera uma nova credencial e sincroniza a senha do RDS com `modify-db-instance`. `test-database.ps1` também aciona esse reparo automaticamente antes do `SELECT 1`.
