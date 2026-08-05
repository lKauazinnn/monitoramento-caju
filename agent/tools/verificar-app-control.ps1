<#
.SYNOPSIS
  Verifica se Smart App Control / WDAC vai bloquear o MonitorAgent nesta máquina.

.DESCRIPTION
  RODE ISTO ANTES DE QUALQUER OUTRA COISA DA IMPLANTAÇÃO.

  O Smart App Control (SAC) do Windows 11 bloqueia binário sem assinatura
  reputável, em QUALQUER caminho. Ele vem LIGADO por padrão em instalação limpa
  de Windows 11 e permanece DESLIGADO em máquinas que foram atualizadas do
  Windows 10.

  Consequência para este projeto: numa máquina com SAC em imposição, o
  MonitorAgent não executa — o serviço "instala" e falha ao iniciar com
  0x800711C7. Nenhuma quantidade de permissão de pasta resolve.

  Detalhe cruel: SAC só pode ser DESLIGADO. Não existe caminho de volta para
  ligado sem redefinir o Windows. Portanto desligar em massa é decisão de
  segurança irreversível, não um ajuste.

  Este script classifica a máquina em uma de três situações e diz o que fazer.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\agent\tools\verificar-app-control.ps1

.EXAMPLE
  # Levantamento do parque via WinRM (precisa de acesso remoto às máquinas)
  Invoke-Command -ComputerName PDV01,PDV02,SRV01 -FilePath .\agent\tools\verificar-app-control.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$resultado = [ordered]@{
  Maquina          = $env:COMPUTERNAME
  Windows          = $null
  Build            = $null
  SacEstado        = 'desconhecido'
  SacBloqueia      = $null
  WdacStatus       = $null
  WdacBloqueia     = $null
  Veredito         = $null
  Acao             = $null
}

try {
  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
  $resultado.Windows = $os.Caption
  $resultado.Build = $os.Version
} catch {
  $resultado.Windows = "erro: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# Smart App Control
# ---------------------------------------------------------------------------
# VerifiedAndReputablePolicyState: 0 = desligado, 1 = imposição, 2 = avaliação.
# Chave ausente significa que a máquina é anterior ao SAC (Windows 10) ou que a
# funcionalidade nunca foi inicializada — nos dois casos, não bloqueia.
$sac = $null
try {
  $sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' `
            -Name VerifiedAndReputablePolicyState -ErrorAction Stop).VerifiedAndReputablePolicyState
} catch {
  $sac = $null
}

switch ($sac) {
  0       { $resultado.SacEstado = 'desligado';  $resultado.SacBloqueia = $false }
  1       { $resultado.SacEstado = 'IMPOSICAO';  $resultado.SacBloqueia = $true  }
  2       { $resultado.SacEstado = 'avaliacao';  $resultado.SacBloqueia = $false }
  $null   { $resultado.SacEstado = 'ausente';    $resultado.SacBloqueia = $false }
  default { $resultado.SacEstado = "valor $sac"; $resultado.SacBloqueia = $true  }
}

# ---------------------------------------------------------------------------
# WDAC / Device Guard
# ---------------------------------------------------------------------------
# CodeIntegrityPolicyEnforcementStatus: 0 = nenhuma, 1 = modo auditoria,
# 2 = imposição. Imposição com política da organização pode bloquear tanto
# quanto o SAC — mas, diferente dele, a TI PODE liberar por assinatura ou hash.
try {
  $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' `
          -ClassName Win32_DeviceGuard -ErrorAction Stop
  $resultado.WdacStatus = $dg.CodeIntegrityPolicyEnforcementStatus
  $resultado.WdacBloqueia = ($dg.CodeIntegrityPolicyEnforcementStatus -eq 2)
} catch {
  $resultado.WdacStatus = 'indisponivel'
  $resultado.WdacBloqueia = $false
}

# ---------------------------------------------------------------------------
# Veredito
# ---------------------------------------------------------------------------
if ($resultado.SacBloqueia) {
  $resultado.Veredito = 'BLOQUEADO por Smart App Control'
  $resultado.Acao = 'Exige binario com assinatura REPUTAVEL (cert EV). Desligar SAC e IRREVERSIVEL.'
} elseif ($resultado.WdacBloqueia) {
  $resultado.Veredito = 'PROVAVELMENTE BLOQUEADO por WDAC'
  $resultado.Acao = 'Liberar por assinatura ou hash na politica WDAC da organizacao.'
} else {
  $resultado.Veredito = 'LIVRE'
  $resultado.Acao = 'O agente pode rodar sem assinatura. Assinar continua sendo recomendavel.'
}

# ---------------------------------------------------------------------------
# Saída
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 70)
Write-Host " Controle de Aplicativo — $($resultado.Maquina)"
Write-Host ('=' * 70)
Write-Host (" Windows            : {0} ({1})" -f $resultado.Windows, $resultado.Build)
Write-Host (" Smart App Control  : {0}" -f $resultado.SacEstado)
Write-Host (" WDAC (Device Guard): {0}" -f $resultado.WdacStatus)
Write-Host ('-' * 70)

$cor = if ($resultado.SacBloqueia -or $resultado.WdacBloqueia) { 'Red' } else { 'Green' }
Write-Host (" {0}" -f $resultado.Veredito) -ForegroundColor $cor
Write-Host (" {0}" -f $resultado.Acao) -ForegroundColor DarkGray
Write-Host ('=' * 70)

if ($resultado.SacBloqueia) {
  Write-Host ''
  Write-Host ' O QUE ISSO SIGNIFICA' -ForegroundColor Yellow
  Write-Host ''
  Write-Host ' Nesta maquina, o MonitorAgent NAO vai executar sem assinatura'
  Write-Host ' reputavel. O sintoma sera: o servico instala e falha ao iniciar,'
  Write-Host ' com FileLoadException 0x800711C7.'
  Write-Host ''
  Write-Host ' Opcoes, da melhor para a pior:'
  Write-Host ''
  Write-Host '  1. Certificado de assinatura de codigo EV (DigiCert, Sectigo).'
  Write-Host '     Ganha reputacao imediata no SAC/SmartScreen. Custa por ano,'
  Write-Host '     mas resolve o parque inteiro e serve para qualquer software'
  Write-Host '     interno futuro. E a resposta certa para dezenas de lojas.'
  Write-Host ''
  Write-Host '  2. Politica WDAC da organizacao liberando por assinatura ou hash.'
  Write-Host '     Gratuito, distribuivel por GPO/Intune. Exige manter a politica'
  Write-Host '     e regerar a regra a cada nova versao do agente (se por hash).'
  Write-Host ''
  Write-Host '  3. Desligar o SAC nas maquinas monitoradas.'
  Write-Host '     ATENCAO: IRREVERSIVEL. Voltar a ligar exige redefinir o Windows.'
  Write-Host '     Reduz a protecao da maquina de forma permanente. So considere'
  Write-Host '     com decisao formal de seguranca.'
  Write-Host ''
  Write-Host ' Antes de escolher, MEÇA: rode este script em varias lojas. Se o SAC'
  Write-Host ' estiver desligado na maioria (comum em maquinas que vieram do'
  Write-Host ' Windows 10), o problema pode ser pequeno.'
  Write-Host ''
}

# Objeto para o pipeline: permite consolidar o levantamento do parque com
# Invoke-Command ... | Export-Csv
[pscustomobject]$resultado

# Código de saída explícito para automação: 0 = a máquina pode rodar o agente.
if ($resultado.SacBloqueia -or $resultado.WdacBloqueia) { exit 1 }
exit 0
