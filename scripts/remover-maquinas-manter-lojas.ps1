<#
.SYNOPSIS
  Remove as maquinas de producao e MANTEM as lojas, para recadastro em lote.

.DESCRIPTION
  IRREVERSIVEL. Exige digitar APAGAR.

  Serve para o caso em que se decide refazer a frota maquina por maquina: as
  lojas continuam cadastradas e cada maquina volta pelo provisionamento normal.

  O QUE SAI JUNTO, e nao da para separar: `machines` e pai de quase tudo por
  `on delete cascade` -- metricas, rollup por hora (os 400 dias de historico),
  eventos, alertas e o token de cada uma. Depois disto, o `config.json` que esta
  em cada PC deixa de valer: o token dele aponta para um cadastro que nao existe
  mais, e a maquina para de conseguir gravar ate ser reprovisionada.

  POR ISSO A CONTAGEM DE MAQUINAS VIVAS APARECE EM DESTAQUE antes de confirmar:
  maquina que esta reportando agora tambem para. Nao e efeito colateral
  inesperado, e a consequencia direta -- mas e facil esquecer dela quando a
  intencao e "limpar as que cairam".

  AUDITORIA: o evento `machine_removed` e gravado ANTES do delete e SEM
  referencia a linha removida, com loja, rotulo e hostname no payload como
  texto. E a regra da 0019, e ela existe porque `events.machine_id` e
  `on delete cascade`: um evento apontando para a maquina removida sumiria junto
  com ela, deixando a trilha vazia exatamente no caso em que ela mais importa.
  Depois deste script, `events` e o unico lugar onde ainda existe o mapa
  rotulo -> hostname que voce levantou.

.PARAMETER Loja
  Remove so as maquinas desta loja (codigo, sem diferenciar maiuscula). Sem
  isto, remove as de TODAS as lojas.

.PARAMETER UrlBanco
  URL do Postgres. Padrao: o pooler de supabase\.temp\pooler-url.

.EXAMPLE
  .\scripts\remover-maquinas-manter-lojas.ps1

.EXAMPLE
  .\scripts\remover-maquinas-manter-lojas.ps1 -Loja CAJU-ASN
#>
[CmdletBinding()]
param(
  [string] $Loja,
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

. (Join-Path $PSScriptRoot '_docker.ps1')
$psql = Get-Command psql -ErrorAction SilentlyContinue
$viaDocker = $null -eq $psql
if (-not (Assert-PsqlDisponivel)) { exit 1 }

# O mesmo filtro nas TRES consultas (retrato, auditoria e delete). Escrito uma
# vez so: um filtro que diverge entre o que e mostrado e o que e apagado e a
# pior forma de errar aqui.
if ([string]::IsNullOrWhiteSpace($Loja)) {
  $filtro = 'true'
  $alvo   = 'TODAS as lojas'
} else {
  $lojaSql = $Loja.Replace("'", "''")
  $filtro  = "s.code ilike '$lojaSql'"
  $alvo    = "a loja $Loja"
}

function Invoke-Sql {
  param([string] $Sql, [switch] $Silencioso)
  $tmp = Join-Path $env:TEMP ('remover-' + [guid]::NewGuid().ToString('N') + '.sql')
  Set-Content -Path $tmp -Value $Sql -Encoding utf8
  $antes = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($viaDocker) {
      docker cp $tmp monitor-db:/tmp/remover.sql | Out-Null
      if ($Silencioso) { docker exec -e PGPASSWORD=$senhaNua monitor-db psql $UrlBanco -q -f /tmp/remover.sql }
      else { docker exec -e PGPASSWORD=$senhaNua monitor-db psql $UrlBanco -f /tmp/remover.sql }
    } else {
      $env:PGPASSWORD = $senhaNua
      if ($Silencioso) { & $psql.Source $UrlBanco -q -f $tmp }
      else { & $psql.Source $UrlBanco -f $tmp }
    }
    $script:saiu = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $antes
    Remove-Item $tmp -ErrorAction SilentlyContinue
  }
}

# ---------------------------------------------------------------------------
# 1. O retrato: o que sai, por loja, com as VIVAS destacadas
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '============================================================'
Write-Host " O QUE SERA REMOVIDO ($alvo)"
Write-Host '============================================================'

Invoke-Sql @"
\pset border 2
select s.code as loja,
       count(*) as maquinas,
       count(*) filter (
         where m.last_contact_at > now() - make_interval(
           secs => public.app_setting_int('offline_timeout_seconds'))) as vivas_agora
from public.machines m
join public.sites s on s.id = m.site_id
where $filtro
group by s.code
order by s.code;

select count(*) as total_maquinas,
       count(*) filter (
         where m.last_contact_at > now() - make_interval(
           secs => public.app_setting_int('offline_timeout_seconds'))) as total_vivas
from public.machines m
join public.sites s on s.id = m.site_id
where $filtro;

select count(*) as lojas_que_permanecem from public.sites;
"@

if ($saiu -ne 0) {
  Write-Host ''
  Write-Host "Nao consegui ler o estado (codigo $saiu). Nada foi removido." -ForegroundColor Red
  exit 1
}

# ---------------------------------------------------------------------------
# 2. A confirmacao
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'ISTO E IRREVERSIVEL.' -ForegroundColor Red
Write-Host '  - as LOJAS permanecem; as MAQUINAS somem'
Write-Host '  - junto vao metricas, rollup de 400 dias, alertas e tokens'
Write-Host '  - o config.json de cada PC deixa de valer: mesmo as que estao'
Write-Host '    reportando agora param, ate serem reprovisionadas'
Write-Host ''
$resposta = Read-Host 'Digite APAGAR para confirmar'
if ($resposta -cne 'APAGAR') {
  Write-Host 'Cancelado. Nada foi removido.' -ForegroundColor Green
  exit 0
}

# ---------------------------------------------------------------------------
# 3. Auditoria e remocao, na MESMA transacao
# ---------------------------------------------------------------------------
# Se o delete falhar, o evento de auditoria tambem nao fica -- registro de
# remocao que nao aconteceu e pior que registro nenhum.
Write-Host ''
Write-Host 'Removendo...' -ForegroundColor Yellow

Invoke-Sql @"
\set ON_ERROR_STOP on
begin;

-- Regra da 0019: o evento vai ANTES e SEM referencia a linha removida, porque
-- events.machine_id e on delete cascade. O identificador viaja no payload, como
-- texto, e por isso sobrevive.
insert into public.events (site_id, kind, severity, message, payload)
select m.site_id,
       'machine_removed',
       'info',
       'removida em lote para recadastro: ' || s.code || ' / ' || m.label,
       jsonb_build_object(
         'site_code',  s.code,
         'label',      m.label,
         'hostname',   m.hostname,
         'machine_id', m.id::text,
         'motivo',     'recadastro em lote')
from public.machines m
join public.sites s on s.id = m.site_id
where $filtro;

delete from public.machines m
using public.sites s
where s.id = m.site_id and $filtro;

commit;
"@

if ($saiu -ne 0) {
  Write-Host ''
  Write-Host "FALHOU (codigo $saiu). A transacao foi desfeita: nada foi removido." -ForegroundColor Red
  exit 1
}

# ---------------------------------------------------------------------------
# 4. O depois
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '============================================================'
Write-Host ' DEPOIS'
Write-Host '============================================================'

Invoke-Sql @"
\pset border 2
select (select count(*) from public.sites)    as lojas,
       (select count(*) from public.machines) as maquinas;

select s.code as loja, count(m.id) as maquinas
from public.sites s
left join public.machines m on m.site_id = s.id
group by s.code
order by s.code;
"@

Write-Host ''
Write-Host 'Feito. As lojas continuam cadastradas.' -ForegroundColor Green
Write-Host ''
Write-Host 'Para cada maquina, agora sao DOIS passos no PC:' -ForegroundColor Yellow
Write-Host '  1. provisionar (gera token novo e o config.json):'
Write-Host '     .\scripts\provision-machine.ps1 -SiteCode <LOJA> -Label <ROTULO> ...'
Write-Host '  2. criar a tarefa agendada, senao ela nao volta no proximo reinicio'
Write-Host ''
Write-Host 'O mapa rotulo -> hostname que voce levantou continua em events:' -ForegroundColor DarkGray
Write-Host "  select payload->>'site_code', payload->>'label', payload->>'hostname'" -ForegroundColor DarkGray
Write-Host "  from public.events where kind = 'machine_removed' order by 1, 2;" -ForegroundColor DarkGray
Write-Host ''
