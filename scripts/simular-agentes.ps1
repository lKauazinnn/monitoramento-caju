<#
.SYNOPSIS
  Simula agentes enviando metricas pela ingestao REAL.

.DESCRIPTION
  Nao insere no banco por SQL: provisiona token de verdade e chama
  public.ingest_batch pelo HTTP do PostgREST, exatamente como o agente Windows
  faz. Serve para dois propositos:

    1. povoar o dashboard com dado realista sem precisar de agente instalado
    2. exercitar o caminho completo de ingestao (token, rate limit, janela
       temporal, idempotencia) de fora do banco

  Os dados carregam agent_version = 'sim-1.0.0', entao um
  `delete from metrics where agent_version like 'sim-%'` limpa tudo.

.PARAMETER Horas
  Horas de historico a gerar. Padrao 24.

.PARAMETER IntervaloSegundos
  Intervalo entre amostras. Padrao 300 (5 min) para o historico nao ficar
  gigante; o agente real usa 60.

.PARAMETER Continuo
  Depois do historico, segue enviando uma amostra por ciclo indefinidamente.
  Use para ver o dashboard atualizando ao vivo.

.EXAMPLE
  .\scripts\simular-agentes.ps1 -Horas 24

.EXAMPLE
  .\scripts\simular-agentes.ps1 -Horas 2 -Continuo
#>
[CmdletBinding()]
param(
  [int]    $Horas = 24,
  [int]    $IntervaloSegundos = 300,
  [switch] $Continuo,
  [string] $RestUrl = 'http://127.0.0.1:3000',
  [string] $Container = 'monitor-db',

  <#
    Token com role=service_role. Obrigatorio: `anon` NAO tem EXECUTE em
    ingest_batch (regra 3), e o token do dashboard e `authenticated`, que
    tambem nao tem. Somente service_role ingere — na producao esse papel e da
    Edge Function, que guarda a chave como variavel de ambiente do servidor.

    Gerado por dev-up.ps1. Nunca vai para arquivo servido ao navegador.
  #>
  [string] $ServiceToken = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Sql {
  param([string] $Consulta)
  $r = docker exec $Container psql -U postgres -q -t -A -c $Consulta
  if ($LASTEXITCODE -ne 0) { throw "consulta falhou: $Consulta" }
  return $r
}

# ---------------------------------------------------------------------------
# Provisiona (ou reaproveita) token para cada maquina do seed
# ---------------------------------------------------------------------------
Write-Host '   provisionando tokens...' -ForegroundColor DarkGray

$maquinas = @()
$linhas = Sql @"
select m.id || '|' || s.code || '|' || m.label || '|' || m.role_code
from public.machines m
join public.sites s on s.id = m.site_id
where m.is_active
order by s.code, m.label;
"@

foreach ($linha in $linhas) {
  if ([string]::IsNullOrWhiteSpace($linha)) { continue }
  $p = $linha.Trim().Split('|')

  # p_rotate => true para ser idempotente: reexecutar o simulador nao explode
  # com "maquina ja possui token ativo".
  $t = Sql "select token from public.provision_machine('$($p[1])', '$($p[2])', '$($p[3])', 'simulador', true);"
  $token = ($t | Where-Object { $_ -match '^mon_' } | Select-Object -First 1)

  if ([string]::IsNullOrWhiteSpace($token)) { throw "nao obtive token para $($p[1])/$($p[2])" }

  $maquinas += [pscustomobject]@{
    Id       = $p[0]
    Loja     = $p[1]
    Rotulo   = $p[2]
    Perfil   = $p[3]
    Token    = $token.Trim()
    Hostname = ('{0}-{1}' -f $p[1], ($p[2] -replace '[^A-Za-z0-9]', '')).ToUpperInvariant()
  }
}

Write-Host "   $($maquinas.Count) maquina(s) com token" -ForegroundColor DarkGray

# Segredo compartilhado: no modo local a chamada vai direto ao PostgREST, sem
# passar pela Edge Function, entao ele nao e exigido. Contra o Supabase, a
# Edge Function exige — e o simulador precisaria envia-lo.
$semente = 20260804

function Enviar {
  param([object] $Maquina, [array] $Amostras)

  $corpo = @{
    p_token = $Maquina.Token
    p_payload = @{
      agent_version = 'sim-1.0.0'
      sent_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
      machine = @{
        hostname     = $Maquina.Hostname
        os_caption   = 'Microsoft Windows 11 Pro'
        os_version   = '10.0.26200'
        os_arch      = '64 bits'
        cpu_model    = if ($Maquina.Perfil -eq 'server') { 'Intel(R) Xeon(R) E-2334 @ 3.40GHz' } else { '11th Gen Intel(R) Core(TM) i5-11400 @ 2.60GHz' }
        cpu_cores    = if ($Maquina.Perfil -eq 'server') { 4 } else { 6 }
        mem_total_mb = if ($Maquina.Perfil -eq 'server') { 16384 } else { 8192 }
        ip_lan       = '10.10.1.' + (10 + ($maquinas.IndexOf($Maquina)))
      }
      samples = $Amostras
    }
  } | ConvertTo-Json -Depth 12 -Compress

  $cab = @{}
  if ($ServiceToken) { $cab['Authorization'] = "Bearer $ServiceToken" }

  try {
    $r = Invoke-RestMethod -Uri "$RestUrl/rpc/ingest_batch" -Method Post `
           -Headers $cab -ContentType 'application/json' -Body $corpo
    return $r
  } catch {
    $detalhe = $_.Exception.Message
    if ($_.Exception.Response) {
      try {
        $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $detalhe = $sr.ReadToEnd()
      } catch { }
    }
    throw "ingestao falhou para $($Maquina.Loja)/$($Maquina.Rotulo): $detalhe"
  }
}

function NovaAmostra {
  param([object] $Maquina, [datetime] $Utc, [int] $Indice)

  # Ruido deterministico derivado do proprio instante: reexecutar produz a mesma
  # serie, o que torna o dashboard reproduzivel entre demonstracoes.
  $h = [Math]::Abs(($Maquina.Rotulo + $Utc.Ticks.ToString()).GetHashCode())
  $ruido = ($h % 1000) / 1000.0

  $baseCpu = if ($Maquina.Perfil -eq 'server') { 34 } else { 16 }
  $onda = 20 * [Math]::Sin(($Utc.TimeOfDay.TotalHours / 24.0) * 2 * [Math]::PI)
  $cpu = [Math]::Round([Math]::Max(2, [Math]::Min(98, $baseCpu + $onda + ($ruido * 14))), 2)

  $memTotal = if ($Maquina.Perfil -eq 'server') { 16384 } else { 8192 }
  $memUsado = [int]($memTotal * (0.44 + ($cpu / 100.0) * 0.22))

  # Cenarios visiveis no dashboard, para a tela nao ficar toda verde e sem graca:
  #   BSB-002/PDV 01 -> disco enchendo (dispara a regra global disk_low)
  #   SP-001         -> sem sensor de temperatura
  $discoLivre = if ($Maquina.Loja -eq 'BSB-002') { [Math]::Round(7.5 - ($Indice * 0.004), 2) } else { [Math]::Round(41 + ($ruido * 6), 2) }
  if ($discoLivre -lt 1) { $discoLivre = 1 }

  $temTemp = $Maquina.Loja -ne 'SP-001'
  $flags = @()
  if (-not $temTemp) { $flags += 'temp_unavailable' }

  $discos = @(
    @{
      drive        = 'C:'
      filesystem   = 'NTFS'
      total_gb     = 237.5
      free_gb      = [Math]::Round(237.5 * $discoLivre / 100.0, 2)
      smart_ok     = $true
      smart_source = 'wmi'
      media_type   = 'SSD'
    }
  )
  if ($Maquina.Perfil -eq 'server') {
    $discos += @{ drive = 'D:'; filesystem = 'NTFS'; total_gb = 931.0; free_gb = 640.2; smart_ok = $true; smart_source = 'wmi'; media_type = 'HDD' }
  }

  # Spooler cai no PDV 01 da BSB-001 nas ultimas 2h, para exercitar o cartao
  # com servico parado.
  $spoolerAtivo = -not ($Maquina.Loja -eq 'BSB-001' -and $Maquina.Rotulo -eq 'PDV 01' -and $Utc -gt (Get-Date).ToUniversalTime().AddHours(-2))

  $servicos = @()
  if ($Maquina.Perfil -eq 'pdv') {
    $servicos += @{
      name       = 'Spooler'
      is_running = $spoolerAtivo
      start_mode = 'Auto'
      state_raw  = if ($spoolerAtivo) { 'Running' } else { 'Stopped' }
    }
  }

  $amostra = @{
    t                = $Utc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    cpu_pct          = $cpu
    cpu_queue_length = 0
    mem_total_mb     = $memTotal
    mem_used_mb      = $memUsado
    swap_used_mb     = 105
    uptime_seconds   = 86400 * 3 + $Indice * $IntervaloSegundos
    proc_count       = 180 + [int]($cpu / 2)
    thread_count     = 2400 + [int]($cpu * 12)
    gw_latency_ms    = [Math]::Round(0.8 + $ruido * 2.4, 2)
    gw_loss_pct      = 0
    central_latency_ms = [Math]::Round(14 + $ruido * 22, 2)
    flags            = $flags
    disks            = $discos
    services         = $servicos
  }

  if ($temTemp) { $amostra.cpu_temp_c = [Math]::Round(42 + ($cpu * 0.3), 1) }

  return $amostra
}

# ---------------------------------------------------------------------------
# Historico
# ---------------------------------------------------------------------------
$agora = (Get-Date).ToUniversalTime()
$totalAmostras = [int](($Horas * 3600) / $IntervaloSegundos)

Write-Host "   gerando $Horas h de historico ($totalAmostras amostras por maquina, intervalo ${IntervaloSegundos}s)..." -ForegroundColor DarkGray

$totalAceitas = 0
$totalDuplicadas = 0

foreach ($m in $maquinas) {
  $amostras = New-Object System.Collections.ArrayList
  $enviadas = 0

  for ($i = $totalAmostras; $i -ge 0; $i--) {
    $t = $agora.AddSeconds(-1 * $i * $IntervaloSegundos)

    # PDV 02 da BSB-001 fica MUDO nas ultimas 3h: e a maquina offline do
    # dashboard, e prova que o status offline funciona.
    if ($m.Loja -eq 'BSB-001' -and $m.Rotulo -eq 'PDV 02' -and $t -gt $agora.AddHours(-3)) { continue }

    [void]$amostras.Add((NovaAmostra -Maquina $m -Utc $t -Indice ($totalAmostras - $i)))

    # Lotes de 200: e o mesmo teto do agente real e do ingest_max_batch_size.
    if ($amostras.Count -ge 200) {
      $r = Enviar -Maquina $m -Amostras $amostras.ToArray()
      $totalAceitas += [int]$r.accepted
      $totalDuplicadas += [int]$r.duplicates
      $enviadas += $amostras.Count
      $amostras.Clear()
    }
  }

  if ($amostras.Count -gt 0) {
    $r = Enviar -Maquina $m -Amostras $amostras.ToArray()
    $totalAceitas += [int]$r.accepted
    $totalDuplicadas += [int]$r.duplicates
    $enviadas += $amostras.Count
  }

  Write-Host ("   {0,-9} {1,-18} {2,5} amostras" -f $m.Loja, $m.Rotulo, $enviadas) -ForegroundColor DarkGray
}

Write-Host "   aceitas: $totalAceitas   duplicadas: $totalDuplicadas" -ForegroundColor Green

if ($totalDuplicadas -gt 0) {
  Write-Host '   (duplicadas > 0 e normal ao reexecutar: a ingestao e idempotente)' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Modo continuo
# ---------------------------------------------------------------------------
if ($Continuo) {
  Write-Host ''
  Write-Host "   MODO CONTINUO: uma amostra a cada ${IntervaloSegundos}s. Ctrl+C para parar." -ForegroundColor Yellow
  Write-Host ''

  $ciclo = 0
  while ($true) {
    Start-Sleep -Seconds $IntervaloSegundos
    $ciclo++
    $t = (Get-Date).ToUniversalTime()
    $ok = 0

    foreach ($m in $maquinas) {
      # PDV 02 continua mudo, para a maquina offline permanecer offline.
      if ($m.Loja -eq 'BSB-001' -and $m.Rotulo -eq 'PDV 02') { continue }
      try {
        $r = Enviar -Maquina $m -Amostras @((NovaAmostra -Maquina $m -Utc $t -Indice $ciclo))
        $ok += [int]$r.accepted
      } catch {
        Write-Host "   $($_.Exception.Message)" -ForegroundColor Red
      }
    }

    Write-Host ("   {0}  ciclo {1}: {2} amostra(s) gravada(s)" -f $t.ToString('HH:mm:ss'), $ciclo, $ok) -ForegroundColor DarkGray
  }
}
