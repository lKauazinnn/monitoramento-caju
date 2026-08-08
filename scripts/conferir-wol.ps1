<#
.SYNOPSIS
  Confere se ESTA maquina pode ser ligada remotamente, e conserta o que da.

.DESCRIPTION
  Wake-on-LAN falha calado. Voce clica "Ligar o PC" no painel, o pacote sai, o
  vizinho relata sucesso — e a maquina nao liga. O comando fez a parte dele: o
  pacote SAIU. Quem nao respondeu foi a placa do alvo, e nada no painel sabe
  disso, porque WoL nao tem resposta.

  Entao a conferencia tem que acontecer ANTES de alguem prometer isso para a
  operacao. Rode este script uma vez em cada PC que voce quer poder ligar.

  O QUE ELE CONFERE, do mais comum para o menos:

    1. Inicializacao Rapida (Fast Startup)
       O motivo numero um. Ela faz o "desligar" do Windows ser uma hibernacao
       disfarcada, e nesse estado a placa costuma nao acordar. E o unico item
       aqui que o script CONSERTA sozinho, com -Corrigir.

    2. A placa esta autorizada a acordar a maquina
       Duas chaves separadas no driver, e as duas precisam estar ligadas.
       Tambem corrigivel.

    3. E cabeada
       WoL por Wi-Fi depende do adaptador e do ponto de acesso, e na pratica
       quase nunca funciona.

    4. BIOS/UEFI
       NAO da para conferir por software de forma confiavel, e nao da para
       corrigir. O script diz onde olhar. Se estiver desligado la, nada do resto
       importa.

.PARAMETER Corrigir
  Aplica o que da para aplicar. Sem isto, o script so relata.
  Exige terminal como Administrador.

.EXAMPLE
  .\scripts\conferir-wol.ps1

.EXAMPLE
  .\scripts\conferir-wol.ps1 -Corrigir
#>
[CmdletBinding()]
param([switch] $Corrigir)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$admin = ([Security.Principal.WindowsPrincipal] `
          [Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($Corrigir -and -not $admin) {
  Write-Host 'Para corrigir, abra o PowerShell como Administrador.' -ForegroundColor Red
  exit 2
}

$problemas = @()
$avisos = @()

function Item {
  param([string] $Nome, [bool] $Ok, [string] $Detalhe, [switch] $Aviso)
  $cor = if ($Ok) { 'Green' } elseif ($Aviso) { 'Yellow' } else { 'Red' }
  $marca = if ($Ok) { '  ok  ' } elseif ($Aviso) { '  ??  ' } else { ' FALTA' }
  Write-Host "$marca $Nome" -ForegroundColor $cor
  if ($Detalhe) { Write-Host "       $Detalhe" -ForegroundColor DarkGray }
  if (-not $Ok) {
    if ($Aviso) { $script:avisos += $Nome } else { $script:problemas += $Nome }
  }
}

Write-Host ''
Write-Host "Wake-on-LAN em $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host ('-' * 60)

# ---------------------------------------------------------------- 1. a placa
$ad = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' -and $_.MediaType -ne 'Native 802.11' } |
        Sort-Object -Property @{ Expression = { $_.LinkSpeed } } -Descending |
        Select-Object -First 1

if (-not $ad) {
  Item 'Placa de rede cabeada ativa' $false `
    'Sem adaptador cabeado ligado. WoL por Wi-Fi quase nunca funciona: esta maquina nao podera ser ligada remotamente.'
  Write-Host ''
  Write-Host 'Sem placa cabeada nao ha o que configurar.' -ForegroundColor Red
  exit 1
}

Item 'Placa de rede cabeada ativa' $true "$($ad.Name) - $($ad.InterfaceDescription) - MAC $($ad.MacAddress)"

# ------------------------------------------------- 2. autorizada a acordar
# Duas chaves diferentes, e as duas precisam estar ligadas. Uma so nao basta, e
# e por isso que "eu marquei a caixa e nao funcionou" e tao comum.
$pm = Get-NetAdapterPowerManagement -Name $ad.Name -ErrorAction SilentlyContinue

if ($pm) {
  $podeAcordar = $pm.WakeOnMagicPacket -eq 'Enabled'
  $naoDesliga  = $pm.DeviceSleepOnDisconnect -ne 'Enabled'

  Item 'Acordar com pacote magico' $podeAcordar `
    "WakeOnMagicPacket = $($pm.WakeOnMagicPacket)"

  if ($Corrigir -and -not $podeAcordar) {
    try {
      Set-NetAdapterPowerManagement -Name $ad.Name -WakeOnMagicPacket Enabled -ErrorAction Stop
      Write-Host '       corrigido' -ForegroundColor Green
      $problemas = $problemas | Where-Object { $_ -ne 'Acordar com pacote magico' }
    } catch {
      Write-Host "       nao consegui corrigir: $($_.Exception.Message)" -ForegroundColor Red
    }
  }

  Item 'A placa nao se desliga sozinha' $naoDesliga `
    "DeviceSleepOnDisconnect = $($pm.DeviceSleepOnDisconnect)" -Aviso:$true
} else {
  Item 'Configuracao de energia da placa' $false `
    'O driver nao expoe as opcoes de energia. Confira em Gerenciador de Dispositivos > a placa > Gerenciamento de Energia.' -Aviso:$true
}

# `AllowComputerToWakeDevice` fica em outra chave e alguns drivers so respeitam
# esta. Ler as duas evita o falso "esta tudo certo".
try {
  $pnp = Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceWakeEnable -ErrorAction Stop |
           Where-Object { $_.InstanceName -like "*$($ad.PnPDeviceID.Split('\')[-1])*" } |
           Select-Object -First 1
  if ($pnp) {
    Item 'Dispositivo autorizado a acordar o computador' ([bool]$pnp.Enable) `
      "MSPower_DeviceWakeEnable = $($pnp.Enable)"

    if ($Corrigir -and -not $pnp.Enable) {
      Set-CimInstance -InputObject $pnp -Property @{ Enable = $true } -ErrorAction Stop
      Write-Host '       corrigido' -ForegroundColor Green
      $problemas = $problemas | Where-Object { $_ -ne 'Dispositivo autorizado a acordar o computador' }
    }
  }
} catch { }

# ------------------------------------------- 3. Inicializacao Rapida: A causa
$fast = $null
try {
  $fast = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
             -Name HiberbootEnabled -ErrorAction Stop).HiberbootEnabled
} catch { }

# Ausente conta como LIGADA: e o padrao do Windows quando a hibernacao existe.
$fastLigada = ($null -eq $fast) -or ($fast -eq 1)

Item 'Inicializacao Rapida DESLIGADA' (-not $fastLigada) `
  $(if ($fastLigada) {
      'Esta e a causa numero um de WoL nao funcionar: com ela ligada, "desligar" vira hibernacao disfarcada e a placa nao acorda.'
    } else { 'HiberbootEnabled = 0' })

if ($Corrigir -and $fastLigada) {
  try {
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
      -Name HiberbootEnabled -Value 0 -Type DWord -ErrorAction Stop
    Write-Host '       corrigido (vale a partir do proximo desligamento)' -ForegroundColor Green
    $problemas = $problemas | Where-Object { $_ -ne 'Inicializacao Rapida DESLIGADA' }
  } catch {
    Write-Host "       nao consegui corrigir: $($_.Exception.Message)" -ForegroundColor Red
  }
}

# ------------------------------------------------------------- 4. o BIOS
Write-Host ''
Write-Host '  ??   Wake-on-LAN no BIOS/UEFI' -ForegroundColor Yellow
Write-Host '       NAO da para conferir isto por software de forma confiavel, e nao' -ForegroundColor DarkGray
Write-Host '       da para corrigir daqui. Se estiver desligado la, nada do resto' -ForegroundColor DarkGray
Write-Host '       importa. Procure por "Wake on LAN", "Power On by PCI-E" ou' -ForegroundColor DarkGray
Write-Host '       "Resume by LAN" na secao de energia.' -ForegroundColor DarkGray

# ------------------------------------------------------------------ resumo
Write-Host ''
Write-Host ('-' * 60)

if ($problemas.Count -eq 0) {
  Write-Host 'Pronta para ser ligada remotamente, no que da para conferir daqui.' -ForegroundColor Green
  Write-Host 'Confirme o BIOS e teste de verdade: desligue e mande "Ligar o PC" pelo painel.' -ForegroundColor DarkGray
} else {
  Write-Host "Faltam $($problemas.Count) item(ns):" -ForegroundColor Red
  $problemas | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  if (-not $Corrigir) {
    Write-Host ''
    Write-Host 'Rode de novo com -Corrigir, como Administrador, para aplicar o que da.' -ForegroundColor Yellow
  }
}

if ($avisos.Count -gt 0) {
  Write-Host ''
  Write-Host 'Vale conferir a mao:' -ForegroundColor Yellow
  $avisos | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}

Write-Host ''
exit $(if ($problemas.Count -gt 0) { 1 } else { 0 })
