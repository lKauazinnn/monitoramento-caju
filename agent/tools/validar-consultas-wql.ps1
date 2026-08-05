<#
.SYNOPSIS
  Valida, contra o Windows real, TODAS as consultas WQL que os coletores do
  MonitorAgent emitem.

.DESCRIPTION
  Existe porque provar que a coleta funciona não depende de executar o agente:
  o que pode dar errado numa máquina específica é a CONSULTA — classe ausente,
  propriedade que não existe, acesso negado, valor localizado.

  Este script emite as consultas literalmente iguais às do código C# e confere
  se as propriedades esperadas voltam com o tipo esperado. Roda em qualquer
  máquina do parque sem instalar nada, o que também o torna a ferramenta de
  triagem para "por que esse PDV não reporta temperatura".

  Rode ELEVADO para cobrir temperatura e SMART.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\agent\tools\validar-consultas-wql.ps1
#>
[CmdletBinding()]
param(
  [string[]] $CriticalServices = @('Spooler')
)

$ErrorActionPreference = 'Continue'

# `powershell -File script.ps1 -CriticalServices A,B` entrega UMA string "A,B",
# não um array — diferente de invocar o script com o operador &. Normalizar aqui
# faz a ferramenta funcionar igual nas duas formas, o que importa porque quem vai
# rodar isto é o técnico de plantão copiando um comando do runbook.
$CriticalServices = @(
  $CriticalServices |
    ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ }
)

if ($CriticalServices.Count -eq 0) { $CriticalServices = @('Spooler') }

$elevado = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ''
Write-Host ('=' * 74)
Write-Host " Validacao das consultas WQL do MonitorAgent"
Write-Host ('=' * 74)
Write-Host (" Windows  : {0}" -f (Get-CimInstance Win32_OperatingSystem).Caption)
Write-Host (" Cultura  : {0} / UI {1}" -f (Get-Culture).Name, (Get-UICulture).Name)
Write-Host (" Elevado  : {0}" -f $(if ($elevado) { 'sim' } else { 'NAO - temperatura e SMART vao falhar' }))
Write-Host ('=' * 74)

$script:ok = 0
$script:aviso = 0
$script:erro = 0

function Test-Wql {
  param(
    [string]   $Nome,
    [string]   $Namespace,
    [string]   $Query,
    [string[]] $PropriedadesEsperadas,
    [switch]   $ToleraAusencia,
    [switch]   $ExigeElevacao
  )

  Write-Host ''
  Write-Host "-- $Nome" -ForegroundColor Cyan
  Write-Host "   $Namespace : $Query" -ForegroundColor DarkGray

  try {
    $r = @(Get-CimInstance -Namespace $Namespace -Query $Query -ErrorAction Stop)
  } catch {
    $msg = $_.Exception.Message
    $negado = $msg -match 'negad|denied'

    if ($ExigeElevacao -and -not $elevado -and $negado) {
      Write-Host "   ESPERADO sem elevacao: $msg" -ForegroundColor Yellow
      $script:aviso++
    } elseif ($ToleraAusencia) {
      Write-Host "   ausente/indisponivel (tolerado): $msg" -ForegroundColor Yellow
      $script:aviso++
    } else {
      Write-Host "   ERRO: $msg" -ForegroundColor Red
      $script:erro++
    }
    return
  }

  if ($r.Count -eq 0) {
    if ($ToleraAusencia) {
      Write-Host '   0 instancias (tolerado)' -ForegroundColor Yellow
      $script:aviso++
    } else {
      Write-Host '   ERRO: 0 instancias retornadas' -ForegroundColor Red
      $script:erro++
    }
    return
  }

  Write-Host ("   {0} instancia(s)" -f $r.Count) -ForegroundColor Green

  $faltando = @()
  foreach ($p in $PropriedadesEsperadas) {
    if ($null -eq $r[0].PSObject.Properties[$p]) { $faltando += $p }
  }

  if ($faltando.Count -gt 0) {
    Write-Host ("   ERRO: propriedades ausentes na classe: {0}" -f ($faltando -join ', ')) -ForegroundColor Red
    $script:erro++
    return
  }

  foreach ($p in $PropriedadesEsperadas) {
    $v = $r[0].$p
    $tipo = if ($null -eq $v) { 'null' } else { $v.GetType().Name }
    Write-Host ("     {0,-26} = {1,-34} [{2}]" -f $p, $(if ($null -eq $v) { '(null)' } else { $v }), $tipo)
  }

  $script:ok++
}

# ---------------------------------------------------------------------------
# SystemCollector
# ---------------------------------------------------------------------------
Test-Wql -Nome 'CPU formatada (principal)' -Namespace 'root/cimv2' `
  -Query "SELECT Name, PercentProcessorTime FROM Win32_PerfFormattedData_PerfOS_Processor WHERE Name = '_Total'" `
  -PropriedadesEsperadas @('Name', 'PercentProcessorTime')

Test-Wql -Nome 'CPU bruta (fallback)' -Namespace 'root/cimv2' `
  -Query "SELECT Name, PercentProcessorTime, Timestamp_Sys100NS FROM Win32_PerfRawData_PerfOS_Processor WHERE Name = '_Total'" `
  -PropriedadesEsperadas @('Name', 'PercentProcessorTime', 'Timestamp_Sys100NS')

Test-Wql -Nome 'Contadores de sistema (fila, processos, uptime)' -Namespace 'root/cimv2' `
  -Query 'SELECT ProcessorQueueLength, Processes, Threads, SystemUpTime FROM Win32_PerfFormattedData_PerfOS_System' `
  -PropriedadesEsperadas @('ProcessorQueueLength', 'Processes', 'Threads', 'SystemUpTime')

Test-Wql -Nome 'Memoria' -Namespace 'root/cimv2' `
  -Query 'SELECT TotalVisibleMemorySize, FreePhysicalMemory FROM Win32_OperatingSystem' `
  -PropriedadesEsperadas @('TotalVisibleMemorySize', 'FreePhysicalMemory')

Test-Wql -Nome 'Page file' -Namespace 'root/cimv2' `
  -Query 'SELECT CurrentUsage FROM Win32_PageFileUsage' `
  -PropriedadesEsperadas @('CurrentUsage') -ToleraAusencia

Test-Wql -Nome 'Boot (fallback de uptime)' -Namespace 'root/cimv2' `
  -Query 'SELECT LastBootUpTime FROM Win32_OperatingSystem' `
  -PropriedadesEsperadas @('LastBootUpTime')

Test-Wql -Nome 'Metadados do SO' -Namespace 'root/cimv2' `
  -Query 'SELECT Caption, Version, OSArchitecture, TotalVisibleMemorySize FROM Win32_OperatingSystem' `
  -PropriedadesEsperadas @('Caption', 'Version', 'OSArchitecture')

Test-Wql -Nome 'Processador' -Namespace 'root/cimv2' `
  -Query 'SELECT Name, NumberOfCores FROM Win32_Processor' `
  -PropriedadesEsperadas @('Name', 'NumberOfCores')

# ---------------------------------------------------------------------------
# DiskCollector
# ---------------------------------------------------------------------------
Test-Wql -Nome 'Volumes fixos' -Namespace 'root/cimv2' `
  -Query 'SELECT DeviceID, VolumeName, FileSystem, Size, FreeSpace FROM Win32_LogicalDisk WHERE DriveType = 3' `
  -PropriedadesEsperadas @('DeviceID', 'VolumeName', 'FileSystem', 'Size', 'FreeSpace')

Test-Wql -Nome 'Discos fisicos (funciona sem elevacao)' -Namespace 'root/microsoft/windows/storage' `
  -Query 'SELECT FriendlyName, MediaType, HealthStatus FROM MSFT_PhysicalDisk' `
  -PropriedadesEsperadas @('FriendlyName', 'MediaType', 'HealthStatus') -ToleraAusencia

Test-Wql -Nome 'Contadores de confiabilidade (desgaste, horas)' -Namespace 'root/microsoft/windows/storage' `
  -Query 'SELECT DeviceId, Wear, PowerOnHours, ReadErrorsUncorrected FROM MSFT_StorageReliabilityCounter' `
  -PropriedadesEsperadas @('Wear', 'PowerOnHours') -ToleraAusencia -ExigeElevacao

Test-Wql -Nome 'SMART - predicao de falha' -Namespace 'root/wmi' `
  -Query 'SELECT InstanceName, PredictFailure FROM MSStorageDriver_FailurePredictStatus' `
  -PropriedadesEsperadas @('InstanceName', 'PredictFailure') -ToleraAusencia -ExigeElevacao

# ---------------------------------------------------------------------------
# ServiceCollector
# ---------------------------------------------------------------------------
$filtro = ($CriticalServices | ForEach-Object { "Name = '$($_ -replace "'", "\'")'" }) -join ' OR '
Test-Wql -Nome "Servicos criticos ($($CriticalServices -join ', '))" -Namespace 'root/cimv2' `
  -Query "SELECT Name, State, Started, StartMode, ProcessId FROM Win32_Service WHERE $filtro" `
  -PropriedadesEsperadas @('Name', 'State', 'Started', 'StartMode', 'ProcessId')

# ---------------------------------------------------------------------------
# TemperatureCollector
# ---------------------------------------------------------------------------
Test-Wql -Nome 'Temperatura (zona termica ACPI)' -Namespace 'root/wmi' `
  -Query 'SELECT InstanceName, CurrentTemperature FROM MSAcpi_ThermalZoneTemperature' `
  -PropriedadesEsperadas @('InstanceName', 'CurrentTemperature') -ToleraAusencia -ExigeElevacao

# ---------------------------------------------------------------------------
# Verificacoes de LOGICA que nao dependem de executar o agente
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '-- Formula do fallback de CPU (delta de contador bruto)' -ForegroundColor Cyan
Write-Host '   PercentProcessorTime bruto e PERF_100NSEC_TIMER_INV: acumula tempo OCIOSO.' -ForegroundColor DarkGray
Write-Host '   ocupado% = 100 * (1 - dContador / dTimestamp)' -ForegroundColor DarkGray

$q = "SELECT Name, PercentProcessorTime, Timestamp_Sys100NS FROM Win32_PerfRawData_PerfOS_Processor WHERE Name = '_Total'"
$a = Get-CimInstance -Namespace 'root/cimv2' -Query $q
Start-Sleep -Milliseconds 1500
$b = Get-CimInstance -Namespace 'root/cimv2' -Query $q

$dc = [double]$b.PercentProcessorTime - [double]$a.PercentProcessorTime
$dt = [double]$b.Timestamp_Sys100NS   - [double]$a.Timestamp_Sys100NS

if ($dt -le 0) {
  Write-Host '   ERRO: delta de timestamp nao positivo' -ForegroundColor Red
  $script:erro++
} else {
  $ocupado = 100.0 * (1.0 - ($dc / $dt))
  $formatado = (Get-CimInstance -Namespace 'root/cimv2' `
    -Query "SELECT PercentProcessorTime FROM Win32_PerfFormattedData_PerfOS_Processor WHERE Name = '_Total'").PercentProcessorTime

  Write-Host ("   delta contador  = {0:N0}" -f $dc)
  Write-Host ("   delta timestamp = {0:N0}" -f $dt)
  Write-Host ("   ocupado (bruto) = {0:N2}%" -f $ocupado)
  Write-Host ("   ocupado (fmt)   = {0}%" -f $formatado)

  if ($ocupado -lt -1 -or $ocupado -gt 101) {
    Write-Host '   ERRO: formula devolveu valor fora de 0..100' -ForegroundColor Red
    $script:erro++
  } else {
    Write-Host '   OK: formula do fallback confere' -ForegroundColor Green
    $script:ok++
  }
}

Write-Host ''
Write-Host '-- Conversao de temperatura (decimos de Kelvin -> Celsius)' -ForegroundColor Cyan
$casos = @(
  @{ dK = 3032; C = 30.05 },
  @{ dK = 2982; C = 25.05 },
  @{ dK = 3732; C = 100.05 }
)
$falhouTemp = $false
foreach ($c in $casos) {
  $calc = [Math]::Round(($c.dK / 10.0) - 273.15, 2)
  $bate = [Math]::Abs($calc - $c.C) -lt 0.011
  Write-Host ("   {0} dK -> {1} C  (esperado {2})  {3}" -f $c.dK, $calc, $c.C, $(if ($bate) { 'ok' } else { 'FALHA' }))
  if (-not $bate) { $falhouTemp = $true }
}
if ($falhouTemp) { $script:erro++ } else { $script:ok++; Write-Host '   OK' -ForegroundColor Green }

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 74)
Write-Host (" OK: {0}   AVISOS: {1}   ERROS: {2}" -f $script:ok, $script:aviso, $script:erro)
Write-Host ('=' * 74)

if ($script:erro -gt 0) {
  Write-Host ' HA ERROS: alguma consulta que o agente depende nao funciona nesta maquina.' -ForegroundColor Red
  Write-Host ''
  exit 1
}

if ($script:aviso -gt 0) {
  Write-Host ' Avisos sao esperados: temperatura/SMART exigem elevacao, e muitos PDVs' -ForegroundColor Yellow
  Write-Host ' simplesmente nao tem zona termica ACPI. A coleta principal esta ok.' -ForegroundColor Yellow
}
Write-Host ''
exit 0
