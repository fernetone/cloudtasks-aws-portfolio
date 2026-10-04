# Sessões e recuperação do laboratório

## Modelo

O laboratório usa `PERSISTENCE=0`. Cada nova inicialização recebe um bind mount em `%USERPROFILE%\.cloudtasks\localstack-runtime\session-*`. O bind permanece necessário ao executor CodeBuild; não é backup nem fonte de verdade dos recursos AWS entre sessões.

Código e scripts descrevem a configuração local. Metadados em `%USERPROFILE%\.cloudtasks` identificam sessão/cluster/RDS; imagens podem permanecer no cache Docker. `.env.localstack` é pessoal e ignorado.

Recursos e **dados de negócio** do RDS são descartáveis nesse modelo. Não se deve esperar que uma nova sessão recupere as tarefas cadastradas na anterior. Na AWS alvo, RDS e recursos são persistentes; essa escolha não reproduz durabilidade AWS.

## Donos das operações

- `resume-environment.ps1`: preparação explícita e reconciliação da aplicação/ALB/HTTPS.
- `create-cicd.ps1`: preflight e entrega pela pipeline, sem bootstrap/reset/reparo implícito.
- `status-*` / `diagnose-*`: leitura e metadados; não corrigem recursos.
- `repair-*`: ferramentas excepcionais existentes, fora do caminho normal de CI/CD. Não devem ser a primeira resposta a uma falha do verificador.

Sessão já saudável: executar somente `create-cicd.ps1` e `test-cicd.ps1`. Sessão realmente indisponível: verificar Docker Desktop/contexto e usar `resume-environment.ps1`. `start-localstack.ps1` cria uma nova sessão; não usá-lo apenas para tentar remover um erro de CI/CD.

## Histórico observado e limites

Execuções anteriores com snapshots tiveram RDS/ECS/ECR restaurados sem runtime/endpoints compatíveis. O modelo efêmero reduz essa classe de problemas. Ele não elimina bugs de scripts, falhas do executor, lentidão de provisioning ou dependências de rede.

O transcript de 01/10 mostrou RDS em `creating` ultrapassando o timeout e duas rotações antes de ficar disponível. Não há evidência suficiente para afirmar a causa do provisioning lento. A correção do preflight Docker não certifica que esse comportamento do RDS foi resolvido.

A política atual de timeout/rotação do bootstrap e a sincronização do ALB continuam como dívida operacional explicitada em [AUDIT.md](AUDIT.md). Não ampliar essa recuperação para o CI/CD. Limpeza de sessões/containers antigos deve ser explícita, direcionada e feita após identificar o que pertence à sessão em uso.

## Repetibilidade

Lockfile e Source normalizado tornam inputs rastreáveis. `localstack/localstack-pro:latest` e `node:24-alpine` continuam tags móveis: registre os digests realmente executados antes de congelar uma versão testada. Não atualize o emulador no meio da homologação. Reconstrução determinística de configuração não promete reprodução binária completa entre versões/plataformas.

## Recuperação Blue/Green

Com `RECOVERY_REQUIRED`, o candidato que atende, suas regras/TG e o lock S3 são preservados. Não executar resume/reset/repair geral nem apagar o lock para continuar a pipeline. Examinar o recibo da execução e o estado nativo, conferir quais destinos atendem e recuperar somente os recursos registrados. Quando o serviço principal foi alterado depois do bake, restaurar a imagem anterior pode exigir novas tasks; não afirmar que os containers blue originais foram preservados.

Somente depois de conferir APIs, containers/digest, HTTP/HTTPS e CRUD/RDS e ausência dos temporários deve-se liberar o proprietário exato do lock. Registrar a recuperação como administrativa, separada. A pipeline e o recibo falhos permanecem falhos; `last-deploy.json` só é escrito por uma entrega nativa efetivamente aprovada. Os operadores descartáveis da investigação não aumentam a coleção permanente de scripts. [Estados e critérios](BLUE-GREEN.md).
