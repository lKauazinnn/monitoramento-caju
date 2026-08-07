// =============================================================================
// Verificação da Content-Security-Policy do dashboard
// =============================================================================
// Rode:  node scripts/verificar-csp.mjs
//
// Serve dashboard/ com EXATAMENTE os cabeçalhos do vercel.json e abre a página
// num Chrome real, contando violações de CSP.
//
// POR QUE: uma CSP que quebra a página é pior que CSP nenhuma — a pessoa
// desabilita a política inteira para o site voltar a funcionar. E o modo de
// falha é traiçoeiro: a página carrega, mas um script bloqueado deixa metade da
// tela morta sem nenhum erro visível fora do console.
//
// O `connect-src` do teste inclui a API local, porque aqui o dashboard fala com
// a stack local. O resto dos cabeçalhos é idêntico ao de produção — e é no
// script-src e no style-src que a quebra aconteceria.
// =============================================================================

import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { createServer } from 'node:http';
import { extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';

const raiz = fileURLToPath(new URL('..', import.meta.url));
const dash = join(raiz, 'dashboard');
const env = readFileSync(join(raiz, '.env'), 'utf8');
const apiPort = /API_PORT=(\d+)/.exec(env)?.[1] ?? '3001';

const vercel = JSON.parse(readFileSync(join(dash, 'vercel.json'), 'utf8'));
const cabGerais = vercel.headers.find((h) => h.source === '/(.*)').headers;

let ok = 0;
const falhas = [];
const v = (nome, cond, det = '') => {
  if (cond) { ok++; console.log(`  ok    ${nome}`); }
  else { falhas.push(nome); console.log(`  FALHA ${nome}\n        ${det}`); }
};

const TIPOS = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
};

const PORTA = 8124;
const servidor = createServer((req, res) => {
  let p = decodeURIComponent(req.url.split('?')[0]);
  if (p === '/') p = '/index.html';

  let corpo;
  try {
    corpo = readFileSync(join(dash, p));
  } catch (_) {
    res.writeHead(404); res.end('nao encontrado'); return;
  }

  const cab = { 'content-type': TIPOS[extname(p)] || 'application/octet-stream' };
  for (const h of cabGerais) {
    // Só a conexão muda: aqui o alvo é a stack local, lá é o Supabase.
    cab[h.key] = h.key === 'Content-Security-Policy'
      ? h.value.replace("connect-src 'self'", `connect-src 'self' http://127.0.0.1:${apiPort}`)
      : h.value;
  }
  res.writeHead(200, cab);
  res.end(corpo);
});
await new Promise((r) => servidor.listen(PORTA, '127.0.0.1', r));

const CAMINHOS = [
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
];
let nav = null;
for (const c of CAMINHOS) { try { readFileSync(c); nav = c; break; } catch (_) { /* proximo */ } }
if (!nav) { console.error('sem navegador'); process.exit(2); }

const perfil = mkdtempSync(join(tmpdir(), 'csp-'));
const dp = 9388;
const proc = spawn(nav, [
  '--headless=new', `--remote-debugging-port=${dp}`, `--user-data-dir=${perfil}`,
  '--no-first-run', '--disable-gpu', '--window-size=1700,1100', 'about:blank',
], { stdio: 'ignore' });

const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

try {
  let wsUrl;
  for (let i = 0; i < 60; i++) {
    try {
      const abas = await (await fetch(`http://127.0.0.1:${dp}/json/list`)).json();
      const pg = abas.find((a) => a.type === 'page');
      if (pg?.webSocketDebuggerUrl) { wsUrl = pg.webSocketDebuggerUrl; break; }
    } catch (_) { /* subindo */ }
    await dormir(200);
  }

  const ws = new WebSocket(wsUrl);
  await new Promise((r) => { ws.onopen = r; });

  let id = 0;
  const pend = new Map();
  const violacoes = [];
  const erros = [];

  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pend.has(m.id)) { pend.get(m.id)(m.result ?? m.error); pend.delete(m.id); return; }

    // A violação de CSP chega como entrada de log da categoria "security".
    if (m.method === 'Log.entryAdded') {
      const e = m.params.entry;
      if (/Content Security Policy|Refused to/i.test(e.text)) violacoes.push(e.text);
      else if (e.level === 'error' && e.source !== 'network') erros.push(`${e.source}: ${e.text}`);
    }
    if (m.method === 'Runtime.exceptionThrown') {
      erros.push(m.params.exceptionDetails?.exception?.description || 'excecao');
    }
  };

  const cmd = (metodo, params = {}) => new Promise((res) => {
    const i = ++id; pend.set(i, res); ws.send(JSON.stringify({ id: i, method: metodo, params }));
  });
  const js = async (e) => (await cmd('Runtime.evaluate',
    { expression: e, returnByValue: true, awaitPromise: true }))?.result?.value;

  await cmd('Runtime.enable'); await cmd('Log.enable'); await cmd('Page.enable');

  console.log(`\nservindo dashboard/ com os cabeçalhos do vercel.json em :${PORTA}\n`);

  for (const pagina of ['/', '/login.html']) {
    violacoes.length = 0;
    erros.length = 0;

    await cmd('Page.navigate', { url: `http://127.0.0.1:${PORTA}${pagina}?v=csp-${Date.now()}` });
    await dormir(4500);

    v(`${pagina} sem violação de CSP`, violacoes.length === 0,
      violacoes.slice(0, 3).join('\n        '));
    v(`${pagina} sem exceção de JavaScript`, erros.length === 0,
      erros.slice(0, 3).join('\n        '));
  }

  // A página tem de estar VIVA, e não apenas sem erro: um script bloqueado pela
  // CSP deixa o DOM montado e a tela morta.
  await cmd('Page.navigate', { url: `http://127.0.0.1:${PORTA}/?v=vivo-${Date.now()}` });
  await dormir(5000);

  const vivo = await js(`
    ({
      build:   !!(window.MONITOR_CONFIG),
      chart:   typeof window.Chart === 'function',
      estilo:  getComputedStyle(document.body).backgroundColor,
      kpi:     document.getElementById('kpi-total')?.textContent,
      tiras:   document.querySelectorAll('.tira').length,
    })
  `);

  v('config.js carregou apesar da CSP', vivo.build === true, JSON.stringify(vivo));
  v('Chart.js carregou apesar da CSP', vivo.chart === true, JSON.stringify(vivo));
  v('styles.css foi aplicado', vivo.estilo !== 'rgba(0, 0, 0, 0)' && vivo.estilo !== '',
    `background=${vivo.estilo}`);
  v('a interface montou', vivo.tiras === 6, `${vivo.tiras} tiras de KPI`);

  ws.close();
} finally {
  try { proc.kill(); } catch (_) { /* ja morreu */ }
  servidor.close();
  try { rmSync(perfil, { recursive: true, force: true }); } catch (_) { /* ocupado */ }
}

console.log('');
if (falhas.length) {
  console.log(`FALHARAM ${falhas.length} de ${ok + falhas.length}: ${falhas.join(', ')}`);
  process.exit(1);
}
console.log(`AS ${ok} VERIFICACOES DE CSP PASSARAM.`);
