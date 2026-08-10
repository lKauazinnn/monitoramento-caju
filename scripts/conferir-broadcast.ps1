# Prova do calculo de broadcast, com o defeito antigo do lado do novo.
$ErrorActionPreference = 'Stop'

function BroadcastNovo {
  param([string] $Ip, [int] $Prefixo)
  $b = [Net.IPAddress]::Parse($Ip).GetAddressBytes()
  $bc = New-Object byte[] 4
  $bits = 32 - $Prefixo
  for ($i = 3; $i -ge 0; $i--) {
    $n = [Math]::Min(8, $bits)
    $bc[$i] = $b[$i] -bor ((1 -shl $n) - 1)
    $bits -= $n
  }
  return ([Net.IPAddress]::new($bc)).ToString()
}

$casos = @(
  @{ ip = '192.168.14.138'; pfx = 24; esperado = '192.168.14.255' },
  @{ ip = '192.168.150.250'; pfx = 24; esperado = '192.168.150.255' },
  @{ ip = '10.0.5.37';      pfx = 16; esperado = '10.0.255.255'   },
  @{ ip = '172.16.9.4';     pfx = 22; esperado = '172.16.11.255'  },
  @{ ip = '10.1.2.3';       pfx = 8;  esperado = '10.255.255.255' },
  @{ ip = '192.168.1.10';   pfx = 30; esperado = '192.168.1.11'   },
  @{ ip = '192.168.1.10';   pfx = 25; esperado = '192.168.1.127'  }
)

$falhas = 0
foreach ($c in $casos) {
  $got = BroadcastNovo -Ip $c.ip -Prefixo $c.pfx
  $ok = $got -eq $c.esperado
  if (-not $ok) { $falhas++ }
  $marca = if ($ok) { 'ok    ' } else { 'FALHOU' }
  Write-Host ("  {0} {1}/{2} -> {3}  (esperado {4})" -f $marca, $c.ip, $c.pfx, $got, $c.esperado)
}

Write-Host ''
Write-Host 'E o defeito antigo, para nao ficar teoria:'
try {
  $m = [uint32]0xFFFFFFFF -shl 8
  Write-Host "  o codigo antigo devolveu $m -- entao o defeito era outro"
  $falhas++
} catch {
  Write-Host "  [uint32]0xFFFFFFFF estoura: $($_.Exception.Message)"
}
Write-Host ("  e 0xFFFFFFFF no PowerShell vale: {0} (tipo {1})" -f 0xFFFFFFFF, (0xFFFFFFFF).GetType().Name)

if ($falhas -gt 0) { Write-Host "`n$falhas falha(s)"; exit 1 }
Write-Host "`nOs $($casos.Count) casos de broadcast estao certos."
