# Desenvolvimento local

## Docker Compose

```bash
docker compose up --build
```

Aplicação: `http://localhost:3000`

Health: `http://localhost:3000/health`

## Persistência

O PostgreSQL usa o volume `cloudtasks_pgdata`.

`docker compose down` preserva os dados.

`docker compose down -v` remove os dados e deve ser usado somente quando um reset for desejado.
