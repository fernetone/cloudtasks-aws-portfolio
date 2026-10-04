# Dependências e qualidade

`package-lock.json` é versionado. Instalações de CI, CodeBuild e Docker exigem `npm ci`; ausência/desalinhamento do lockfile é erro, sem fallback para `npm install`.

A combinação existente Vite `7.3.6` e `@vitejs/plugin-react` `5.1.3` foi preservada. Mudanças de dependências devem atualizar o lockfile e executar `npm run verify` e Docker build antes de adoção; não usar atualização major automática para tentar corrigir o laboratório.

Node: linha 24. O Dockerfile continua `node:24-alpine`; registrar seu digest e o digest do LocalStack para congelar versões após a homologação. O lockfile não fixa esses runtimes nem garante bytes da imagem idênticos entre plataformas.

`npm run verify` inclui lint sem avisos, testes da aplicação e do controlador/adaptador Blue/Green, e compilação. `npm run format:check` é uma checagem separada; o original apresentava dívida de formatação que não foi corrigida por alteração em massa do código durante esta auditoria. Os resultados atuais de formatação/advisories estão em [AUDIT.md](AUDIT.md).

Vitest possui advisory de severidade moderada no grafo recebido, relacionado ao servidor de testes quando exposto. É dependência de desenvolvimento/teste, não instalada no estágio de produção com `--omit=dev`. Revisar a versão corrigida e compatibilidade em atualização própria; não expor o servidor de testes na rede. Consulte [advisory oficial](https://github.com/vitest-dev/vitest/security/advisories/GHSA-82fw-gwwq-j7x9).

O Express exige quatro parâmetros no middleware de erro. Prefixos `_` são permitidos para parâmetros intencionalmente não usados; a configuração permanece rigorosa para os demais. `eslint.config.mjs` explicita ESM; a fixture ESM de regressões possui globals Node.
