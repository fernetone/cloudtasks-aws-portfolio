# Segurança

## Credenciais e entrega

Não versionar tokens, senhas, chaves privadas ou SecretString. `.env.localstack` é pessoal, ignorado e não acompanha o pacote. Se uma credencial já foi distribuída em ZIP/Git/logs e continua ativa, revogue/substitua no provedor; removê-la do novo pacote não revoga a anterior.

Não reutilizar credenciais AWS reais no LocalStack. Token LocalStack não é variável do CodeBuild. RDS usa `cloudtasks/database` no Secrets Manager; a task definition guarda referência, e a aplicação monta configuração em memória. `DATABASE_SECRET_JSON` nunca deve ser impresso.

## Fronteiras independentes

- Git: `.gitignore` exclui ambientes, runtime, logs, artifacts e builds. Isso não remove itens previamente rastreados; revisar `git ls-files` e histórico antes de publicar.
- S3 Source: seleção positiva dos inputs de build. O publisher bloqueia valores ativos conhecidos do token local/RDS e padrões reconhecíveis de chaves/tokens; não imprime o valor recusado.
- Docker: contexto restrito a manifests/lockfile/configuração e `src` da aplicação; `.env`, PEMs, chaves e diretórios de secrets continuam excluídos. Nenhum runtime/log/documentação/script operacional é enviado ao builder.
- Entrega: empacotar somente código/documentação e conferir o ZIP; `.gitignore` não protege um ZIP criado por outra ferramenta.

A varredura não é prova universal de ausência de qualquer senha arbitrária em código. Não inserir credenciais em inputs aprovados; complementar revisão e scanner de secrets do repositório quando disponível.

## Erros, logs e temporários

Wrappers usados no fluxo sensível exibem serviço/operação/código de saída, sem reproduzir os argumentos ou respostas brutas. Erros de parsing JSON não expõem SecretString. Diagnósticos não despejam logs Docker/CodeBuild/LocalStack automaticamente.

Logs do provider e ambiente dos containers podem conter credenciais porque o executor precisa injetá-las. Eles permanecem disponíveis localmente: não compartilhar `docker inspect` completo, `docker compose config`, dumps de env ou logs sem revisão/redaction. O fato de a ferramenta não ler `.env.localstack` não torna toda saída de logs segura.

O wrapper CodeBuild recebido para análise usa `set -x` e imprime `env`. Erros de download também podem trazer URLs assinadas com credenciais temporárias em parâmetros, inclusive codificadas. O preflight da imagem captura essa saída e exibe somente o exit code em caso de falha; o diagnóstico continua restrito a metadados. Não publicar o `.env` efetivo do runner, arquivos `customer.env`, logs originais ou URLs assinadas. O wrapper pertence ao executor, não foi copiado ou modificado no projeto.

Temporários são removidos em `finally`. Interrupções abruptas podem deixar resíduos em diretórios temporários do usuário/container; revisar resíduos direcionados após interrupção. ACLs/permissões efetivas do Windows ainda precisam de validação local.

## Aplicação e infraestrutura

Containers rodam sem root. Zod valida payloads, SQL é parametrizado, Helmet e graceful shutdown estão ativos. Este CRUD de demonstração não é um serviço público com autenticação/autorização de usuários implementadas. Credenciais públicas de exemplo do Compose/fallback local não são o secret ativo do RDS; não usá-las em produção nem substituir o secret real por esses valores.

O socket Docker compartilhado dá poder amplo ao runner: executar apenas Source confiável em um laboratório pessoal. Bind de gateway/portas RDS limita-se a localhost; o isolamento local não equivale aos security groups da AWS.

Policies IAM locais representam papéis e integrações, mas ainda incluem wildcards. Antes de deploy AWS real, restringir ARNs/PassRole, concretizar capacidade EC2/rede e revisar autenticação e TLS do banco. O modo SSL atual com `rejectUnauthorized: false` não certifica conexão RDS produtiva.

## HTTPS

Chave/PEMs de laboratório são gerados dentro do container e removidos após importação ACM. O certificado ACM valida a configuração do listener; o gateway LocalStack termina o TLS efetivo em `:4566`.

Na AWS real, usar certificado ACM validado e ALB terminando TLS; não transportar certificado autoassinado nem exceções de validação TLS do laboratório para produção.

## Estado

`PERSISTENCE=0` e bind por sessão não são backup. Metadados auxiliares guardam nomes, IDs, URIs, hashes/digests e revisões; não guardam token ou senha. Nunca incluir `%USERPROFILE%\.cloudtasks`, `.localstack` ou diretórios de sessão na entrega/Git/Source.
