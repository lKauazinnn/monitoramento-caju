# Fase 2 — Ingestão

Estado: **entregue.** Camada de banco validada contra PostgreSQL 16 real (12
sub-testes). Lógica pura da Edge Function validada com Node (34 testes). O HTTP
da Edge Function só pode ser testado depois de publicada — script pronto.

---

## 1. Decisão de arquitetura: a lógica ficou no banco

Você pediu Edge Function e não respondeu à minha pergunta sobre RPC direto.
Segui o stack que você definiu — a função existe — mas **coloquei toda a decisão
dentro do PostgreSQL** e deixei a Edge Function como casca fina.

O que vive onde:

| Responsabilidade | Onde | Por quê |
|---|---|---|
| Segredo compartilhado (regra 6) | Edge Function | é da camada HTTP |
| Validação de token | `ingest_batch` (SQL) | atômico com a gravação |
| Rate limit | `ingest_consume_quota` (SQL) | precisa de estado transacional |
| Janela temporal | `register_metrics` (SQL) | idem, e é regra de negócio |
| Coerção de tipos | `register_metrics` (SQL) | fonte única |
| SQLSTATE → HTTP | Edge Function | é tradução de protocolo |

**O ganho:** a Fase 2 inteira é testável com `psql`, sem subir Deno nem
publicar nada. Regra duplicada em duas linguagens é como as duas divergem — e a
divergência aparece em produção, não em teste.

**Consequência prática:** se você depois quiser matar a Edge Function e apontar
os agentes direto para `POST /rest/v1/rpc/ingest_batch`, funciona sem tocar em
nada do banco. O caminho fica aberto.

---

## 2. Contrato da API

### `POST /functions/v1/ingest`

Headers:

```
x-monitor-secret: <INGEST_SHARED_SECRET>
Authorization: Bearer mon_<64 hex>
Content-Type: application/json
```

Corpo:

```json
{
  "agent_version": "1.0.0",
  "sent_at": "2026-08-04T22:31:05.120Z",
  "machine": {
    "hostname": "PDV01-BSB001",
    "os_caption": "Microsoft Windows 11 Pro",
    "os_version": "10.0.26200",
    "os_arch": "64 bits",
    "cpu_model": "11th Gen Intel(R) Core(TM) i5-11400 @ 2.60GHz",
    "cpu_cores": 6,
    "mem_total_mb": 32561,
    "ip_lan": "10.10.1.11"
  },
  "samples": [
    {
      "t": "2026-08-04T22:30:05.000Z",
      "cpu_pct": 11.0,
      "cpu_queue_length": 0,
      "mem_total_mb": 32561,
      "mem_used_mb": 18194,
      "swap_used_mb": 0,
      "uptime_seconds": 116182,
      "proc_count": 282,
      "thread_count": 4229,
      "cpu_temp_c": null,
      "gw_latency_ms": 1.2,
      "gw_loss_pct": 0,
      "central_latency_ms": 18.4,
      "flags": ["temp_denied"],
      "disks": [
        {
          "drive": "C:", "volume_label": "", "filesystem": "NTFS",
          "total_gb": 237.50, "free_gb": 121.03,
          "smart_ok": true, "smart_source": "wmi", "media_type": "SSD"
        }
      ],
      "services": [
        { "name": "Spooler", "is_running": true, "start_mode": "Auto", "state_raw": "Running" }
      ]
    }
  ]
}
```

Notas de contrato que o agente da Fase 3 precisa respeitar:

- **`t` é o relógio do agente em UTC** e é a chave da série (regra 12).
- **`sent_at` é o relógio do agente no momento do ENVIO**, não da coleta. É como
  o drift é medido sem se confundir com reenvio de spool: `max(t)` de um lote
  antigo também é antigo, mas `sent_at` é sempre "agora" na visão do agente.
- **`mem_pct` e `free_pct` NÃO são enviados** — o servidor deriva de
  used/total. Uma conta a menos para o agente errar.
- `flags` é vocabulário aberto. Já em uso: `temp_denied`, `temp_unavailable`,
  `smart_unavailable`, `cpu_raw_fallback`, `gw_unreachable`.
- `services[].is_running` é **booleano**. Ausente ou com tipo errado conta como
  **parado** — falso positivo é preferível a um PDV sem impressão passando
  batido.

Resposta 200:

```json
{
  "ok": true, "received": 200, "accepted": 200, "duplicates": 0,
  "out_of_window": 0, "disk_rows": 200, "service_rows": 200,
  "oldest": "...", "newest": "...", "clock_drift_seconds": 2,
  "server_time": "...", "machine_id": "..."
}
```

Erros:

| HTTP | SQLSTATE | Quando | O que o agente deve fazer |
|---|---|---|---|
| 400 | MON03 | payload malformado, lote acima do teto | **não** reenviar igual; é bug do agente |
| 401 | MON01 | segredo, token inválido/revogado/expirado, máquina ou loja inativa | parar de tentar, acumular spool, alertar log |
| 422 | MON04 | lote **inteiro** fora da janela temporal | corrigir o relógio; **manter** o spool |
| 429 | MON02 | rate limit (header `Retry-After: 60`) | recuar e tentar depois |
| 502/504 | — | banco inacessível / timeout | retry com backoff |
| 500 | qualquer outro | erro interno | retry com backoff |

**Regra 14 verificada em teste:** nenhum caminho de erro devolve 200. O default
do mapeamento SQLSTATE→HTTP é 500, e há um teste que percorre códigos
desconhecidos garantindo que nunca saia 2xx.

### `GET /functions/v1/ingest/healthz`

Sem o header de segredo: só liveness (`{"ok":true,"service":"ingest"}`). Com o
segredo: acrescenta diagnóstico — total/online de máquinas, partições adiante,
amostras na última hora. **Nada sobre o parque vaza para quem só sabe a URL.**

`partitions_ahead` é o número que importa: se chegar a 0, a ingestão para.

---

## 3. Como testar

### 3.1 Banco (sem publicar nada)

```powershell
$env:MONITOR_DB_URL = 'postgresql://...'
.\scripts\apply-migrations.ps1 -Twice -Seed
.\scripts\run-tests.ps1
```

Cobre os 7 casos exigidos, mais rate limit, drift, renomeação de host e
healthcheck. Tudo em transação com `ROLLBACK`.

### 3.2 Lógica pura da Edge Function (sem banco, sem Deno)

```powershell
node supabase\functions\ingest\lib.test.mjs
```

34 testes. Node 24 remove anotações de tipo nativamente, então o `lib.ts` é
importado sem etapa de build.

### 3.3 Publicar e testar por HTTP

```powershell
# Segredos: NUNCA no repositório
supabase secrets set INGEST_SHARED_SECRET='<32+ caracteres aleatorios>'

# --no-verify-jwt é obrigatorio: agentes nao tem JWT do Supabase.
# A regra 6 e satisfeita porque a funcao valida o segredo proprio.
supabase functions deploy ingest --no-verify-jwt

.\scripts\test-ingest-http.ps1 `
  -FunctionUrl 'https://SEUPROJETO.supabase.co/functions/v1/ingest' `
  -SharedSecret '<o mesmo segredo>'
```

O script provisiona uma máquina descartável, roda 16 verificações (incluindo
revogar o token e conferir o 401) e apaga a máquina no `finally`.

Para gerar o segredo:

```powershell
[Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
```

### 3.4 Resultado observado

| Verificação | Resultado |
|---|---|
| 12 migrations, duas passagens do zero | sem erro |
| `04_ingestao.sql` | 12 sub-testes |
| `lib.test.mjs` | 34 testes |
| Token válido / revogado / inexistente / adulterado | grava / MON01 / MON01 / MON01 |
| Lote duplicado | `accepted=0, duplicates=2`, contagem de linhas inalterada |
| Lote de 200 amostras | 200 métricas + 200 discos numa chamada |
| Payload malformado (7 formas) | MON03 |
| Rate limit | MON02 na 6ª com teto 5, sem afetar outro agente |
| Drift de 90s | registrado em `machines.clock_drift_seconds`, timestamp do agente preservado |

---

## 4. O bug mais importante desta fase

A primeira versão do `register_metrics` **abortava o lote inteiro se uma única
amostra tivesse um campo com tipo errado.**

Por que isso é grave e não cosmético: o spool existe justamente para guardar o
dado do incidente. Se um lote reenviado contém uma linha corrompida — disco
cheio no meio da gravação do SQLite, bug de uma versão antiga do agente,
arquivo truncado — e essa linha derruba o lote, então o agente **nunca consegue
drenar o spool**. Ele reenvia, falha, reenvia, falha, o spool bate no teto e
descarta o mais antigo. O dado que você mais queria é o primeiro a morrer.

O teste que expôs isso mandava `"t": "nao-e-data"` junto com amostras boas. A
correção tem duas partes:

1. **Coerção defensiva** (`jnum`, `jnum_in`, `jpct`, `jtext`, `jbool`, `jarr`,
   `jinet`, `jts`): campo com tipo inválido vira `NULL`, não exceção. Funções
   `IMMUTABLE` em SQL puro, inlineadas pelo planejador.
2. **Faixas iguais às dos CHECKs**: `cpu_temp_c` fora de −20..150 entra como
   `NULL` em vez de violar a constraint. Um sensor ruim reportando 200 °C
   também derrubaria o lote.

Percentuais são **clampados** para 0..100 (clampar um percentual é seguro).
Temperatura fora de faixa é **anulada**, não clampada — inventar 150 °C seria
fabricar dado.

Havia ainda um resíduo do mesmo bug: o cálculo de `last_boot_at` reparseava
`uptime_seconds` de **todas** as amostras, fora do CTE onde a validação já
havia ocorrido. Movido para dentro.

**Regra que fica:** amostra com timestamp inválido é descartada individualmente;
campo com tipo inválido vira `NULL`; o lote só falha se estiver integralmente
inaproveitável — e nesse caso é `MON04`/`MON03`, nunca 200.

---

## 5. O que pode dar errado

**Esquecer `--no-verify-jwt`.** A função responde 401 para todos os agentes,
porque eles não têm JWT do Supabase. O sintoma é "todos os agentes offline ao
mesmo tempo logo após o deploy".

**Publicar sem `INGEST_SHARED_SECRET`.** A função **não** sobe silenciosamente
aberta: `CONFIG_ERROR` é avaliado na carga do módulo, o log registra
`config_invalida` e toda requisição recebe 503. Sem fallback com valor padrão —
mesmo princípio do `${VAR:?}` da regra 8.

**Segredo curto.** Menos de 24 caracteres é rejeitado na partida. Um segredo
compartilhado curto é força-brutável.

**`Retry-After` ignorado pelo agente.** No 429 a resposta traz
`Retry-After: 60`. Se o agente ignorar, ele se mantém em rate limit
indefinidamente. Isso é responsabilidade da Fase 3 e está anotado.

**Rate limit muito baixo para reenvio de spool.** Padrão: 120 req/min por
máquina. Um agente drenando 10 minutos de spool em lotes de 200 faz poucas
requisições, então o padrão é folgado. Mas se você reduzir
`ingest_rate_limit_per_minute` e um agente voltar depois de horas offline, ele
pode bater no teto. O agente respeitando `Retry-After` resolve.

**`touch_agent_token` atualiza no máximo a cada 5 min.** Se você olhar
`last_used_at` esperando precisão de segundos, vai achar que o agente está
mudo. Isso é deliberado: uma escrita por agente por ciclo criaria linha quente.
Para saber se o agente está vivo, use `machines.last_seen_at`.

**A Edge Function não foi testada por HTTP aqui.** Deno não está instalado nesta
máquina. A lógica pura tem 34 testes; o encanamento (roteamento, `fetch` no
PostgREST, mapeamento de headers) só é exercitado por
`scripts\test-ingest-http.ps1` depois do deploy. **Rode esse script antes de
instalar o primeiro agente.**

---

## 6. Próximo passo

Fase 3 — Agente Windows. Já medido nesta máquina (Windows 11 Pro pt-BR) e
registrado na seção 5 de [FASE-1.md](FASE-1.md):

- `Win32_Service.State` é **invariante** (`Running`); `DisplayName` é que é
  traduzido.
- `OSArchitecture` é traduzido (`64 bits`).
- Fila de processador, processos, threads e uptime vêm de
  `Win32_PerfFormattedData_PerfOS_System`, **não** da classe `_Processor`.
- Temperatura e SMART exigem **elevação**; `MSFT_PhysicalDisk` funciona sem.

**Bloqueio:** o SDK do .NET 8 não está instalado nesta máquina
(`dotnet` ausente). Eu consigo escrever o Worker Service completo, mas não
consigo compilar nem rodar o critério de aceite (10 minutos sem rede e todas as
amostras chegando). Para validar de verdade:

```powershell
winget install -e --id Microsoft.DotNet.SDK.8
```

Diga se posso instalar, ou instale você — a partir daí a Fase 3 sai compilada e
testada contra a ingestão real.
