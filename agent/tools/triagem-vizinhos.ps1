<#
.SYNOPSIS
  Triagem e conserto do agente nas OUTRAS maquinas da mesma loja, a partir de
  uma que ainda esta viva.

.DESCRIPTION
  O canal remoto do proprio sistema (a fila de comandos) nao serve aqui: ele
  chega pela resposta da telemetria, entao so alcanca maquina cujo agente esta
  VIVO -- exatamente o que as caidas nao tem. E `wake_machine` acorda o PC mas
  nao cria tarefa agendada, entao a maquina liga e continua muda.

  A saida e a mesma que a 0026 ja usa para Wake-on-LAN: o VIZINHO. Uma maquina
  viva da loja alcanca as outras pela rede local, onde nao ha NAT no meio.

  POR QUE DCOM E NAO WinRM: PC de loja quase nunca tem WinRM ligado, e ligar
  remotamente exigiria... WinRM. `New-CimSession -Protocol Dcom` usa o RPC que
  o Windows ja tem de pe. E a credencial vai como objeto PSCredential, nunca
  como texto em linha de comando -- `schtasks /U /P` colocaria a senha na lista
  de processos de todas as maquinas da loja.

  O QUE ELE CONSERTA: a tarefa agendada ausente. Os arquivos do agente
  (config.json e o script) precisam ja existir no alvo -- e existem, se a
  maquina ja reportou algum dia. Onde o config sumiu, o veredito diz, e ai o
  caminho e reprovisionar com a MESMA loja e o MESMO rotulo.

  SOMENTE LEITURA sem -Consertar.

.PARAMETER Maquinas
  Nomes das maquinas da loja. Pegue no painel ou no ver-producao.ps1. Nao ha
  varredura de rede aqui, de proposito: sondar a rede da loja e o tipo de coisa
  que acorda o antivirus e assusta o cliente.

.PARAMETER Credencial
  Conta com administrador local nos alvos. Sem isto usa a identidade de quem
  esta rodando, que ja basta em dominio.

.PARAMETER Consertar
  Cria a tarefa agendada que falta e inicia o agente.

.EXAMPLE
  .\triagem-vizinhos.ps1 -Maquinas KDS-PRINCIPAL,KDS-SUSHI-05,PARILLA-02

.EXAMPLE
  $c = Get-Credential
  .\triagem-vizinhos.ps1 -Maquinas KDS-PRINCIPAL,PARILLA-02 -Credencial $c -Consertar
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string[]] $Maquinas,
  [System.Management.Automation.PSCredential] $Credencial,
  [switch] $Consertar
)

$ErrorActionPreference = 'Continue'
$NOME     = 'MonitorAgent'
$RELATIVO = 'ProgramData\MonitorAgent'
$LOCAL    = 'C:\ProgramData\MonitorAgent\agente-powershell.ps1'
$resultados = @()

function Nova-Sessao {
  param([string] $Alvo)
  # DCOM primeiro: e o que existe numa loja. WSMan fica de reserva, para o caso
  # de alguem ja ter ligado WinRM naquele parque.
  foreach ($proto in @('Dcom', 'Wsman')) {
    try {
      $p = @{
        ComputerName        = $Alvo
        SessionOption       = (New-CimSessionOption -Protocol $proto)
        OperationTimeoutSec = 20
        ErrorAction         = 'Stop'
      }
      if ($Credencial) { $p.Credential = $Credencial }
      return (New-CimSession @p)
    } catch { }
  }
  return $null
}

foreach ($alvo in $Maquinas) {

  $r = [ordered]@{
    maquina       = $alvo
    alcance       = 'nenhum'
    tem_config    = $false
    tem_script    = $false
    tarefa        = '-'
    batimento_min = $null
    veredito      = $null
    acao          = $null
  }

  # --- 1. Os arquivos, pela pasta administrativa ---------------------------
  # Responde a pergunta que decide tudo: o cadastro sobreviveu? O config.json E
  # a identidade da maquina no painel; enquanto ele existir, nao ha o que
  # recadastrar.
  # ALCANCE PRIMEIRO, E SEPARADO. Test-Path numa pasta administrativa que nao
  # responde devolve $false em vez de erro -- entao "maquina desligada" e "sem
  # config.json" chegam aqui com a MESMA cara. Confundir os dois faz o script
  # mandar reprovisionar uma maquina que so estava desligada, e reprovisionar
  # com rotulo novo cria DUPLICATA no painel. Por isso a raiz do
  # compartilhamento e testada sozinha, antes de qualquer arquivo.
  $base = '\\' + $alvo + '\C$\' + $RELATIVO
  $raizOk = $false
  try { $raizOk = Test-Path ('\\' + $alvo + '\C$') } catch { }

  if ($raizOk) {
    $r.tem_config = Test-Path (Join-Path $base 'config.json')
    $r.tem_script = Test-Path (Join-Path $base 'agente-powershell.ps1')

    # O BATIMENTO: a regra 16 manda gravar no spool ANTES de tentar enviar,
    # entao spool.jsonl e tocado em todo ciclo, inclusive quando o envio falha.
    $marcas = @()
    foreach ($f in @('spool.jsonl', 'agente-ps.log')) {
      $c = Join-Path $base $f
      if (Test-Path $c) { $marcas += (Get-Item $c).LastWriteTime }
    }
    if ($marcas.Count -gt 0) {
      $ultima = ($marcas | Sort-Object -Descending)[0]
      $r.batimento_min = [int]((Get-Date) - $ultima).TotalMinutes
    }
    $r.alcance = 'arquivos'
  }

  # --- 2. A tarefa agendada ------------------------------------------------
  $sessao = Nova-Sessao -Alvo $alvo
  if ($sessao) {
    if ($r.alcance -eq 'arquivos') { $r.alcance = 'total' } else { $r.alcance = 'cim' }
    try {
      $t = Get-ScheduledTask -TaskName $NOME -CimSession $sessao -ErrorAction Stop
      $r.tarefa = [string]$t.State
    } catch { $r.tarefa = 'ausente' }
  }

  # --- 3. Veredito ---------------------------------------------------------
  # A ordem importa: a primeira condicao verdadeira e a causa RAIZ.
  $vivo = ($null -ne $r.batimento_min) -and ($r.batimento_min -le 3)

  if ($r.alcance -eq 'nenhum') {
    $r.veredito = 'INALCANCAVEL'
    $r.acao = 'Nem pasta administrativa nem CIM responderam. Maquina desligada, fora desta rede, ou sem direito de administrador.'
  }
  elseif ($r.alcance -eq 'cim' -and -not $r.tem_config) {
    $r.veredito = 'SEM_ACESSO_A_PASTA'
    $r.acao = 'O CIM responde mas C$ nao. Veja compartilhamento administrativo e direito da conta usada.'
  }
  elseif (-not $r.tem_config) {
    $r.veredito = 'SEM_CONFIG'
    $r.acao = 'Reprovisione com a MESMA loja e o MESMO rotulo do painel. Rotulo diferente cria maquina DUPLICADA.'
  }
  elseif (-not $r.tem_script) {
    $r.veredito = 'SEM_SCRIPT'
    $r.acao = 'O cadastro sobreviveu, o agente nao. Copie o agente para a pasta; nada a recadastrar.'
  }
  elseif ($null -eq $sessao) {
    $r.veredito = 'SEM_CIM'
    $r.acao = 'Os arquivos estao la, mas nao da para ver nem criar tarefa. Libere RPC/DCOM ou conserte nesta maquina com triagem-agente.ps1.'
  }
  elseif ($r.tarefa -eq 'ausente') {
    if ($vivo) { $r.veredito = 'RODANDO_SEM_TAREFA' } else { $r.veredito = 'PARADO_SEM_TAREFA' }
    $r.acao = 'Use -Consertar: sem tarefa o agente nao volta depois que o PC reinicia.'
  }
  elseif (-not $vivo) {
    $r.veredito = 'TAREFA_PARADA'
    $r.acao = 'Use -Consertar para iniciar a tarefa.'
  }
  else {
    $r.veredito = 'SAUDAVEL'
    $r.acao = 'Nada a fazer.'
  }

  # --- 4. Conserto ---------------------------------------------------------
  $consertaveis = @('RODANDO_SEM_TAREFA', 'PARADO_SEM_TAREFA', 'TAREFA_PARADA')
  if ($Consertar -and ($consertaveis -contains $r.veredito) -and $sessao) {
    try {
      if ($r.tarefa -eq 'ausente') {
        $argumento = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $LOCAL + '"'

        # ExecutionTimeLimit zero = SEM PRAZO. O padrao do Windows e 72 h, e um
        # agente que e laco infinito seria morto no terceiro dia -- o tipo de
        # sumico que ninguem liga a um prazo de tarefa agendada.
        $pCfg = @{
          MultipleInstances          = 'IgnoreNew'
          ExecutionTimeLimit         = [TimeSpan]::Zero
          RestartCount               = 3
          RestartInterval            = (New-TimeSpan -Minutes 1)
          AllowStartIfOnBatteries    = $true
          DontStopIfGoingOnBatteries = $true
        }
        $pTarefa = @{
          TaskName   = $NOME
          Action     = (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argumento)
          Trigger    = (New-ScheduledTaskTrigger -AtStartup)
          Principal  = (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest)
          Settings   = (New-ScheduledTaskSettingsSet @pCfg)
          Force      = $true
          CimSession = $sessao
        }
        Register-ScheduledTask @pTarefa | Out-Null
      }

      Start-ScheduledTask -TaskName $NOME -CimSession $sessao
      Start-Sleep -Seconds 4
      $r.tarefa = [string](Get-ScheduledTask -TaskName $NOME -CimSession $sessao).State
      $r.acao = 'CONSERTADO: tarefa ' + $r.tarefa + '. Agora volta sozinha depois de reiniciar.'
    }
    catch {
      $r.acao = 'FALHOU o conserto: ' + $_.Exception.Message
    }
  }

  if ($sessao) { Remove-CimSession $sessao -ErrorAction SilentlyContinue }
  $resultados += [pscustomobject]$r
}

# --- 5. Saida --------------------------------------------------------------
Write-Host ''
$resultados | Format-Table maquina, alcance, tarefa, batimento_min, veredito -AutoSize

$quebradas = @($resultados | Where-Object { $_.veredito -ne 'SAUDAVEL' })
if ($quebradas.Count -gt 0) {
  Write-Host ''
  Write-Host 'O QUE FAZER, por maquina:' -ForegroundColor Yellow
  foreach ($q in $quebradas) {
    Write-Host ('  ' + $q.maquina + ' [' + $q.veredito + ']')
    Write-Host ('      ' + $q.acao) -ForegroundColor DarkGray
  }
}

Write-Host ''
Write-Host ('Resumo: ' + @($resultados | Where-Object { $_.veredito -eq 'SAUDAVEL' }).Count + ' saudavel(is), ' + $quebradas.Count + ' com problema, de ' + $resultados.Count + '.')
Write-Host ''

$resultados
