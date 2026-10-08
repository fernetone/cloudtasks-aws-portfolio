# Referência obrigatória do projeto - vídeo BIA

Revisão de 08/10/2026. Este documento define o escopo solicitado pela usuária e substitui interpretações anteriores de equivalência apenas conceitual. A entrega solicitada é a reprodução do projeto demonstrado, incluindo aplicação, comportamento, apresentação e infraestrutura AWS efetiva. LocalStack é um ambiente auxiliar de desenvolvimento e testes; seus resultados não encerram a entrega final.

## Fonte, método e limites

- Vídeo fornecido: `1000328093.mp4`, duração 57,636 s, resolução 720 x 1600.
- SHA256: `c6e4eee64c325c375d62300cb8b1fc13745ab955b184668030dca55feab0e2b5`.
- Foram examinados quadros ao longo de toda a duração, telas em resolução original e as legendas incorporadas. Os tempos abaixo permitem localizar as evidências.
- Código comparado: `main` do projeto em `b17a31d3269f116f3f2531501b1e7ebf49fac43a` (1.8.0), e checkpoint local 1.8.1 da reconstrução fria ainda pendente.
- O repositório público [henrylle/bia](https://github.com/henrylle/bia) foi consultado como fonte complementar, inclusive a revisão histórica `8799459fa1dcf67ac041f134c9b08aa8f5ac60c7`. Esse commit não foi identificado como a release da gravação: seus textos também diferem do vídeo. Não copiar a versão atual e declará-la idêntica à versão filmada.
- O recorte não revela todos os arquivos, configurações, permissões, dados nem operações CRUD. Igualdade integral de código/configuração exige a identificação da revisão original e seus arquivos de infraestrutura. Configurações ocultas permanecem não verificadas.
- Na revisão documental inicial, o dispositivo `Monitor` estava offline. Após a reconexão em 08/10/2026, os resultados preservados de 04/10 foram lidos: a terceira reconstrução teve sete etapas com exit code 0. Na sessão de 08/10, a primeira inicialização ultrapassou o timeout; depois da recuperação do serviço, o bootstrap e os testes de banco/ECS/ALB/HTTPS passaram. Esses dois eventos e a falha inicial são registros distintos.

## Comparação vinculada à referência

| ID | Tempo e evidência | Estado encontrado no projeto | Correção e prova exigidas |
| --- | --- | --- | --- |
| V01 | 00-03 s: CodePipeline com Source **GitHub (via GitHub App)**, Build **AWS CodeBuild** e Deploy **Amazon ECS**, todos em verde. | Source local é snapshot S3. GitHub Actions e publicação do repositório existem, mas não equivalem à integração GitHub da CodePipeline. Os arquivos AWS atuais não provisionam essa pipeline completa. | Implementar a origem GitHub por conexão autorizada e a pipeline AWS; comprovar que um commit dispara Source, Build e Deploy e altera a imagem servida. |
| V02 | 02-03 s: provedor de Deploy é **Amazon ECS**, sem CodeDeploy ou Blue/Green mostrado. | Rolling é o modo local padrão; o Blue/Green local usa outra ação CodeBuild e um adaptador específico do emulador. | Reproduzir primeiro a ação ECS padrão na AWS. Preservar a solicitação posterior de Blue/Green e suas provas como trabalho adicional; seu aceite não substitui V01 nem certifica o controlador AWS. |
| V03 | 04-10 s: Amazon Q CLI `q chat --agent "bia"` em terminal do Systems Manager, com `awslabs.ecs-mcp-server` e `postgres` listados. Há aviso de carregamento de MCP. | Sem arquivos ou instalação de agente Q/MCP no projeto. O acesso pelo Desktop Commander é uma ferramenta de trabalho, não essa integração. | Configurar agente, MCP ECS e MCP PostgreSQL com credenciais em runtime e permissões delimitadas; demonstrar consultas reais aos recursos e ao banco. A imagem do vídeo não comprova que ambos os servidores terminaram de carregar. |
| V04 | 11-20 s: ALB ativo, internet-facing, duas AZs e dois listeners HTTP 80 / HTTPS 443. | Topologia e listeners emulados; conexão HTTPS local termina no gateway LocalStack. Infraestrutura AWS completa ausente. | Implantar ALB e TLS/ACM efetivos na conta/região autorizadas, duas AZs e ambos os listeners; conferir o certificado apresentado e o tráfego real. |
| V05 | 13-16 s: dois targets **Healthy** identificados por `i-...`, porta 32768; ECS também é mencionado. | Executor Docker sem EC2 reais registradas; TG local `ip` e porta 3000. A etiqueta EC2 da API emulada não cria os hosts. | Implementar capacidade ECS/EC2, hosts registrados e TG `instance` com registro instância/porta; provar duas réplicas atendendo e retirada de um target sem perder o serviço. A porta filmada não deve ser fixada apenas para imitar a captura. |
| V06 | 19-21 s: aplicação Node/React e banco PostgreSQL são mencionados. | Mesmas tecnologias gerais, mas implementação independente. `PERSISTENCE=0` descarta o banco em uma nova sessão local. | Entregar PostgreSQL durável na infraestrutura final e CRUD compartilhado pelas réplicas; registrar persistência após reiniciar a aplicação. O vídeo não mostra console RDS, versão do engine, esquema ou estratégia de migração. |
| V07 | 21-32 s: distribuição CloudFront existente, **Disabled**, descrição `cdn.formacaoaws.com.br`; o autor explica que já a desabilitou após o trabalho. | CloudFront ausente; chamadas ao ALB/gateway não exercitam CDN. | Implementar distribuição e origin, preservar chamadas da API sem cache indevido e validar TLS/tráfego/cache. Registrar habilitação/desabilitação separadamente. A tela Disabled prova configuração existente, não tráfego CDN ativo. Domínio do autor não é domínio autorizado da usuária. |
| V08 | 33-57 s: cartão escuro BIA, formulário vertical, botão verde, indicador circular e controle de tema. | Tela clara CloudTasks; cabeçalho de portfólio, formulário em colunas, badge técnico, contador e título de fila adicionais. | Reproduzir a tela observável, com os textos BIA, margens, cores, proporções e ordem do formulário; verificar visualmente em desktop e celular. A identidade visual não está dispensada do escopo literal. |
| V09 | 33-57 s: `Tarefa`, `O que você precisa fazer?`, `Data/Prazo`, `Quando?`, `Importante`, `Adicionar Nova Tarefa`. | Label, capitalização e campo de data diferem. `taskSchema.ts` exige ISO; `db.ts` usa DATE. O código público BIA complementar usa texto em `dia_atividade`. | Alinhar o comportamento de prazo após confirmar a revisão original, preservando os dados existentes e testando compatibilidade. Trocar somente o placeholder não resolve a diferença de contrato/banco. |
| V10 | 38-57 s: `Nenhuma tarefa por aqui`, instrução para usar o formulário, rodapé `Formação AWS` / `Sobre a BIA`. | Outro estado vazio; rodapé e destino Sobre a BIA ausentes. | Reproduzir textos e navegação com destino funcional; não inserir link sem implementação. Conteúdo de telas não exibidas depende de confirmação da referência. |
| V11 | 39-40 s: CRUD completo é declarado; não há execução das quatro operações na gravação. | API implementa criação/listagem/edição/exclusão e conclusão. A tela não permite mudar Importante após criar; o código público complementar usa estrela/duplo clique para isso. | Demonstrar o CRUD e a prioridade do original com dados reais, em ambas as réplicas. Não retirar operações existentes nem inventar fluxos ocultos antes de confirmar a versão original. |
| V12 | 42-57 s: indicador verde visível. O código público complementar consulta a API para decidir o estado. | O badge `API + PostgreSQL` tem ponto verde fixo, inclusive quando a carga falha. | O indicador deve refletir verificação real de disponibilidade, falha e recuperação; evitar estado saudável apenas decorativo. |

## Correções de escopo feitas nesta revisão

1. AWS real, capacidade ECS/EC2, TG por instância, integração GitHub, CloudFront e Q/MCP passam a ser requisitos da entrega, não possibilidades de expansão.
2. A aplicação e a identidade visual BIA entram no aceite literal. A frase anterior que dispensava copiar nome/interface foi retirada.
3. As 13 etapas anteriores são um plano interno. A gravação não fornece uma sequência oficial de 13 etapas.
4. O Deploy mostrado é ECS padrão. O adaptador Blue/Green não deve ser apresentado como mecanismo demonstrado no vídeo nem como homologação produtiva AWS.
5. Histórico de testes locais aprovado permanece válido no seu contexto. Não é convertido em prova atual do Windows ou paridade AWS.
6. O projeto não está concluído nem idêntico à referência. A revisão documental corrigiu os critérios; a atualização 1.8.2 agora implementa a tela observável, tema, saúde real, prazo textual e edição de prioridade. Os testes de integração PostgreSQL e a verificação visual da nova tela são requisitos antes do aceite desta atualização. Recursos AWS e conteúdo de telas não exibidas seguem sem comprovação.

## Encaminhamento obrigatório

1. Restabelecer o acesso e ler o estado do Docker/LocalStack e o resultado preservado do bootstrap interrompido. Não refazer/resetar a sessão como preflight de leitura.
2. Vincular a revisão original da BIA e as configurações de infraestrutura disponíveis à comparação, e confirmar conta/região/conexão GitHub/domínio da implantação. Não pedir nem publicar valores de credenciais no chat ou no código.
3. Implementar as diferenças de interface, prazo, prioridade e estado de saúde com testes específicos e migração compatível quando necessária. Preservar os contratos e dados existentes durante a transição.
4. Concretizar infraestrutura AWS, ECS/EC2, banco, ALB/TG/ACM e pipeline GitHub -> CodeBuild -> ECS padrão; comprovar uma entrega disparada por commit.
5. Completar CloudFront e o agente Amazon Q com os dois MCPs. Os ensaios LocalStack podem apoiar o desenvolvimento, sem encerrar esses itens.
6. Reexecutar a matriz V01-V12, anexar as provas e só então declarar a equivalência demonstrada. Toda configuração não observada deve ficar identificada, sem promessa de igualdade byte a byte.

## Critério de encerramento

Testes de qualidade verdes, banco local funcionando ou Blue/Green local aprovado são necessários nos respectivos contextos, mas não bastam. O encerramento exige aplicação fiel à referência e evidências atuais de cada serviço final na AWS. O recorte do vídeo também não autoriza assumir igualdade de configurações que ele não mostra.
