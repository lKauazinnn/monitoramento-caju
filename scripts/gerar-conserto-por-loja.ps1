<#
.SYNOPSIS
  Gera, por loja, o bloco pronto para colar que conserta as maquinas caidas.

.DESCRIPTION
  Digitar nome de maquina a mao e retrabalho e fonte de erro -- e erro de nome
  aqui custa caro: reprovisionar com rotulo diferente cria maquina DUPLICADA no
  painel. A lista de quem existe em cada loja e de quem esta fora ja esta no
  proprio painel, entao e de la que ela sai.

  Para cada loja com maquina fora, o script decide se ha PONTE -- uma maquina
  ainda viva naquela loja. Havendo, ele imprime um bloco autocontido para rodar
  NAQUELE servidor, com os nomes ja preenchidos. Nao havendo, a loja entra numa
  lista separada: sem ponte nao existe caminho remoto, e alguem precisa chegar
  nela de outro jeito.

  O bloco gerado nunca mexe em maquina saudavel, e para sozinho onde o
  config.json sumiu -- que e o unico caso que realmente precisa reprovisionar.

  SOMENTE LEITURA: consulta o painel e imprime texto. Nao altera producao.

.PARAMETER ChaveServiceRole
  service_role key. Tenta SUPABASE_SERVICE_ROLE_KEY e depois pergunta, escondida.

.PARAMETER Loja
  Gera so para esta loja. Sem isto, gera para todas as que tem maquina fora.

.PARAMETER UrlRest
  Endereco do PostgREST. Padrao: <SUPABASE_URL>/rest/v1 do .env.producao.

.EXAMPLE
  .\scripts\gerar-conserto-por-loja.ps1

.EXAMPLE
  .\scripts\gerar-conserto-por-loja.ps1 -Loja CAJU-ASN
#>
[CmdletBinding()]
param(
  [string] $ChaveServiceRole,
  [string] $Loja,
  [string] $UrlRest
)

$ErrorActionPreference = 'Stop'

foreach ($nome in @('Tls12', 'Tls13')) {
  try {
    $valor = [Enum]::Parse([Net.SecurityProtocolType], $nome)
    [Net.ServicePointManager]::SecurityProtocol =
      [Net.ServicePointManager]::SecurityProtocol -bor $valor
  } catch { }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$envProducao = Join-Path $repoRoot '.env.producao'

if (-not (Test-Path $envProducao)) {
  Write-Host '   .env.producao nao existe. Publique primeiro:' -ForegroundColor Red
  Write-Host '     .\scripts\publicar-supabase.ps1 -ProjetoRef SEU_REF' -ForegroundColor DarkGray
  exit 1
}

$cfg = @{}
Get-Content $envProducao | ForEach-Object {
  if ($_ -match '^\s*([A-Z_]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() }
}

if ([string]::IsNullOrWhiteSpace($ChaveServiceRole)) {
  $ChaveServiceRole = $env:SUPABASE_SERVICE_ROLE_KEY
}
# O .env.producao ja foi lido acima para pegar a SUPABASE_URL. Se a chave
# tambem estiver la, nao ha motivo para pedir de novo -- e uma pergunta a menos
# num processo que ja tem passo demais. Quando nao estiver, cai no prompt.
if ([string]::IsNullOrWhiteSpace($ChaveServiceRole)) {
  foreach ($k in @('SUPABASE_SERVICE_ROLE_KEY', 'SERVICE_ROLE_KEY')) {
    if ($cfg.ContainsKey($k) -and -not [string]::IsNullOrWhiteSpace($cfg[$k])) {
      $ChaveServiceRole = $cfg[$k]
      Write-Host "   chave lida do .env.producao ($k)" -ForegroundColor DarkGray
      break
    }
  }
}
if ([string]::IsNullOrWhiteSpace($ChaveServiceRole)) {
  Write-Host '   service_role key (Settings > API). Nao aparece na tela.' -ForegroundColor DarkGray
  $seguro = Read-Host -Prompt '   service_role key' -AsSecureString
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seguro)
  try { $ChaveServiceRole = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

if ([string]::IsNullOrWhiteSpace($UrlRest)) { $UrlRest = "$($cfg['SUPABASE_URL'])/rest/v1" }
$urlRest = $UrlRest.TrimEnd('/')
$cab = @{ apikey = $ChaveServiceRole; Authorization = "Bearer $ChaveServiceRole" }

# `hostname` e obrigatorio aqui, e nao detalhe: o alvo de \\MAQUINA\C$ e o nome
# de REDE, e rotulo do painel nao e nome de rede. Em producao ha rotulos como
# "CBO CAMINITO" e "CBO FOSTERS" -- com ESPACO, que hostname do Windows nao pode
# ter. Gerar o bloco a partir do rotulo produzia alvos que nunca resolveriam, e
# o operador leria "INALCANCAVEL" achando que a maquina estava desligada.
# O hostname e o que o proprio agente reporta, entao e o nome verdadeiro.
$campos = 'site_code,label,hostname,status,seconds_since_seen,agent_version'
$consulta = "$urlRest/machines_status?select=$campos&order=site_code,label"
if ($Loja) { $consulta += "&site_code=ilike.$([uri]::EscapeDataString($Loja))" }

try {
  $resposta = Invoke-RestMethod -Uri $consulta -Headers $cab -Method Get -TimeoutSec 30
} catch {
  Write-Host ''
  Write-Host "Falhou a consulta: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}

# O Invoke-RestMethod do PowerShell 5.1 pode devolver o array JSON como UM item
# que contem o array. Normaliza antes de contar qualquer coisa.
$maquinas = @()
foreach ($item in @($resposta)) {
  if ($item -is [System.Collections.IEnumerable] -and $item -isnot [string]) { $maquinas += $item }
  else { $maquinas += $item }
}

if ($maquinas.Count -eq 0) {
  Write-Host 'Nenhuma maquina voltou da consulta.' -ForegroundColor Yellow
  exit 0
}

$porLoja = $maquinas | Group-Object site_code | Sort-Object Name
$semPonte = @()
$comPonte = 0
$totalFora = 0

Write-Host ''
Write-Host '============================================================'
Write-Host ' CONSERTO POR LOJA'
Write-Host '============================================================'

foreach ($g in $porLoja) {
  $fora   = @($g.Group | Where-Object { $_.status -ne 'online' })
  $online = @($g.Group | Where-Object { $_.status -eq 'online' })
  if ($fora.Count -eq 0) { continue }
  $totalFora += $fora.Count

  if ($online.Count -eq 0) {
    $semPonte += [pscustomobject]@{ loja = $g.Name; fora = $fora.Count }
    continue
  }

  $comPonte++

  # Nome de REDE, com o rotulo so como ultimo recurso. Quando os dois diferem, o
  # aviso sai junto: quem opera precisa saber que "CBO FOSTERS" no painel e
  # outra coisa na rede, senao vai procurar a maquina errada.
  $semNome = @()
  $alvosNome = @()
  foreach ($f in $fora) {
    $n = $f.hostname
    if ([string]::IsNullOrWhiteSpace($n)) { $n = $f.label; $semNome += $f.label }
    $alvosNome += $n
  }
  $nomes = ($alvosNome | ForEach-Object { "'" + $_ + "'" }) -join ','

  Write-Host ''
  Write-Host ('--- ' + $g.Name + ' : ' + $fora.Count + ' fora, ' + $online.Count + ' viva(s) ---') -ForegroundColor Cyan
  Write-Host ('    ponte: ' + (($online | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace($_.hostname)) { $_.label } else { $_.hostname }
  }) -join ', ')) -ForegroundColor DarkGray

  $renomeadas = @($fora | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_.hostname) -and $_.hostname -ne $_.label })
  if ($renomeadas.Count -gt 0) {
    Write-Host '    rotulo no painel != nome na rede (usando o da rede):' -ForegroundColor DarkYellow
    foreach ($x in $renomeadas) {
      Write-Host ('      "' + $x.label + '" -> ' + $x.hostname) -ForegroundColor DarkGray
    }
  }
  if ($semNome.Count -gt 0) {
    Write-Host ('    SEM hostname reportado, usando o rotulo (pode nao resolver): ' +
                ($semNome -join ', ')) -ForegroundColor Yellow
  }
  Write-Host '    Entre NESSA maquina viva, abra o PowerShell como ADMINISTRADOR e cole:'
  Write-Host ''

  $bloco = @"
`$alvos = $nomes
foreach (`$m in `$alvos) {
  if (-not (Test-Path "\\`$m\C`$")) { "`$m : INALCANCAVEL"; continue }
  if (-not (Test-Path "\\`$m\C`$\ProgramData\MonitorAgent\config.json")) { "`$m : SEM CONFIG - nao mexa"; continue }
  try { `$s = New-CimSession -ComputerName `$m -SessionOption (New-CimSessionOption -Protocol Dcom) -OperationTimeoutSec 20 -ErrorAction Stop }
  catch { "`$m : SEM CIM"; continue }
  `$t = Get-ScheduledTask -TaskName MonitorAgent -CimSession `$s -ErrorAction SilentlyContinue
  if (`$t -and `$t.State -eq 'Running') { "`$m : ja saudavel"; Remove-CimSession `$s; continue }
  `$ag = 'C:\ProgramData\MonitorAgent\agente-powershell.ps1'
  `$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + `$ag + '"')
  `$cf = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
  Register-ScheduledTask -TaskName MonitorAgent -Action `$a -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest) -Settings `$cf -Force -CimSession `$s | Out-Null
  Start-ScheduledTask -TaskName MonitorAgent -CimSession `$s
  "`$m : CONSERTADA"
  Remove-CimSession `$s
}
"@
  Write-Host $bloco
}

if ($semPonte.Count -gt 0) {
  Write-Host ''
  Write-Host '--- LOJAS SEM PONTE (nenhuma maquina viva la) ---' -ForegroundColor Yellow
  Write-Host '    Nao ha caminho remoto: e preciso chegar nelas de outro jeito.'
  Write-Host '    Em cada uma, o conserto e o bloco de duas etapas do triagem-agente.ps1.'
  foreach ($s in $semPonte) {
    Write-Host ('      ' + $s.loja.PadRight(26) + $s.fora + ' fora')
  }
}

Write-Host ''
Write-Host ('Resumo: ' + $totalFora + ' maquina(s) fora. ' + $comPonte + ' loja(s) com ponte, ' + $semPonte.Count + ' sem.')
Write-Host ''
