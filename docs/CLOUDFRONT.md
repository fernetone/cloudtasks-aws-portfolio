# CloudFront da BIA no LocalStack

A distribuição usa o ALB do projeto como origin e termina o teste em **Disabled**, estado mostrado no vídeo. Não usa o domínio do autor. O tráfego funcional foi verificado pelo domínio gerado pelo provider, incluindo HTML, JavaScript, CSS e CRUD no PostgreSQL compartilhado.

Na sessão saudável, execute na raiz do projeto:

```powershell
.\scripts\localstack\create-cloudfront.ps1
.\scripts\localstack\test-cloudfront.ps1
.\scripts\localstack\status-cloudfront.ps1
```

O teste habilita temporariamente apenas a distribuição própria, confere ownership, configuração e ETag, exercita o proxy e restaura Disabled. Mudanças concorrentes ou uma resposta ambígua de atualização encerram o teste e preservam o estado para investigação. A tarefa temporária do CRUD é excluída.

Na sessão de 10/10, o endereço efetivamente testado foi `https://bdf15dae.cloudfront.localhost.localstack.cloud:4566`. Consulte o status para obter o domínio de uma sessão nova. O alias `cloudtasks-cdn.localhost.localstack.cloud` é declarado, mas não roteou no provider; a primeira tentativa rejeitada está preservada na [evidência](EVIDENCE-CLOUDFRONT-20261010.json).

| Fronteira             | Configuração / resultado verificado                           | Limite do provider                                            |
| --------------------- | ------------------------------------------------------------- | ------------------------------------------------------------- |
| Origin                | ALB próprio, HTTP interno em 4566                             | Não certifica TLS entre CDN e origin AWS                      |
| API e rotas dinâmicas | Métodos CRUD permitidos, query strings encaminhadas, TTL zero | Sem cache hit certificado                                     |
| Assets                | Bytes e hashes iguais ao ALB; TTL estático declarado          | Cache de edge não implementado                                |
| HTTPS do viewer       | Tráfego real com pin do certificado do gateway                | Não certifica certificado CloudFront/ACM AWS                  |
| Redirect              | `redirect-to-https` declarado                                 | HTTP respondeu 200, sem redirect efetivo                      |
| Disabled              | Estado final lido pela API e ETag                             | HTTPS ainda respondeu 200; bloqueio de tráfego não é aplicado |

O navegador desktop/celular continua usando o ALB. O teste CloudFront foi pelo protocolo HTTP, sem certificar navegação pelo domínio da CDN. As duas origens de CORS permitidas no LocalStack permanecem as do ALB; não ampliar essa configuração apenas para esconder diferenças do provider.
