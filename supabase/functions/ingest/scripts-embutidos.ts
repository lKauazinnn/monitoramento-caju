// =============================================================================
// GERADO — não edite à mão
// =============================================================================
// Origem:
//   agent/agente-powershell.ps1  (55970 bytes, sha256:db4b8ae45138a814)
//   docker/ingest-local/instalar.ps1  (12532 bytes, sha256:2dbff83b3f196c6c)
//   scripts/atualizar-agente.ps1  (8832 bytes, sha256:8676568c50530e89)
//
// Regerar:  node scripts/gerar-scripts-embutidos.mjs
//
// A Edge Function serve estes dois arquivos em HTTPS para que o comando de uma
// linha funcione numa loja remota, onde o endpoint local da LAN não existe.
// =============================================================================

export const AGENTE_PS1: string = `<#
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
  Caminho do config.json. Padrao: %ProgramData%\\MonitorAgent\\config.json

.PARAMETER UmaVez
  Coleta uma amostra, envia e sai. Use para testar.

.PARAMETER MostrarJson
  Imprime o JSON que seria enviado e sai, sem enviar nada.

.EXAMPLE
  .\\agent\\agente-powershell.ps1 -MostrarJson

.EXAMPLE
  .\\agent\\agente-powershell.ps1
#>
[CmdletBinding()]
param(
  [string] $Config = (Join-Path $env:ProgramData 'MonitorAgent\\config.json'),
  [switch] $UmaVez,
  [switch] $MostrarJson
)

$ErrorActionPreference = 'Stop'
$VERSAO = 'ps-1.6.1'

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
  Write-Host 'Gere com: .\\scripts\\monitorar-este-pc.ps1' -ForegroundColor Yellow
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

function Cim {
  param([string] $Classe, [string] $Filtro, [int] $Prazo = 8)

  # PRAZO OBRIGATORIO, e a razao veio de uma instalacao real:
  #
  # Num servidor com os contadores de performance do WMI corrompidos, cada
  # \`Get-CimInstance Win32_PerfFormattedData_*\` levou NOVENTA SEGUNDOS para
  # falhar com "Classe invalida". Dois coletores nessa situacao fizeram um
  # ciclo de 60s levar 4m38s — o agente passou a reportar menos de uma vez a
  # cada cinco minutos, e o painel mostrava a maquina quase offline.
  #
  # \`-OperationTimeoutSec\` corta isso: a consulta falha em 8s e o ciclo segue.
  # Um coletor quebrado custa 8 segundos, nao um minuto e meio.
  $p = @{ ClassName = $Classe; OperationTimeoutSec = $Prazo; ErrorAction = "Stop" }
  if ($Filtro) { $p.Filter = $Filtro }
  Get-CimInstance @p
}
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
    # Win32_PerfFormattedData_* depende dos contadores de performance do WMI,
    # que EM ALGUNS SERVIDORES estao corrompidos ou nao registrados — o erro
    # que aparece e "Classe invalida", que nao sugere nada disso.
    #
    # Win32_Processor.LoadPercentage nao depende deles: e uma propriedade do
    # proprio objeto de hardware. E menos precisa (amostra instantanea, nao
    # media de intervalo), mas um numero aproximado e infinitamente melhor que
    # nenhum — sem ele a maquina aparece no painel sem CPU, e ninguem sabe se
    # ela esta ociosa ou fervendo.
    $formatado = $null
    try {
      $f = Cim Win32_PerfFormattedData_PerfOS_Processor "Name='_Total'"
      $formatado = [double]$f.PercentProcessorTime
    } catch {
      $lp = (Cim Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
      if ($null -ne $lp) {
        $formatado = [double]$lp
        $amostra.flags += 'cpu_win32_processor'
      } else {
        throw
      }
    }

    # Contador bruto para o fallback: PercentProcessorTime bruto acumula tempo
    # OCIOSO (PERF_100NSEC_TIMER_INV), entao ocupado = 100 * (1 - dCont/dTempo).
    # O contador bruto e so o desempate do caso "formatado devolve 0 sempre".
    # Se ele tambem nao existir, seguimos com o que temos.
    $b = $null
    try { $b = Cim Win32_PerfRawData_PerfOS_Processor "Name='_Total'" } catch { }
    $bruto = $null
    if ($null -ne $b -and $null -ne $script:cpuBrutoAnterior) {
      $dc = [double]$b.PercentProcessorTime - $script:cpuBrutoAnterior
      $dt = [double]$b.Timestamp_Sys100NS   - $script:cpuTsAnterior
      if ($dt -gt 0 -and $dc -ge 0) { $bruto = 100.0 * (1.0 - ($dc / $dt)) }
    }
    if ($null -ne $b) {
      $script:cpuBrutoAnterior = [double]$b.PercentProcessorTime
      $script:cpuTsAnterior = [double]$b.Timestamp_Sys100NS
    }

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
    # Mesmo problema, mesma saida. Uptime vem de LastBootUpTime, que e
    # propriedade do sistema operacional e nao depende de contador nenhum; a
    # contagem de processos vem de Get-Process.
    #
    # O que se perde no caminho alternativo: fila do processador e contagem de
    # threads. Sao os dois numeros menos usados do painel, e perde-los e melhor
    # que perder o uptime — que e o que diz ha quantos dias a maquina nao
    # reinicia, e alimenta o alerta de manutencao devida.
    try {
      $sy = Cim Win32_PerfFormattedData_PerfOS_System
      $amostra.cpu_queue_length = [double]$sy.ProcessorQueueLength
      $amostra.proc_count       = [int]$sy.Processes
      $amostra.thread_count     = [int]$sy.Threads
      $amostra.uptime_seconds   = [long]$sy.SystemUpTime
    } catch {
      $os = Cim Win32_OperatingSystem
      $amostra.uptime_seconds = [long]((Get-Date) - $os.LastBootUpTime).TotalSeconds
      $amostra.proc_count     = @(Get-Process -ErrorAction SilentlyContinue).Count
      $amostra.flags += 'sistema_sem_contadores'
    }
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
      $filtro = ($servicos | ForEach-Object { "Name='$($_ -replace "'", "\\'")'" }) -join ' OR '
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

  # ---- Virtualizacao: quem hospeda esta maquina --------------------------
  # Wake-on-LAN nao alcanca maquina virtual (a placa nao existe com a VM
  # desligada), e ligar uma exige a API do hipervisor. Para chegar la faltavam
  # tres coisas, e DUAS delas o proprio Windows sabe responder de dentro da VM:
  #
  #   QUAL hipervisor  -> o fabricante da placa-mae virtual se entrega
  #   QUAL VM e esta   -> o UUID de SMBIOS e o mesmo que o hipervisor conhece
  #
  # A terceira, a credencial, nenhum agente pode descobrir — ela vem de uma
  # pessoa. Mas sem estas duas o operador teria que abrir cada VM para dizer
  # onde ela mora, e e exatamente esse trabalho manual que o sistema existe
  # para eliminar.
  #
  # Fica no InfoMaquina, que roda de hora em hora, e nao no ciclo de 60s: isto
  # nao muda enquanto a maquina existir.
  try {
    $cs = Cim Win32_ComputerSystem
    $info.virt_fabricante = $cs.Manufacturer
    $info.virt_modelo     = $cs.Model

    # Fabricante e modelo em texto identificam o hipervisor sem depender de
    # nenhuma lista nossa ficar atualizada:
    #   QEMU / Standard PC (Q35 + ICH9)  -> KVM (Proxmox, libvirt)
    #   VMware, Inc.                     -> ESXi / Workstation
    #   Microsoft Corporation + Virtual Machine -> Hyper-V
    #   innotek GmbH                     -> VirtualBox
    #   Xen                              -> XCP-ng / XenServer
    # A classificacao fica no SERVIDOR, com o texto cru guardado: se aparecer um
    # hipervisor que eu nao previ, o dado esta la para alguem ler.
  } catch { }

  try {
    $p = Cim Win32_ComputerSystemProduct
    # O UUID de SMBIOS. No Proxmox e o mesmo valor que a API devolve para a VM,
    # entao ele e a ponte entre "esta maquina" e "o vmid la" — sem ninguem
    # digitar numero de VM em formulario.
    $info.virt_uuid = $p.UUID
  } catch { }

  try {
    $b = Cim Win32_BIOS
    $info.virt_bios = ($b.Manufacturer, $b.SMBIOSBIOSVersion -join ' ')
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
              Where-Object { $_.IPAddress -notmatch '^(127\\.|169\\.254\\.)' } |
              Select-Object -First 1
      if ($ip) { $info.ip_lan = $ip.IPAddress }
    }
  } catch { }

  # Sem rota padrao (maquina isolada): cai para o primeiro IPv4 util.
  if (-not $info.ip_lan) {
    try {
      $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
              Where-Object { $_.IPAddress -notmatch '^(127\\.|169\\.254\\.)' } |
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
  $amostraFlagRede = $null

  # PELO ADAPTADOR DA ROTA PADRAO, e nao por \`Get-NetAdapter -Physical\`.
  #
  # A primeira versao filtrava por -Physical, e numa maquina virtualizada isso
  # devolve VAZIO: o Windows nao marca a placa de VM como hardware fisico. O
  # agente reportava \`mac = null\`, o servidor aceitava (null e legitimo: existe
  # maquina so com Wi-Fi), e o painel dizia "nunca reportou o endereco da placa"
  # sem nenhuma pista de por que.
  #
  # A rota padrao ja foi resolvida acima para o ip_lan, e ela aponta para a placa
  # que REALMENTE carrega o trafego desta maquina — que e exatamente a que tem
  # que receber o pacote magico. Serve para fisica e para virtual.
  try {
    $ad = $null

    if ($rota) {
      $ad = Get-NetAdapter -InterfaceIndex $rota.InterfaceIndex -ErrorAction SilentlyContinue
    }

    # Sem rota utilizavel: a melhor placa ligada que nao seja Wi-Fi.
    if (-not $ad) {
      $ad = Get-NetAdapter -ErrorAction Stop |
              Where-Object { $_.Status -eq 'Up' -and $_.MediaType -ne 'Native 802.11' } |
              Sort-Object -Property @{ Expression = { $_.LinkSpeed } } -Descending |
              Select-Object -First 1
    }

    if ($ad -and $ad.MacAddress) {
      # Get-NetAdapter devolve com hifen (AA-BB-CC); o banco normaliza, mas o
      # formato com dois-pontos e o que todo mundo espera ver num log.
      $info.mac = $ad.MacAddress.Replace('-', ':')

      # Wi-Fi vai junto, mas MARCADO: WoL sobre Wi-Fi depende do adaptador e do
      # ponto de acesso e quase nunca funciona. Sem esta marca, o painel
      # ofereceria "Ligar o PC" para uma maquina que nunca vai acordar.
      $info.mac_wifi = ($ad.MediaType -eq 'Native 802.11')
    } else {
      # Falhar em silencio foi o defeito. Se nao achou placa, DIGA.
      $amostraFlagRede = 'sem_placa_para_mac'
    }
  } catch {
    $amostraFlagRede = "erro_mac: $($_.Exception.Message)"
  }

  if ($amostraFlagRede) { Registrar 'AVI' "MAC nao coletado: $amostraFlagRede" }

  return $info
}

# ---------------------------------------------------------------------------
# Spool — regra 16: grava ANTES de enviar
# ---------------------------------------------------------------------------
# UTF-8 SEM BOM, escrito pelo .NET e nao por Add-Content.
#
# \`Add-Content -Encoding utf8\` no PowerShell 5.1 grava BOM ao criar o arquivo, e
# o BOM fica colado no inicio da PRIMEIRA linha. ConvertFrom-Json entao falha
# naquela linha, o agente a classifica como ilegivel e DESCARTA — a primeira
# amostra de cada spool novo se perdia em silencio, com a mensagem
# "descartadas 1 linha(s) ilegivel(is)" como unica pista.
$script:utf8SemBom = New-Object System.Text.UTF8Encoding($false)

function SpoolGravar {
  param([hashtable] $Amostra)
  $linha = ($Amostra | ConvertTo-Json -Depth 10 -Compress) + "\`n"
  [System.IO.File]::AppendAllText($spoolPath, $linha, $script:utf8SemBom)
}

<#
  ATENCAO AO USAR: sempre escreva \`$x = @(SpoolLer)\`, com o @() NO CHAMADOR.

  O PowerShell DESEMBRULHA array de um unico elemento ao retornar de uma funcao.
  O \`@()\` aqui dentro nao sobrevive ao return: com exatamente uma amostra no
  spool, o chamador recebia a STRING em vez de um array de uma posicao. Ai
  \`$pendentes[0]\` indexava a string e devolvia um CARACTERE, o ConvertFrom-Json
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
  return @($texto.TrimStart([char]0xFEFF) -split "\`r?\`n" | Where-Object { $_.Trim() })
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
    [System.IO.File]::WriteAllText($spoolPath, (($vivas -join "\`n") + "\`n"), $script:utf8SemBom)
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
    [System.IO.File]::WriteAllText($spoolPath, (($restam -join "\`n") + "\`n"), $script:utf8SemBom)
  }
}

# ---------------------------------------------------------------------------
# Envio
# ---------------------------------------------------------------------------
function Enviar {
  # \`PrazoSegundos\` existe para o PULSO. O envio normal pode esperar 30s: perder
  # uma amostra e pior que atrasar. O pulso nao: ele e melhoria de latencia, e um
  # pulso pendurado 30s dentro do laco de espera rouba metade do ciclo seguinte.
  # Prazo curto ali significa "se nao for rapido, deixa para o proximo".
  param([array] $Amostras, [hashtable] $Maquina, [int] $PrazoSegundos = 30)

  $envelope = @{
    agent_version = $VERSAO
    sent_at       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    machine       = $Maquina
    samples       = $Amostras
    # O que executei desde o ultimo envio. Vai junto com a telemetria porque nao
    # ha canal de volta: a mesma conexao de saida serve para relatar e perguntar.
    command_results = @($script:resultadosPendentes)
    # Endereco da placa, para esta maquina poder ser LIGADA pelo vizinho um dia.
    # Vai fora de \`machine\` porque quem grava e a funcao da fila, nao a ingestao.
    network = @{ mac = $Maquina.mac; mac_wifi = $Maquina.mac_wifi }
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
  $resp = Invoke-RestMethod -Uri $url -Method Post -Headers $cab \`
            -ContentType 'application/json' -Body $corpo -TimeoutSec $PrazoSegundos
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
    Add-Content -Path $resultadosPath -Encoding utf8 \`
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

  # Confirma o estado em vez de assumir. \`Restart-Service\` retorna sem erro para
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
    texto = "$verbo $n arquivo(s), \${mb}MB, mais velhos que $DiasMinimos dia(s)" +
            $(if ($falhas -gt 0) { "; $falhas em uso, ignorados" } else { '' })
    payload = @{ arquivos = $n; mb = $mb; em_uso = $falhas; simulacao = $Simulacao }
  }
}

function ExecutarRunTestCollection {
  param([bool] $Simulacao)

  # Serve para responder "o agente ainda coleta?" sem esperar o proximo ciclo.
  $a = NovaAmostra
  # \`Coletar\` marca coletor que falhou como flag "erro_<nome>". Ler um campo que
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
               Where-Object { $_.IPAddress -notmatch '^(127\\.|169\\.254\\.)' -and $_.PrefixLength -lt 31 })

    foreach ($r in $redes) {
      try {
        # Endereco de broadcast da sub-rede: IP com os bits de host todos em 1.
        #
        # SEM MASCARA DE 32 BITS AQUI, e sem \`[uint32]\`. A versao anterior fazia
        #
        #   $mascara = [uint32]0xFFFFFFFF -shl (32 - $r.PrefixLength)
        #
        # e nunca funcionou uma vez. No PowerShell, \`0xFFFFFFFF\` e Int32 e vale
        # -1, nao 4294967295 — entao \`[uint32]0xFFFFFFFF\` e \`[uint32](-1)\` e
        # estoura com "Value was either too large or too small for a UInt32"
        # ANTES de deslocar bit nenhum. Como isso acontecia dentro do try de cada
        # placa, o erro virava "nao consegui enviar o pacote" e parecia problema
        # de rede.
        #
        # Byte por byte, da direita para a esquerda, os bits de host viram 1. So
        # numeros pequenos, nenhuma conversao de tipo, nada para estourar.
        $ip = [Net.IPAddress]::Parse($r.IPAddress).GetAddressBytes()
        $bc = New-Object byte[] 4
        $bitsDeHost = 32 - $r.PrefixLength

        for ($i = 3; $i -ge 0; $i--) {
          $n = [Math]::Min(8, $bitsDeHost)
          # (1 -shl n) - 1 = os n bits mais baixos em 1. Com n = 0 da zero, e o
          # byte fica igual ao do IP — que e o certo para a parte da rede.
          $bc[$i] = $ip[$i] -bor ((1 -shl $n) - 1)
          $bitsDeHost -= $n
        }

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

  # \`ok\` significa "o pacote saiu", NAO "a maquina ligou". WoL nao tem resposta:
  # quem confirma e o alvo voltar a reportar telemetria daqui a alguns minutos.
  # Dizer "ligada com sucesso" aqui seria afirmar o que nao se sabe.
  return @{
    ok    = $true
    texto = "pacote magico enviado para $Alvo ($Mac) em $enviados destino(s). " +
            "Se a maquina estiver apta, ela aparece online em ate 2 min."
    payload = @{ mac = $Mac; alvo = $Alvo; destinos = $enviados }
  }
}

function ExecutarSleepMachine {
  param([string] $Modo, [bool] $Simulacao)

  # Confere ANTES de suspender que da para acordar. Suspender uma maquina que
  # nao acorda e transformar um PC funcionando num PC apagado a 900 km — e a
  # unica hora em que da para descobrir isso e enquanto ela ainda responde.
  $armados = @()
  try { $armados = @(& powercfg.exe -devicequery wake_armed 2>$null) } catch { }

  $placa = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
             Where-Object { $_.Status -eq 'Up' -and $_.MediaType -ne 'Native 802.11' } |
             Select-Object -First 1

  $placaArmada = $false
  if ($placa) {
    $placaArmada = @($armados | Where-Object { $_ -like "*$($placa.InterfaceDescription)*" }).Count -gt 0
  }

  if (-not $placaArmada) {
    return @{
      ok = $false
      texto = 'RECUSADO: a placa de rede nao esta armada para acordar esta maquina. ' +
              'Suspender agora deixaria o PC inacessivel. Rode conferir-wol.ps1 -Corrigir primeiro.'
      payload = @{ wake_armed = $armados }
    }
  }

  # O estado precisa EXISTIR neste sistema. Hibernacao desligada e comum, e
  # \`shutdown /h\` numa maquina sem hibernacao nao faz nada e nao reclama.
  $estados = ''
  try { $estados = (& powercfg.exe /a 2>$null) -join ' ' } catch { }

  if ($Modo -eq 'hibernar' -and $estados -notmatch 'Hibernar|Hibernate') {
    return @{ ok = $false; texto = 'hibernacao nao esta disponivel nesta maquina' }
  }

  if ($Simulacao) {
    return @{ ok = $true
              texto = "SIMULACAO: $Modo esta maquina. A placa ESTA armada " +
                      "($($placa.InterfaceDescription)), entao daria para acorda-la depois."
              payload = @{ modo = $Modo; placa_armada = $true } }
  }

  # O relato tem que SAIR antes de a maquina cair. Vai no envelope do proximo
  # envio, que o chamador dispara logo em seguida — mesma logica do reinicio.
  $script:suspenderDepois = $Modo

  return @{
    ok    = $true
    texto = "$Modo agendado. A placa esta armada; use 'Ligar o PC' pelo painel para acordar."
    payload = @{ modo = $Modo; placa = $placa.InterfaceDescription }
    suspender = $true
  }
}


function ExecutarUpdateAgent {
  param([bool] $Simulacao)

  # O agente se substituindo. E a operacao mais perigosa que ele faz: se gravar
  # um arquivo quebrado por cima de si mesmo, a maquina fica MUDA — e muda numa
  # loja a 900 km e uma visita.
  #
  # Por isso a ordem aqui e: baixar -> CONFERIR -> so entao gravar. E o relato
  # sai antes do reinicio, como no restart_machine.
  #
  # O endereco vem do config.json desta maquina, NUNCA do comando. Aceitar uma
  # URL vinda do painel daria a quem controlasse o banco o poder de mandar cada
  # PC baixar e executar um script arbitrario.
  $url = $cfg.ingestUrl.TrimEnd('/') + '/agente.ps1'

  try {
    $novo = Invoke-RestMethod -Uri $url -TimeoutSec 30
  } catch {
    return @{ ok = $false; texto = "nao consegui baixar de $($url): $($_.Exception.Message)" }
  }

  # Um proxy devolvendo pagina de login responde HTTP 200 com corpo curto.
  # Gravar isso por cima do agente derrubaria o monitoramento em vez de
  # atualiza-lo.
  if ([string]::IsNullOrWhiteSpace($novo) -or $novo.Length -lt 20000) {
    return @{ ok = $false; texto = "o que voltou nao parece o agente ($($novo.Length) bytes)" }
  }

  if ($novo -notmatch '\\$VERSAO\\s*=\\s*''(ps-[0-9.]+)''') {
    return @{ ok = $false; texto = 'o que voltou nao tem linha de versao; nada foi alterado' }
  }
  $versaoNova = $Matches[1]

  if ($versaoNova -eq $VERSAO) {
    return @{ ok = $true; texto = "ja esta na $VERSAO; nada a fazer" }
  }

  # Onde EU estou. PSCommandPath e o caminho real deste arquivo — nao um nome
  # chutado, que ja me custou uma correcao quando o instalador usava outro.
  $alvo = $PSCommandPath
  if ([string]::IsNullOrWhiteSpace($alvo)) {
    $alvo = Join-Path $dirDados 'agente-powershell.ps1'
  }

  if ($Simulacao) {
    return @{ ok = $true
              texto = "SIMULACAO: trocaria $VERSAO por $versaoNova em $alvo"
              payload = @{ de = $VERSAO; para = $versaoNova } }
  }

  # Copia de seguranca ANTES de sobrescrever: se o novo nao subir, quem for ate
  # a maquina tem para onde voltar sem baixar nada.
  try { Copy-Item $alvo "$alvo.anterior" -Force -ErrorAction Stop } catch { }

  try {
    # BOM obrigatorio: o PowerShell 5.1 le .ps1 SEM BOM como ANSI, e um acento
    # vira caractere que quebra a analise sintatica.
    [IO.File]::WriteAllText($alvo, $novo, [Text.UTF8Encoding]::new($true))
  } catch {
    return @{ ok = $false; texto = "nao consegui gravar em $($alvo): $($_.Exception.Message)" }
  }

  $script:reiniciarAgenteDepois = $alvo

  return @{
    ok    = $true
    texto = "atualizado de $VERSAO para $versaoNova; reiniciando o agente"
    payload = @{ de = $VERSAO; para = $versaoNova; arquivo = $alvo }
    reiniciarAgente = $true
  }
}

function ExecutarComando {
  param($Comando)

  $tipo = [string]$Comando.kind
  $sim  = [bool]$Comando.dry_run
  $p    = $Comando.params

  # \`switch\` sobre uma lista FECHADA, e o default recusa. Um tipo desconhecido
  # vindo de um servidor mais novo tem que virar falha explicita, nunca acao
  # adivinhada — e o relato de falha diz ao painel para atualizar o agente.
  switch ($tipo) {
    'restart_service'     { return (ExecutarRestartService -Servico ([string]$p.servico) -Simulacao $sim) }
    'clear_temp'          { return (ExecutarClearTemp -DiasMinimos ([int]$p.dias_minimos) -Simulacao $sim) }
    'run_test_collection' { return (ExecutarRunTestCollection -Simulacao $sim) }
    'wake_machine'        { return (ExecutarWakeMachine -Mac ([string]$p.mac) -Alvo ([string]$p.alvo) -Simulacao $sim) }
    'sleep_machine'       { return (ExecutarSleepMachine -Modo ([string]$p.modo) -Simulacao $sim) }
    'update_agent'        { return (ExecutarUpdateAgent -Simulacao $sim) }
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

    # ATUALIZAR-SE, na mesma ordem: o relato sai antes de o processo morrer.
    #
    # Sem isto o comando ficaria "sent" ate expirar, e o painel diria "expirou
    # sem ser executado" sobre uma maquina que atualizou certinho — e alguem
    # mandaria de novo.
    if ($r.reiniciarAgente -and -not $c.dry_run) {
      try {
        Enviar -Amostras @(NovaAmostra) -Maquina $Maquina | Out-Null
        ResultadosLimpar
        Registrar 'INF' "atualizacao relatada; trocando de versao agora"
      } catch {
        Registrar 'AVI' "nao consegui relatar antes de atualizar: $($_.Exception.Message)"
      }

      # Sobe o agente NOVO e CONFERE QUE ELE VIVEU antes de sair.
      #
      # A versao anterior fazia Start-Process e \`exit 0\` sem olhar o resultado.
      # Num servidor onde a sessao 0 nao cria processo (desktop heap esgotado,
      # 0xC0000142), o processo novo morria na largada e o velho ja tinha se
      # despedido: a maquina ficava SEM AGENTE ate o proximo boot. Foi assim que
      # eu apaguei o monitoramento de duas maquinas de loja, relatando sucesso.
      #
      # Uma atualizacao que falha deve deixar a maquina rodando a versao ANTIGA,
      # nunca sem monitoramento nenhum.
      $novo = $null
      try {
        $novo = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
          '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
          ("\`"" + $script:reiniciarAgenteDepois + "\`""))
      } catch {
        Registrar 'ERR' "nao consegui subir o agente novo: $($_.Exception.Message)"
      }

      # 4s: tempo de o PowerShell carregar e falhar se for falhar. Processo que
      # morre por politica ou por falta de recurso morre nos primeiros segundos.
      $vivo = $false
      if ($novo) {
        Start-Sleep -Seconds 4
        try { $vivo = -not (Get-Process -Id $novo.Id -ErrorAction Stop).HasExited } catch { $vivo = $false }
      }

      if ($vivo) {
        Registrar 'INF' "agente novo de pe (pid $($novo.Id)); saindo"
        exit 0
      }

      # Nao subiu. Volta o arquivo antigo para o proximo boot nao insistir numa
      # versao que nao roda aqui, e SEGUE VIVO nesta versao — ela esta carregada
      # em memoria e funciona.
      Registrar 'ERR' 'o agente novo nao subiu; restaurando a versao anterior e continuando nesta'
      try {
        $bkp = "$($script:reiniciarAgenteDepois).anterior"
        if (Test-Path $bkp) { Copy-Item $bkp $script:reiniciarAgenteDepois -Force }
      } catch {
        Registrar 'ERR' "nem o rollback funcionou: $($_.Exception.Message)"
      }

      $script:reiniciarAgenteDepois = $null
    }

    # SUSPENDER, pela mesma razao e na mesma ordem: o relato sai primeiro.
    if ($r.suspender -and -not $c.dry_run) {
      try {
        Enviar -Amostras @(NovaAmostra) -Maquina $Maquina | Out-Null
        ResultadosLimpar
        Registrar 'INF' "resultado enviado; $($script:suspenderDepois) em 10s"
      } catch {
        Registrar 'AVI' "nao consegui relatar antes de suspender: $($_.Exception.Message)"
      }

      Start-Sleep -Seconds 10

      # SetSuspendState(hibernar, forcar, desabilitarEventosDeWake).
      # O terceiro parametro e FALSE de proposito: passar true desarmaria os
      # dispositivos de wake, e a maquina nunca mais acordaria pela rede — o
      # oposto exato do que este comando existe para permitir.
      $hibernar = ($script:suspenderDepois -eq 'hibernar')
      Add-Type -AssemblyName System.Windows.Forms
      [void][System.Windows.Forms.Application]::SetSuspendState($hibernar, $true, $false)
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
Registrar 'INF' "destino $($cfg.ingestUrl) | intervalo \${intervalo}s | spool $spoolPath"

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
          # catch que FALA. A versao anterior era \`catch { }\` e engolia o motivo:
          # o agente dizia apenas "descartadas N linhas ilegiveis" e nao havia
          # como saber por que. Um catch silencioso num caminho de descarte de
          # dado e exatamente onde um defeito se esconde.
          Registrar 'AVI' ("linha {0} do spool ilegivel: {1} | inicio: {2}" -f \`
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
        Registrar 'INF' ("enviadas {0} | aceitas {1}{2} | cpu {3}% mem {4}/{5}MB" -f \`
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

  # -------------------------------------------------------------------------
  # PULSO: reenvio da ultima amostra durante a espera
  # -------------------------------------------------------------------------
  # O problema: com envio a cada 60s, o servidor so pode declarar uma maquina
  # offline depois de ~120s (dois envios perdidos). Menos que isso e qualquer
  # ciclo lento vira falso offline. Entao saber que um servidor caiu levava mais
  # de dois minutos.
  #
  # A solucao NAO e um endpoint novo: e reenviar a MESMA amostra a cada 15s.
  #
  #   - \`register_metrics\` carimba \`last_contact_at = now()\` em TODO lote aceito
  #   - a amostra repetida cai no \`on conflict do nothing\` da chave
  #     (machine_id, time) e nao cria linha nenhuma
  #
  # Ou seja: o contato e renovado a cada 15s sem inserir um unico registro. Sem
  # crescimento de banco, sem migracao, sem rota nova. O limiar de offline pode
  # cair para ~40s.
  #
  # ISTO SO FUNCIONA POR CAUSA DA 0032. Antes dela, quem marcava o contato era o
  # relogio do AGENTE, vindo dentro da amostra — reenviar a mesma amostra
  # reenviaria o mesmo timestamp e nao renovaria nada. Foi a separacao entre
  # "quando foi medido" e "quando chegou" que tornou o pulso possivel.
  #
  # Se o envio falhar, o catch de sempre trata: o pulso e melhoria de latencia,
  # nao caminho critico. A amostra ja esta no spool.
  # O PULSO TEM ORCAMENTO DE TEMPO, e este e o conserto da primeira versao.
  #
  # Antes ele usava "o tempo que sobra do ciclo". Numa maquina cuja coleta demora
  # 50s sobravam 15s, entao ela mandava 1 lote por minuto — quase nenhum pulso.
  # As maquinas que MAIS precisavam do pulso eram as que menos recebiam, e o
  # envio extra dentro do laco principal atrasava ainda mais o ciclo delas. Duas
  # ficaram instaveis por isso.
  #
  # Agora: o pulso so acontece se houver folga de verdade, ele tem prazo curto
  # proprio, e NUNCA empurra o proximo ciclo. Se a espera for menor que 20s, nao
  # ha folga e ele simplesmente nao pulsa — a amostra do ciclo ja e o contato.
  $fim = (Get-Date).AddSeconds($espera)
  $ultima = $amostra
  $podePulsar = ($espera -ge 20) -and ($tentativa -eq 0) -and ($null -ne $ultima)

  while ((Get-Date) -lt $fim) {
    $resta = ($fim - (Get-Date)).TotalSeconds
    Start-Sleep -Seconds ([int][Math]::Max(1, [Math]::Min(15, $resta)))

    # Nao pulsa perto do fim: um envio comecando a 3s do proximo ciclo atrasa a
    # coleta, que e a funcao que nao pode ser perdida.
    if (($fim - (Get-Date)).TotalSeconds -lt 5) { break }
    if (-not $podePulsar) { continue }

    try {
      # \`Out-Null\` e nao \`Registrar\`: um pulso por 15s encheria o log com linha
      # que nao diz nada. O que interessa no log e a amostra e a falha.
      Enviar -Amostras @($ultima) -Maquina $maquina -PrazoSegundos 8 | Out-Null
    } catch {
      # Silencio proposital, e o pulso PARA no primeiro erro deste ciclo. Insistir
      # numa rede que nao responde e o que transformava latencia em atraso de
      # coleta: cada tentativa pendurada roubava segundos do ciclo seguinte.
      $podePulsar = $false
    }
  }
}

Registrar 'INF' 'agente encerrado'
`;

export const INSTALAR_PS1: string = `<#
  Instalador do agente de monitoramento — baixado e executado em UMA linha.

  Servido pelo proprio endpoint de ingestao, e o dashboard monta o comando com o
  token da maquina ja preenchido. O objetivo e nao precisar copiar pasta nenhuma:
  no PC novo, cola uma linha no PowerShell e acabou.

  O comando que o dashboard gera tem esta forma:

    & ([scriptblock]::Create((irm 'http://SERVIDOR:PORTA/instalar.ps1'))) \`
        -Servidor 'http://SERVIDOR:PORTA' -Token 'mon_...' -Segredo '...'

  scriptblock::Create em vez de \`iex\` direto porque so assim da para PASSAR
  ARGUMENTOS para um script baixado — com \`iex\` os parametros seriam ignorados em
  silencio e o instalador rodaria sem token.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string] $Servidor,
  [Parameter(Mandatory = $true)][string] $Token,
  [Parameter(Mandatory = $true)][string] $Segredo,

  [int]      $IntervaloSegundos = 60,
  [string[]] $Servicos = @(),

  # Registra tarefa agendada para o agente voltar sozinho apos reiniciar. Exige
  # terminal ELEVADO — e, rodando como SYSTEM, temperatura e SMART tambem passam
  # a ser coletados.
  [switch]   $ComTarefa,

  [switch]   $Parar
)

$ErrorActionPreference = 'Stop'

# TLS 1.2/1.3 antes de qualquer requisicao. O PowerShell 5.1 herda o padrao do
# .NET Framework, que em Windows sem atualizacao ainda negocia SSL3/TLS 1.0, e o
# Supabase recusa. Sem isto o instalador falharia ja no /healthz com "a conexao
# subjacente foi fechada" — mensagem que joga o diagnostico para firewall e
# certificado, quando o problema e a versao do protocolo.
foreach ($nome in @('Tls12', 'Tls13')) {
  try {
    $valor = [Enum]::Parse([Net.SecurityProtocolType], $nome)
    [Net.ServicePointManager]::SecurityProtocol =
      [Net.ServicePointManager]::SecurityProtocol -bor $valor
  } catch { }
}

$dirDados = Join-Path $env:ProgramData 'MonitorAgent'
$pidFile = Join-Path $dirDados 'agente.pid'
$agentePath = Join-Path $dirDados 'agente-powershell.ps1'
$configPath = Join-Path $dirDados 'config.json'

function Passo { param([string]$T) Write-Host ''; Write-Host "== $T ==" -ForegroundColor Cyan }
function Ok    { param([string]$T) Write-Host "   $T" -ForegroundColor Green }

function Info  { param([string]$T) Write-Host "   $T" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# NAO USE "exit" NESTE ARQUIVO. Use "return", sem valor.
# ---------------------------------------------------------------------------
# Ele e executado de uma linha so, assim:
#
#   & ([scriptblock]::Create((irm 'https://.../instalar.ps1'))) -Servidor ...
#
# Nessa forma, "exit" nao encerra o script: encerra a SESSAO do PowerShell. A
# janela fecha antes de a pessoa ler o que aconteceu — e num caminho de ERRO e
# justamente a mensagem de erro que se perde, deixando quem instalou sem nenhuma
# pista do que houve.
#
# "return" sem valor sai do scriptblock e deixa a janela viva. COM valor ele
# imprimiria o numero na saida, no meio das mensagens.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
if ($Parar) {
  if (Test-Path $pidFile) {
    try { Stop-Process -Id ([int](Get-Content $pidFile)) -Force -ErrorAction Stop; Ok 'agente encerrado' }
    catch { Info 'agente nao estava rodando' }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
  } else { Info 'nenhum agente registrado' }
  try { Unregister-ScheduledTask -TaskName 'MonitorAgent' -Confirm:$false -ErrorAction Stop; Ok 'tarefa agendada removida' } catch { }
  return
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host " Instalando o agente de monitoramento em $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

$Servidor = $Servidor.TrimEnd('/')

# ---------------------------------------------------------------------------
Passo 'Testando a conexao com o servidor'
# ---------------------------------------------------------------------------
# ANTES de instalar qualquer coisa. Descobrir aqui que o firewall bloqueia e muito
# melhor que instalar, subir o agente e ele ficar mudo sem ninguem saber.
try {
  $h = Invoke-RestMethod -Uri "$Servidor/healthz" -TimeoutSec 10
  if (-not $h.ok) { throw 'servidor respondeu, mas nao esta saudavel' }
  Ok "servidor respondeu: $Servidor"
} catch {
  Write-Host ''
  Write-Host "   NAO CONSEGUI FALAR COM $Servidor" -ForegroundColor Red
  Write-Host "   $($_.Exception.Message)" -ForegroundColor Red
  Write-Host ''

  # As duas situacoes pedem verificacoes OPOSTAS, e dar a lista errada custa
  # horas: numa loja remota nao existe "libere a porta no servidor", e na LAN nao
  # existe problema de DNS publico.
  if (([uri]$Servidor).Scheme -eq 'https') {
    Write-Host '   Endereco publico (HTTPS). Verifique, na ordem:' -ForegroundColor Yellow
    Write-Host '    1. esta maquina tem internet:'
    Write-Host '       Test-NetConnection 1.1.1.1 -Port 443' -ForegroundColor DarkGray
    Write-Host '    2. o nome resolve:'
    Write-Host "       Resolve-DnsName $(([uri]$Servidor).Host)" -ForegroundColor DarkGray
    Write-Host '    3. a rede da loja nao bloqueia a saida na 443 nem exige proxy'
    Write-Host '    4. o TLS desta maquina fecha com o servidor:'
    Write-Host "       Invoke-RestMethod '$Servidor/healthz'" -ForegroundColor DarkGray
    Write-Host '       (se falhar so aqui, o Windows esta sem atualizacao de TLS)'
    Write-Host '    5. a funcao de ingestao esta publicada e com os segredos definidos'
  } else {
    Write-Host '   Endereco de rede local (HTTP). Verifique, na ordem:' -ForegroundColor Yellow
    Write-Host '    1. o PC servidor esta ligado e a stack no ar'
    Write-Host '    2. as duas maquinas estao na MESMA rede'
    Write-Host '    3. o Firewall do Windows no servidor libera a porta:'
    Write-Host "       New-NetFirewallRule -DisplayName 'Monitoramento' -Direction Inbound -Protocol TCP -LocalPort $(([uri]$Servidor).Port) -Action Allow" -ForegroundColor DarkGray
    Write-Host '    4. o IP do servidor nao mudou (gere o comando de novo no dashboard)'
  }

  Write-Host ''
  return
}

# ---------------------------------------------------------------------------
Passo 'Baixando o agente'
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $dirDados | Out-Null

try {
  $script = Invoke-RestMethod -Uri "$Servidor/agente.ps1" -TimeoutSec 30
} catch {
  Write-Host "   nao foi possivel baixar o agente: $($_.Exception.Message)" -ForegroundColor Red
  return
}

# BOM UTF-8 de proposito: o PowerShell 5.1 le .ps1 como ANSI quando nao ha BOM, e
# um acento no arquivo viraria caractere de aspas que quebra a analise sintatica.
[System.IO.File]::WriteAllText($agentePath, $script, (New-Object System.Text.UTF8Encoding($true)))
Ok "agente em $agentePath"

# ---------------------------------------------------------------------------
Passo 'Detectando a rede desta maquina'
# ---------------------------------------------------------------------------
$gateway = ''
try {
  $rota = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric | Select-Object -First 1
  if ($rota -and $rota.NextHop -ne '0.0.0.0') { $gateway = $rota.NextHop }
} catch { }

if ($gateway) { Ok "gateway: $gateway" } else { Info 'gateway nao detectado (latencia da LAN ficara desligada)' }

# ---------------------------------------------------------------------------
Passo 'Gravando a configuracao'
# ---------------------------------------------------------------------------
$listaServicos = @($Servicos | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($listaServicos.Count -eq 0) { $listaServicos = @('Spooler', 'Dhcp', 'Dnscache') }

$config = [ordered]@{
  localRpc         = $false
  ingestUrl        = $Servidor
  sharedSecret     = $Segredo
  token            = $Token
  machineLabel     = $env:COMPUTERNAME
  intervalSeconds  = $IntervaloSegundos
  batchSize        = 200
  gatewayIp        = $gateway
  criticalServices = $listaServicos
  spool            = @{ maxRows = 20000; maxAgeHours = 72 }
}

# UTF-8 SEM BOM: JSON com BOM e recusado por parser estrito.
[System.IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 6),
  (New-Object System.Text.UTF8Encoding($false)))

Ok "configuracao em $configPath"
Info "servicos vigiados: $($listaServicos -join ', ')"

# ---------------------------------------------------------------------------
Passo 'Coleta de teste'
# ---------------------------------------------------------------------------
& powershell -NoProfile -ExecutionPolicy Bypass -File "$agentePath" -UmaVez
if ($LASTEXITCODE -ne 0) {
  Write-Host ''
  Write-Host '   a coleta de teste falhou — veja a mensagem acima' -ForegroundColor Red
  return
}

# ---------------------------------------------------------------------------
Passo 'Subindo o agente'
# ---------------------------------------------------------------------------
if (Test-Path $pidFile) {
  try { Stop-Process -Id ([int](Get-Content $pidFile)) -Force -ErrorAction Stop; Info 'agente anterior encerrado' } catch { }
}

$ehAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)

if ($ComTarefa -and $ehAdmin) {
  # Tarefa agendada como SYSTEM: sobrevive a reinicio e a logoff, e coleta
  # temperatura e SMART, que exigem privilegio.
  try { Unregister-ScheduledTask -TaskName 'MonitorAgent' -Confirm:$false -ErrorAction Stop } catch { }

  $acao = New-ScheduledTaskAction -Execute 'powershell.exe' \`
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \`"$agentePath\`""
  $gatilho = New-ScheduledTaskTrigger -AtStartup
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
  $cfgTarefa = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries \`
                 -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

  Register-ScheduledTask -TaskName 'MonitorAgent' -Action $acao -Trigger $gatilho \`
    -Principal $principal -Settings $cfgTarefa -Description 'Agente de monitoramento de infraestrutura' | Out-Null

  Start-ScheduledTask -TaskName 'MonitorAgent'
  Ok 'tarefa agendada criada (roda como SYSTEM, volta apos reiniciar)'
  Info 'como SYSTEM elevado, temperatura e SMART tambem sao coletados'
} else {
  if ($ComTarefa -and -not $ehAdmin) {
    Write-Host '   -ComTarefa exige terminal ELEVADO; subindo apenas nesta sessao' -ForegroundColor Yellow
  }

  # Caminho ENTRE ASPAS: Start-Process junta os argumentos sem citar, e
  # %ProgramData% pode conter espaco.
  $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden \`
            -RedirectStandardOutput (Join-Path $dirDados 'agente.out.log') \`
            -RedirectStandardError  (Join-Path $dirDados 'agente.err.log') \`
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "\`"$agentePath\`"")

  $proc.Id | Out-File -FilePath $pidFile -Encoding ascii
  Start-Sleep -Seconds 4

  if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) {
    Ok "agente no ar (PID $($proc.Id))"
  } else {
    Write-Host '   o agente morreu ao iniciar:' -ForegroundColor Red
    Get-Content (Join-Path $dirDados 'agente.err.log') -Tail 10 -ErrorAction SilentlyContinue |
      ForEach-Object { Write-Host "     $_" -ForegroundColor Red }
    return
  }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host " $env:COMPUTERNAME ESTA SENDO MONITORADA" -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
Write-Host "  Log   : $dirDados\\agente.out.log"
Write-Host "  Parar : & ([scriptblock]::Create((irm '$Servidor/instalar.ps1'))) -Servidor '$Servidor' -Token x -Segredo x -Parar"
if (-not $ComTarefa) {
  Write-Host ''
  Write-Host '  O agente NAO volta sozinho apos reiniciar o Windows.' -ForegroundColor Yellow
  Write-Host '  Para isso, rode o mesmo comando com -ComTarefa num terminal ELEVADO.' -ForegroundColor Yellow
}
Write-Host '============================================================' -ForegroundColor Green
Write-Host ''
`;

export const ATUALIZAR_PS1: string = `<#
.SYNOPSIS
  Atualiza o agente DESTA maquina para a versao mais nova, mantendo o token.

.DESCRIPTION
  A auto-atualizacao ainda nao existe (Fase 6). Ate la, um agente instalado nao
  se atualiza sozinho — e a diferenca entre versoes importa:

    ps-1.1.0  nao executa comando nenhum
    ps-1.2.0  executa comandos, mas nao reporta o MAC (nao da para ligar)
    ps-1.3.0  reporta o MAC e sabe suspender

  Reinstalar do zero funcionaria, mas gera um TOKEN NOVO e deixa o antigo
  pendurado. Este script troca so o codigo: o config.json, o token e o historico
  da maquina ficam como estao.

  Ele nao inventa o endereco: le do proprio config.json. Uma maquina que ja
  reporta sabe de onde baixar.

.PARAMETER Config
  Caminho do config.json. Padrao: %ProgramData%\\MonitorAgent\\config.json

.EXAMPLE
  # Na maquina a ser atualizada, como Administrador:
  .\\atualizar-agente.ps1
#>
[CmdletBinding()]
param(
  [string] $Config = (Join-Path $env:ProgramData 'MonitorAgent\\config.json')
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# =============================================================================
# POR QUE O CORPO INTEIRO E UMA FUNCAO
# =============================================================================
# Este script e feito para ser executado de uma linha so:
#
#   & ([scriptblock]::Create((irm 'https://.../atualizar.ps1')))
#
# E nesse modo a instrucao de saida NAO encerra o script: encerra a SESSAO do
# PowerShell. A janela simplesmente fecha, antes de a pessoa ler o que
# aconteceu — inclusive quando tudo deu certo. Foi o que aconteceu na primeira
# versao: o comando rodava, a janela sumia, e nao havia como saber o resultado.
#
# Com o corpo dentro de uma funcao, \`return\` sai apenas da funcao. O codigo de
# saida so vira encerramento de processo la embaixo, e SO quando o script veio
# de um arquivo (-File), onde isso e o comportamento certo.
# =============================================================================
function Invoke-AtualizacaoDoAgente {
  param([string] $Config)

  $ErrorActionPreference = 'Stop'
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

  foreach ($nome in @('Tls12', 'Tls13')) {
    try {
      $v = [Enum]::Parse([Net.SecurityProtocolType], $nome)
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $v
    } catch { }
  }

  if (-not (Test-Path $Config)) {
    Write-Host "config.json nao encontrado em $Config" -ForegroundColor Red
    Write-Host 'Esta maquina nao tem o agente instalado. Use o comando de "Adicionar PC" do painel.' -ForegroundColor Yellow
    return 1
  }

  $cfg = Get-Content $Config -Raw | ConvertFrom-Json
  $dir = Split-Path -Parent $Config

  # QUAL arquivo o agente roda de verdade.
  #
  # Isto foi um defeito na primeira versao: eu chutei 'agente.ps1', mas o
  # instalador grava 'agente-powershell.ps1'. O script baixava, gravava, dizia
  # "atualizado para ps-1.3.0" — e criava um arquivo que NADA executa. O agente
  # real continuava na versao antiga, e a unica pista era o painel insistindo na
  # versao velha.
  #
  # A correcao nao e trocar um nome chutado por outro: e PERGUNTAR a tarefa
  # agendada qual caminho ela executa. Se um dia o instalador mudar o nome de
  # novo, isto continua certo.
  $alvo = $null
  try {
    $acao = (Get-ScheduledTask -TaskName 'MonitorAgent' -ErrorAction Stop).Actions |
              Select-Object -First 1
    if ($acao.Arguments -match '-File\\s+"?([^"]+\\.ps1)"?') {
      $alvo = $Matches[1]
    }
  } catch { }

  if (-not $alvo) {
    # Sem tarefa agendada (instalacao em primeiro plano): o instalador tambem usa
    # este nome. Nao inventa um terceiro.
    $alvo = Join-Path $dir 'agente-powershell.ps1'
  }

  if (-not (Test-Path $alvo)) {
    Write-Host "nao encontrei o agente em $alvo" -ForegroundColor Red
    Write-Host 'Arquivos .ps1 nesta pasta:' -ForegroundColor Yellow
    Get-ChildItem $dir -Filter *.ps1 | ForEach-Object { Write-Host "  $($_.Name)" }
    return 1
  }

  # O endereco da ingestao ja aponta para quem serve o agente: em producao a
  # propria Edge Function, na LAN o shim local. \`/ingest\` no fim vira \`/agente.ps1\`
  # no mesmo prefixo.
  # SEM remover nada do endereco. Os scripts sao servidos POR DENTRO da funcao
  # de ingestao — o instalador sempre fez "$Servidor/agente.ps1" — entao o certo
  # e acrescentar ao endereco inteiro:
  #
  #   producao: https://xxx.supabase.co/functions/v1/ingest  + /agente.ps1
  #   LAN:      http://192.168.0.10:3010                     + /agente.ps1
  #
  # A primeira versao tirava o "/ingest" do fim, e ai producao virava
  # .../functions/v1/agente.ps1 -> 404. Passou no teste local porque o endereco
  # da LAN nao tem esse sufixo: o caso quebrado era justamente o que nao era
  # testado.
  $url = $cfg.ingestUrl.TrimEnd('/') + '/agente.ps1'

  Write-Host ''
  Write-Host "Baixando de $url" -ForegroundColor Cyan

  try {
    $novo = Invoke-RestMethod -Uri $url -TimeoutSec 30
  } catch {
    Write-Host "falhou: $($_.Exception.Message)" -ForegroundColor Red
    return 1
  }

  if ([string]::IsNullOrWhiteSpace($novo) -or $novo.Length -lt 5000) {
    # Um proxy de hotel devolvendo pagina de login tem 200 e corpo curto. Gravar
    # isso por cima do agente derrubaria o monitoramento da loja.
    Write-Host "o que voltou nao parece o agente ($($novo.Length) bytes)" -ForegroundColor Red
    return 1
  }

  if ($novo -notmatch '\\$VERSAO\\s*=\\s*''(ps-[0-9.]+)''') {
    Write-Host 'o que voltou nao tem versao reconhecivel; nada foi alterado' -ForegroundColor Red
    return 1
  }
  $versaoNova = $Matches[1]

  $versaoAtual = 'nenhuma'
  if (Test-Path $alvo) {
    $atual = Get-Content $alvo -Raw
    if ($atual -match '\\$VERSAO\\s*=\\s*''(ps-[0-9.]+)''') { $versaoAtual = $Matches[1] }
  }

  Write-Host "atual: $versaoAtual  ->  nova: $versaoNova" -ForegroundColor Cyan

  if ($versaoAtual -eq $versaoNova) {
    Write-Host 'ja esta na versao mais nova. Nada a fazer.' -ForegroundColor Green
    return 0
  }

  # BOM obrigatorio: o PowerShell 5.1 le .ps1 SEM BOM como ANSI, e ai um acento
  # vira caractere que quebra a analise sintatica. Vale para arquivo em DISCO —
  # servido por HTTP para [scriptblock]::Create seria o contrario.
  [IO.File]::WriteAllText($alvo, $novo, [Text.UTF8Encoding]::new($true))
  Write-Host "gravado em $alvo" -ForegroundColor Green

  # Reinicia a tarefa. Sem isto, o processo antigo continua rodando com o codigo
  # antigo em memoria ate a maquina reiniciar, e a atualizacao parece nao ter
  # funcionado.
  # Duas formas de instalacao, e as duas precisam ser tratadas: tarefa agendada
  # (o padrao) e processo em primeiro plano com um .pid (o caminho sem permissao
  # de administrador). Reiniciar so uma delas deixaria o processo velho vivo com o
  # codigo velho em memoria, e a atualizacao pareceria nao ter funcionado.
  $reiniciou = $false

  try {
    Get-ScheduledTask -TaskName 'MonitorAgent' -ErrorAction Stop | Out-Null
    Stop-ScheduledTask -TaskName 'MonitorAgent' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-ScheduledTask -TaskName 'MonitorAgent' -ErrorAction Stop
    Write-Host 'tarefa MonitorAgent reiniciada' -ForegroundColor Green
    $reiniciou = $true
  } catch { }

  $pidFile = Join-Path $dir 'agente.pid'
  if (-not $reiniciou -and (Test-Path $pidFile)) {
    try {
      $velho = [int](Get-Content $pidFile -Raw).Trim()
      Stop-Process -Id $velho -Force -ErrorAction SilentlyContinue
      Start-Sleep -Seconds 2

      $proc = Start-Process powershell.exe -PassThru -WindowStyle Hidden \`
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "\`"$alvo\`"")
      $proc.Id | Out-File -FilePath $pidFile -Encoding ascii
      Write-Host "agente reiniciado (pid $($proc.Id))" -ForegroundColor Green
      $reiniciou = $true
    } catch {
      Write-Host "nao consegui reiniciar o processo: $($_.Exception.Message)" -ForegroundColor Yellow
    }
  }

  if (-not $reiniciou) {
    Write-Host 'o arquivo foi trocado, mas o processo antigo continua rodando.' -ForegroundColor Yellow
    Write-Host 'Reinicie a maquina para a versao nova entrar em uso.' -ForegroundColor Yellow
  }

  Write-Host ''
  Write-Host "Agente atualizado para $versaoNova." -ForegroundColor Green
  Write-Host 'Em ate 2 min o painel deve mostrar a versao nova e o MAC da placa.' -ForegroundColor DarkGray
  Write-Host ''

}

$codigo = Invoke-AtualizacaoDoAgente -Config $Config
if ($null -eq $codigo) { $codigo = 0 }

# $PSCommandPath so tem valor quando isto veio de um ARQUIVO. Como scriptblock
# ele e vazio, e ai nao ha processo proprio para encerrar — terminar aqui
# fecharia a janela de quem colou o comando.
if (-not [string]::IsNullOrEmpty($PSCommandPath)) { exit $codigo }
`;
