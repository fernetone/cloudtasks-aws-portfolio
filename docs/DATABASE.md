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

O script é idempotente: reutiliza o secret e a instância quando já existem e estão saudáveis. O laboratório usa `RDS_PG_CUSTOM_VERSIONS=0`, selecionando a versão padrão do provider, **não garantindo ausência de instalação de pacotes**. A documentação RDS atual informa PostgreSQL 17 como padrão; a página genérica de configuração ainda cita outro padrão. A API continua declarando `engine-version=16`; só uma consulta SQL comprova a versão efetiva. Em AWS real, o alvo permanece PostgreSQL 16. [Referência do provider](https://docs.localstack.cloud/aws/services/rds/#postgresql-engine).

Uma tentativa fria de 04/10/2026 falhou antes do ECS: apt exit100 ao instalar PostgreSQL17.11, com `Cannot allocate memory` no descompactador dpkg e EOF subsequente. Não houve OOM no cgroup nem prova de pacote corrompido: o mesmo pacote, conferido pelo SHA256 do apt, descompactou normalmente nos ensaios isolados. Não se afirma correção permanente da causa interna; a tentativa permanece falha. Isso é comportamento observado do provider local, não do RDS AWS nem da aplicação.

## Primeira criação concorrente — v1.8.1

Cada réplica chama `ensureSchema()` antes de abrir a porta HTTP. `IF NOT EXISTS` não serializava as duas criações simultâneas: uma startup falhou com PostgreSQL23505 em `pg_type_typname_nsp_index`. O teste isolado no PostgreSQL real reproduziu quatro falhas em oito rodadas de duas inicializações; com a correção, as 16 passaram.

`ensureSchema()` adquire um único client do pool, inicia transação, obtém `pg_advisory_xact_lock` com chave estável e só então executa o DDL original. Commit/rollback encerram o lock. Erros continuam propagados; se rollback falhar, a conexão é descartada. Não há retry de erro de catálogo, criação manual prévia da tabela nem alteração de schema/dados. Os sete testes de transação/erro são unitários com IO PostgreSQL simulado; a prova concorrente foi executada separadamente no banco real, em schema isolado, sem tocar a tabela da aplicação.

Isso resolve a inicialização idempotente do schema atual, não substitui um sistema de migrações versionadas para alterações futuras incompatíveis. [Locks PostgreSQL](https://www.postgresql.org/docs/16/explicit-locking.html#ADVISORY-LOCKS); [transações node-postgres](https://node-postgres.com/features/transactions); [registro de execução](EVIDENCE-COLD-REBUILD.json).

## Prazo textual e compatibilidade — v1.8.2

O campo Data/Prazo aceita texto de até 255 caracteres. A migração adiciona `due_text TEXT` na mesma transação serializada; mantém `due_date DATE`, a tabela, os IDs e os demais dados. Datas ISO válidas ficam apenas em `due_date`, com `due_text` nulo. Textos livres ficam apenas em `due_text`, com `due_date` nulo. A leitura prioriza uma data não nula para reconhecer edições de clientes anteriores. A atualização altera somente os campos enviados, evitando que duas réplicas sobrescrevam mudanças independentes de prioridade e conclusão.

O trigger `cloudtasks_legacy_deadline` limpa o texto anterior quando um cliente antigo muda a coluna DATE sem mudar o texto. Assim, uma edição texto → data → prazo nulo pelo cliente antigo não ressuscita o texto anterior. Atualizações que não mudam a data preservam o prazo; a nova API troca os dois campos juntos.

A compatibilidade com releases anteriores cobre os contratos ISO/nulo e a preservação física dos novos textos. A API antiga não aceita prazo textual e o lê como nulo. Em uma linha textual cuja DATE já é nula, um comando antigo que grava novamente nulo é indistinguível de uma edição de outro campo; para limpar esse prazo, usar a API 1.8.2. Uma reversão de imagem não desfaz a migração nem apaga os textos, mas a interface antiga não os apresenta. Não tratar isso como paridade de leitura textual entre releases.

Os testes de integração criam um schema isolado no PostgreSQL real, exercitam inicializações concorrentes, preservação de tarefas antigas, CRUD textual, datas/nulos, edições por cliente anterior e duas atualizações simultâneas. `TEST_DATABASE_URL` habilita esses testes; a CI fornece PostgreSQL 17. Sem essa variável eles ficam explicitamente ignorados, e não contam como prova de banco real.

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
