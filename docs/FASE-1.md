# Fase 1 — Fundação de dados

Estado: **entregue e verificada contra PostgreSQL 16 real** (container `postgres:16`,
duas passagens do zero + seed + 3 arquivos de teste, todos verdes).

---

## 1. O que foi entregue

```
supabase/
  migrations/
    ..._0001_compat_e_settings.sql        shims de ambiente + app_settings (config central)
    ..._0002_marcas_e_lojas.sql           brands, sites
    ..._0003_maquinas_tokens_acesso.sql   machine_roles, machines, agent_tokens,
                                          user_roles, user_site_access, helpers de authz
    ..._0004_metricas.sql                 metrics, metrics_disks, metrics_services (particionadas)
    ..._0005_regras_de_alerta.sql         alert_rules + 8 regras globais de partida
    ..._0006_rollup_e_eventos.sql         metrics_hourly, metrics_disks_hourly, events
    ..._0007_particoes.sql                criação/expurgo automático de partições
    ..._0008_provisionamento.sql          provision_machine, revoke_agent_token, verify_agent_token
    ..._0009_views.sql                    machines_status, sites_status, brands_status,
                                          agent_tokens_admin, machine_services_expected, open_alerts
    ..._0010_rls.sql                      RLS, grants de tabela, grants de função
    ..._0011_cron.sql                     pg_cron (tolerante à ausência da extensão)
  seed/
    seed_demo.sql                         2 marcas, 3 lojas, 5 máquinas
    seed_metrics_sinteticas.sql           24h de métricas p/ desenvolver a Fase 4 (OPCIONAL)
  tests/
    01_estrutura_e_regras.sql             12 guardas automáticos das regras inegociáveis
    02_isolamento_anon.sql                isolamento de anon + escopo por loja
    03_provisionamento.sql                ciclo de vida completo do token
scripts/
  apply-migrations.ps1                    aplica (com -Twice para provar idempotência)
  run-tests.ps1                           roda a suíte
  provision-machine.ps1                   emite token, mostra uma vez
  revoke-token.ps1                        revoga por prefixo / lista inventário
```

---

## 2. Como testar

### 2.1 Pré-requisito: psql

Não está instalado nesta máquina. Instale os client tools:

```powershell
winget install -e --id PostgreSQL.PostgreSQL.16
# adicione ao PATH:
$env:Path += ';C:\Program Files\PostgreSQL\16\bin'
```

Se preferir não instalar nada, dá para colar os arquivos no SQL Editor do
Supabase **na ordem do nome** — mas o teste de idempotência vira manual (colar
tudo duas vezes).

### 2.2 Contra o Supabase

```powershell
# Supabase > Project Settings > Database > Connection string > URI
$env:MONITOR_DB_URL = 'postgresql://postgres.SEUPROJETO:SENHA@aws-0-sa-east-1.pooler.supabase.com:5432/postgres'

# Critério de aceite 1: rodar do zero duas vezes seguidas sem erro
.\scripts\apply-migrations.ps1 -Twice -Seed

# Critérios de aceite 2 e 3
.\scripts\run-tests.ps1
```

Antes disso, habilite `pg_cron` em **Database > Extensions** e reaplique a
migration `0011`. Sem isso a manutenção de partições não fica agendada — e a
migration avisa em WARNING, não falha calada.

### 2.3 Contra PostgreSQL local (foi assim que validei)

Não publica porta nenhuma (regra 8) — o acesso é só por `docker exec`.

```powershell
docker run -d --name monitor-pg-test -e POSTGRES_PASSWORD=teste_local_apenas postgres:16
docker exec monitor-pg-test mkdir -p /work/migrations /work/seed /work/tests
docker cp supabase\migrations\. monitor-pg-test:/work/migrations/
docker cp supabase\seed\.       monitor-pg-test:/work/seed/
docker cp supabase\tests\.      monitor-pg-test:/work/tests/

docker exec monitor-pg-test bash -c 'set -e
for pass in 1 2; do
  for f in /work/migrations/*.sql; do
    psql -U postgres -q --single-transaction -v ON_ERROR_STOP=1 -f "$f" >/dev/null
  done
  echo "PASSAGEM $pass OK"
done
psql -U postgres -q -v ON_ERROR_STOP=1 -f /work/seed/seed_demo.sql >/dev/null
psql -U postgres -q -v ON_ERROR_STOP=1 -f /work/seed/seed_metrics_sinteticas.sql >/dev/null
for t in /work/tests/*.sql; do
  psql -U postgres -q -v ON_ERROR_STOP=1 -f "$t" >/dev/null && echo "TESTE OK: $(basename $t)"
done'

docker rm -f monitor-pg-test
```

### 2.4 Provisionar a primeira máquina

```powershell
.\scripts\provision-machine.ps1 -SiteCode BSB-001 -Label 'PDV 03' -Role pdv
.\scripts\revoke-token.ps1 -List
.\scripts\revoke-token.ps1 -Prefix mon_xxxxxxxxxxxx -Reason 'PDV substituido'
```

### 2.5 Resultado observado na validação

| Verificação | Resultado |
|---|---|
| 11 migrations, duas passagens do zero | sem erro |
| Seed | 2 marcas, 3 lojas, 5 máquinas, 7025 amostras |
| `01_estrutura_e_regras.sql` | 12 guardas passaram |
| `02_isolamento_anon.sql` | 13 tabelas negadas a `anon`, escopo por loja sem vazamento |
| `03_provisionamento.sql` | 10 asserções passaram |
| `run_maintenance()` | criou 15 partições, removeu partição vencida, expurgou agregados |
| Regra 23 na prática | mudar `offline_timeout_seconds` de 180 para 7200 virou 4 máquinas para `online` na mesma consulta |

---

## 3. O que pode dar errado

**`pg_cron` não habilitado.** É o risco operacional nº 1 desta fase. Sem o cron,
as partições futuras acabam em ~3 meses e **a ingestão para de aceitar dados** —
não existe partição default por decisão de projeto (ela arruinaria o pruning).
Confira com:

```sql
select jobname, schedule, active from cron.job;
select * from cron.job_run_details order by start_time desc limit 10;
```

Se sua conta não tiver `pg_cron`, agende `select public.run_maintenance();` em
qualquer agendador externo, diariamente.

**Default privileges do Supabase.** O Supabase concede acesso a
`anon`/`authenticated` em tabelas novas automaticamente. Isso significa que
**qualquer tabela criada fora destas migrations nasce legível por `anon`**. Duas
defesas já estão no lugar: `ensure_month_partition()` revoga no mesmo ato da
criação, e o teste `01.6` falha se `anon` tiver qualquer privilégio em `public`.
Rode a suíte depois de qualquer alteração de schema.

**Código de loja errado.** Os códigos do seed (`BSB-001`, `SP-001`) são
placeholder. O código vai literalmente para o `config.json` do agente; trocá-lo
depois de instalar significa reconfigurar máquina por máquina. **Decida isto
antes da Fase 3.**

**Retenção efetiva é maior que a configurada.** Partição mensal só cai quando o
mês inteiro está fora da janela. Com 30 dias configurados, a retenção real
oscila entre 30 e 61 dias. Nunca retém *menos* que o pedido. Se precisar de
corte preciso, o particionamento tem que virar semanal — me avise.

**Reaplicar migration não sobrescreve configuração.** `app_settings` usa
`on conflict do nothing`. Se você ajustar `offline_timeout_seconds` em produção,
reaplicar as migrations preserva seu valor. Isso é intencional; para mudar o
padrão de um ambiente novo, edite a migration *e* faça um `update` explícito.

**Métricas sintéticas envelhecem.** O seed opcional gera dados até `now()`; três
minutos depois todas as máquinas aparecem `offline`. Rode o arquivo novamente
para atualizar a janela. Limpe tudo com:

```sql
delete from public.metrics where agent_version like 'seed-%';
```

**Custo do RLS em `metrics`.** A policy usa `exists (select 1 from machines ...)`
por linha. Para o card de status (uma amostra por máquina) é irrelevante. Para
gráfico de 30 dias vai pesar. O plano é a Fase 4 ler histórico por uma função
`SECURITY DEFINER` que autoriza uma vez e devolve a série — a policy fica como
rede de segurança. Não é problema hoje; é decisão já tomada para depois.

**A view de status varre partições.** `machines_status` faz um `lateral` por
máquina limitado por `status_lookback_hours` (168h) justamente para restringir
quantas partições o planejador toca. Se você aumentar esse valor muito, a view
desacelera na proporção do número de partições varridas.

---

## 4. Desvios do que você pediu — e por quê

**1. `anon` recebe "permissão negada", não "zero linhas".**
Você pediu que `select` com role `anon` em `metrics` retornasse vazio. Eu fui
além: além de a RLS não conceder linha nenhuma, o `GRANT` de `SELECT` foi
revogado. O resultado observável passa a ser erro de privilégio.

Por que é melhor: "retorna vazio" depende exclusivamente de a RLS estar
correta. Sem o `GRANT`, um erro futuro em policy não abre a tabela — não há
privilégio para a policy filtrar. O teste `02.1` aceita as duas formas de
negação e falha se qualquer linha vazar.

**2. Colunas que você não pediu, e que eu considero necessárias.**

- `metrics.ingested_at` — sem o relógio do servidor ao lado do relógio do
  agente, não há como distinguir "link caiu 10 min e o spool foi reenviado" de
  "relógio da máquina está quebrado". Custa 8 bytes por linha.
- `metrics.collect_flags` — sensor que falhou no ciclo. Sem isso, temperatura
  ausente e temperatura zero ficam indistinguíveis.
- `metrics_services.is_running` **como booleano**, com a string do SO em
  `state_raw` só para diagnóstico. Motivo na seção 5.
- `metrics_disks_hourly` — a projeção de disco cheio da Fase 7 precisa de
  tendência **por unidade**, e o mínimo entre volumes não serve.

**3. `user_roles` e `user_site_access` entregues já na Fase 1**, mesmo sem você
ter respondido quem acessa o dashboard. Enxertar escopo em RLS depois é
retrabalho garantido. Se toda a TI vê tudo, basta pôr todos como `admin` e as
tabelas ficam inertes.

**4. Tabela `brands` em vez de coluna.** Relatório mensal por marca é Fase 7, e
`telegram_chat_id` por marca é Fase 5. Migrar depois dói mais.

---

## 5. Localização em pt-BR: o que foi MEDIDO nesta máquina

Medido em Windows 11 Pro 10.0.26200, `Get-Culture` = `pt-BR`, sessão **não
elevada**. Resultados brutos e as conclusões:

| Propriedade CIM | Valor retornado | Localizado? |
|---|---|---|
| `Win32_Service.State` | `Running` | **NÃO** — invariante |
| `Win32_Service.StartMode` | `Auto` | NÃO |
| `Win32_Service.Status` | `OK` | NÃO |
| `Win32_Service.DisplayName` | `Spooler de Impressão` | **SIM** |
| `Win32_OperatingSystem.OSArchitecture` | `64 bits` | **SIM** (em inglês: `64-bit`) |
| `Win32_OperatingSystem.Caption` | `Microsoft Windows 11 Pro` | não aqui, mas pode ser |
| `Win32_PerfFormattedData_PerfOS_Processor.PercentProcessorTime` | `11` | NÃO (numérico) |

**Correção de uma afirmação anterior:** eu havia escrito que `Win32_Service.State`
é localizado em pt-BR. **Não é** — os valores vêm do MOF e são fixos. O que é
localizado é `DisplayName`.

A decisão de schema não muda: `metrics_services.is_running` continua booleano e
`state_raw` continua sendo só diagnóstico. Mas a justificativa correta é outra:
não é que `State` esteja traduzido, é que um booleano não depende de a Microsoft
manter a tabela de enum estável nem de o agente acertar a string. O booleano vem
de `Win32_Service.Started` ou de `ServiceController.Status`, e é o que decide
alerta.

**`machine_roles.critical_services` guarda o nome curto** (`ServiceName`, ex.
`Spooler`), nunca `DisplayName` — este sim é traduzido e mudaria de máquina para
máquina conforme o idioma instalado.

### Onde os contadores realmente estão

`Win32_PerfFormattedData_PerfOS_Processor` **não** tem `ProcessorQueueLength`
(retornou vazio). Os valores corretos vêm de outra classe:

| Métrica | Classe correta | Medido |
|---|---|---|
| CPU % | `Win32_PerfFormattedData_PerfOS_Processor` (`Name='_Total'`) | 11 |
| Fila de processador | `Win32_PerfFormattedData_PerfOS_System` | 0 |
| Processos / threads | `Win32_PerfFormattedData_PerfOS_System` | 282 / 4229 |
| Uptime | `Win32_PerfFormattedData_PerfOS_System.SystemUpTime` | 116182 s |
| Memória | `Win32_OperatingSystem` (KB) | 33342932 / 14711724 |

**Ressalva mantida:** `Win32_PerfFormattedData_*` é invariante de idioma, mas vem
zerado em máquinas cujo cache de contadores de desempenho corrompeu (comum após
upgrade in-place). A Fase 3 usa o formatado com fallback para delta de dois
snapshots de `Win32_PerfRawData`, sinalizando `cpu_raw_fallback` em
`collect_flags`.

### Temperatura e SMART exigem elevação

| Classe | Sem elevação | Consequência |
|---|---|---|
| `MSAcpi_ThermalZoneTemperature` | **Acesso negado** | temperatura só com elevação |
| `MSStorageDriver_FailurePredictStatus` | **Acesso negado** | SMART só com elevação |
| `MSFT_StorageReliabilityCounter` | recurso indisponível ao cliente | idem |
| `MSFT_PhysicalDisk` | **funcionou** | `HealthStatus` + `MediaType` sem elevação |

O serviço roda como LocalSystem e terá acesso. **Mas testar em modo console sem
elevação faz todo sensor térmico e de SMART falhar** — e o diagnóstico natural
("essa máquina não tem sensor") é errado. As instruções da Fase 3 vão exigir
console elevado, e `collect_flags` vai distinguir `temp_denied` de
`temp_unavailable` justamente para não confundir os dois casos.

`MSFT_PhysicalDisk.HealthStatus` funcionar sem elevação é um achado útil: dá um
sinal de saúde de disco mesmo quando o SMART detalhado está inacessível. Medido
nesta máquina: `PLEXTOR PX-256M7VC`, `MediaType=4` (SSD), `HealthStatus=0`
(saudável).

---

## 6. Bugs encontrados e corrigidos durante a validação

Registrados porque três deles só apareceram por eu ter rodado o SQL de verdade:

| Onde | Bug | Consequência se tivesse passado |
|---|---|---|
| `drop_old_partitions()` | `pg_class.relname` é `name`, não `text`; `RETURN QUERY` rejeitava | O cron diário funcionaria por meses e **quebraria no dia em que a primeira partição vencesse** — retenção nunca aplicada, banco crescendo sem limite |
| `ensure_month_partition()` | partição nova herdava os default privileges do Supabase | `anon` leria `metrics_202608` **direto**, contornando as policies do pai |
| `teste 02.2 / 02.3` | `raise exception` dentro do bloco protegido era engolido pelo próprio `when others` | Os testes de negação **passariam em falso** mesmo com a segurança quebrada |
| `teste 02.6` | comparação tautológica sob RLS ("toda linha visível pertence a algo visível") | Passaria com o RLS desligado |
| `sites.timezone` | `now() at time zone <coluna>` em CHECK levanta exceção em vez de violar o check | Mensagem obscura ao cadastrar loja com fuso inválido |
| `metrics_hourly.hour` | `date_trunc` é STABLE e depende do TimeZone da sessão | CHECK rejeitaria linha válida em sessão com fuso de offset fracionário |
| testes 01.4 / 01.11 | `text \|\| "char"` ambíguo; `name[] = text[]` inexistente | Os guardas nem executavam |

---

## 7. Premissas assumidas — confirme ou corrija

Você pediu para eu começar sem ter respondido as nove perguntas, então assumi o
seguinte. Tudo está registrado no cabeçalho da migration `0001`.

| # | Premissa | Como mudar |
|---|---|---|
| 1 | Marca é tabela própria | — |
| 2 | `sites.vpn_subnet` nullable, `/24` dentro de `10.0.0.0/8` | — |
| 3 | **Código de loja é texto livre `^[A-Za-z0-9][A-Za-z0-9._-]{1,31}$`** | **decida antes da Fase 3** |
| 4 | Coleta a cada 60s | `app_settings.agent_interval_seconds` |
| 5 | 30 dias bruto / 400 dias rollup | `app_settings.metrics_retention_days` |
| 6 | Dimensionado para ~600 máquinas | — |
| 7 | Escopo por loja existe; ninguém cadastrado ainda | inserir em `user_roles` |
| 8 | Serviços críticos por perfil; **só `Spooler` semeado, é placeholder** | `machine_roles.critical_services` |
| 9 | Um chat Telegram por marca | `brands.telegram_chat_id` |

Ainda me faltam, e não têm default seguro: **plano do Supabase** (decide se
retenção é escolha ou restrição) e a **lista real de serviços críticos** do
ERP/PDV.

### Dar acesso de admin ao dashboard

```sql
-- pegue o id em Supabase > Authentication > Users
insert into public.user_roles (user_id, role, note)
values ('<uuid-do-usuario>', 'admin', 'TI')
on conflict (user_id) do update set role = 'admin';
```

### Fixture para o critério de aceite da Fase 4

```sql
update public.machines
set hostname = '<script>alert(1)</script>'
where label = 'PDV 02';
```

Verificado: o banco armazena os 25 caracteres literais. Se o dashboard usar
`textContent`, aparece como texto; se usar `innerHTML`, executa.

---

## 8. Próximo passo

Fase 2 — Ingestão. O que já está pronto para ela:

- `verify_agent_token(text) -> uuid` valida token, revogação, expiração, máquina
  e loja inativas em uma chamada.
- `touch_agent_token(bytea)` contabiliza uso no máximo a cada 5 min, para não
  gerar uma escrita por agente por ciclo em linha quente.
- `app_settings` já traz `clock_skew_future_seconds`, `backfill_max_age_seconds`,
  `ingest_rate_limit_per_minute` e `ingest_max_batch_size`.
- PK `(machine_id, time)` dá a idempotência do `on conflict do nothing` (regra 13).

Falta você decidir uma coisa antes de eu começar: **Edge Function ou RPC direto
via PostgREST.** Meu argumento pelo RPC direto está na resposta anterior; a Edge
Function é defensável se você quiser rejeitar payload malformado antes de tocar o
banco. Diga qual e eu executo a Fase 2.
