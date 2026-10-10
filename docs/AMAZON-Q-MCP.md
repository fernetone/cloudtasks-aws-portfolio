# Amazon Q 1.19.7 e os dois MCPs da BIA

A referência mostra `q chat --agent "bia"`, o servidor oficial ECS e o servidor PostgreSQL. Este projeto instala **Amazon Q CLI 1.19.7**, sem substituir a interface por Kiro. A versão exata do Q da filmagem não foi identificada. A integração usa recursos reais do runtime Docker/LocalStack autorizado, sem provisionar AWS paga.

Na raiz do projeto:

```powershell
.\scripts\localstack\create-mcp.ps1
.\scripts\localstack\test-mcp.ps1
.\scripts\localstack\status-mcp.ps1
.\scripts\localstack\create-q-agent.ps1
.\scripts\localstack\status-q-agent.ps1
```

A configuração canônica é `.amazonq/cli-agents/bia.json`. O Q roda em um container temporário separado, com DNS normal para autenticação, binários oficiais conferidos por SHA256 e perfil privado persistido no computador. Os servidores MCP são processos stdio dentro do LocalStack. Dependências ficam em `/opt/cloudtasks-mcp-tools`, no disco interno Linux; a primeira instalação no bind mount do Windows excedeu o tempo de inicialização.

| Componente            | Versão fixada                                 | Verificação                                                                    |
| --------------------- | --------------------------------------------- | ------------------------------------------------------------------------------ |
| ECS oficial           | `awslabs.ecs-mcp-server==0.1.36`              | Inicialização MCP, leitura do cluster/serviço/task definition e escrita negada |
| FastMCP / SDK Python  | `3.4.8` / `1.30.0`                            | Compatibilidade com a API usada pelo servidor ECS                              |
| PostgreSQL oficial    | `@modelcontextprotocol/server-postgres@0.6.2` | Inicialização, recursos/schema e consultas ao banco real                       |
| Cliente de teste Node | `@modelcontextprotocol/sdk@1.0.1`             | Protocolo stdio real; lockfile das dependências Node                           |
| Q legado              | `q 1.19.7`                                    | Binários q e qchat, instalação e status de autenticação                        |

O pacote PostgreSQL oficial é arquivado/depreciado. Foi mantido para reproduzir a integração da referência; isso está registrado no relatório. A instalação não executa scripts npm. As dependências Python centrais são fixadas: FastMCP 4 removeu `add_tool_transformation`, usado pelo pacote ECS, e causou uma rejeição real na inicialização. Essa incompatibilidade foi corrigida por versões compatíveis, sem alterar o código do fornecedor ou seus controles de permissão.

O usuário `cloudtasks_mcp_readonly` tem CONNECT, USAGE e SELECT, sem poderes administrativos ou escrita. O bootstrap confere ownership e endpoint contra a instância RDS atual, preserva contagem/fingerprint das tarefas e prova negação de UPDATE pelo PostgreSQL mesmo fora da transação somente para leitura. A senha fica no Secrets Manager local e em memória durante a conexão. O pedido de criação/atualização do segredo usa um arquivo temporário privado 0600, removido em finally; nenhuma senha vai em argumentos do sistema operacional, configuração do agente, Git ou evidências.

O servidor ECS recebe apenas chaves locais fictícias, endpoint `http://127.0.0.1:4566`, região `us-east-1`, ALLOW_WRITE=false e ALLOW_SENSITIVE_DATA=false. Perfis AWS, licença LocalStack e tokens de sessão não são repassados ao processo oficial. A documentação pública AWS Knowledge usada na inicialização tem acesso HTTPS externo; os recursos ECS continuam presos ao endpoint local.

O agente só expõe `@ecs/ecs_resource_management` e `@postgres/query`, ambos com permissão automática de leitura. Não possui ferramentas internas de shell/arquivos nem carrega servidores legados ocultos. A validação pelo Q e o chat exigem login Builder ID do usuário, inclusive `q agent validate`.

```powershell
.\scripts\localstack\login-q-agent.ps1
.\scripts\localstack\test-q-agent.ps1
.\scripts\localstack\chat-q-agent.ps1
```

O login usa a modalidade free e device flow. Abra o endereço e informe o código exibido; as credenciais ficam no perfil privado. No chat, solicite a lista de clusters, o estado de `cloudtasks-service` e a contagem/schema de `public.tasks`. Os resultados devem vir dos dois MCPs. Configuração aceita, servidores inicializados e resposta do chat autenticado são verificações distintas; não atribuir uma aprovação a outra. [Resultados e tentativas preservadas](EVIDENCE-MCP-Q-20261010.json).
