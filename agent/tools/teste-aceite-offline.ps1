<#
.SYNOPSIS
  Teste de aceite da Fase 3: desconectar a rede por N minutos e provar que TODAS
  as amostras do periodo chegam ao banco com os timestamps corretos.

.DESCRIPTION
  Este e o teste que decide se o agente presta. Ele nao verifica "o agente
  funciona"; verifica a propriedade que motiva o projeto inteiro: o dado do
  incidente sobrevive ao incidente.

  Como funciona:
    1. registra o estado inicial (ultimo timestamp no banco)
    2. desabilita o adaptador de rede (ou espera voce desconectar o cabo)
    3. espera N minutos, acompanhando o spool crescer
    4. reabilita a rede
    5. espera a drenagem
    6. compara: cada timestamp que o spool tinha aparece em metrics?

  Exige terminal ELEVADO para mexer no adaptador, e MONITOR_DB_URL para consultar
  o banco.

.PARAMETER Minutos
  Duracao da desconexao. O critério de aceite pede 10.

.PARAMETER MachineId
  GUID da maquina (o mesmo do config.json).

.PARAMETER Adaptador
  Nome do adaptador a desabilitar. Omitido, o script pede para voce desconectar
  o cabo manualmente — util em maquina que voce acessa por RDP, onde desabilitar
  a rede derruba a sua propria sessao.

.EXAMPLE
  $env:MONITOR_DB_URL = 'postgresql://...'
  .\agent\tools\teste-aceite-offline.ps1 -Minutos 10 -MachineId 'bbbb...' -Adaptador 'Ethernet'

.EXAMPLE
  # Sem tocar no adaptador (voce desconecta o cabo quando o script pedir)
  .\agent\tools\teste-aceite-offline.ps1 -Minutos 10 -MachineId 'bbbb...'
#>
[CmdletBinding()]
param(
  [int]    $Minutos = 10,
  [Parameter(Mandatory = $true)][string] $MachineId,
  [string] $Adaptador = '',
  [string] $ServiceName = 'MonitorAgent'
)

$ErrorActionPreference = 'Stop'

$psql = Get-Command psql -ErrorAction SilentlyContinue
if ($null -eq $psql) { Write-Host 'psql ausente.' -ForegroundColor Red; exit 1 }
if ([string]::IsNullOrWhiteSpace($env:MONITOR_DB_URL)) {
  Write-Host 'MONITOR_DB_URL nao definida.' -ForegroundColor Red; exit 1
}

$spoolDb = Join-Path $env:ProgramData 'MonitorAgent\spool.db'
$agentExe = Join-Path $env:ProgramFiles 'MonitorAgent\MonitorAgent.exe'

function Query-Db {
  param([string] $Sql)
  $out = & $psql.Source --dbname=$env:MONITOR_DB_URL --no-psqlrc --tuples-only --no-align `
           --set=ON_ERROR_STOP=1 -v mid=$MachineId --command=$Sql
  if ($LASTEXITCODE -ne 0) { throw 'consulta ao banco falhou' }
  return $out
}

function Get-SpoolCount {
  if (-not (Test-Path $spoolDb)) { return -1 }
  try {
    $r = & $agentExe --spool-status 2>&1 | Select-String -Pattern 'pendentes\s*:\s*(\d+)'
    if ($r) { return [int]$r.Matches[0].Groups[1].Value }
  } catch { }
  return -1
}

Write-Host ''
Write-Host ('=' * 70)
Write-Host ' TESTE DE ACEITE DA FASE 3 - resiliencia a queda de link'
Write-Host ('=' * 70)
Write-Host " maquina  : $MachineId"
Write-Host " duracao  : $Minutos minuto(s) sem rede"
Write-Host " spool    : $spoolDb"
Write-Host ('=' * 70)

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Estado inicial ==' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -eq $svc -or $svc.Status -ne 'Running') {
  Write-Host "servico $ServiceName nao esta rodando. Instale e inicie antes." -ForegroundColor Red
  exit 1
}
Write-Host "  servico  : $($svc.Status)" -ForegroundColor Green

$antes = (Query-Db "select coalesce(max(time)::text, 'nenhuma') from public.metrics where machine_id = :'mid';").Trim()
Write-Host "  ultima amostra no banco: $antes"

$countAntes = [int](Query-Db "select count(*) from public.metrics where machine_id = :'mid';").Trim()
Write-Host "  amostras no banco      : $countAntes"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Desconectando ==' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
$marcoInicio = (Get-Date).ToUniversalTime()

if ($Adaptador) {
  $ehAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $ehAdmin) {
    Write-Host 'Desabilitar adaptador exige terminal ELEVADO.' -ForegroundColor Red
    exit 1
  }
  Write-Host "  desabilitando adaptador '$Adaptador'..."
  Disable-NetAdapter -Name $Adaptador -Confirm:$false
  Write-Host '  adaptador DESABILITADO' -ForegroundColor Yellow
} else {
  Write-Host ''
  Write-Host '  >>> DESCONECTE O CABO DE REDE AGORA e pressione ENTER <<<' -ForegroundColor Yellow
  Read-Host
  $marcoInicio = (Get-Date).ToUniversalTime()
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host "== Aguardando $Minutos minuto(s) ==" -ForegroundColor Cyan
# ---------------------------------------------------------------------------
$fim = (Get-Date).AddMinutes($Minutos)
while ((Get-Date) -lt $fim) {
  $restante = [int]($fim - (Get-Date)).TotalSeconds
  $pend = Get-SpoolCount
  Write-Host ("  restam {0,4}s   spool: {1} amostra(s) pendente(s)" -f $restante, $pend)
  Start-Sleep -Seconds 30
}

$marcoFim = (Get-Date).ToUniversalTime()
$pendentesNoPico = Get-SpoolCount

Write-Host ''
Write-Host "  spool no pico: $pendentesNoPico amostra(s)" -ForegroundColor Yellow

if ($pendentesNoPico -le 0) {
  Write-Host ''
  Write-Host '  FALHA: o spool nao acumulou nada durante a queda.' -ForegroundColor Red
  Write-Host '  Isso significa que o agente nao esta coletando, ou nao esta' -ForegroundColor Red
  Write-Host '  gravando antes de enviar (violacao da regra 16).' -ForegroundColor Red
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Reconectando ==' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
if ($Adaptador) {
  Enable-NetAdapter -Name $Adaptador -Confirm:$false
  Write-Host '  adaptador reabilitado' -ForegroundColor Green
} else {
  Write-Host ''
  Write-Host '  >>> RECONECTE O CABO e pressione ENTER <<<' -ForegroundColor Yellow
  Read-Host
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Aguardando drenagem ==' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
# Generoso de proposito: o backoff pode estar em recuo longo quando a rede volta.
$limite = (Get-Date).AddMinutes(10)
$drenou = $false

while ((Get-Date) -lt $limite) {
  Start-Sleep -Seconds 15
  $pend = Get-SpoolCount
  Write-Host ("  spool: {0} pendente(s)" -f $pend)
  if ($pend -eq 0) { $drenou = $true; break }
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Verificacao ==' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
$sqlJanela = @"
select count(*)
from public.metrics
where machine_id = :'mid'
  and time >= '$($marcoInicio.ToString('o'))'::timestamptz
  and time <= '$($marcoFim.ToString('o'))'::timestamptz;
"@
$naJanela = [int](Query-Db $sqlJanela).Trim()

$countDepois = [int](Query-Db "select count(*) from public.metrics where machine_id = :'mid';").Trim()

# Buracos maiores que 2x o intervalo de coleta dentro da janela: e isto que
# revela amostra perdida, e nao a contagem total.
$sqlBuracos = @"
with s as (
  select time,
         lag(time) over (order by time) as anterior
  from public.metrics
  where machine_id = :'mid'
    and time >= '$($marcoInicio.AddMinutes(-2).ToString('o'))'::timestamptz
    and time <= '$($marcoFim.AddMinutes(2).ToString('o'))'::timestamptz
)
select count(*)
from s
where anterior is not null
  and time - anterior > make_interval(secs => 2 * public.app_setting_int('agent_interval_seconds'));
"@
$buracos = [int](Query-Db $sqlBuracos).Trim()

# Regra 12: nenhuma amostra pode ter chegado com o horario do ENVIO em vez do da
# coleta. Se o servidor tivesse sobrescrito, todas teriam time ~= ingested_at.
$sqlTimestamps = @"
select count(*)
from public.metrics
where machine_id = :'mid'
  and time >= '$($marcoInicio.ToString('o'))'::timestamptz
  and time <= '$($marcoFim.ToString('o'))'::timestamptz
  and ingested_at - time > interval '60 seconds';
"@
$reenviadas = [int](Query-Db $sqlTimestamps).Trim()

$esperado = [Math]::Floor(($marcoFim - $marcoInicio).TotalSeconds / 60)

Write-Host ''
Write-Host ('-' * 70)
Write-Host ("  amostras no banco antes      : {0}" -f $countAntes)
Write-Host ("  amostras no banco depois     : {0}" -f $countDepois)
Write-Host ("  dentro da janela de queda    : {0}" -f $naJanela)
Write-Host ("  esperado (aprox, 60s)        : {0}" -f $esperado)
Write-Host ("  com timestamp anterior ao envio: {0}" -f $reenviadas)
Write-Host ("  buracos > 2x intervalo       : {0}" -f $buracos)
Write-Host ("  spool drenou por completo    : {0}" -f $drenou)
Write-Host ('-' * 70)

$falhas = @()

if (-not $drenou)                    { $falhas += 'o spool nao drenou em 10 minutos apos a reconexao' }
if ($naJanela -lt ($esperado - 2))   { $falhas += "so $naJanela de ~$esperado amostras da janela chegaram" }
if ($buracos -gt 0)                  { $falhas += "$buracos buraco(s) na serie dentro da janela" }
if ($reenviadas -eq 0 -and $naJanela -gt 0) {
  $falhas += 'nenhuma amostra tem ingested_at maior que time — o timestamp do agente pode ter sido sobrescrito (regra 12)'
}

Write-Host ''
if ($falhas.Count -eq 0) {
  Write-Host ('=' * 70) -ForegroundColor Green
  Write-Host ' CRITERIO DE ACEITE DA FASE 3: APROVADO' -ForegroundColor Green
  Write-Host " Todas as amostras dos $Minutos minutos sem rede chegaram ao banco," -ForegroundColor Green
  Write-Host ' com os timestamps originais da coleta.' -ForegroundColor Green
  Write-Host ('=' * 70) -ForegroundColor Green
  exit 0
}

Write-Host ('=' * 70) -ForegroundColor Red
Write-Host ' CRITERIO DE ACEITE DA FASE 3: REPROVADO' -ForegroundColor Red
foreach ($f in $falhas) { Write-Host "  - $f" -ForegroundColor Red }
Write-Host ('=' * 70) -ForegroundColor Red
Write-Host ''
Write-Host ' Diagnostico:' -ForegroundColor Yellow
Write-Host "   Get-Content '$env:ProgramData\MonitorAgent\logs\agent.log' -Tail 80"
Write-Host "   & '$agentExe' --spool-status"
Write-Host ''
exit 1
