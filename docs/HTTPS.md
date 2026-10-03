# HTTPS + ACM no ALB local

A versão 1.5.0 adiciona o equivalente lógico do listener HTTPS `:443` ao Application Load Balancer do CloudTasks e associa um certificado do AWS Certificate Manager emulado.

## O que é validado

```text
Cliente HTTPS
    |
    v
LocalStack TLS gateway :4566
    |
    v
cloudtasks-alb
HTTPS listener lógico :443
    |
    +--> certificado associado no ACM
    |
    v
cloudtasks-tg
2/2 healthy
    |
    +--> ECS task 1
    +--> ECS task 2
             |
             v
      RDS PostgreSQL 16
```

O script cria/reutiliza:

- certificado ACM para `cloudtasks-alb.elb.localhost.localstack.cloud`;
- listener `HTTPS :443`;
- ação `forward` para `cloudtasks-tg`;
- política TLS moderna quando aceita pelo runtime local;
- coexistência com o listener HTTP `:80`.

## Certificado local

Para tornar o laboratório determinístico, o script tenta primeiro reutilizar um certificado `ISSUED`. Se não houver, gera um certificado autoassinado temporário **dentro do container LocalStack**, importa-o no ACM e remove imediatamente os arquivos PEM temporários.

A chave privada não é escrita no host, não entra no ZIP e não deve ser versionada.

Se a importação não estiver disponível no runtime, há fallback para `acm request-certificate`.

## Diferença importante: TLS do gateway LocalStack

O listener e a associação do certificado ACM são recursos do plano de controle ELBv2/ACM emulado. Porém, quando acessamos:

```text
https://cloudtasks-alb.elb.localhost.localstack.cloud:4566
```

o handshake TLS de rede é terminado pelo certificado de infraestrutura do próprio LocalStack no gateway compartilhado `:4566`.

Portanto, no laboratório local não afirmamos que o PEM associado ao ACM é o certificado efetivamente apresentado pelo socket `:4566`.

Em AWS real, a diferença desaparece: o listener HTTPS do ALB termina TLS com o certificado ACM associado.

## Criar/reconciliar

```powershell
.\scripts\localstack\create-https.ps1
```

## Status

```powershell
.\scripts\localstack\status-https.ps1
```

## Teste ponta a ponta

```powershell
.\scripts\localstack\test-https.ps1
```

O teste exige:

- listener HTTPS com `forward` para `cloudtasks-tg`;
- certificado ACM associado ao listener;
- domínio esperado no certificado;
- 2/2 targets healthy;
- `/health` por HTTPS com `database=ok`;
- POST e GET por HTTPS chegando ao RDS;
- listener HTTP permanecendo funcional em paralelo.

O teste usa primeiro o DNS do ALB. Se o ambiente Windows/DNS não conseguir validar esse hostname, usa a URL alternativa oficial do gateway LocalStack:

```text
https://localhost.localstack.cloud:4566/_aws/elb/cloudtasks-alb
```

A validação de certificado TLS não é desabilitada pelo script.

## AWS real

Em produção, o desenho alvo é:

1. domínio real controlado pela organização;
2. certificado público ACM;
3. validação DNS;
4. listener ALB `HTTPS :443` com política TLS moderna;
5. opcionalmente listener `HTTP :80` redirecionando para HTTPS;
6. Target Group gerenciado automaticamente pelo ECS.

O certificado autoassinado importado existe apenas para a emulação local e não é uma recomendação de produção.
