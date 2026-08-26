<#
.SYNOPSIS
  Empurra a frota deste monitoramento para a API Sentinela do sistema principal,
  para as maquinas aparecerem la.

.DESCRIPTION
  Le o estado atual do NOSSO banco e faz um POST por maquina em
  /functions/v1/sentinela-ingest do projeto Sentinela, traduzindo os campos.

  AUTENTICACAO: aquele endpoint usa TOKEN DE AGENTE, um por maquina, emitido em
  Sentinela > Cadastros > Gerar token. Nao existe token global. Entao este script
  precisa de um arquivo com o token de cada maquina -- ver -ArquivoTokens.

  O QUE ELE NAO FAZ, DE PROPOSITO:

  Nao empurra maquina OFFLINE. O POST e um sinal de vida: quem recebe marca a
  maquina como vista AGORA. Mandar a ultima amostra de uma maquina desligada ha
  tres horas faria o painel do outro sistema mostra-la ONLINE para sempre, e ele
  nunca abriria alerta por ela -- o oposto do proposito. O silencio e a
  informacao; deixo o silencio chegar la tambem.

  Use -IncluirOffline apenas para uma carga inicial de INVENTARIO, sabendo que as
  offline vao aparecer como vistas agora ate o proximo ciclo.

  Nao empurra volume desmarcado aqui (machine_volumes.acompanhar = false). Se o D:
  de backup foi tirado da conta neste painel de proposito, manda-lo para la
  reintroduziria o mesmo alerta eterno no outro sistema.

.PARAMETER ArquivoTokens
  JSON { "NOME-DA-MAQUINA": "token", ... }. Padrao:
  %LOCALAPPDATA%\sentinela\tokens-espelho.json

  FORA do repositorio de proposito: sao credenciais de outro sistema, precisam
  viajar em texto claro (nao ha como hashear o que tem de ser enviado) e nao podem
  entrar em commit.

.PARAMETER Url
  Endpoint de ingestao do outro sistema.

.PARAMETER Maquina
  Filtra por trecho do nome. Padrao: todas.

.PARAMETER Simular
  Mostra exatamente o que seria enviado, e NAO envia. Use na primeira vez.

.PARAMETER IncluirOffline
  Envia tambem as offline. Leia o aviso acima antes.

.EXAMPLE
  .\scripts\espelhar-no-sentinela.ps1 -Simular

.EXAMPLE
  .\scripts\espelhar-no-sentinela.ps1
#>
[CmdletBinding()]
param(
  [string] $ArquivoTokens = "$env:LOCALAPPDATA\sentinela\tokens-espelho.json",
  [string] $Url = 'https://bieknqhxbecmakxgaspe.supabase.co/functions/v1/sentinela-ingest',
  [string] $Maquina = '%',
  [switch] $Simular,
  [switch] $IncluirOffline,
  [string] $UrlBanco,
  [System.Security.SecureString] $Senha
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

# ------------------------------------------------------------------ os tokens
$tokens = @{}
if (Test-Path $ArquivoTokens) {
  (Get-Content $ArquivoTokens -Raw | ConvertFrom-Json).PSObject.Properties |
    ForEach-Object { $tokens[$_.Name] = $_.Value }
}

if ($Simular) {
  Write-Host 'SIMULACAO: nada sera enviado.' -ForegroundColor Yellow
} elseif ($tokens.Count -eq 0) {
  Write-Host ''
  Write-Host "Nenhum token em: $ArquivoTokens" -ForegroundColor Red
  Write-Host ''
  Write-Host 'Cada maquina precisa do SEU token, emitido no outro sistema em'
  Write-Host 'Sentinela > Cadastros > Gerar token. Crie o arquivo assim:'
  Write-Host ''
  Write-Host '  {' -ForegroundColor DarkGray
  Write-Host '    "CAJU-ASN/CAJU-ASN": "eyJhbGciOi...",' -ForegroundColor DarkGray
  Write-Host '    "NAZO-ASA-SUL/SERVIDOR-NAZO-SUL": "eyJhbGciOi..."' -ForegroundColor DarkGray
  Write-Host '  }' -ForegroundColor DarkGray
  Write-Host ''
  Write-Host 'A chave e LOJA/MAQUINA, como o -Simular imprime.'
  Write-Host 'Rode com -Simular para ver os nomes exatos e o que seria enviado.'
  exit 1
} else {
  Write-Host "$($tokens.Count) token(s) carregado(s)" -ForegroundColor DarkGray
}

# --------------------------------------------------------------------- o banco
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

# O psql sai de dentro do contentor, e o Docker Desktop caiu tres vezes num dia
# de trabalho. Em vez de morrer com "npipe: cannot find the file", sobe o Docker e
# espera -- e se nao subir, diz o que fazer.
. (Join-Path $PSScriptRoot '_docker.ps1')

$psql = Get-Command psql -ErrorAction SilentlyContinue
$viaDocker = $null -eq $psql
if (-not (Assert-PsqlDisponivel)) { exit 1 }

# =============================================================================
# A traducao mora no SQL
# =============================================================================
# O de-para fica aqui, e nao no PowerShell, por dois motivos: da para ler os dois
# lados na mesma linha, e o resultado ja sai no formato exato que a outra API
# espera -- o script nao monta nada, so entrega.
#
# jsonb_strip_nulls no fim: campo que nao medimos vai AUSENTE, e nao null. Uma API
# que valida tipo costuma recusar null num campo numerico, e "ausente" e a verdade
# (nao medimos), enquanto null pode ser lido como zero do outro lado.
$sql = @'
\pset tuples_only on
\pset format unaligned
\pset fieldsep '|'

with alvo as (
  select ms.*
  from public.machines_status ms
  where ms.label ilike :'padrao'
    and ms.is_active
    and ms.last_sample_at is not null
    and (:incluir_offline or ms.status in ('online', 'degradado'))
)
select
  -- LOJA/MAQUINA, e nao so o nome: quatro nomes se repetem nesta frota.
  a.site_code || '/' || a.label as chave,
  a.label,
  a.status,
  jsonb_strip_nulls(jsonb_build_object(
    -- O outro sistema documenta "1.4.0"; o nosso e "ps-1.8.0". Mando so a parte
    -- numerica para nao arriscar uma validacao de formato do outro lado.
    'versao_agente', regexp_replace(coalesce(a.agent_version, ''), '^ps-', ''),
    'host', jsonb_build_object(
      'hostname', coalesce(a.hostname, a.label),
      'ip_lan',   a.ip_lan,
      'so_nome',  a.os_caption
    ),
    'metricas', jsonb_build_object(
      'cpu_pct',             a.cpu_pct,
      -- Reserva: mem_pct e preenchida pelo agente, nao derivada. Agente antigo
      -- deixa nula, e o campo sumiria do corpo (jsonb_strip_nulls). Com usado e
      -- total na mao, calcular e aritmetica honesta.
      'memoria_pct', coalesce(
        a.mem_pct,
        case when coalesce(a.mem_total_mb, 0) > 0
             then round(a.mem_used_mb::numeric * 100 / a.mem_total_mb, 1)
        end),
      'uptime_segundos',     a.uptime_seconds,
      'latencia_gateway_ms', a.gw_latency_ms
    ),
    'discos', (
      select jsonb_agg(jsonb_build_object(
               'unidade',  d.drive,
               'total_gb', round(d.total_gb)::int,
               'livre_gb', round(d.free_gb)::int,
               'smart_ok', d.smart_ok
             ) order by d.drive)
      from public.metrics_disks d
      left join public.machine_volumes mv
             on mv.machine_id = d.machine_id
            and mv.drive = upper(btrim(d.drive))
      where d.machine_id = a.machine_id
        and d."time" = a.last_sample_at
        -- Respeita a escolha feita NESTE painel: volume desmarcado aqui nao vai
        -- para la reintroduzir o alerta que a gente acabou de calar.
        and coalesce(mv.acompanhar, true)
        -- E o piso de tamanho, a MESMA regra da 0036 que o painel usa. Sem ele a
        -- particao de reserva do Windows viaja: a simulacao pegou um E: com 0 GB
        -- livres de 1 GB, que do outro lado seria um alerta critico de disco
        -- cheio por um volume que nao e disco.
        and (d.total_gb is null
             or d.total_gb >= public.app_setting_int('disk_ignore_below_gb'))
    ),
    'servicos', (
      select jsonb_agg(jsonb_build_object(
               'servico', sv.service_name,
               'rodando', sv.is_running
             ) order by sv.service_name)
      from public.metrics_services sv
      where sv.machine_id = a.machine_id
        and sv."time" = a.last_sample_at
    )
  ))::text as corpo
from alvo a
order by a.site_code, a.label;
'@

$tmp = Join-Path $env:TEMP 'espelho-sentinela.sql'
Set-Content -Path $tmp -Value $sql -Encoding utf8

$off = $IncluirOffline.IsPresent.ToString().ToLower()

function Consultar {
  # 'Continue' em volta do nativo: o psql escreve avisos no stderr e o PowerShell
  # 5.1 embrulha cada linha num ErrorRecord, o que com 'Stop' abortaria aqui.
  $antes = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($viaDocker) {
      docker cp $tmp monitor-db:/tmp/espelho.sql | Out-Null
      docker exec -e PGPASSWORD=$senhaNua monitor-db psql $UrlBanco `
        -v padrao="$Maquina" -v incluir_offline=$off -f /tmp/espelho.sql
    } else {
      $env:PGPASSWORD = $senhaNua
      & $psql.Source $UrlBanco -v padrao="$Maquina" -v incluir_offline=$off -f $tmp
    }
  } finally { $ErrorActionPreference = $antes }
}

Write-Host ''
Write-Host '== Lendo a frota ==' -ForegroundColor Cyan
$bruto = Consultar
$saiu = $LASTEXITCODE
$linhas = @($bruto | Where-Object { $_ -match '\|\{' })
Remove-Item $tmp -ErrorAction SilentlyContinue

# FALHA e VAZIO sao coisas diferentes, e confundir as duas chegou na tela: com o
# Docker parado o psql nunca rodou, e o script anunciou "nenhuma maquina para
# espelhar" -- que se le como "esta tudo bem, so nao ha nada". O codigo de saida e
# o unico sinal confiavel aqui.
if ($saiu -ne 0) {
  Write-Host ''
  Write-Host "A CONSULTA FALHOU (codigo $saiu). Nada foi lido, nada foi enviado." -ForegroundColor Red
  ($bruto | Select-Object -Last 6) | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
  Write-Host ''
  Write-Host 'Causas comuns: senha errada, monitor-db fora do ar, ou rede.' -ForegroundColor Yellow
  exit 1
}

if ($linhas.Count -eq 0) {
  Write-Host 'A consulta funcionou e nao devolveu maquina nenhuma.' -ForegroundColor Yellow
  if (-not $IncluirOffline) {
    Write-Host 'Sem -IncluirOffline so vao as online -- talvez seja isso.' -ForegroundColor DarkGray
  }
  exit 0
}

Write-Host "$($linhas.Count) maquina(s)"

# Quais nomes se repetem: decide se o nome puro pode servir de chave.
$repetidos = [System.Collections.Generic.HashSet[string]]::new()
$vistos = @{}
foreach ($l in $linhas) {
  $n = ($l -split '\|', 4)[1]
  if ($vistos.ContainsKey($n)) { [void]$repetidos.Add($n) } else { $vistos[$n] = 1 }
}
if ($repetidos.Count -gt 0) {
  Write-Host ("   ATENCAO: $($repetidos.Count) nome(s) repetido(s) na frota: " +
    ($repetidos -join ', ')) -ForegroundColor Yellow
  Write-Host '   Para esses, a chave do token TEM de ser LOJA/MAQUINA.' -ForegroundColor DarkGray
}
Write-Host ''
Write-Host '== Enviando ==' -ForegroundColor Cyan

$ok = 0; $erro = 0; $semToken = 0

foreach ($l in $linhas) {
  # Divido no maximo 4 vezes: o corpo e JSON e pode conter '|' dentro.
  $p = $l -split '\|', 4
  $chave = $p[0]; $nome = $p[1]; $estado = $p[2]; $corpo = $p[3]

  # A chave e LOJA/MAQUINA. Aceito tambem o nome puro, para o arquivo nao ficar
  # verboso nas maquinas de nome unico -- mas so quando ele NAO se repete na
  # frota, senao voltaria a colisao que a chave composta existe para evitar.
  $usar = $null
  if ($tokens.ContainsKey($chave)) { $usar = $chave }
  elseif ($tokens.ContainsKey($nome) -and -not $repetidos.Contains($nome)) { $usar = $nome }

  if (-not $usar) {
    $semToken++
    # Mostra a CHAVE que falta, nao so o nome: e o texto exato que vai no arquivo.
    $aviso = if ($repetidos.Contains($nome)) { ' (nome repetido na frota!)' } else { '' }
    Write-Host ("  {0,-34} SEM TOKEN{1}" -f $chave, $aviso) -ForegroundColor DarkYellow
    if ($Simular) { Write-Host "      $corpo" -ForegroundColor DarkGray }
    continue
  }

  if ($Simular) {
    Write-Host ("  {0,-34} [{1}] enviaria:" -f $chave, $estado) -ForegroundColor DarkGray
    Write-Host "      $corpo" -ForegroundColor DarkGray
    $ok++
    continue
  }

  try {
    $r = Invoke-RestMethod -Method Post -Uri $Url -TimeoutSec 25 `
      -Headers @{ Authorization = "Bearer $($tokens[$usar])" } `
      -ContentType 'application/json' -Body $corpo

    # A API documenta { "sucesso": true }. HTTP 200 com sucesso=false e RECUSA, e
    # tratar isso como sucesso esconderia o problema exatamente onde ele importa.
    if ($r.sucesso -eq $true) {
      $ok++
      Write-Host ("  {0,-34} ok" -f $chave) -ForegroundColor Green
    } else {
      $erro++
      Write-Host ("  {0,-34} RECUSADO: {1}" -f $chave, ($r | ConvertTo-Json -Compress -Depth 4)) -ForegroundColor Red
    }
  } catch {
    $erro++
    $st = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    Write-Host ("  {0,-34} ERRO HTTP {1}: {2}" -f $chave, $st, $_.Exception.Message) -ForegroundColor Red
  }
}

Write-Host ''
Write-Host '============================================================'
Write-Host (" {0} enviada(s) | {1} com erro | {2} sem token" -f $ok, $erro, $semToken)
Write-Host '============================================================'

if ($semToken -gt 0) {
  Write-Host ''
  Write-Host "Emita o token dessas $semToken maquina(s) no outro sistema" -ForegroundColor Yellow
  Write-Host '(Sentinela > Cadastros > Gerar token) e acrescente em:' -ForegroundColor Yellow
  Write-Host "  $ArquivoTokens" -ForegroundColor Yellow
  Write-Host 'Gerar novamente REVOGA o token anterior daquela maquina.' -ForegroundColor DarkGray
}
Write-Host ''
