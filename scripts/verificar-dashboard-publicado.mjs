// =============================================================================
// Verificação do dashboard PUBLICADO
// =============================================================================
// Rode:  node scripts/verificar-dashboard-publicado.mjs <url> <email> <senha>
//
// Abre a URL de produção num Chrome real, faz login e confere que a tela monta
// com dado vindo do Supabase.
//
// POR QUE NÃO BASTA O `curl` QUE JÁ RODOU: cabeçalho certo e arquivo no lugar
// provam que o deploy subiu, não que a página funciona. Um `connect-src` que
// esqueceu o domínio do Supabase, por exemplo, devolve 200 em tudo e deixa o
// dashboard eternamente "carregando" — sem erro nenhum fora do console.
// =============================================================================

import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';

const [, , urlArg, email, senha] = process.argv;
if (!urlArg || !email || !senha) {
  console.error('uso: node scripts/verificar-dashboard-publicado.mjs <url> <email> <senha>');
  process.exit(2);
}
const URL_BASE = urlArg.replace(/\/+$/, '');

let ok = 0;
const falhas = [];
const v = (nome, cond, det = '') => {
  if (cond) { ok++; console.log(`  ok    ${nome}`); }
  else { falhas.push(nome); console.log(`  FALHA ${nome}\n        ${det}`); }
};

const CAMINHOS = [
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
];
let nav = null;
for (const c of CAMINHOS) { try { readFileSync(c); nav = c; break; } catch (_) { /* proximo */ } }
if (!nav) { console.error('sem navegador'); process.exit(2); }

const perfil = mkdtempSync(join(tmpdir(), 'pub-'));
const dp = 9399;
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
      const p = abas.find((a) => a.type === 'page');
      if (p?.webSocketDebuggerUrl) { wsUrl = p.webSocketDebuggerUrl; break; }
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

  console.log(`\nverificando ${URL_BASE}\n`);

  // ---- sem sessão, o dashboard manda para o login --------------------------
  await cmd('Page.navigate', { url: `${URL_BASE}/?v=${Date.now()}` });
  await dormir(4500);

  const semSessao = await js('({ url: location.pathname, temForm: !!document.getElementById("form-login") })');
  v('sem sessão, o dashboard redireciona para o login',
    semSessao.temForm === true, JSON.stringify(semSessao));

  // ---- login ---------------------------------------------------------------
  violacoes.length = 0;
  erros.length = 0;

  await js(`
    (() => {
      document.getElementById('email').value = ${JSON.stringify(email)};
      document.getElementById('senha').value = ${JSON.stringify(senha)};
      document.getElementById('form-login').dispatchEvent(new Event('submit', { cancelable: true }));
      return true;
    })()
  `);
  await dormir(8000);

  const depois = await js(`
    ({
      temApp:  !!document.getElementById('app') && !document.getElementById('app').hidden,
      erroLogin: document.getElementById('erro') && !document.getElementById('erro').hidden
                   ? document.getElementById('erro').textContent : null,
      falha:   document.getElementById('falha-js') && !document.getElementById('falha-js').hidden
                   ? document.getElementById('falha-js-msg').textContent : null,
      usuario: document.getElementById('rotulo-usuario')?.textContent,
      kpi:     document.getElementById('kpi-total')?.textContent,
      tiras:   document.querySelectorAll('.tira').length,
      pulso:   document.getElementById('pulso-min')?.textContent,
    })
  `);

  v('login funciona no site publicado', depois.erroLogin === null, depois.erroLogin);
  v('o dashboard montou depois do login', depois.temApp === true, JSON.stringify(depois));
  v('nenhuma faixa de erro de script', depois.falha === null, depois.falha);
  v('o nome do usuário aparece', (depois.usuario || '').length > 0, `usuario="${depois.usuario}"`);
  v('as 6 tiras de KPI montaram', depois.tiras === 6, `${depois.tiras} tiras`);

  // Chamou o Supabase de verdade: o KPI e o pulso saem de RPC, não de HTML.
  v('os dados vieram do Supabase (KPI preenchido)',
    /^\d+$/.test(depois.kpi || ''), `kpi=${depois.kpi}`);
  v('o pulso de ingestão respondeu',
    depois.pulso !== undefined && depois.pulso !== '—' || depois.pulso === '0',
    `pulso=${depois.pulso}`);

  v('nenhuma violação de CSP em produção', violacoes.length === 0,
    violacoes.slice(0, 3).join('\n        '));
  v('nenhuma exceção de JavaScript', erros.length === 0, erros.slice(0, 3).join('\n        '));

  ws.close();
} finally {
  try { proc.kill(); } catch (_) { /* ja morreu */ }
  try { rmSync(perfil, { recursive: true, force: true }); } catch (_) { /* ocupado */ }
}

console.log('');
if (falhas.length) {
  console.log(`FALHARAM ${falhas.length} de ${ok + falhas.length}: ${falhas.join(', ')}`);
  process.exit(1);
}
console.log(`AS ${ok} VERIFICACOES DO DASHBOARD PUBLICADO PASSARAM.`);
