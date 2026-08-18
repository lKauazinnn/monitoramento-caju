<#
.SYNOPSIS
  Aplica a migracao 0043 em producao e CONFERE que o avaliador de alertas ficou
  agendado.

.DESCRIPTION
  A migracao 0043 e a que faz o sistema de alerta existir. Ate ela, o pipeline
  inteiro estava correto e nunca rodava: `avaliar_alertas()` so era chamada por
  testes, entao nenhum alerta era aberto, a faixa vermelha nunca acendia e o
  aviso sonoro nao tinha o que tocar.

  Este script existe em vez de um comando avulso por dois motivos:

    1. A senha e LIDA, nunca digitada na linha de comando. Comando com senha fica
       no historico do PowerShell, aparece na lista de processos e vaza para
       qualquer log de terminal.

    2. Aplicar nao e o mesmo que funcionar. A stack local nao tem pg_cron, entao
       o caso mais importante do teste 14 (o agendamento) SO pode ser conferido
       aqui. Este script confere depois de aplicar, e falha alto se o job nao
       ficou de pe.

  Nao altera dado de maquina nenhuma. Cria duas funcoes, estende uma constraint e
  agenda um job de um minuto.

.PARAMETER UrlBanco
  URL do Postgres de producao. Sem senha: ela e pedida a parte.
  Padrao: o pooler gravado em supabase\.temp\pooler-url.

.PARAMETER Senha
  Senha do banco. Se ausente, e pedida escondida no terminal.

.EXAMPLE
  .\scripts\ligar-avaliacao-de-alertas.ps1
#>
[CmdletBinding()]
param(
  [string] $UrlBanco,
  [System.Security.SecureString] $Senha
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

$migracao = Join-Path $raiz 'supabase\migrations\20260813170000_0043_o_avaliador_precisa_rodar.sql'
if (-not (Test-Path $migracao)) {
  Write-Host "Nao achei a migracao: $migracao" -ForegroundColor Red
  exit 1
}

if ([string]::IsNullOrWhiteSpace($UrlBanco)) {
  $arq = Join-Path $raiz 'supabase\.temp\pooler-url'
  if (-not (Test-Path $arq)) {
    Write-Host 'Sem -UrlBanco e sem supabase\.temp\pooler-url. Rode `npx supabase link` ou passe -UrlBanco.' -ForegroundColor Red
    exit 1
  }
  $UrlBanco = (Get-Content $arq -Raw).Trim()
}

if ($null -eq $Senha) {
  $Senha = Read-Host -Prompt 'Senha do banco de producao' -AsSecureString
}

# A senha vai por variavel de ambiente do processo do psql (PGPASSWORD), e nao
# dentro da URL: URL com senha aparece em `docker ps`, no historico e em qualquer
# log de erro que ecoe o comando.
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Senha)
try {
  $senhaNua = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

# psql: o do PATH, ou o do contentor local, que ja existe nesta maquina.
$psql = Get-Command psql -ErrorAction SilentlyContinue
$viaDocker = $null -eq $psql
if ($viaDocker) {
  $temDocker = Get-Command docker -ErrorAction SilentlyContinue
  if ($null -eq $temDocker) {
    Write-Host 'Nem psql no PATH nem docker. Instale o psql ou suba a stack local.' -ForegroundColor Red
    exit 1
  }
  Write-Host 'psql nao esta no PATH: usando o do contentor monitor-db.' -ForegroundColor DarkGray
  docker cp $migracao monitor-db:/tmp/0043.sql | Out-Null
}

function Invocar([string] $sql, [string] $arquivo) {
  if ($viaDocker) {
    if ($arquivo) { docker exec -e PGPASSWORD=$senhaNua monitor-db psql $UrlBanco -v ON_ERROR_STOP=1 -f $arquivo }
    else          { docker exec -e PGPASSWORD=$senhaNua monitor-db psql $UrlBanco -A -t -c $sql }
  } else {
    $env:PGPASSWORD = $senhaNua
    if ($arquivo) { & $psql.Source $UrlBanco -v ON_ERROR_STOP=1 -f $arquivo }
    else          { & $psql.Source $UrlBanco -A -t -c $sql }
  }
}

Write-Host ''
Write-Host '== Aplicando a 0043 ==' -ForegroundColor Cyan
$saida = Invocar $null ($(if ($viaDocker) { '/tmp/0043.sql' } else { $migracao })) 2>&1
$saida | ForEach-Object { Write-Host "   $_" }

if ($LASTEXITCODE -ne 0) {
  Write-Host ''
  Write-Host 'A MIGRACAO FALHOU. Nada foi agendado.' -ForegroundColor Red
  exit 1
}

Write-Host ''
Write-Host '== Conferindo o que a stack local NAO consegue conferir ==' -ForegroundColor Cyan

# 1. O job existe, esta ativo e e de um minuto.
$job = Invocar "select coalesce((select jobname || ' | ' || schedule || ' | ativo=' || active from cron.job where jobname = 'monitor_avaliar_alertas'), 'AUSENTE');" $null
$job = ($job | Out-String).Trim()
Write-Host "   job: $job"

if ($job -eq 'AUSENTE' -or $job -notmatch 'ativo=t') {
  Write-Host ''
  Write-Host 'O JOB NAO FICOU DE PE. Os alertas continuam sem ser avaliados:' -ForegroundColor Red
  Write-Host '  - nenhuma maquina offline vai abrir alerta' -ForegroundColor Red
  Write-Host '  - a faixa vermelha nao acende e o som nao toca' -ForegroundColor Red
  Write-Host 'Confira se pg_cron esta habilitado no projeto (Database > Extensions).' -ForegroundColor Yellow
  exit 1
}

# 2. As funcoes respondem de verdade. Conferir pg_proc provaria que existem, e nao
#    que o PostgREST as ve -- foi assim que uma RPC "aplicada" ficou 404 antes.
$n = (Invocar "select jsonb_array_length(public.regras_de_alerta());" $null | Out-String).Trim()
Write-Host "   regras_de_alerta responde: $n regra(s)"

# 3. A primeira avaliacao, feita agora, para nao esperar um minuto para saber.
$r = (Invocar "select public.avaliar_alertas()::text;" $null | Out-String).Trim()
Write-Host "   primeira avaliacao: $r"

$abertos = (Invocar "select count(*) from public.open_alerts where severity = 'critical';" $null | Out-String).Trim()
Write-Host "   alertas criticos em aberto agora: $abertos"

Write-Host ''
Write-Host '============================================================'
Write-Host ' AVALIACAO DE ALERTAS LIGADA' -ForegroundColor Green
Write-Host '============================================================'
Write-Host ''
Write-Host "  A partir de agora a avaliacao roda a cada minuto. Uma maquina que"
Write-Host "  desligar abre alerta critico em ate ~1 min depois de ser considerada"
Write-Host "  offline (~130 s de silencio), e o painel toca."
Write-Host ''
if ([int]$abertos -gt 0) {
  Write-Host "  Os $abertos alerta(s) acima sao de maquinas que JA estavam offline." -ForegroundColor Yellow
  Write-Host "  Eles nao vao tocar: a primeira carga da pagina nunca toca, de proposito." -ForegroundColor DarkGray
}
Write-Host '  No painel: barra lateral > Som (liga) e Alertas (ajusta).'
Write-Host ''
