# Observabilidade funcional da BIA

O coletor observa as tasks físicas Docker, cruza os IPs com os targets saudáveis do ALB e faz uma requisição HTTPS real a `/health`, que consulta o PostgreSQL. Publica métricas customizadas em `CloudTasks/LocalStack`, logs sanitizados e um dashboard com quatro widgets. Não apresenta CPU/memória AWS fabricadas.

Na raiz do projeto, com a sessão saudável:

```powershell
.\scripts\localstack\create-observability.ps1
.\scripts\localstack\status-observability.ps1
.\scripts\localstack\test-observability.ps1
```

`create` é idempotente para o runtime próprio e inicia um processo Node no Windows. O ciclo espera 30 segundos entre coletas; a coleta e a publicação acrescentam sua duração. PID, identidade do processo e heartbeat recente são conferidos. Depois de reiniciar o computador, execute novamente `create`; não há serviço global instalado. Um PID ocupado por outro processo não é encerrado.

| Métrica         | Medição                                                                              |
| --------------- | ------------------------------------------------------------------------------------ |
| RunningReplicas | Containers RUNNING associados às tasks atuais do serviço                             |
| HealthyReplicas | Interseção entre containers saudáveis e targets healthy com os mesmos IPs/porta 3000 |
| ProbeUp         | 1 apenas para HTTP 200 com `status=ok` e `database=ok`                               |
| ProbeLatency    | Tempo real da requisição, em milissegundos                                           |

Os alarmes `cloudtasks-healthy-replicas` e `cloudtasks-health-probe` usam mínimo, período de 60 segundos e dois pontos em três abaixo de 2 e 1, respectivamente. Ausência de dados é breaching; a inicialização pode causar ALARM até completar a janela saudável. Não há SNS, e-mail ou notificações externas. Os logs `/cloudtasks/observability` têm retenção de sete dias.

O teste de alarme usa um servidor HTTP isolado que responde 200 → 503 → 200. O provider avaliou as medições e mudou INSUFFICIENT_DATA → OK → ALARM → OK. Não foi usado `SetAlarmState`, nem foi provocada indisponibilidade na BIA. O teste também lê de volta métricas, logs e dashboard. [Evidência e conferência posterior do runtime](EVIDENCE-OBSERVABILITY-20261010.json).

Em 10/10, o monitor detectou targets antigos enquanto o ECS declarava duas tasks novas. A imagem/digest era a mesma. Os novos targets foram registrados antes de retirar os antigos; somente dois containers do projeto, ligados a tasks STOPPED, foram parados. O banco e a revisão da aplicação foram preservados. A causa da substituição automática continua não comprovada; essa reconciliação é registrada separadamente da aprovação anterior da pipeline.
