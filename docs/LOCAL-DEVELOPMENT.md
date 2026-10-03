# Desenvolvimento local

## Via Docker

```bash
docker compose up --build
```

Serviços:

```text
app -> http://localhost:3000
db  -> localhost:5432
```

O Compose aguarda o PostgreSQL ficar saudável antes de iniciar a aplicação.

## Via Node.js

1. Instale Node.js 24.
2. Disponibilize PostgreSQL.
3. Copie `.env.example` para `.env`.
4. Execute:

```bash
npm ci
npm run dev
```

Frontend de desenvolvimento: `http://localhost:5173`.
API: `http://localhost:3000`.

## Verificação antes de commit

```bash
npm run verify
```

## Reset do banco local

Somente quando desejar apagar todos os dados:

```bash
docker compose down -v
docker compose up --build
```
