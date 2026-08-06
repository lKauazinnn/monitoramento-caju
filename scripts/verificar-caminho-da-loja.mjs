// =============================================================================
// Ensaio do caminho que o PC da loja percorre
// =============================================================================
// Rode:  node scripts/verificar-caminho-da-loja.mjs [ip] [porta]
//
// Ensaia, do lado do servidor, exatamente o que o PC da loja vai fazer:
// baixar o instalador, baixar o agente, e enviar uma amostra com o token dele
// mais o segredo compartilhado. Se isto passa, o que sobra e so o caminho de
// rede ate a outra maquina — que o firewall acabou de liberar.
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

const raiz = fileURLToPath(new URL('..', import.meta.url));

/**
 * Endereço da ingestão.
 *
 * Vem do BANCO, que é a mesma fonte que o dashboard usa para montar o comando de
 * instalação. Cravar o IP aqui faria o ensaio continuar verde depois de a
 * máquina trocar de rede — exatamente quando ele precisaria falhar.
 */
function enderecoDaIngestao() {
  if (process.argv[2]) {
    return `http://${process.argv[2]}:${process.argv[3] || 3010}`;
  }
  const url = execFileSync('docker',
    ['exec', 'monitor-db', 'psql', '-U', 'postgres', '-t', '-A', '-c',
      'select ingest_url from public.ingest_config'],
    { encoding: 'utf8' }).trim();

  if (!url) {
    console.error('ingest_config vazio. Rode scripts/dev-up.ps1 primeiro.');
    process.exit(2);
  }
  return url.replace(/\/+$/, '');
}

const BASE = enderecoDaIngestao();
console.log(`\nensaiando contra ${BASE}\n`);

const sql = (q) => execFileSync('docker',
  ['exec', 'monitor-db', 'psql', '-U', 'postgres', '-t', '-A', '-c', q],
  { encoding: 'utf8' }).trim();

let ok = 0; const falhas = [];
const v = (nome, cond, det = '') => {
  if (cond) { ok++; console.log(`  ok    ${nome}`); }
  else { falhas.push(nome); console.log(`  FALHA ${nome}\n        ${det}`); }
};

// ---- 1. o endpoint responde pelo IP da rede (nao por loopback) -------------
try {
  const h = await (await fetch(`${BASE}/healthz`)).json();
  v('healthz responde pelo IP da LAN', h.ok === true, JSON.stringify(h));
} catch (e) {
  v('healthz responde pelo IP da LAN', false, e.message);
}

// ---- 2. os dois scripts que o comando baixa --------------------------------
for (const [arq, marca] of [['instalar.ps1', 'param('], ['agente.ps1', 'NovaAmostra']]) {
  try {
    const r = await fetch(`${BASE}/${arq}`);
    const bruto = Buffer.from(await r.arrayBuffer());
    const t = bruto.toString('utf8');

    v(`${arq} baixa pelo IP da LAN`, r.ok && t.length > 1000, `HTTP ${r.status}, ${t.length} bytes`);
    v(`${arq} tem conteudo de PowerShell`, t.includes(marca), `procurava ${marca}`);

    // SEM BOM. O comando de instalacao faz `[scriptblock]::Create((irm ...))`, e
    // um BOM no inicio vira o primeiro CARACTERE do texto: com algo antes dele,
    // `param()` deixa de ser a primeira instrucao e o PowerShell recusa o bloco
    // inteiro com "Token 'param' inesperado". Foi assim que a instalacao falhou
    // na primeira tentativa real, e nenhuma verificacao pegava.
    v(`${arq} servido SEM BOM`,
      !(bruto[0] === 0xEF && bruto[1] === 0xBB && bruto[2] === 0xBF),
      `primeiros bytes: ${[...bruto.slice(0, 3)].map((x) => x.toString(16)).join(' ')}`);

    if (arq === 'agente.ps1') {
      v('agente baixado forca TLS 1.2/1.3', t.includes('SecurityProtocol'));
    }
  } catch (e) {
    v(`${arq} baixa pelo IP da LAN`, false, e.message);
  }
}

// ---- 2b. o PowerShell CONSEGUE montar o scriptblock? -----------------------
//
// A verificacao definitiva, e a que faltava: em vez de inspecionar o texto,
// manda o proprio PowerShell fazer exatamente o que o comando de instalacao faz
// — baixar e chamar [scriptblock]::Create. Se ele recusar, o motivo aparece
// aqui, e nao na loja.
//
// `Create` apenas ANALISA; nada e executado, porque o bloco nao e invocado.
for (const arq of ['instalar.ps1', 'agente.ps1']) {
  const ps = `
    $ErrorActionPreference = 'Stop'
    try {
      $t = Invoke-RestMethod -Uri '${BASE}/${arq}' -TimeoutSec 20
      $null = [scriptblock]::Create($t)
      'OK'
    } catch {
      'ERRO: ' + $_.Exception.Message.Split([char]10)[0]
    }`;

  let saida = '';
  try {
    saida = execFileSync('powershell',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', ps],
      { encoding: 'utf8' }).trim();
  } catch (e) {
    saida = `ERRO: ${e.message}`;
  }

  v(`o PowerShell analisa ${arq} como scriptblock`, saida.startsWith('OK'), saida.slice(0, 200));
}

// ---- 3. token de uma maquina descartavel -----------------------------------
const codigo = 'ZZENSAIO';
sql(`insert into public.brands (code,name) select '${codigo}','ensaio'
     where not exists (select 1 from public.brands where code='${codigo}')`);
sql(`insert into public.sites (brand_id,code,name)
     select b.id,'${codigo}','ensaio' from public.brands b where b.code='${codigo}'
       and not exists (select 1 from public.sites where code='${codigo}')`);

const linha = sql(`select t.token from public.provision_machine('${codigo}','PC-ENSAIO','pdv','ensaio',true) t`);
const token = (linha.split('\n').find((l) => l.startsWith('mon_')) || '').trim();
v('token emitido para a maquina de ensaio', token.startsWith('mon_'), `token=${token.slice(0, 12)}`);

// ---- 4. o segredo que o dashboard entrega ----------------------------------
const segredo = sql('select shared_secret from public.ingest_config');
const segredoContainer = execFileSync('docker',
  ['exec', 'monitor-ingest', 'printenv', 'INGEST_SHARED_SECRET'], { encoding: 'utf8' }).trim();
v('segredo do dashboard e o que o endpoint exige', segredo === segredoContainer,
  `banco=${segredo.slice(0, 6)}... endpoint=${segredoContainer.slice(0, 6)}...`);

// ---- 5. o POST que o agente faz a cada minuto ------------------------------
const agora = new Date().toISOString();
const envelope = {
  agent_version: 'ensaio-1.0.0',
  sent_at: agora,
  machine: { hostname: 'PC-ENSAIO', os_caption: 'Microsoft Windows 11 Pro', ip_lan: '192.168.14.99' },
  samples: [{ t: agora, cpu_pct: 7.5, mem_pct: 41.2, uptime_seconds: 1234 }],
};

async function enviar(cabecalhos) {
  const r = await fetch(BASE, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...cabecalhos },
    body: JSON.stringify(envelope),
  });
  return { status: r.status, corpo: await r.text() };
}

const bom = await enviar({ 'x-monitor-secret': segredo, authorization: `Bearer ${token}` });
v('INGESTAO REAL pelo IP da LAN aceita a amostra', bom.status === 200, `HTTP ${bom.status} ${bom.corpo.slice(0, 160)}`);
if (bom.status === 200) {
  const d = JSON.parse(bom.corpo);
  v('a amostra foi contada como aceita', d.accepted >= 1, bom.corpo);
}

// ---- 6. as duas negacoes ---------------------------------------------------
const semSegredo = await enviar({ 'x-monitor-secret': 'errado-de-proposito', authorization: `Bearer ${token}` });
v('segredo errado e recusado com 401', semSegredo.status === 401, `HTTP ${semSegredo.status}`);

const tokenRuim = await enviar({ 'x-monitor-secret': segredo, authorization: 'Bearer mon_naoexiste' });
v('token invalido e recusado com 401', tokenRuim.status === 401, `HTTP ${tokenRuim.status}`);

// ---- 7. chegou no banco ----------------------------------------------------
const gravou = sql(`select count(*) from public.metrics s
  join public.machines m on m.id=s.machine_id where m.label='PC-ENSAIO'`);
v('a amostra esta gravada em metrics', Number(gravou) >= 1, `linhas=${gravou}`);

// ---- limpeza ---------------------------------------------------------------
sql(`delete from public.machines where label='PC-ENSAIO'`);
sql(`delete from public.sites where code='${codigo}'`);
sql(`delete from public.brands where code='${codigo}'`);
console.log('  (maquina de ensaio removida)');

console.log('');
if (falhas.length) {
  console.log(`FALHARAM ${falhas.length} de ${ok + falhas.length}: ${falhas.join(', ')}`);
  process.exit(1);
}
console.log(`AS ${ok} VERIFICACOES DO CAMINHO DA LOJA PASSARAM.`);
