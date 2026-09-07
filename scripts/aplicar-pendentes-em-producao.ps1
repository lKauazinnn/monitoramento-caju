<#
.SYNOPSIS
  Aplica as migracoes 0043 e 0044 em producao e CONFERE que cada uma passou a
  valer -- nao so que o arquivo rodou.

.DESCRIPTION
  Duas coisas dependem disto, e nenhuma das duas funciona sem:

    0043  agenda avaliar_alertas() a cada minuto. Ate ela, o pipeline de alerta
          existia inteiro e NUNCA rodava em producao (so nos testes): nenhuma
          maquina offline abria alerta, a faixa vermelha nunca acendia e o botao
          "Som" nao tinha efeito nenhum.

    0044  cria a escolha de volumes acompanhados. Sem ela, o interruptor
          "acompanhar" aparece na gaveta e da erro no clique, porque a funcao
          definir_volume_acompanhado nao existe do outro lado.

  APLICAR NAO E O MESMO QUE FUNCIONAR, e este script existe por causa disso. A
  stack local nao tem pg_cron, entao o caso mais importante do teste 14 -- o
  agendamento -- so pode ser conferido aqui. E uma RPC recem-criada pode existir
  em pg_proc e ainda dar 404 no painel enquanto o PostgREST nao recarregar o
  cache. As conferencias do fim CHAMAM as funcoes, em vez de perguntar se elas
  existem.

  A senha e LIDA escondida, nunca digitada na linha de comando: comando com senha
  fica no historico do PowerShell e aparece na lista de processos.

  Idempotente: rodar duas vezes nao faz mal. As migracoes usam create or replace,
  if not exists, e reagendamento por nome.

.PARAMETER UrlBanco
  URL do Postgres. Padrao: o pooler de supabase\.temp\pooler-url.

.EXAMPLE
  .\scripts\aplicar-pendentes-em-producao.ps1
#>
[CmdletBinding()]
param(
  [string] $UrlBanco,
  [System.Security.SecureString] $Senha
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

$migracoes = @(
  @{ nome = '0043 — agendar a avaliacao de alertas';
     arq  = 'supabase\migrations\20260813170000_0043_o_avaliador_precisa_rodar.sql' },
  @{ nome = '0044 — escolher os discos acompanhados';
     arq  = 'supabase\migrations\20260813190000_0044_escolher_os_discos_acompanhados.sql' },
  @{ nome = '0045 — todos os volumes no cartao';
     arq  = 'supabase\migrations\20260813210000_0045_todos_os_volumes_no_cartao.sql' }
)

foreach ($m in $migracoes) {
  if (-not (Test-Path (Join-Path $raiz $m.arq))) {
    Write-Host "Nao achei $($m.arq)" -ForegroundColor Red
    exit 1
  }
}

if ([string]::IsNullOrWhiteSpace($UrlBanco)) {
  $arq = Join-Path $raiz 'supabase\.temp\pooler-url'
  if (-not (Test-Path $arq)) {
    Write-Host 'Passe -UrlBanco: nao achei supabase\.temp\pooler-url.' -ForegroundColor Red
    exit 1
  }
  $UrlBanco = (Get-Content $arq -Raw).Trim()
}

if ($null -eq $Senha) { $Senha = Read-Host -Prompt 'Senha do banco de producao' -AsSecureString }

$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Senha)
try { $senhaNua = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

$psql = Get-Command psql -ErrorAction SilentlyContinue
$viaDocker = $null -eq $psql
if ($viaDocker) {
  if ($null -eq (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host 'Nem psql no PATH nem docker.' -ForegroundColor Red
    exit 1
  }
  Write-Host 'psql nao esta no PATH: usando o do contentor monitor-db.' -ForegroundColor DarkGray
}

# ARMADILHA DO POWERSHELL 5.1, e ela derrubou este script na primeira vez que o
# Kaua rodou: o psql escreve os NOTICE no STDERR, e o PowerShell embrulha cada
# linha de stderr de programa nativo num ErrorRecord. Com ErrorActionPreference
# 'Stop', o proprio aviso de SUCESSO ("job agendado a cada minuto") abortou o
# script antes de aplicar a 0044.
#
# Por isso 'Continue' em volta das chamadas nativas: a decisao de sucesso passa a
# ser o $LASTEXITCODE, que e o unico sinal confiavel aqui.
function Aplicar([string] $caminho) {
  $antes = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($viaDocker) {
      docker cp $caminho monitor-db:/tmp/mig.sql | Out-Null
      docker exec -e PGPASSWORD=$senhaNua monitor-db psql $UrlBanco -v ON_ERROR_STOP=1 -f /tmp/mig.sql
    } else {
      $env:PGPASSWORD = $senhaNua
      & $psql.Source $UrlBanco -v ON_ERROR_STOP=1 -f $caminho
    }
  } finally {
    $ErrorActionPreference = $antes
  }
}

function Perguntar([string] $sql) {
  $antes = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($viaDocker) {
      docker exec -e PGPASSWORD=$senhaNua monitor-db psql $UrlBanco -A -t -c $sql
    } else {
      $env:PGPASSWORD = $senhaNua
      & $psql.Source $UrlBanco -A -t -c $sql
    }
  } finally {
    $ErrorActionPreference = $antes
  }
}

Write-Host ''
Write-Host '============================================================'
Write-Host ' Aplicando as migracoes pendentes' -ForegroundColor Cyan
Write-Host '============================================================'

foreach ($m in $migracoes) {
  Write-Host ''
  Write-Host "== $($m.nome) ==" -ForegroundColor Cyan
  # Sem 2>&1: redirecionar o stderr de um programa nativo e justamente o que
  # transforma cada NOTICE em erro. Deixo o psql escrever direto no console.
  Aplicar (Join-Path $raiz $m.arq)
  if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host "FALHOU: $($m.nome). Parei aqui." -ForegroundColor Red
    exit 1
  }
}

Write-Host ''
Write-Host '============================================================'
Write-Host ' Conferindo o que passou a VALER' -ForegroundColor Cyan
Write-Host '============================================================'

$falhas = 0
function Conferir([string] $rotulo, [string] $sql, [string] $esperado, [string] $seFalhar) {
  $r = (Perguntar $sql | Out-String).Trim()
  $bom = $r -match $esperado
  $cor = if ($bom) { 'Green' } else { 'Red' }
  Write-Host ("   {0,-42} {1}" -f $rotulo, $r) -ForegroundColor $cor
  if (-not $bom) {
    Write-Host "      $seFalhar" -ForegroundColor Yellow
    $script:falhas++
  }
}

# 0043 — o agendamento. E o unico caso que a stack local nao consegue conferir.
# O job CERTO e o 'avaliar-alertas' da 0020, a cada 5 minutos. A versao anterior
# conferia o 'monitor_avaliar_alertas', que era o DUPLICADO que eu criei por
# engano e que a 0043 agora REMOVE -- a conferencia passaria a falhar sempre, e
# conferencia que falha por estar errada treina a ignorar conferencia.
Conferir 'job avaliar-alertas (0020)' `
  "select coalesce((select schedule || ' ativo=' || active from cron.job where jobname = 'avaliar-alertas'), 'AUSENTE');" `
  'ativo=t' `
  'sem esse job nenhum alerta e avaliado. Reaplique a 0020.'

Conferir 'job duplicado removido' `
  "select case when exists (select 1 from cron.job where jobname = 'monitor_avaliar_alertas') then 'AINDA EXISTE' else 'removido' end;" `
  'removido' `
  'o duplicado de um minuto ainda esta agendado. Rode: select cron.unschedule(''monitor_avaliar_alertas'');'

# As RPC CHAMADAS, e nao procuradas em pg_proc: e a chamada que prova que o
# PostgREST recarregou o cache e que o painel vai encontra-las.
Conferir 'regras_de_alerta() responde' `
  'select jsonb_array_length(public.regras_de_alerta());' `
  '^[1-9]' `
  'a funcao nao respondeu. Rode: notify pgrst, ''reload schema'';'

Conferir 'tabela machine_volumes' `
  "select to_regclass('public.machine_volumes')::text;" `
  'machine_volumes' `
  'a 0044 nao criou a tabela.'

Conferir 'machines_status tem disk_volumes_fora' `
  "select count(*) from information_schema.columns where table_name = 'machines_status' and column_name in ('disk_volumes_fora','disk_drives_fora');" `
  '^2$' `
  'a view nao foi recriada: o cartao nao vai avisar sobre volume fora.'

Conferir 'discos_da_maquina mantem a forma' `
  "select case when d like '%''medido_em''%' and d like '%''discos''%' and d like '%''free_gb''%' and d like '%''acompanhando''%' then 'ok (medido_em, discos, free_gb, acompanhando)' else 'FORMA ERRADA' end from (select pg_get_functiondef('public.discos_da_maquina(uuid)'::regprocedure) as d) x;" `
  'ok' `
  'a gaveta de discos vai ficar VAZIA no painel: falta um dos campos que o painel le.'

Conferir 'definir_volume_acompanhado existe' `
  "select count(*) from pg_proc where proname = 'definir_volume_acompanhado';" `
  '^1$' `
  'o interruptor da gaveta vai dar erro no clique.'

Conferir 'disk_volumes preenchido na frota' `
  "select count(*) || ' maquina(s) com volumes' from public.machines_status where disk_volumes is not null;" `
  '^[1-9]' `
  'a coluna existe mas veio vazia em todas: o cartao cai na linha agregada de reserva. Confira se ha leitura de disco recente.'

# A primeira avaliacao feita agora, para nao esperar um minuto para saber.
Write-Host ''
Write-Host '   primeira avaliacao (feita agora, sem esperar o cron):'
$r = (Perguntar 'select public.avaliar_alertas()::text;' | Out-String).Trim()
Write-Host "      $r"
$abertos = (Perguntar "select count(*) from public.open_alerts where severity = 'critical';" | Out-String).Trim()
Write-Host "      alertas criticos em aberto agora: $abertos"

Write-Host ''
Write-Host '============================================================'
if ($falhas -gt 0) {
  Write-Host " $falhas CONFERENCIA(S) FALHARAM" -ForegroundColor Red
  Write-Host '============================================================'
  exit 1
}
Write-Host ' TUDO NO AR' -ForegroundColor Green
Write-Host '============================================================'
Write-Host ''
Write-Host '  ALERTA  a avaliacao roda a cada minuto. Uma maquina que desligar'
Write-Host '          abre alerta critico em ate ~1 min depois de ser considerada'
Write-Host '          offline (~130 s de silencio), e o painel toca.'
Write-Host '          Na barra lateral: Som (liga) e Alertas (ajusta).'
Write-Host ''
Write-Host '  DISCOS  abra uma maquina > secao DISCOS: cada volume tem o'
Write-Host '          interruptor "acompanhar". Desmarcado, o volume sai do numero'
Write-Host '          do cartao E dos alertas de disco.'
Write-Host ''
if ([int]$abertos -gt 0) {
  Write-Host "  Os $abertos alerta(s) criticos acima sao de maquinas que JA estavam" -ForegroundColor Yellow
  Write-Host '  offline. Eles nao vao tocar: a primeira carga da pagina nunca toca.' -ForegroundColor DarkGray
  Write-Host ''
}
