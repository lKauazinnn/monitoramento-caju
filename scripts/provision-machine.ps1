<#
.SYNOPSIS
  Provisiona uma máquina e emite o token do agente. O texto claro aparece UMA
  ÚNICA VEZ, nesta saída.

.DESCRIPTION
  Chama public.provision_machine() via psql. No banco fica apenas o SHA-256
  (regra 2): não existe caminho de recuperação do token.

  A service_role_key do Supabase NÃO é usada nem aceita por este script
  (regra 1). A autenticação é a connection string do banco, em variável de
  ambiente MONITOR_DB_URL, que só a TI possui.

.PARAMETER SiteCode
  Código da loja como cadastrado em public.sites (ex.: BSB-001).

.PARAMETER Label
  Nome operacional da máquina dentro da loja (ex.: 'PDV 01').

.PARAMETER Role
  Perfil: pdv, server ou admin.

.PARAMETER Rotate
  Emite token adicional para máquina que já tem token ativo (rotação com
  sobreposição). Sem esta flag, a operação é bloqueada de propósito.

.PARAMETER IngestUrl
  URL de ingestão a gravar no config.json. Só necessário com -OutConfig.

.PARAMETER OutConfig
  Caminho onde gravar o config.json do agente. NÃO aponte para dentro do
  repositório: o arquivo contém o token em texto claro.

.EXAMPLE
  $env:MONITOR_DB_URL = 'postgresql://...'
  .\scripts\provision-machine.ps1 -SiteCode BSB-001 -Label 'PDV 03' -Role pdv

.EXAMPLE
  .\scripts\provision-machine.ps1 -SiteCode BSB-001 -Label 'PDV 03' `
      -IngestUrl 'https://abc.supabase.co/functions/v1/ingest' `
      -OutConfig 'C:\temp\config-pdv03.json'
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string] $SiteCode,
  [Parameter(Mandatory = $true)][string] $Label,
  [ValidateSet('pdv', 'server', 'admin')][string] $Role = 'pdv',
  [string] $Notes = '',
  [switch] $Rotate,
  [string] $IngestUrl = '',
  [string] $OutConfig = ''
)

$ErrorActionPreference = 'Stop'

$psql = Get-Command psql -ErrorAction SilentlyContinue
if ($null -eq $psql) {
  Write-Host 'psql nao encontrado no PATH. Veja .\scripts\apply-migrations.ps1' -ForegroundColor Red
  exit 1
}

if ([string]::IsNullOrWhiteSpace($env:MONITOR_DB_URL)) {
  Write-Host 'MONITOR_DB_URL nao definida.' -ForegroundColor Red
  exit 1
}

if ($OutConfig -ne '' -and $IngestUrl -eq '') {
  Write-Host '-OutConfig exige -IngestUrl.' -ForegroundColor Red
  exit 1
}

$rotateLiteral = 'false'
if ($Rotate) { $rotateLiteral = 'true' }

# :'var' faz o psql aplicar quoting de literal SQL. É o que impede que um label
# com apóstrofo (ou pior) vire injeção.
$sql = @"
select machine_id, site_code, site_name, label, role_code, token, token_prefix, is_new_machine
from public.provision_machine(:'site', :'label', :'role', :'notes', :'rotate'::boolean);
"@

$saida = & $psql.Source `
  --dbname=$env:MONITOR_DB_URL `
  --no-psqlrc `
  --tuples-only `
  --no-align `
  --field-separator='|' `
  --set=ON_ERROR_STOP=1 `
  -v site=$SiteCode `
  -v label=$Label `
  -v role=$Role `
  -v notes=$Notes `
  -v rotate=$rotateLiteral `
  --command=$sql

if ($LASTEXITCODE -ne 0) {
  Write-Host ''
  Write-Host 'Provisionamento FALHOU. Mensagem do banco acima.' -ForegroundColor Red
  Write-Host ''
  Write-Host 'Causas comuns:' -ForegroundColor Yellow
  Write-Host '  - loja inexistente ou inativa  -> cadastre em public.sites'
  Write-Host '  - maquina ja tem token ativo   -> use -Rotate se a intencao e rotacionar'
  Write-Host '  - perfil invalido              -> pdv | server | admin'
  exit 1
}

$linha = ($saida | Where-Object { $_ -match '\|' } | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($linha)) {
  Write-Host 'Resposta inesperada do banco:' -ForegroundColor Red
  Write-Host $saida
  exit 1
}

$c = $linha.Split('|')
$machineId  = $c[0]
$siteCodeDb = $c[1]
$siteName   = $c[2]
$labelDb    = $c[3]
$roleDb     = $c[4]
$token      = $c[5]
$prefix     = $c[6]
$isNew      = $c[7]

Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host ' MAQUINA PROVISIONADA' -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
Write-Host ("  Loja      : {0} - {1}" -f $siteCodeDb, $siteName)
Write-Host ("  Maquina   : {0}  (perfil {1})" -f $labelDb, $roleDb)
Write-Host ("  GUID      : {0}" -f $machineId)
Write-Host ("  Prefixo   : {0}" -f $prefix)
if ($isNew -eq 't') {
  Write-Host '  Situacao  : maquina nova'
} else {
  Write-Host '  Situacao  : maquina existente (token de ROTACAO emitido)' -ForegroundColor Yellow
}
Write-Host ''
Write-Host '  TOKEN (aparece uma unica vez):' -ForegroundColor Yellow
Write-Host ("  {0}" -f $token) -ForegroundColor White
Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host ' No banco existe apenas o SHA-256. Perdeu o token, rotaciona.' -ForegroundColor DarkGray
Write-Host ' Revogar: .\scripts\revoke-token.ps1 -Prefix ' -NoNewline -ForegroundColor DarkGray
Write-Host $prefix -ForegroundColor DarkGray
Write-Host '============================================================' -ForegroundColor Green

if ($OutConfig -ne '') {
  # FORMATO PROVISORIO: a Fase 3 fixa o schema definitivo do config.json.
  # As chaves abaixo cobrem o minimo que o agente precisa.
  $config = [ordered]@{
    ingestUrl       = $IngestUrl
    token           = $token
    machineId       = $machineId
    siteCode        = $siteCodeDb
    machineLabel    = $labelDb
    role            = $roleDb
    intervalSeconds = 60
  }

  $dir = Split-Path -Parent $OutConfig
  if ($dir -ne '' -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }

  $config | ConvertTo-Json -Depth 4 | Out-File -FilePath $OutConfig -Encoding utf8

  Write-Host ''
  Write-Host ("config.json gravado em: {0}" -f $OutConfig) -ForegroundColor Cyan
  Write-Host 'ESTE ARQUIVO CONTEM O TOKEN EM TEXTO CLARO.' -ForegroundColor Yellow
  Write-Host 'Copie para %ProgramData%\MonitorAgent\ na maquina e apague a origem.' -ForegroundColor Yellow
  Write-Host 'Formato provisorio: a Fase 3 fixa o schema final.' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Lembrete: o token acabou de passar pelo console. Se voce usa' -ForegroundColor DarkGray
Write-Host 'Start-Transcript ou logging de terminal, ele esta gravado la.' -ForegroundColor DarkGray
Write-Host ''
