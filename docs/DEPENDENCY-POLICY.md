# Política de dependências

As dependências do toolchain que possuem forte acoplamento entre versões podem ser fixadas explicitamente.

Exemplo atual:

- `vite`: `7.3.6`
- `@vitejs/plugin-react`: `5.1.3`

Isso evita que uma atualização automática introduza uma combinação de peer dependencies incompatível durante builds Docker ou CI.

Após a geração do `package-lock.json`, os ambientes de CI devem preferir `npm ci`.
