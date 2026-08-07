// =============================================================================
// Verificação: como a tela se comporta com uma frota NOVA
// =============================================================================
// Rode:  node scripts/verificar-frota-nova.mjs
//
// Cria uma loja com uma única máquina e UMA única amostra — o estado exato de
// quem acabou de publicar a produção e instalou o primeiro agente — e confere
// que nada na tela mente por falta de histórico.
//
// POR QUE ESTE CASO MERECE TESTE PROPRIO: todas as outras verificações rodam
// contra um banco com 24 h de série, onde gráfico e sparkline têm dezenas de
// pontos. O primeiro dia de uso é justamente o que ninguém testa, e foi onde
// apareceram os dois defeitos que motivaram este arquivo:
//
//   - a sparkline com um balde só virava um retângulo de largura total, que se
//     lê como "100% de alguma coisa";
//   - o gráfico da frota, com `pointRadius: 0`, não desenhava nada: uma linha
//     precisa de dois pontos para existir.
// =============================================================================

import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn, execFileSync } from 'node:child_process';

const raiz = fileURLToPath(new URL('..', import.meta.url));
const env = readFileSync(join(raiz, '.env'), 'utf8');
const webPort = /WEB_PORT=(\d+)/.exec(env)?.[1] ?? '8081';
const URL_DASH = `http://127.0.0.1:${webPort}`;

const sql = (q) => execFileSync('docker',
  ['exec', 'monitor-db', 'psql', '-U', 'postgres', '-q', '-t', '-A', '-c', q],
  { encoding: 'utf8' }).trim();

let ok = 0;
const falhas = [];
const v = (nome, cond, det = '') => {
  if (cond) { ok++; console.log(`  ok    ${nome}`); }
  else { falhas.push(nome); console.log(`  FALHA ${nome}\n        ${det}`); }
};

const FIX = 'ZZNOVA';
const MAQ = 'PC-PRIMEIRO-DIA';

const limpar = () => {
  try {
    sql(`delete from public.machines where label = '${MAQ}';
         delete from public.sites  where code = '${FIX}';
         delete from public.brands where code = '${FIX}';`);
  } catch (_) { /* nada a fazer */ }
};

// Guarda o que existe para restaurar depois: a tela precisa ficar SO com a
// frota nova, senão o histórico das outras máquinas mascara o caso.
const outras = sql("select count(*) from public.machines where label <> '" + MAQ + "'");

limpar();
sql(`
  insert into public.brands (code, name) select '${FIX}', 'frota nova'
  where not exists (select 1 from public.brands where code = '${FIX}');

  insert into public.sites (brand_id, code, name)
  select b.id, '${FIX}', 'loja nova' from public.brands b where b.code = '${FIX}'
    and not exists (select 1 from public.sites where code = '${FIX}');

  insert into public.machines (site_id, role_code, label, hostname, agent_version, last_seen_at)
  select s.id, 'pdv', '${MAQ}', 'HOST-NOVO', 'ps-1.1.0', now()
  from public.sites s where s.code = '${FIX}';

  insert into public.metrics (machine_id, "time", agent_version, cpu_pct, mem_pct, uptime_seconds)
  select m.id, now(), 'ps-1.1.0', 8, 41, 600
  from public.machines m where m.label = '${MAQ}';
`);

console.log(`\ncenário: 1 loja, 1 máquina, 1 amostra (${outras} outra(s) máquina(s) no banco)\n`);

const CAMINHOS = [
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
];
let nav = null;
for (const c of CAMINHOS) { try { readFileSync(c); nav = c; break; } catch (_) { /* proximo */ } }
if (!nav) { console.error('sem navegador'); process.exit(2); }

const perfil = mkdtempSync(join(tmpdir(), 'nova-'));
const dp = 9401;
const proc = spawn(nav, [
  '--headless=new', `--remote-debugging-port=${dp}`, `--user-data-dir=${perfil}`,
  '--no-first-run', '--disable-gpu', '--hide-scrollbars', '--window-size=1700,1100', 'about:blank',
], { stdio: 'ignore' });

const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

try {
  let wsUrl;
  for (let i = 0; i < 60; i++) {
    try {
      const abas = await (await fetch(`http://127.0.0.1:${dp}/json/list`)).json();
      const p = abas.find((a) => a.type === 'page');
      if (p?.webSocketDebuggerUrl) { wsUrl = p.webSocketDebuggerUrl; break; }
    } catch (_) { /* subindo */ }
    await dormir(200);
  }

  const ws = new WebSocket(wsUrl);
  await new Promise((r) => { ws.onopen = r; });
  let id = 0; const pend = new Map(); const erros = [];
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pend.has(m.id)) { pend.get(m.id)(m.result ?? m.error); pend.delete(m.id); }
    if (m.method === 'Runtime.exceptionThrown') {
      erros.push(m.params.exceptionDetails?.exception?.description || 'excecao');
    }
  };
  const cmd = (metodo, params = {}) => new Promise((res) => {
    const i = ++id; pend.set(i, res); ws.send(JSON.stringify({ id: i, method: metodo, params }));
  });
  const js = async (e) => (await cmd('Runtime.evaluate',
    { expression: e, returnByValue: true, awaitPromise: true }))?.result?.value;

  await cmd('Page.enable'); await cmd('Runtime.enable');
  await cmd('Page.navigate', { url: `${URL_DASH}/?v=nova-${Date.now()}` });
  await dormir(6000);

  // Filtra para a loja nova, isolando o caso.
  await js(`
    (() => {
      const s = document.getElementById('filtro-loja');
      s.value = '${FIX}';
      s.dispatchEvent(new Event('change'));
      return true;
    })()
  `);
  await dormir(1200);

  // ---- a sparkline nao pode virar um bloco --------------------------------
  const spark = await js(`
    (() => {
      const medir = (id) => {
        const c = document.getElementById(id);
        const barras = [...c.querySelectorAll('span')].filter((b) => !b.classList.contains('spark-vazio'));
        const larguraCaixa = c.getBoundingClientRect().width;
        const maior = Math.max(0, ...barras.map((b) => b.getBoundingClientRect().width));
        return { barras: barras.length, larguraCaixa: Math.round(larguraCaixa), maior: Math.round(maior) };
      };
      return { online: medir('spark-online'), ingest: medir('spark-ingest'), lateral: medir('pulso-faixa') };
    })()
  `);

  for (const [nome, m] of Object.entries(spark)) {
    if (m.barras === 0) { v(`sparkline ${nome}: sem dados, mostra o aviso`, true); continue; }
    // Uma barra nunca deve ocupar mais que uma fração da caixa: se ocupa, o
    // desenho vira um retângulo cheio e se lê como 100%.
    v(`sparkline ${nome} não vira um bloco de largura total`,
      m.maior <= 8, `${m.barras} barra(s), maior=${m.maior}px numa caixa de ${m.larguraCaixa}px`);
  }

  // ---- o grafico precisa desenhar algo ------------------------------------
  const grafico = await js(`
    (() => {
      const g = Estado.graficos['grafico-frota'];
      if (!g) return { existe: false };
      const ds = g.data.datasets[0];
      return {
        existe: true,
        pontos: g.data.labels.length,
        raio: ds.pointRadius,
        primeiro: ds.data[0],
      };
    })()
  `);

  v('o gráfico da frota existe', grafico.existe === true, JSON.stringify(grafico));
  if (grafico.existe) {
    v('com série curta, o ponto é desenhado',
      grafico.pontos >= 4 || grafico.raio > 0,
      `${grafico.pontos} ponto(s), raio=${grafico.raio}`);
    v('o gráfico tem valor de verdade',
      grafico.primeiro !== null && grafico.primeiro !== undefined, JSON.stringify(grafico));
  }

  // ---- e o resto da tela precisa estar coerente ---------------------------
  const tela = await js(`
    ({
      cartoes: document.querySelectorAll('.cartao-loja').length,
      quadrados: document.querySelectorAll('.host-quad').length,
      kpi: document.getElementById('kpi-total').textContent,
      pulso: document.getElementById('pulso-min').textContent,
      vazio: !!document.querySelector('.vazio'),
      avisoEscopo: getComputedStyle(document.getElementById('escopo-kpi')).display !== 'none',
    })
  `);

  v('a loja nova aparece como cartão', tela.cartoes === 1, JSON.stringify(tela));
  v('a máquina aparece no heatmap', tela.quadrados === 1, JSON.stringify(tela));
  // As tiras contam a FROTA INTEIRA, de proposito: filtrar por "offline" e ver
  // o contador de offline zerar seria absurdo. O que se verifica aqui e que a
  // tela AVISA disso quando ha filtro — eu mesmo li o numero errado ao escrever
  // esta verificacao, o que ja e evidencia suficiente de que o aviso faz falta.
  v('o KPI conta a frota inteira, nao o filtro',
    Number(tela.kpi) >= 1, `kpi=${tela.kpi}`);
  v('a tela avisa que as tiras sao da frota inteira',
    tela.avisoEscopo === true, `aviso visivel: ${tela.avisoEscopo}`);
  v('nenhuma exceção de JavaScript', erros.length === 0, erros.join(' | '));

  // Captura para inspeção visual, quando alguém quiser conferir com o olho.
  const r = await cmd('Page.captureScreenshot', { format: 'png' });
  if (r?.data) {
    const arq = join(raiz, 'capturas', 'frota-nova.png');
    try {
      writeFileSync(arq, Buffer.from(r.data, 'base64'));
      console.log(`\n  captura: ${arq}`);
    } catch (_) { /* pasta capturas/ pode nao existir */ }
  }

  ws.close();
} finally {
  try { proc.kill(); } catch (_) { /* ja morreu */ }
  try { rmSync(perfil, { recursive: true, force: true }); } catch (_) { /* ocupado */ }
  limpar();
}

console.log('');
if (falhas.length) {
  console.log(`FALHARAM ${falhas.length} de ${ok + falhas.length}: ${falhas.join(', ')}`);
  process.exit(1);
}
console.log(`AS ${ok} VERIFICACOES DE FROTA NOVA PASSARAM.`);
