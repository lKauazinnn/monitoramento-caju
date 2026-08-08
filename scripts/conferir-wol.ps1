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
# Aqui a resposta MUDA por fabricante, e a diferenca e grande: em maquina
# corporativa Dell/HP/Lenovo da para mexer no BIOS pelo Windows. Em placa avulsa
# (ASUS, Gigabyte, ASRock de varejo) nao existe essa interface — e nao adianta
# procurar, porque a configuracao so existe no firmware.
Write-Host ''
$cs = Get-CimInstance Win32_ComputerSystem
$fab = "$($cs.Manufacturer)".Trim()
$modelo = "$($cs.Model)".Trim()

Write-Host "       $fab / $modelo" -ForegroundColor DarkGray

$mexeuNoBios = $false

# ---- Lenovo: interface WMI nativa, sem instalar nada -----------------------
$lenovo = $null
try {
  $lenovo = Get-CimInstance -Namespace root\wmi -ClassName Lenovo_SetBiosSetting -ErrorAction Stop
} catch { }

if ($lenovo) {
  Write-Host '  ok   BIOS controlavel por aqui (Lenovo, WMI nativa)' -ForegroundColor Green
  $atual = try {
    (Get-CimInstance -Namespace root\wmi -ClassName Lenovo_BiosSetting -ErrorAction Stop |
      Where-Object { $_.CurrentSetting -like 'WakeOnLAN,*' }).CurrentSetting
  } catch { $null }
  Write-Host "       $atual" -ForegroundColor DarkGray

  if ($Corrigir) {
    try {
      Invoke-CimMethod -InputObject $lenovo -MethodName SetBiosSetting `
        -Arguments @{ parameter = 'WakeOnLAN,Primary' } -ErrorAction Stop | Out-Null
      Invoke-CimMethod -Namespace root\wmi -ClassName Lenovo_SaveBiosSettings `
        -MethodName SaveBiosSettings -Arguments @{ parameter = 'Save' } -ErrorAction Stop | Out-Null
      Write-Host '       WakeOnLAN ligado no BIOS' -ForegroundColor Green
      $mexeuNoBios = $true
    } catch {
      Write-Host "       nao consegui: $($_.Exception.Message)" -ForegroundColor Red
    }
  }
}

# ---- Dell: precisa do Dell Command | Configure -----------------------------
elseif ($fab -match 'Dell') {
  $cctk = Get-Command cctk.exe -ErrorAction SilentlyContinue
  if (-not $cctk) {
    $p = 'C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe'
    if (Test-Path $p) { $cctk = $p }
  } else { $cctk = $cctk.Source }

  if ($cctk) {
    Write-Host '  ok   BIOS controlavel por aqui (Dell Command | Configure)' -ForegroundColor Green
    if ($Corrigir) {
      try {
        & $cctk --wakeonlan=lanwlan | Out-Null
        Write-Host '       WakeOnLAN ligado no BIOS' -ForegroundColor Green
        $mexeuNoBios = $true
      } catch {
        Write-Host "       nao consegui: $($_.Exception.Message)" -ForegroundColor Red
      }
    }
  } else {
    Write-Host '  ??   BIOS: da para automatizar, mas falta a ferramenta' -ForegroundColor Yellow
    Write-Host '       Instale o "Dell Command | Configure" e rode este script de novo.' -ForegroundColor DarkGray
  }
}

# ---- HP: WMI proprio, presente nas linhas corporativas ---------------------
elseif ($fab -match 'HP|Hewlett') {
  $hp = $null
  try {
    $hp = Get-CimInstance -Namespace root\hp\instrumentedBIOS -ClassName HP_BIOSSettingInterface -ErrorAction Stop
  } catch { }

  if ($hp) {
    Write-Host '  ok   BIOS controlavel por aqui (HP, WMI)' -ForegroundColor Green
    if ($Corrigir) {
      try {
        # Senha vazia: so funciona se o BIOS nao tiver senha de setup definida.
        Invoke-CimMethod -InputObject $hp -MethodName SetBIOSSetting -Arguments @{
          Name = 'S5 Wake on LAN'; Value = 'Boot to Network'; Password = ''
        } -ErrorAction Stop | Out-Null
        Write-Host '       S5 Wake on LAN ligado no BIOS' -ForegroundColor Green
        $mexeuNoBios = $true
      } catch {
        Write-Host "       nao consegui (BIOS com senha?): $($_.Exception.Message)" -ForegroundColor Red
      }
    }
  } else {
    Write-Host '  ??   BIOS: instale o "HP BIOS Configuration Utility" para automatizar.' -ForegroundColor Yellow
  }
}

# ---- Placa avulsa: nao existe caminho por software -------------------------
else {
  Write-Host '  ??   Wake-on-LAN no BIOS/UEFI: SO NA MAO nesta maquina' -ForegroundColor Yellow
  Write-Host '       Placa de varejo nao expoe as opcoes de firmware ao Windows — nao' -ForegroundColor DarkGray
  Write-Host '       ha PowerShell nem CMD que resolva. Reinicie no setup e procure:' -ForegroundColor DarkGray
  Write-Host '         - "Power On By PCI-E/PCI"  ->  Enabled' -ForegroundColor DarkGray
  Write-Host '         - "ErP Ready" / "Deep Sleep"  ->  DISABLED' -ForegroundColor DarkGray
  Write-Host '       O ErP e o que mais engana: ele corta a energia de reserva da placa' -ForegroundColor DarkGray
  Write-Host '       com o PC desligado, e ai nada escuta o pacote.' -ForegroundColor DarkGray
  Write-Host ''
  Write-Host '       ANTES DE IR AO SETUP: teste. Muita maquina acorda sem mexer em' -ForegroundColor DarkGray
  Write-Host '       nada no BIOS, e ai voce economiza a viagem ate a loja.' -ForegroundColor DarkGray
  $avisos += 'Wake-on-LAN no BIOS (so na mao)'
}

if ($mexeuNoBios) {
  Write-Host '       (vale a partir do proximo desligamento)' -ForegroundColor DarkGray
}

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
