<#
.SYNOPSIS
  Agente de monitoramento em PowerShell. Coleta metricas REAIS desta maquina.

.DESCRIPTION
  Este e um agente de verdade, nao um simulador: cada numero vem de uma consulta
  CIM a esta maquina. As consultas sao as MESMAS que o agente .NET usa, e foram
  validadas contra Windows 11 pt-BR (ver docs/FASE-3.md).

  POR QUE EXISTE, alem de conveniencia: o Smart App Control bloqueia binario sem
  assinatura reputavel, entao o agente .NET nao executa em maquina com SAC ligado.
  Script PowerShell nao passa por essa politica. Ou seja, este arquivo e tambem a
  saida pratica para monitorar o parque enquanto o certificado de assinatura de
  codigo nao existe.

  O que ele mantem das regras do projeto:
    - regra 16: grava no spool ANTES de tentar enviar
    - regra 17: spool com teto de linhas e de idade, descartando o mais antigo
    - regra 12: o timestamp e o desta maquina, em UTC
    - regra 18: timeout explicito, retry com backoff e jitter no intervalo
    - regra 19: falha de um coletor nao derruba o ciclo
    - regra 10: so classes CIM, nunca PerformanceCounter com nome de categoria

  O que ele NAO tem, e por isso o agente .NET continua sendo o alvo:
    - nao roda como servico do Windows (morre com a sessao, salvo via Agendador)
    - spool em arquivo de texto, sem as garantias de um banco transacional
    - fallback de CPU por contador bruto simplificado

.PARAMETER Config
  Caminho do config.json. Padrao: %ProgramData%\MonitorAgent\config.json

.PARAMETER UmaVez
  Coleta uma amostra, envia e sai. Use para testar.

.PARAMETER MostrarJson
  Imprime o JSON que seria enviado e sai, sem enviar nada.

.EXAMPLE
  .\agent\agente-powershell.ps1 -MostrarJson

.EXAMPLE
  .\agent\agente-powershell.ps1
#>
[CmdletBinding()]
param(
  [string] $Config = (Join-Path $env:ProgramData 'MonitorAgent\config.json'),
  [switch] $UmaVez,
  [switch] $MostrarJson
)

$ErrorActionPreference = 'Stop'
$VERSAO = 'ps-1.3.0'

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# ---------------------------------------------------------------------------
# TLS
# ---------------------------------------------------------------------------
# OBRIGATORIO para falar com a Edge Function em HTTPS, e o motivo nao e obvio:
# o PowerShell 5.1 herda o SecurityProtocol padrao do .NET Framework, que em
# Windows sem atualizacao ainda oferece SSL3/TLS 1.0. O Supabase recusa essas
# versoes, e o erro que chega e "A conexao subjacente foi fechada" — que nao diz
# nada sobre versao de TLS e manda o diagnostico para o lado errado (firewall,
# proxy, certificado).
#
# Na LAN, em HTTP, isto nao muda nada. Fica aqui para a loja remota funcionar sem
# ninguem descobrir isso do jeito difIcil.
foreach ($nome in @('Tls12', 'Tls13')) {
  try {
    # [Enum]::Parse e nao [Net.SecurityProtocolType]::Tls13 porque Tls13 nao
    # existe no .NET Framework antigo, e referencia direta a membro inexistente
    # e erro de COMPILACAO do script, nao excecao capturavel.
    $valor = [Enum]::Parse([Net.SecurityProtocolType], $nome)
    [Net.ServicePointManager]::SecurityProtocol =
      [Net.ServicePointManager]::SecurityProtocol -bor $valor
  } catch { }
}

# ---------------------------------------------------------------------------
# Configuracao
# ---------------------------------------------------------------------------
if (-not (Test-Path $Config)) {
  Write-Host "config.json nao encontrado em $Config" -ForegroundColor Red
  Write-Host 'Gere com: .\scripts\monitorar-este-pc.ps1' -ForegroundColor Yellow
  exit 1
}

$cfg = Get-Content $Config -Raw | ConvertFrom-Json

foreach ($campo in @('ingestUrl', 'token')) {
  if ([string]::IsNullOrWhiteSpace($cfg.$campo)) {
    Write-Host "config.json sem '$campo'" -ForegroundColor Red
    exit 1
  }
}

$intervalo = if ($cfg.intervalSeconds) { [int]$cfg.intervalSeconds } else { 60 }
$lote      = if ($cfg.batchSize)       { [int]$cfg.batchSize }       else { 200 }
$gateway   = $cfg.gatewayIp
$servicos  = @()
if ($cfg.criticalServices) { $servicos = @($cfg.criticalServices) }

$dirDados = Split-Path -Parent $Config
$spoolPath = Join-Path $dirDados 'spool.jsonl'
$logPath = Join-Path $dirDados 'agente-ps.log'

$spoolMaxLinhas = if ($cfg.spool.maxRows)   { [int]$cfg.spool.maxRows }   else { 20000 }
$spoolMaxHoras  = if ($cfg.spool.maxAgeHours) { [int]$cfg.spool.maxAgeHours } else { 72 }

function Registrar {
  param([string] $Nivel, [string] $Mensagem)
  $linha = '{0} {1} {2}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'), $Nivel, $Mensagem
  Write-Host $linha -ForegroundColor $(switch ($Nivel) { 'ERR' { 'Red' } 'AVI' { 'Yellow' } default { 'Gray' } })
  try { Add-Content -Path $logPath -Value $linha -Encoding utf8 } catch { }
}

# ---------------------------------------------------------------------------
# Coletores — cada um isolado, para que a falha de um nao derrube o ciclo
# ---------------------------------------------------------------------------
# Estado do fallback de CPU por delta de contador bruto.
$script:cpuBrutoAnterior = $null
$script:cpuTsAnterior = $null

function Coletar {
  param([string] $Nome, [scriptblock] $Bloco, [hashtable] $Amostra)
  try {
    & $Bloco
  } catch {
    # Regra 19: registra e segue. A amostra sai sem esse campo.
    $Amostra.flags += "erro_$Nome"
    Registrar 'AVI' "coletor '$Nome' falhou: $($_.Exception.Message)"
  }
}

function NovaAmostra {
  # Regra 12: o timestamp e capturado ANTES da coleta e e o desta maquina, em UTC.
  $amostra = @{
    t     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    flags = @()
    disks = @()
    services = @()
  }

  # ---- CPU ---------------------------------------------------------------
  Coletar 'cpu' {
    $f = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
    $formatado = [double]$f.PercentProcessorTime

    # Contador bruto para o fallback: PercentProcessorTime bruto acumula tempo
    # OCIOSO (PERF_100NSEC_TIMER_INV), entao ocupado = 100 * (1 - dCont/dTempo).
    $b = Get-CimInstance Win32_PerfRawData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
    $bruto = $null
    if ($null -ne $script:cpuBrutoAnterior) {
      $dc = [double]$b.PercentProcessorTime - $script:cpuBrutoAnterior
      $dt = [double]$b.Timestamp_Sys100NS   - $script:cpuTsAnterior
      if ($dt -gt 0 -and $dc -ge 0) { $bruto = 100.0 * (1.0 - ($dc / $dt)) }
    }
    $script:cpuBrutoAnterior = [double]$b.PercentProcessorTime
    $script:cpuTsAnterior = [double]$b.Timestamp_Sys100NS

    # Cache de contadores corrompido devolve 0 de forma persistente; se o bruto
    # discorda, o formatado e que esta mentindo.
    if ($formatado -le 0.0001 -and $null -ne $bruto -and $bruto -gt 2) {
      $amostra.cpu_pct = [Math]::Round([Math]::Max(0, [Math]::Min(100, $bruto)), 2)
      $amostra.flags += 'cpu_raw_fallback'
    } else {
      $amostra.cpu_pct = [Math]::Round([Math]::Max(0, [Math]::Min(100, $formatado)), 2)
    }
  } $amostra

  # ---- fila, processos, threads, uptime ----------------------------------
  # ATENCAO: estes NAO estao na classe _Processor. Vem de _System.
  Coletar 'sistema' {
    $s = Get-CimInstance Win32_PerfFormattedData_PerfOS_System -ErrorAction Stop
    $amostra.cpu_queue_length = [double]$s.ProcessorQueueLength
    $amostra.proc_count       = [int]$s.Processes
    $amostra.thread_count     = [int]$s.Threads
    $amostra.uptime_seconds   = [long]$s.SystemUpTime
  } $amostra

  # ---- memoria (Win32_OperatingSystem reporta em KILOBYTES) --------------
  Coletar 'memoria' {
    $o = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $totalMb = [int]([long]$o.TotalVisibleMemorySize / 1024)
    $livreMb = [int]([long]$o.FreePhysicalMemory / 1024)
    $amostra.mem_total_mb = $totalMb
    $amostra.mem_used_mb  = $totalMb - $livreMb
    # mem_pct NAO e enviado: o servidor deriva de used/total.
  } $amostra

  Coletar 'pagefile' {
    $pf = Get-CimInstance Win32_PageFileUsage -ErrorAction Stop
    $soma = 0
    foreach ($p in @($pf)) { $soma += [int]$p.CurrentUsage }
    $amostra.swap_used_mb = $soma
  } $amostra

  # ---- discos (DriveType 3 = fixo; removivel geraria alerta falso) -------
  Coletar 'disco' {
    $saude = $null
    $tipo = $null
    try {
      $fisicos = Get-CimInstance -Namespace 'root/microsoft/windows/storage' -ClassName MSFT_PhysicalDisk -ErrorAction Stop
      $saude = $true
      foreach ($d in @($fisicos)) {
        if ($d.HealthStatus -ne 0) { $saude = $false }
        if (-not $tipo) { $tipo = switch ([int]$d.MediaType) { 3 { 'HDD' } 4 { 'SSD' } 5 { 'SCM' } default { $null } } }
      }
    } catch {
      $amostra.flags += 'smart_unavailable'
    }

    # Size > 0 no filtro WQL, e nao so DriveType=3.
    #
    # Esta maquina tem um G: com Size = 0 — volume montado mas sem tamanho
    # utilizavel (leitor de cartao vazio, particao bloqueada por BitLocker,
    # unidade virtual). Ele entrava na serie com total_gb = 0 e free_pct nulo,
    # sujando o "menor volume livre" do dashboard com um disco que nao existe.
    foreach ($v in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3 AND Size > 0' -ErrorAction Stop) {
      $amostra.disks += @{
        drive        = $v.DeviceID
        volume_label = $v.VolumeName
        filesystem   = $v.FileSystem
        total_gb     = [Math]::Round([double]$v.Size / 1GB, 2)
        free_gb      = [Math]::Round([double]$v.FreeSpace / 1GB, 2)
        smart_ok     = $saude
        smart_source = if ($null -ne $saude) { 'wmi' } else { 'none' }
        media_type   = $tipo
      }
      # free_pct NAO e enviado: derivado no servidor.
    }
  } $amostra

  # ---- servicos criticos -------------------------------------------------
  # Medido em Windows 11 pt-BR: State devolve 'Running' (invariante, vem do MOF).
  # Quem decide alerta e o BOOLEANO Started; state_raw e so diagnostico.
  if ($servicos.Count -gt 0) {
    Coletar 'servicos' {
      $filtro = ($servicos | ForEach-Object { "Name='$($_ -replace "'", "\'")'" }) -join ' OR '
      $achados = @{}
      foreach ($s in Get-CimInstance Win32_Service -Filter $filtro -ErrorAction Stop) {
        $achados[$s.Name] = $s
      }
      foreach ($nome in $servicos) {
        if ($achados.ContainsKey($nome)) {
          $s = $achados[$nome]
          $amostra.services += @{
            name       = $nome
            is_running = [bool]$s.Started
            start_mode = $s.StartMode
            state_raw  = $s.State
            pid        = if ([int]$s.ProcessId -gt 0) { [int]$s.ProcessId } else { $null }
          }
        } else {
          # Servico configurado que nao existe conta como PARADO, nao omitido:
          # e justamente o caso de alguem ter desinstalado o software.
          $amostra.services += @{ name = $nome; is_running = $false; state_raw = 'NotInstalled' }
        }
      }
    } $amostra
  }

  # ---- temperatura (exige elevacao; ausencia e comum em PDV) -------------
  Coletar 'temperatura' {
    try {
      $z = Get-CimInstance -Namespace 'root/wmi' -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
      $maior = $null
      foreach ($t in @($z)) {
        # CurrentTemperature vem em DECIMOS DE KELVIN.
        $c = ([double]$t.CurrentTemperature / 10.0) - 273.15
        if ($c -ge -20 -and $c -le 150 -and ($null -eq $maior -or $c -gt $maior)) { $maior = $c }
      }
      if ($null -ne $maior) { $amostra.cpu_temp_c = [Math]::Round($maior, 1) }
      else { $amostra.flags += 'temp_unavailable' }
    } catch {
      # Distinguir privilegio de ausencia evita o diagnostico errado
      # "essa maquina nao tem sensor".
      $amostra.flags += $(if ($_.Exception.Message -match 'negad|denied') { 'temp_denied' } else { 'temp_unavailable' })
    }
  } $amostra

  # ---- latencia ----------------------------------------------------------
  Coletar 'rede' {
    if ([string]::IsNullOrWhiteSpace($gateway)) {
      $amostra.flags += 'gw_not_configured'
    } else {
      $r = Test-Connection -ComputerName $gateway -Count 3 -ErrorAction SilentlyContinue
      $ok = @($r | Where-Object { $_ })
      if ($ok.Count -gt 0) {
        $tempos = $ok | ForEach-Object { if ($_.Latency -ne $null) { $_.Latency } else { $_.ResponseTime } }
        $amostra.gw_latency_ms = [Math]::Round(($tempos | Measure-Object -Average).Average, 2)
        $amostra.gw_loss_pct = [Math]::Round(100.0 * (3 - $ok.Count) / 3, 2)
      } else {
        $amostra.gw_loss_pct = 100
        $amostra.flags += 'gw_unreachable'
      }
    }
  } $amostra

  return $amostra
}

function InfoMaquina {
  $info = @{ hostname = $env:COMPUTERNAME }
  try {
    $o = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $info.os_caption   = $o.Caption
    $info.os_version   = $o.Version
    $info.os_arch      = $o.OSArchitecture     # localizado em pt-BR: "64 bits"
    $info.mem_total_mb = [int]([long]$o.TotalVisibleMemorySize / 1024)
  } catch { }
  try {
    $c = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
    $info.cpu_model = $c[0].Name
    $info.cpu_cores = ($c | Measure-Object -Property NumberOfCores -Sum).Sum
  } catch { }
  # O IP vem do adaptador que ATENDE A ROTA PADRAO, nao do primeiro da lista.
  #
  # A versao anterior pegava o primeiro IPv4 nao-loopback e devolveu
  # 172.26.48.1 — adaptador virtual do WSL nesta maquina — quando a LAN real e
  # 192.168.15.x. Num parque com Hyper-V, WSL, VirtualBox ou VPN isso praticamente
  # garante o endereco errado, e o campo existe justamente para localizar a
  # maquina na loja.
  try {
    $rota = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
              Sort-Object RouteMetric | Select-Object -First 1

    if ($rota) {
      $ip = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $rota.InterfaceIndex -ErrorAction Stop |
              Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
              Select-Object -First 1
      if ($ip) { $info.ip_lan = $ip.IPAddress }
    }
  } catch { }

  # Sem rota padrao (maquina isolada): cai para o primeiro IPv4 util.
  if (-not $info.ip_lan) {
    try {
      $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
              Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
              Select-Object -First 1
      if ($ip) { $info.ip_lan = $ip.IPAddress }
    } catch { }
  }

  # ---- MAC, para poder ser LIGADA remotamente ----------------------------
  # Wake-on-LAN nao usa IP: o pacote magico carrega o endereco da placa. Sem
  # isto, esta maquina nunca podera ser ligada pelo painel.
  #
  # A placa CABEADA, especificamente: WoL por Wi-Fi depende de suporte do
  # adaptador e do ponto de acesso, e na pratica quase nunca funciona — anunciar
  # que da para ligar uma maquina em Wi-Fi seria prometer o que nao se cumpre.
  try {
    $ad = Get-NetAdapter -Physical -ErrorAction Stop |
            Where-Object { $_.Status -eq 'Up' -and $_.MediaType -ne 'Native 802.11' } |
            Sort-Object -Property @{ Expression = { $_.LinkSpeed } } -Descending |
            Select-Object -First 1

    if ($ad -and $ad.MacAddress) {
      # Get-NetAdapter devolve com hifen (AA-BB-CC); o banco normaliza, mas o
      # formato com dois-pontos e o que todo mundo espera ver num log.
      $info.mac = $ad.MacAddress.Replace('-', ':')
    }
  } catch { }

  return $info
}

# ---------------------------------------------------------------------------
# Spool — regra 16: grava ANTES de enviar
# ---------------------------------------------------------------------------
# UTF-8 SEM BOM, escrito pelo .NET e nao por Add-Content.
#
# `Add-Content -Encoding utf8` no PowerShell 5.1 grava BOM ao criar o arquivo, e
# o BOM fica colado no inicio da PRIMEIRA linha. ConvertFrom-Json entao falha
# naquela linha, o agente a classifica como ilegivel e DESCARTA — a primeira
# amostra de cada spool novo se perdia em silencio, com a mensagem
# "descartadas 1 linha(s) ilegivel(is)" como unica pista.
$script:utf8SemBom = New-Object System.Text.UTF8Encoding($false)

function SpoolGravar {
  param([hashtable] $Amostra)
  $linha = ($Amostra | ConvertTo-Json -Depth 10 -Compress) + "`n"
  [System.IO.File]::AppendAllText($spoolPath, $linha, $script:utf8SemBom)
}

<#
  ATENCAO AO USAR: sempre escreva `$x = @(SpoolLer)`, com o @() NO CHAMADOR.

  O PowerShell DESEMBRULHA array de um unico elemento ao retornar de uma funcao.
  O `@()` aqui dentro nao sobrevive ao return: com exatamente uma amostra no
  spool, o chamador recebia a STRING em vez de um array de uma posicao. Ai
  `$pendentes[0]` indexava a string e devolvia um CARACTERE, o ConvertFrom-Json
  falhava naquele char, e o agente descartava a amostra como "ilegivel".

  O efeito era cruel: funcionava com 2 ou mais amostras pendentes e falhava
  sempre com exatamente 1 — que e o caso normal de um agente saudavel enviando a
  cada ciclo. Ou seja, em operacao normal NENHUMA amostra chegava.
#>
function SpoolLer {
  if (-not (Test-Path $spoolPath)) { return @() }
  $texto = [System.IO.File]::ReadAllText($spoolPath, $script:utf8SemBom)
  # TrimStart do BOM tambem na leitura: um spool criado por versao anterior
  # continua legivel em vez de ter a primeira amostra descartada.
  return @($texto.TrimStart([char]0xFEFF) -split "`r?`n" | Where-Object { $_.Trim() })
}

function SpoolAparar {
  # Regra 17: teto de linhas e de idade, descartando o MAIS ANTIGO.
  if (-not (Test-Path $spoolPath)) { return }

  $linhas = @(SpoolLer)
  $limite = (Get-Date).ToUniversalTime().AddHours(-$spoolMaxHoras)
  $antes = $linhas.Count

  $vivas = foreach ($l in $linhas) {
    try {
      $o = $l | ConvertFrom-Json
      if ([datetime]::Parse($o.t).ToUniversalTime() -ge $limite) { $l }
    } catch {
      # Linha ilegivel e descartada: sem isso ela travaria a fila para sempre.
    }
  }
  $vivas = @($vivas)

  if ($vivas.Count -gt $spoolMaxLinhas) {
    $vivas = $vivas[($vivas.Count - $spoolMaxLinhas)..($vivas.Count - 1)]
  }

  if ($vivas.Count -ne $antes) {
    [System.IO.File]::WriteAllText($spoolPath, (($vivas -join "`n") + "`n"), $script:utf8SemBom)
    Registrar 'AVI' "spool aparado: $antes -> $($vivas.Count) amostras (descarte do mais antigo)"
  }
}

function SpoolRemoverPrimeiras {
  param([int] $Quantidade)
  $linhas = @(SpoolLer)
  if ($Quantidade -ge $linhas.Count) {
    [System.IO.File]::WriteAllText($spoolPath, '', $script:utf8SemBom)
  } else {
    $restam = $linhas[$Quantidade..($linhas.Count - 1)]
    [System.IO.File]::WriteAllText($spoolPath, (($restam -join "`n") + "`n"), $script:utf8SemBom)
  }
}

# ---------------------------------------------------------------------------
# Envio
# ---------------------------------------------------------------------------
function Enviar {
  param([array] $Amostras, [hashtable] $Maquina)

  $envelope = @{
    agent_version = $VERSAO
    sent_at       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    machine       = $Maquina
    samples       = $Amostras
    # O que executei desde o ultimo envio. Vai junto com a telemetria porque nao
    # ha canal de volta: a mesma conexao de saida serve para relatar e perguntar.
    command_results = @($script:resultadosPendentes)
    # Endereco da placa, para esta maquina poder ser LIGADA pelo vizinho um dia.
    # Vai fora de `machine` porque quem grava e a funcao da fila, nao a ingestao.
    network = @{ mac = $Maquina.mac }
  }

  $cab = @{}
  $corpo = $null
  $url = $cfg.ingestUrl

  if ($cfg.localRpc) {
    # MODO LOCAL: fala direto com o PostgREST, porque a stack local nao tem a
    # Edge Function. O token da maquina vai no corpo, e o de service_role no
    # header — e o mesmo caminho que o simulador usa.
    $corpo = @{ p_token = $cfg.token; p_payload = $envelope } | ConvertTo-Json -Depth 12 -Compress
    if ($cfg.serviceToken) { $cab['Authorization'] = "Bearer $($cfg.serviceToken)" }
  } else {
    # MODO PRODUCAO: contrato real da Fase 2 — segredo compartilhado no header e
    # o token DA MAQUINA como Bearer. A maquina nunca ve credencial de servidor.
    $corpo = $envelope | ConvertTo-Json -Depth 12 -Compress
    $cab['x-monitor-secret'] = $cfg.sharedSecret
    $cab['Authorization'] = "Bearer $($cfg.token)"
  }

  # Regra 18: timeout explicito.
  $resp = Invoke-RestMethod -Uri $url -Method Post -Headers $cab `
            -ContentType 'application/json' -Body $corpo -TimeoutSec 30
  return $resp
}

# ---------------------------------------------------------------------------
# Execucao de comandos
# ---------------------------------------------------------------------------
# O agente so faz conexao de SAIDA. Nao existe rota do servidor ate este PC, e
# criar uma exigiria porta liberada, IP publico ou VPN — as tres coisas que esta
# arquitetura evita de proposito.
#
# Entao o servidor nao manda: ele deixa o comando na fila, e o agente PERGUNTA,
# na resposta do mesmo POST de telemetria que ja acontece. Nenhum canal novo,
# nenhuma credencial nova, nenhuma porta nova.
#
# NADA AQUI EXECUTA STRING VINDA DO SERVIDOR. O servidor manda um TIPO de uma
# lista fechada e parametros ja validados; o mapeamento de tipo para acao mora
# neste arquivo, assinado e instalado na maquina. Se o servidor for comprometido,
# o pior que ele consegue e reiniciar um servico que esta maquina ja vigia.

# Resultados esperam aqui ate o proximo ciclo poder envia-los. Nao ha canal de
# volta imediato: relatar no ciclo seguinte e o preco de nao abrir porta na loja.
#
# EM DISCO, e nao so em memoria, pela mesma razao da regra 16 valer para as
# amostras: entre executar e relatar existe uma janela, e nessa janela o agente
# pode cair, ser reiniciado, ou a maquina desligar. Se o relato so existisse na
# memoria do processo, o comando ficaria 'sent' ate expirar e o painel diria
# "expirou sem ser executado" sobre um comando que executou — a pior mentira que
# este sistema pode contar, porque leva alguem a executar de novo.
$resultadosPath = Join-Path $dirDados 'resultados.jsonl'
$script:resultadosPendentes = @()

function ResultadosCarregar {
  if (-not (Test-Path $resultadosPath)) { return @() }
  $saida = @()
  foreach ($linha in (Get-Content $resultadosPath -ErrorAction SilentlyContinue)) {
    if ([string]::IsNullOrWhiteSpace($linha)) { continue }
    try { $saida += ($linha | ConvertFrom-Json) }
    catch { Registrar 'AVI' "resultado ilegivel descartado: $($_.Exception.Message)" }
  }
  return $saida
}

function ResultadoGravar {
  param($Resultado)
  try {
    Add-Content -Path $resultadosPath -Encoding utf8 `
      -Value ($Resultado | ConvertTo-Json -Depth 8 -Compress)
  } catch {
    Registrar 'ERR' "nao consegui gravar o resultado em disco: $($_.Exception.Message)"
  }
}

function ResultadosLimpar {
  try { Remove-Item $resultadosPath -Force -ErrorAction SilentlyContinue } catch { }
  $script:resultadosPendentes = @()
}

function ExecutarRestartService {
  param([string] $Servico, [bool] $Simulacao)

  # Cinto e suspensorio: o servidor ja validou contra a lista da maquina, mas o
  # agente tem a SUA propria lista no config. Se as duas discordarem, a mais
  # restritiva vence — o agente nao confia no servidor mais do que precisa.
  if ($servicos.Count -gt 0 -and $servicos -notcontains $Servico) {
    return @{ ok = $false; texto = "servico '$Servico' nao esta na lista local desta maquina" }
  }

  $svc = Get-Service -Name $Servico -ErrorAction SilentlyContinue
  if (-not $svc) { return @{ ok = $false; texto = "servico '$Servico' nao existe nesta maquina" } }

  if ($Simulacao) {
    return @{ ok = $true; texto = "SIMULACAO: reiniciaria '$Servico' (estado atual: $($svc.Status))" }
  }

  $antes = $svc.Status
  Restart-Service -Name $Servico -Force -ErrorAction Stop

  # Confirma o estado em vez de assumir. `Restart-Service` retorna sem erro para
  # servico que sobe e cai logo em seguida, que e justamente o caso interessante.
  Start-Sleep -Seconds 3
  $depois = (Get-Service -Name $Servico).Status

  return @{
    ok    = ($depois -eq 'Running')
    texto = "servico '$Servico': $antes -> $depois"
    payload = @{ servico = $Servico; antes = "$antes"; depois = "$depois" }
  }
}

function ExecutarClearTemp {
  param([int] $DiasMinimos, [bool] $Simulacao)

  $limite = (Get-Date).AddDays(-$DiasMinimos)
  $alvos = @($env:TEMP, (Join-Path $env:WINDIR 'Temp')) | Where-Object { $_ -and (Test-Path $_) }

  $bytes = 0L; $n = 0; $falhas = 0

  foreach ($dir in $alvos) {
    # -Force para alcancar arquivo oculto; SilentlyContinue porque diretorio
    # temporario tem sempre algo que o usuario atual nao le, e isso nao e falha.
    $arquivos = @(Get-ChildItem -Path $dir -Recurse -File -Force -ErrorAction SilentlyContinue |
                  Where-Object { $_.LastWriteTime -lt $limite })

    foreach ($f in $arquivos) {
      $bytes += $f.Length
      if ($Simulacao) { $n++; continue }
      try { Remove-Item $f.FullName -Force -ErrorAction Stop; $n++ }
      catch { $falhas++ }   # arquivo em uso: normal, nao e erro do comando
    }
  }

  $mb = [Math]::Round($bytes / 1MB, 1)
  $verbo = if ($Simulacao) { 'apagaria' } else { 'apagou' }

  return @{
    ok    = $true
    texto = "$verbo $n arquivo(s), ${mb}MB, mais velhos que $DiasMinimos dia(s)" +
            $(if ($falhas -gt 0) { "; $falhas em uso, ignorados" } else { '' })
    payload = @{ arquivos = $n; mb = $mb; em_uso = $falhas; simulacao = $Simulacao }
  }
}

function ExecutarRunTestCollection {
  param([bool] $Simulacao)

  # Serve para responder "o agente ainda coleta?" sem esperar o proximo ciclo.
  $a = NovaAmostra
  # `Coletar` marca coletor que falhou como flag "erro_<nome>". Ler um campo que
  # nao existe daria uma lista vazia e o relato diria "todos os coletores ok"
  # justamente quando nenhum funcionou.
  $falhos = @($a.flags | Where-Object { $_ -like 'erro_*' })

  return @{
    ok    = ($falhos.Count -eq 0)
    texto = "coleta de teste: cpu $($a.cpu_pct)% mem $($a.mem_pct)% " +
            $(if ($falhos.Count -gt 0) { "| coletores com falha: $($falhos -join ', ')" } else { '| todos os coletores ok' })
    payload = @{ cpu_pct = $a.cpu_pct; mem_pct = $a.mem_pct; coletores_com_falha = $falhos }
  }
}

function ExecutarWakeMachine {
  param([string] $Mac, [string] $Alvo, [bool] $Simulacao)

  # O "pacote magico": 6 bytes 0xFF seguidos do MAC repetido 16 vezes. E so
  # isso — nao ha protocolo, nao ha resposta, nao ha confirmacao. A placa do
  # alvo reconhece o proprio endereco nesse padrao e liga a maquina.
  $limpo = ($Mac -replace '[^0-9A-Fa-f]', '')
  if ($limpo.Length -ne 12) {
    return @{ ok = $false; texto = "MAC invalido: $Mac" }
  }

  $bytesMac = for ($i = 0; $i -lt 12; $i += 2) { [Convert]::ToByte($limpo.Substring($i, 2), 16) }
  $pacote = [byte[]] (, 0xFF * 6) + ([byte[]] $bytesMac * 16)

  if ($Simulacao) {
    return @{ ok = $true
              texto = "SIMULACAO: mandaria o pacote magico para $Alvo ($Mac)" }
  }

  # Broadcast na sub-rede de CADA placa. O broadcast global (255.255.255.255)
  # sai por uma interface so, escolhida pelo sistema — e numa maquina com duas
  # placas costuma ser a errada.
  $enviados = 0
  $erros = @()

  try {
    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.EnableBroadcast = $true

    $redes = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
               Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.PrefixLength -lt 31 })

    foreach ($r in $redes) {
      try {
        # Endereco de broadcast da sub-rede: IP com os bits de host todos em 1.
        $ip = [Net.IPAddress]::Parse($r.IPAddress).GetAddressBytes()
        $mascara = [uint32]0xFFFFFFFF -shl (32 - $r.PrefixLength)
        $mb = [BitConverter]::GetBytes([uint32]$mascara)
        if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($mb) }

        $bc = New-Object byte[] 4
        for ($i = 0; $i -lt 4; $i++) { $bc[$i] = $ip[$i] -bor (-bnot $mb[$i] -band 0xFF) }
        $destino = [Net.IPAddress]::new($bc)

        # 9 e a porta convencional (discard). 7 tambem e usada; mandar nas duas
        # custa nada e cobre placa que so escuta uma.
        foreach ($porta in 9, 7) {
          $ponto = New-Object Net.IPEndPoint($destino, $porta)
          [void]$udp.Send($pacote, $pacote.Length, $ponto)
          $enviados++
        }
      } catch {
        $erros += "$($r.IPAddress): $($_.Exception.Message)"
      }
    }

    $udp.Close()
  } catch {
    return @{ ok = $false; texto = "falha ao abrir o socket: $($_.Exception.Message)" }
  }

  if ($enviados -eq 0) {
    return @{ ok = $false
              texto = "nao consegui enviar o pacote: $($erros -join '; ')" }
  }

  # `ok` significa "o pacote saiu", NAO "a maquina ligou". WoL nao tem resposta:
  # quem confirma e o alvo voltar a reportar telemetria daqui a alguns minutos.
  # Dizer "ligada com sucesso" aqui seria afirmar o que nao se sabe.
  return @{
    ok    = $true
    texto = "pacote magico enviado para $Alvo ($Mac) em $enviados destino(s). " +
            "Se a maquina estiver apta, ela aparece online em ate 2 min."
    payload = @{ mac = $Mac; alvo = $Alvo; destinos = $enviados }
  }
}

function ExecutarComando {
  param($Comando)

  $tipo = [string]$Comando.kind
  $sim  = [bool]$Comando.dry_run
  $p    = $Comando.params

  # `switch` sobre uma lista FECHADA, e o default recusa. Um tipo desconhecido
  # vindo de um servidor mais novo tem que virar falha explicita, nunca acao
  # adivinhada — e o relato de falha diz ao painel para atualizar o agente.
  switch ($tipo) {
    'restart_service'     { return (ExecutarRestartService -Servico ([string]$p.servico) -Simulacao $sim) }
    'clear_temp'          { return (ExecutarClearTemp -DiasMinimos ([int]$p.dias_minimos) -Simulacao $sim) }
    'run_test_collection' { return (ExecutarRunTestCollection -Simulacao $sim) }
    'wake_machine'        { return (ExecutarWakeMachine -Mac ([string]$p.mac) -Alvo ([string]$p.alvo) -Simulacao $sim) }
    'restart_machine' {
      # O relato precisa dizer o que REALMENTE aconteceu. "reinicio agendado"
      # numa simulacao ensina a nao confiar no dry-run, que so serve enquanto
      # for confiavel.
      if ($sim) { return @{ ok = $true; texto = 'SIMULACAO: reiniciaria esta maquina em 15s' } }
      return @{ ok = $true; texto = 'reinicio agendado para daqui a 15s'; reiniciar = $true }
    }
    default {
      return @{ ok = $false; texto = "tipo de comando desconhecido nesta versao do agente ($VERSAO): $tipo" }
    }
  }
}

function ProcessarComandos {
  param([array] $Comandos, [hashtable] $Maquina)

  foreach ($c in $Comandos) {
    $r = $null
    try {
      Registrar 'INF' ("comando {0} recebido{1}" -f $c.kind, $(if ($c.dry_run) { ' (simulacao)' } else { '' }))
      $r = ExecutarComando $c
    } catch {
      # O comando falhar nao pode derrubar o agente: o monitoramento tem que
      # sobreviver a acao remota, senao um comando ruim cega a loja.
      $r = @{ ok = $false; texto = "erro ao executar: $($_.Exception.Message)" }
    }

    $registro = @{
      command_id = $c.command_id
      ok         = [bool]$r.ok
      texto      = [string]$r.texto
      payload    = $r.payload
    }

    # Grava ANTES de qualquer outra coisa: se o processo morrer daqui em diante,
    # o relato sobrevive e sobe no proximo ciclo.
    ResultadoGravar $registro
    $script:resultadosPendentes += $registro

    Registrar $(if ($r.ok) { 'INF' } else { 'AVI' }) ("comando {0}: {1}" -f $c.kind, $r.texto)

    # REINICIO POR ULTIMO, e so depois de o resultado SAIR daqui.
    # Se reiniciasse antes de relatar, o comando ficaria 'sent' ate expirar e o
    # painel diria "expirou sem ser executado" para uma maquina que reiniciou
    # certinho — o relato mentiria sobre o que aconteceu.
    if ($r.reiniciar -and -not $c.dry_run) {
      try {
        # Com uma amostra fresca, e nao vazia: o contrato de ingestao recusa
        # lote sem amostra, e esta e a ultima leitura antes de a maquina cair —
        # exatamente a que interessa se ela nao voltar.
        Enviar -Amostras @(NovaAmostra) -Maquina $Maquina | Out-Null
        ResultadosLimpar
        Registrar 'INF' 'resultado do reinicio enviado; reiniciando em 15s'
      } catch {
        Registrar 'AVI' "nao consegui relatar antes de reiniciar: $($_.Exception.Message)"
      }
      # /t 15 da tempo de o log ser gravado em disco antes do desligamento.
      & shutdown.exe /r /t 15 /c 'Reinicio solicitado pelo Sentinela' | Out-Null
      return
    }
  }
}

# ---------------------------------------------------------------------------
# Modo diagnostico
# ---------------------------------------------------------------------------
if ($MostrarJson) {
  $a = NovaAmostra
  @{
    agent_version = $VERSAO
    sent_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    machine = InfoMaquina
    samples = @($a)
  } | ConvertTo-Json -Depth 12
  exit 0
}

# ---------------------------------------------------------------------------
# Laco principal
# ---------------------------------------------------------------------------
Registrar 'INF' "agente $VERSAO iniciando | maquina $($cfg.machineLabel) | loja $($cfg.siteCode)"
Registrar 'INF' "destino $($cfg.ingestUrl) | intervalo ${intervalo}s | spool $spoolPath"

$maquina = InfoMaquina
$tentativa = 0
$proximaInfo = (Get-Date).AddHours(1)

# Retoma o que executou e nao conseguiu relatar antes de o processo anterior
# terminar — queda do agente, reinicio da maquina, ou o proprio comando de
# reinicio. Sem isto, gravar em disco nao serviria para nada.
$script:resultadosPendentes = @(ResultadosCarregar)
if ($script:resultadosPendentes.Count -gt 0) {
  Registrar 'INF' "$($script:resultadosPendentes.Count) resultado(s) de comando pendente(s) do ciclo anterior"
}

while ($true) {
  $inicioCiclo = Get-Date

  try {
    # 1. coleta
    $amostra = NovaAmostra

    # 2. REGRA 16: grava no spool ANTES de tentar enviar
    SpoolGravar $amostra

    # 3. retencao
    SpoolAparar

    # 4. metadados de hora em hora
    if ((Get-Date) -ge $proximaInfo) { $maquina = InfoMaquina; $proximaInfo = (Get-Date).AddHours(1) }

    # 5. drena o spool, do mais antigo para o mais novo
    $pendentes = @(SpoolLer)
    if ($pendentes.Count -gt 0) {
      $enviar = @()
      $n = [Math]::Min($lote, $pendentes.Count)
      for ($i = 0; $i -lt $n; $i++) {
        try {
          $enviar += ($pendentes[$i] | ConvertFrom-Json)
        } catch {
          # catch que FALA. A versao anterior era `catch { }` e engolia o motivo:
          # o agente dizia apenas "descartadas N linhas ilegiveis" e nao havia
          # como saber por que. Um catch silencioso num caminho de descarte de
          # dado e exatamente onde um defeito se esconde.
          Registrar 'AVI' ("linha {0} do spool ilegivel: {1} | inicio: {2}" -f `
            $i, $_.Exception.Message,
            $pendentes[$i].Substring(0, [Math]::Min(120, $pendentes[$i].Length)))
        }
      }

      if ($enviar.Count -gt 0) {
        $r = Enviar -Amostras $enviar -Maquina $maquina
        SpoolRemoverPrimeiras $n
        $tentativa = 0

        # So limpa DEPOIS de o envio voltar sem erro. Limpar antes perderia o
        # relato numa falha de rede, e o comando expiraria como "nao executado"
        # tendo executado.
        ResultadosLimpar

        $extra = ''
        if ($r.duplicates -gt 0) { $extra = ", $($r.duplicates) duplicadas" }
        Registrar 'INF' ("enviadas {0} | aceitas {1}{2} | cpu {3}% mem {4}/{5}MB" -f `
          $enviar.Count, $r.accepted, $extra, $amostra.cpu_pct, $amostra.mem_used_mb, $amostra.mem_total_mb)

        # 6. o que o servidor pediu. Por ultimo no ciclo: um comando demorado
        #    (ou um reinicio) nao pode atrasar a gravacao da telemetria, que e a
        #    funcao que o sistema nao pode perder.
        $comandos = @($r.comandos)
        if ($comandos.Count -gt 0) { ProcessarComandos -Comandos $comandos -Maquina $maquina }
      } else {
        SpoolRemoverPrimeiras $n
        Registrar 'AVI' "descartadas $n linha(s) ilegivel(is) do spool"
      }
    }
  } catch {
    $tentativa++
    # Link caido e o caso NORMAL numa loja: nivel baixo, com marco visivel de
    # tanto em tanto para uma queda longa nao ficar invisivel.
    if ($tentativa -in @(1, 5, 20, 60)) {
      Registrar 'AVI' "falha no envio (tentativa $tentativa): $($_.Exception.Message)"
      Registrar 'AVI' "as amostras continuam sendo gravadas no spool"
    }
  }

  if ($UmaVez) { break }

  # Regra 18: jitter no intervalo. Sem ele, muitos agentes que ligam juntos batem
  # no servidor no mesmo segundo, para sempre.
  $gasto = ((Get-Date) - $inicioCiclo).TotalSeconds
  $espera = $intervalo * (1 + ((Get-Random -Minimum -200 -Maximum 200) / 1000.0)) - $gasto

  # Recuo exponencial quando ha falha acumulada.
  if ($tentativa -gt 0) {
    $espera = [Math]::Min(300, $intervalo * [Math]::Pow(2, [Math]::Min($tentativa, 5)))
  }

  if ($espera -lt 1) { $espera = 1 }
  Start-Sleep -Seconds $espera
}

Registrar 'INF' 'agente encerrado'
