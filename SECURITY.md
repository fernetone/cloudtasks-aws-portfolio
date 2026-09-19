# Security Policy

## Princípios

- Não versionar segredos, tokens, senhas ou chaves privadas.
- Usar variáveis de ambiente e serviços gerenciados de segredo na AWS.
- Executar containers como usuário não-root.
- Validar entradas da API.
- Aplicar headers de segurança.
- Manter dependências e imagens atualizadas.
- Tratar `/health` como endpoint operacional, sem dados sensíveis.

## Relato de vulnerabilidades

Para este projeto de portfólio, vulnerabilidades devem ser relatadas de forma privada ao mantenedor do repositório, evitando divulgação pública antes da correção.
