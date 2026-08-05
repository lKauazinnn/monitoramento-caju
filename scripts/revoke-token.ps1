<#
.SYNOPSIS
  Revoga um token de agente pelo prefixo. Efeito imediato.

.DESCRIPTION
  Chama public.revoke_agent_token(). A revogação é individual: outros tokens da
  mesma máquina continuam valendo (rotação com sobreposição).

  Se o prefixo não corresponder a nenhum token ATIVO, o banco levanta erro — não
  há sucesso silencioso (regra 14).

.PARAMETER Prefix
  Prefixo do token (16 caracteres, ex.: mon_a1b2c3d4e5f6). Consulte em
  public.agent_tokens_admin.

.PARAMETER Reason
  Motivo, gravado em events para auditoria.

.PARAMETER List
  Em vez de revogar, lista os tokens e sai.

.EXAMPLE
  .\scripts\revoke-token.ps1 -List

.EXAMPLE
  .\scripts\revoke-token.ps1 -Prefix mon_a1b2c3d4e5f6 -Reason 'PDV substituido'
#>
[CmdletBinding(DefaultParameterSetName = 'Revoke')]
param(
  [Parameter(Mandatory = $true, ParameterSetName = 'Revoke')][string] $Prefix,
  [Parameter(ParameterSetName = 'Revoke')][string] $Reason = 'revogado manualmente',
  [Parameter(Mandatory = $true, ParameterSetName = 'List')][switch] $List
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

if ($PSCmdlet.ParameterSetName -eq 'List') {
  $sqlList = @"
select site_code, machine_label, token_prefix, token_status,
       to_char(created_at, 'YYYY-MM-DD HH24:MI') as criado,
       coalesce(to_char(last_used_at, 'YYYY-MM-DD HH24:MI'), '-') as ultimo_uso,
       use_count as usos,
       active_tokens_for_machine as ativos_na_maquina
from public.agent_tokens_admin
order by site_code, machine_label, created_at desc;
"@

  & $psql.Source `
    --dbname=$env:MONITOR_DB_URL `
    --no-psqlrc `
    --set=ON_ERROR_STOP=1 `
    --command=$sqlList

  if ($LASTEXITCODE -ne 0) { exit 1 }

  Write-Host ''
  Write-Host 'ativos_na_maquina > 1 significa rotacao em andamento ou token esquecido.' -ForegroundColor DarkGray
  Write-Host ''
  exit 0
}

$sql = @"
select token_prefix, site_code, label, to_char(revoked_at, 'YYYY-MM-DD HH24:MI:SS')
from public.revoke_agent_token(:'prefix', :'reason');
"@

$saida = & $psql.Source `
  --dbname=$env:MONITOR_DB_URL `
  --no-psqlrc `
  --tuples-only `
  --no-align `
  --field-separator='|' `
  --set=ON_ERROR_STOP=1 `
  -v prefix=$Prefix `
  -v reason=$Reason `
  --command=$sql

if ($LASTEXITCODE -ne 0) {
  Write-Host ''
  Write-Host 'Revogacao FALHOU. Mensagem do banco acima.' -ForegroundColor Red
  Write-Host 'Confira os prefixos ativos com: .\scripts\revoke-token.ps1 -List' -ForegroundColor Yellow
  exit 1
}

$linha = ($saida | Where-Object { $_ -match '\|' } | Select-Object -First 1)
$c = $linha.Split('|')

Write-Host ''
Write-Host 'TOKEN REVOGADO' -ForegroundColor Yellow
Write-Host ("  Prefixo : {0}" -f $c[0])
Write-Host ("  Loja    : {0}" -f $c[1])
Write-Host ("  Maquina : {0}" -f $c[2])
Write-Host ("  Em      : {0}" -f $c[3])
Write-Host ("  Motivo  : {0}" -f $Reason)
Write-Host ''
Write-Host 'O agente dessa maquina passa a receber 401 no proximo envio.' -ForegroundColor DarkGray
Write-Host 'O spool local dele vai acumular ate o teto configurado.' -ForegroundColor DarkGray
Write-Host ''
