<#
.SYNOPSIS
  Fecha a configuracao do banco na maquina servidora: MOSTRA o estado, aplica a
  0047 e PROVA o resultado rodando o teste 01.

.DESCRIPTION
  Roda NA MAQUINA SERVIDORA (DESKTOP-K7W6IMC / PC-BANCO-DD). Nao roda de outro
  PC: a stack de producao publica uma unica porta em 127.0.0.1 -- quem alcanca o
  banco de fora e o tunel, e o tunel ainda nao existe. Da rede, a porta 2121 nem
  responde, e isso e de proposito.

  O QUE FALTA NO BANCO, e por que este script existe:

    A 0047 fecha o schema `cron` para os papeis da aplicacao. Ela apareceu na
    PRIMEIRA instalacao self-hosted e nao podia ter aparecido antes: no Supabase
    o pg_cron ja vinha instalado e fechado; aqui quem cria a extensao somos nos
    (0011), e ela traz os proprios GRANTs para PUBLIC. O que incomoda de verdade
    nao e o vazamento de hoje -- as policies do pg_cron filtram por
    `username = current_user`, entao `anon` leria zero linhas -- e sim PUBLIC ter
    DELETE em `cron.job_run_details`: apagar o historico do agendador e apagar
    justamente a evidencia que se usa quando o agendamento falha.

  APLICAR NAO E O MESMO QUE VALER. Por isso a ordem e: estado ANTES, aplicar,
  estado DEPOIS, e o teste 01 no fim -- foi ele que acusou o problema, entao e
  ele quem tem autoridade para dizer que acabou.

  SO O TESTE 01 RODA AQUI. Ele e de estrutura e nao escreve nada. Os testes 02
  em diante INSEREM dados (maquinas, metricas, usuarios) e nao podem tocar num
  banco de producao com as maquinas da rede dentro.

  SEM SENHA EM LUGAR NENHUM: o psql roda DENTRO do contentor, pelo socket local,
  onde a imagem oficial do Postgres autentica por trust. Nada de senha na linha
  de comando (ela ficaria no historico do PowerShell e na lista de processos) e
  nada de senha na conversa. Se o socket recusar, o script cai para a senha do
  .env.selfhost -- lida do arquivo, na maquina, nunca digitada.

.PARAMETER SoConferir
  Mostra o estado e NAO aplica nada. Bom para olhar antes de mexer.

.PARAMETER Container
  Nome do contentor do banco. Padrao: monitor-db.

.PARAMETER Raiz
  Pasta do projeto. Padrao: a pasta acima deste script.

.EXAMPLE
  .\scripts\finalizar-banco-selfhost.ps1 -SoConferir

.EXAMPLE
  .\scripts\finalizar-banco-selfhost.ps1
#>
[CmdletBinding()]
param(
  [switch] $SoConferir,
  [string] $Container = 'monitor-db',
  [string] $Raiz
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Raiz)) { $Raiz = Split-Path -Parent $PSScriptRoot }

$migracao = Join-Path $Raiz 'supabase\migrations\20260915220000_0047_cron_fora_do_alcance_da_aplicacao.sql'
$teste01  = Join-Path $Raiz 'supabase\tests\01_estrutura_e_regras.sql'

foreach ($f in @($migracao, $teste01)) {
  if (-not (Test-Path $f)) {
    Write-Host "Nao achei $f" -ForegroundColor Red
    Write-Host 'Este script precisa da copia do repositorio NA maquina servidora.' -ForegroundColor Yellow
    exit 1
  }
}

# ---------------------------------------------------------------------------
# A armadilha do PowerShell 5.1, que ja derrubou script deste repositorio antes
# ---------------------------------------------------------------------------
# O psql escreve NOTICE no stderr, e o PowerShell embrulha cada linha de stderr
# de programa nativo num ErrorRecord. Com ErrorActionPreference = 'Stop', o
# proprio aviso de SUCESSO aborta o script. Quem decide sucesso aqui e o
# $LASTEXITCODE -- unico sinal confiavel de comando nativo.
function Invocar([scriptblock] $Bloco) {
  $antes = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Bloco } finally { $ErrorActionPreference = $antes }
}

if ($null -eq (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-Host 'docker nao esta no PATH. O Docker Desktop precisa estar rodando.' -ForegroundColor Red
  exit 1
}

$vivo = Invocar { docker inspect -f '{{.State.Running}}' $Container }
if ($LASTEXITCODE -ne 0 -or ("$vivo".Trim() -ne 'true')) {
  Write-Host "O contentor $Container nao esta de pe." -ForegroundColor Red
  Write-Host 'Suba a stack primeiro:  .\scripts\subir-servidor.ps1' -ForegroundColor Yellow
  exit 1
}

# ---------------------------------------------------------------------------
# Como falar com o banco: socket de dentro primeiro, senha do arquivo depois
# ---------------------------------------------------------------------------
$argsSenha = @()
Invocar { docker exec $Container psql -U postgres -d postgres -A -t -c 'select 1' } | Out-Null
if ($LASTEXITCODE -ne 0) {
  $envPath = Join-Path $Raiz '.env.selfhost'
  if (-not (Test-Path $envPath)) {
    Write-Host 'psql pelo socket recusou e nao achei .env.selfhost para a senha.' -ForegroundColor Red
    exit 1
  }
  $senha = $null
  foreach ($linha in (Get-Content $envPath)) {
    if ($linha -match '^\s*POSTGRES_PASSWORD\s*=\s*(.+?)\s*$') { $senha = $Matches[1] }
  }
  if ([string]::IsNullOrWhiteSpace($senha)) {
    Write-Host 'Nao achei POSTGRES_PASSWORD no .env.selfhost.' -ForegroundColor Red
    exit 1
  }
  $argsSenha = @('-e', "PGPASSWORD=$senha")
  Write-Host 'socket recusou: usando a senha do .env.selfhost.' -ForegroundColor DarkGray
}

function Perguntar([string] $sql) {
  Invocar { docker exec @argsSenha $Container psql -U postgres -d postgres -A -t -c $sql }
}

function Rodar([string] $caminhoLocal, [string] $nomeRemoto) {
  Invocar {
    docker cp $caminhoLocal "${Container}:/tmp/$nomeRemoto" | Out-Null
    docker exec @argsSenha $Container psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f "/tmp/$nomeRemoto"
  }
}

$falhas = 0
function Conferir([string] $rotulo, [string] $sql, [string] $esperado, [string] $seFalhar) {
  $r = (Perguntar $sql | Out-String).Trim()
  $bom = $r -match $esperado
  Write-Host ("   {0,-38} {1}" -f $rotulo, $r) -ForegroundColor $(if ($bom) { 'Green' } else { 'Red' })
  if (-not $bom) {
    Write-Host "      $seFalhar" -ForegroundColor Yellow
    $script:falhas++
  }
  return $bom
}

Write-Host ''
Write-Host '============================================================'
Write-Host ' Estado do banco ANTES' -ForegroundColor Cyan
Write-Host '============================================================'

Conferir 'versao do Postgres' `
  'show server_version;' '^16' 'esperado Postgres 16.' | Out-Null

Conferir 'pg_cron instalado' `
  "select coalesce((select extversion from pg_extension where extname = 'pg_cron'), 'AUSENTE');" `
  '^[0-9]' 'sem pg_cron a criacao de particao futura para -- e a ingestao para junto.' | Out-Null

Conferir 'tabelas em public' `
  "select count(*) from information_schema.tables where table_schema = 'public';" `
  '^[0-9]+$' '' | Out-Null

# Os quatro jobs, nominalmente. Contar nao basta: quatro jobs errados contam
# quatro do mesmo jeito, e ja existiu aqui um duplicado criado por engano.
foreach ($j in @('monitor_maintenance', 'avaliar-alertas', 'rollup-horario', 'expirar-comandos')) {
  Conferir "job $j" `
    "select coalesce((select schedule || ' ativo=' || active from cron.job where jobname = '$j'), 'AUSENTE');" `
    'ativo=t' `
    'esse job nao esta agendado e ativo.' | Out-Null
}

$jaFechado = Conferir 'privilegio de aplicacao no cron' `
  "select coalesce(string_agg(distinct grantee || ':' || privilege_type, ', '), 'nenhum') from information_schema.role_table_grants where table_schema = 'cron' and grantee in ('PUBLIC', 'anon', 'authenticated');" `
  '^nenhum$' `
  'e exatamente isto que a 0047 remove.'

# ---------------------------------------------------------------------------
# Aplicar
# ---------------------------------------------------------------------------
if ($SoConferir) {
  Write-Host ''
  Write-Host '-SoConferir: nada foi aplicado.' -ForegroundColor DarkGray
  exit 0
}

Write-Host ''
Write-Host '============================================================'
Write-Host ' Aplicando a 0047' -ForegroundColor Cyan
Write-Host '============================================================'

if ($jaFechado) {
  Write-Host 'Ja estava fechado. Aplico assim mesmo: a 0047 e idempotente e o' -ForegroundColor DarkGray
  Write-Host 'proprio arquivo confere o resultado no fim.' -ForegroundColor DarkGray
}

Rodar $migracao '0047.sql'
if ($LASTEXITCODE -ne 0) {
  Write-Host ''
  Write-Host 'A 0047 FALHOU. Parei aqui.' -ForegroundColor Red
  exit 1
}

Write-Host ''
Write-Host '============================================================'
Write-Host ' Estado DEPOIS' -ForegroundColor Cyan
Write-Host '============================================================'

$falhas = 0
Conferir 'privilegio de aplicacao no cron' `
  "select coalesce(string_agg(distinct grantee || ':' || privilege_type, ', '), 'nenhum') from information_schema.role_table_grants where table_schema = 'cron' and grantee in ('PUBLIC', 'anon', 'authenticated');" `
  '^nenhum$' `
  'a 0047 rodou e o privilegio continua la. NAO siga sem entender isto.' | Out-Null

Conferir 'usage no cron para public' `
  "select case when has_schema_privilege('public', 'cron', 'usage') then 'AINDA TEM' else 'revogado' end;" `
  '^revogado$' `
  'o revoke de usage nao pegou.' | Out-Null

# O agendador tem de continuar agendando DEPOIS do revoke. Quem agenda e o
# superusuario, pelas migrations -- mas isso e uma afirmacao, e afirmacao se
# confere.
Conferir 'jobs ativos apos o revoke' `
  'select count(*) from cron.job where active;' `
  '^4$' `
  'algum job sumiu ou ficou inativo depois do revoke.' | Out-Null

Write-Host ''
Write-Host '============================================================'
Write-Host ' Teste 01 -- estrutura e regras (nao escreve nada)' -ForegroundColor Cyan
Write-Host '============================================================'

Rodar $teste01 'teste01.sql'
$testeOk = ($LASTEXITCODE -eq 0)

Write-Host ''
Write-Host '============================================================'
if ($testeOk -and $falhas -eq 0) {
  Write-Host ' BANCO FECHADO: 0047 aplicada e teste 01 passou.' -ForegroundColor Green
  Write-Host ''
  Write-Host ' Falta, fora do banco:' -ForegroundColor Cyan
  Write-Host '   1. endereco fixo para o tunel (item travado)'
  Write-Host '   2. .\scripts\subir-servidor.ps1 -Instalar   (terminal ELEVADO)'
  Write-Host '   3. apontar o config.js da Vercel para o endereco final'
  Write-Host '   4. reinstalar o agente nas maquinas que faltam'
  exit 0
} else {
  if (-not $testeOk) { Write-Host ' O TESTE 01 FALHOU. Leia a excecao acima.' -ForegroundColor Red }
  if ($falhas -gt 0) { Write-Host " $falhas conferencia(s) falharam." -ForegroundColor Red }
  exit 1
}
