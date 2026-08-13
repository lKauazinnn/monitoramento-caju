<#
.SYNOPSIS
  Log de quedas de uma maquina: hora a hora, e cada queda com hora de inicio,
  hora de volta e duracao.

.DESCRIPTION
  De onde sai o dado, e por que nao sai do historico de alertas:

  O historico de alertas de offline NAO EXISTE. O avaliador (`avaliar_alertas()`)
  nunca foi agendado em producao -- so era chamado por testes --, entao nenhuma
  queda jamais foi gravada como `alert_open`. A migracao 0043 conserta isso, mas
  vale do momento em que for aplicada para frente; nao inventa passado.

  A fonte que existe e a TELEMETRIA, e ela e melhor do que o alerta para esta
  pergunta: tem a hora exata de cada amostra. Um intervalo entre duas amostras
  maior que o limite de offline e uma queda, com inicio (ultima amostra antes do
  silencio) e fim (primeira amostra depois).

  RELOGIO DO SERVIDOR, e nao da maquina. A tabela tem duas horas: `time` e o
  relogio do agente, `ingested_at` e o do servidor na gravacao. Este relatorio usa
  `ingested_at`. O motivo e concreto: o SERVIDOR-NAZO-SUL ja apareceu com o
  relogio 230 s atrasado, e um log de quedas construido sobre o relogio da propria
  maquina que caiu diria a hora errada exatamente na maquina onde mais importa
  acertar.

  O QUE ISTO MEDE: o agente parou de reportar. Isso inclui o PC desligado E o
  agente morto num PC ligado -- e nesta frota os dois acontecem. A coluna `pistas`
  separa: `boot`/`agent_start` logo depois da volta = reiniciou de verdade;
  travessao = o agente so parou de falar.

  A queda EM CURSO tambem aparece, marcada com `>>`. Ela nao sai de um intervalo
  entre duas amostras (nao existe a amostra de volta): sai do silencio entre a
  ultima amostra e agora. Sem esse caso, uma maquina desligada neste instante nao
  apareceria em lugar nenhum do relatorio -- o pior buraco possivel num relatorio
  de queda.

.PARAMETER Maquina
  Trecho do nome. Padrao: '%ASA%SUL%'. Use % como curinga.

.PARAMETER Dias
  Quantos dias para tras, contando hoje. Padrao 1 (so hoje, fuso de Brasilia).

.PARAMETER Vigiar
  Repete a cada 60 s, ate Ctrl+C. Serve para acompanhar durante um incidente.

.PARAMETER UrlBanco
  URL do Postgres. Padrao: o pooler de supabase\.temp\pooler-url.

.EXAMPLE
  .\scripts\quedas-de-hoje.ps1

.EXAMPLE
  .\scripts\quedas-de-hoje.ps1 -Maquina '%NAZO%SUL%' -Dias 7

.EXAMPLE
  .\scripts\quedas-de-hoje.ps1 -Vigiar
#>
[CmdletBinding()]
param(
  [string] $Maquina = '%ASA%SUL%',
  [int]    $Dias = 1,
  [switch] $Vigiar,
  [string] $UrlBanco,
  [System.Security.SecureString] $Senha
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($UrlBanco)) {
  $arq = Join-Path $raiz 'supabase\.temp\pooler-url'
  if (-not (Test-Path $arq)) {
    Write-Host 'Passe -UrlBanco: nao achei supabase\.temp\pooler-url.' -ForegroundColor Red
    exit 1
  }
  $UrlBanco = (Get-Content $arq -Raw).Trim()
}

if ($null -eq $Senha) { $Senha = Read-Host -Prompt 'Senha do banco de producao' -AsSecureString }

$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Senha)
try { $senhaNua = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

$psql = Get-Command psql -ErrorAction SilentlyContinue
$viaDocker = $null -eq $psql
if ($viaDocker -and $null -eq (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-Host 'Nem psql no PATH nem docker.' -ForegroundColor Red
  exit 1
}

# A consulta num arquivo, e nao em -c: assim a senha e o SQL nunca aparecem juntos
# numa linha de comando, e o SQL pode ter quebras de linha e comentarios.
$sql = @'
\timing off
\pset border 2
\pset null '—'

-- Tudo o que vem depois se apoia nestes tres blocos. `lim` sai do banco e nao e
-- um numero repetido aqui: se alguem mudar app_settings, o relatorio muda junto.
create temporary view v_lim as
  select coalesce((select value::integer from public.app_settings
                   where key = 'offline_timeout_seconds'), 180) as s;

create temporary view v_janela as
  select (((now() at time zone 'America/Sao_Paulo')::date
           - make_interval(days => :dias - 1)) at time zone 'America/Sao_Paulo') as ini;

create temporary view v_alvo as
  select ms.machine_id, ms.label from public.machines_status ms
  where ms.label ilike :'padrao';

-- As amostras com a anterior ao lado. O filtro por "time" existe SO para o
-- Postgres poder descartar particoes (a tabela e particionada por time); a
-- verdade do relatorio e ingested_at. Os dois dias de folga cobrem relogio torto
-- sem deixar a consulta varrer a tabela inteira.
create temporary view v_am as
  select a.machine_id, a.label, m.ingested_at as t,
         lag(m.ingested_at) over (partition by a.machine_id order by m.ingested_at) as ant
  from v_alvo a
  join public.metrics m on m.machine_id = a.machine_id
  where m."time" >= (select ini from v_janela) - interval '2 days'
    and m.ingested_at >= (select ini from v_janela);

create temporary view v_quedas as
  -- Quedas FECHADAS: o buraco entre duas amostras.
  select am.machine_id, am.label, am.ant as calou, am.t as voltou, false as em_curso
  from v_am am, v_lim
  where am.ant is not null
    and am.t - am.ant > make_interval(secs => v_lim.s)
  union all
  -- A queda EM CURSO. Nao ha amostra de volta, entao ela vai do ultimo contato
  -- ate agora.
  --
  -- O ultimo contato sai de machines_status, e NAO da ultima amostra dentro da
  -- janela do relatorio. A diferenca nao e estilo: a primeira versao usava a
  -- ultima amostra de v_am, e uma maquina caida ANTES do inicio da janela nao tem
  -- nenhuma amostra ali -- entao ela sumia do relatorio inteiro. Testando contra a
  -- base local, o PC-Brayan estava fora havia sete dias e o log mostrava travessao
  -- em todas as horas, como se estivesse de pe. Um relatorio de queda que esconde
  -- a maquina mais caida de todas e pior que relatorio nenhum.
  --
  -- `calou` fica com a hora verdadeira, mesmo antes da janela: e informacao, e a
  -- interseccao por hora ja recorta com greatest(calou, hora).
  select a.machine_id, a.label,
         coalesce(ms.last_contact_at, ms.last_seen_at) as calou,
         now() as voltou, true as em_curso
  from v_alvo a
  join public.machines_status ms on ms.machine_id = a.machine_id,
       v_lim
  where coalesce(ms.last_contact_at, ms.last_seen_at) is not null
    -- Maquina que NUNCA reportou nao "caiu": ela nunca subiu. Aparece na secao
    -- AGORA como never_seen, e inventar uma queda para ela poluiria a contagem.
    and now() - coalesce(ms.last_contact_at, ms.last_seen_at) > make_interval(secs => v_lim.s);

\echo ''
\echo '=== AGORA ==='
select ms.label,
       ms.status,
       ms.seconds_since_seen as silencio_s,
       to_char(ms.last_contact_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI:SS') as ultimo_contato,
       ms.agent_version
from public.machines_status ms
where ms.label ilike :'padrao'
order by ms.label;

\echo ''
\echo '=== HORA A HORA ==='
\echo '(fora = minutos sem reportar naquela hora; a barra e a mesma coisa em blocos de 5 min)'
with horas as (
  select generate_series(date_trunc('hour', (select ini from v_janela)),
                         date_trunc('hour', now()),
                         interval '1 hour') as h
),
grade as (
  select a.machine_id, a.label, h.h from v_alvo a cross join horas h
),
conta as (
  select g.machine_id, g.label, g.h,
         (select count(*) from v_am am
          where am.machine_id = g.machine_id
            and am.t >= g.h and am.t < g.h + interval '1 hour') as amostras,
         -- Interseccao de cada queda com esta hora. Uma queda de 90 min aparece
         -- repartida entre as horas que ela atravessa, e nao inteira na primeira:
         -- e o que faz a coluna somar 60 no maximo e a linha ser legivel.
         coalesce((select sum(extract(epoch from
                     least(q.voltou, g.h + interval '1 hour') - greatest(q.calou, g.h)))
                   from v_quedas q
                   where q.machine_id = g.machine_id
                     and q.calou < g.h + interval '1 hour'
                     and q.voltou > g.h), 0)::int as fora_s,
         (select count(*) from v_quedas q
          where q.machine_id = g.machine_id
            and q.calou >= g.h and q.calou < g.h + interval '1 hour') as caiu
  from grade g
)
select label,
       to_char(h at time zone 'America/Sao_Paulo', 'DD/MM HH24') || 'h' as hora,
       amostras,
       case when fora_s = 0 then '—' else (fora_s / 60) || 'min' end as fora,
       repeat('#', least(12, (fora_s / 300)::int)) as barra,
       case when caiu > 0 then caiu::text else '' end as caiu
from conta
order by label, h;

\echo ''
\echo '=== CADA QUEDA ==='
select q.label,
       case when q.em_curso then '>>' else '  ' end as ec,
       to_char(q.calou  at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI:SS') as desligou_as,
       case when q.em_curso then 'AINDA FORA'
            else to_char(q.voltou at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI:SS') end as voltou_as,
       case when extract(epoch from q.voltou - q.calou) >= 3600
              then (extract(epoch from q.voltou - q.calou)::int / 3600) || 'h'
                   || lpad(((extract(epoch from q.voltou - q.calou)::int % 3600) / 60)::text, 2, '0')
            when extract(epoch from q.voltou - q.calou) >= 60
              then (extract(epoch from q.voltou - q.calou)::int / 60) || 'min'
            else extract(epoch from q.voltou - q.calou)::int || 's' end as parada,
       -- A pista que separa "PC desligou" de "agente morreu".
       coalesce((select string_agg(distinct e.kind, ', ')
                 from public.events e
                 where e.machine_id = q.machine_id
                   and e.opened_at between q.calou - interval '2 min'
                                        and q.voltou + interval '5 min'
                   and e.kind in ('boot', 'shutdown', 'agent_start', 'agent_stop',
                                  'agent_update', 'agent_error')), '—') as pistas
from v_quedas q
order by q.calou;

\echo ''
\echo '=== RESUMO ==='
select a.label,
       (select count(*) from v_quedas q where q.machine_id = a.machine_id) as quedas,
       -- Recortado na janela com greatest(calou, ini): uma queda que comecou
       -- antes de hoje entraria com dias inteiros e "min_fora" passaria de 1440
       -- num relatorio de um dia -- um numero que nao quer dizer nada.
       coalesce((select sum(extract(epoch from
                   q.voltou - greatest(q.calou, (select ini from v_janela))))::int / 60
                 from v_quedas q where q.machine_id = a.machine_id), 0) as min_fora,
       coalesce((select max(extract(epoch from
                   q.voltou - greatest(q.calou, (select ini from v_janela))))::int / 60
                 from v_quedas q where q.machine_id = a.machine_id), 0) as maior_min,
       (select count(*) from v_am am where am.machine_id = a.machine_id) as amostras,
       -- Intervalo TIPICO entre amostras. Serve para ler as duas colunas acima:
       -- se o tipico e 90 s, o agente esta reportando devagar e horas com poucas
       -- amostras nao querem dizer queda.
       coalesce((select percentile_disc(0.5) within group (order by extract(epoch from am.t - am.ant))::int
                 from v_am am where am.machine_id = a.machine_id and am.ant is not null), 0) as tipico_s
from v_alvo a
order by 2 desc, 1;

\echo ''
\echo '=== EVENTOS NO PERIODO ==='
select to_char(e.opened_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI:SS') as hora,
       e.kind, e.severity, left(e.message, 76) as mensagem
from public.events e
where e.machine_id in (select machine_id from v_alvo)
  and e.opened_at >= (select ini from v_janela)
order by e.opened_at;
'@

$tmp = Join-Path $env:TEMP 'quedas-de-hoje.sql'
Set-Content -Path $tmp -Value $sql -Encoding utf8
if ($viaDocker) { docker cp $tmp monitor-db:/tmp/quedas.sql | Out-Null }

function Rodar {
  Write-Host ''
  Write-Host ("Maquina: $Maquina   Periodo: $Dias dia(s) ate agora   " +
              "Consulta: $(Get-Date -Format 'HH:mm:ss')") -ForegroundColor Cyan

  if ($viaDocker) {
    docker exec -e PGPASSWORD=$senhaNua monitor-db `
      psql $UrlBanco -v padrao="$Maquina" -v dias=$Dias -f /tmp/quedas.sql
  } else {
    $env:PGPASSWORD = $senhaNua
    & $psql.Source $UrlBanco -v padrao="$Maquina" -v dias=$Dias -f $tmp
  }
}

if ($Vigiar) {
  Write-Host 'Vigiando a cada 60 s. Ctrl+C para parar.' -ForegroundColor DarkGray
  while ($true) {
    Clear-Host
    Rodar
    Start-Sleep -Seconds 60
  }
}

Rodar
Remove-Item $tmp -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'COMO LER:' -ForegroundColor Yellow
Write-Host '  HORA A HORA  "fora" e quanto tempo daquela hora a maquina passou sem'
Write-Host '               reportar. Uma queda longa aparece repartida entre as horas'
Write-Host '               que ela atravessa, por isso a coluna nunca passa de 60.'
Write-Host '  CADA QUEDA   ">>" e queda EM CURSO: a maquina ainda nao voltou.'
Write-Host '  pistas       boot/agent_start = reiniciou de verdade.'
Write-Host '               travessao = o agente parou de falar num PC possivelmente ligado.'
Write-Host '  tipico_s     intervalo normal entre amostras. Se estiver alto, o agente'
Write-Host '               reporta devagar e hora com poucas amostras nao e queda.'
Write-Host ''
Write-Host 'As horas sao do RELOGIO DO SERVIDOR (ingested_at), nao do PC: o Asa Sul'
Write-Host 'ja apareceu com relogio 230 s atrasado.' -ForegroundColor DarkGray
Write-Host ''
