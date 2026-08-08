// Confere o painel NOVO no ar: login real, dado de producao, sem violacao de
// CSP. O verificar-dashboard-publicado.mjs testa a estrutura do painel ANTIGO
// (ids como #app e #pulso-min) — ele nao se aplica mais, e sera reescrito.
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';

const URL_PROD = 'https://monitoramento-cajupar.vercel.app';
const [email, senha] = process.argv.slice(2);

const perfil = mkdtempSync(join(tmpdir(), 'prod-'));
const porta = 9397;
const proc = spawn('C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe', [
  '--headless=new', `--remote-debugging-port=${porta}`, `--user-data-dir=${perfil}`,
  '--no-first-run', '--disable-gpu', '--hide-scrollbars', '--window-size=1700,1200', 'about:blank',
], { stdio: 'ignore' });

const dormir = (ms) => new Promise((r) => setTimeout(r, ms));
let passou = 0; const falhas = [];
const v = (n, ok, d = '') => {
  if (ok) { passou++; console.log(`  ok    ${n}`); }
  else { falhas.push(n); console.log(`  FALHA ${n}\n        ${d}`); }
};

try {
  let wsUrl;
  for (let i = 0; i < 80; i++) {
    try {
      const abas = await (await fetch(`http://127.0.0.1:${porta}/json/list`)).json();
      const p = abas.find((a) => a.type === 'page');
      if (p?.webSocketDebuggerUrl) { wsUrl = p.webSocketDebuggerUrl; break; }
    } catch { /* subindo */ }
    await dormir(200);
  }

  const ws = new WebSocket(wsUrl);
  await new Promise((r) => { ws.onopen = r; });
  let id = 0; const pend = new Map(); const erros = []; const csp = [];
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pend.has(m.id)) { pend.get(m.id)(m.result ?? m.error); pend.delete(m.id); }
    if (m.method === 'Runtime.exceptionThrown') {
      erros.push(m.params.exceptionDetails?.exception?.description ?? 'exceção');
    }
    if (m.method === 'Log.entryAdded') {
      const t = m.params.entry.text ?? '';
      if (/Content Security Policy/i.test(t)) csp.push(t.slice(0, 160));
    }
  };
  const cmd = (metodo, params = {}) => new Promise((res) => {
    const i = ++id; pend.set(i, res); ws.send(JSON.stringify({ id: i, method: metodo, params }));
  });
  const js = async (e) => (await cmd('Runtime.evaluate',
    { expression: e, returnByValue: true, awaitPromise: true }))?.result?.value;

  await cmd('Page.enable'); await cmd('Runtime.enable'); await cmd('Log.enable');

  // Sem sessão: tem que ir para o login, não mostrar tela vazia.
  await cmd('Page.navigate', { url: `${URL_PROD}/?v=${Date.now()}` });
  await dormir(4000);
  const url1 = await js('location.pathname');
  v('sem sessão, o painel manda para o login', String(url1).includes('login'), String(url1));

  // Login de verdade, pelo formulário.
  await cmd('Page.navigate', { url: `${URL_PROD}/login.html?v=${Date.now()}` });
  await dormir(2500);
  await js(`
    document.getElementById('email').value = ${JSON.stringify(email)};
    document.getElementById('senha').value = ${JSON.stringify(senha)};
    document.querySelector('form').requestSubmit(); true
  `);
  await dormir(6000);

  const url2 = await js('location.pathname');
  v('o login leva ao painel', !String(url2).includes('login'), String(url2));

  await dormir(4000);
  const h1 = await js("document.querySelector('h1')?.textContent ?? ''");
  v('o painel novo montou', h1.includes('Centro de operações'), `h1="${h1}"`);

  const tiras = await js("document.body.innerText.includes('HOSTS ONLINE')");
  v('as tiras de KPI apareceram', tiras === true);

  // O dado veio do Supabase? A contagem de máquinas de produção é > 0.
  const temDado = await js(`
    (() => {
      const t = document.body.innerText;
      return /\\d+\\s*(de|máquina)/i.test(t) && !t.includes('Não consegui carregar');
    })()
  `);
  v('os dados vieram de produção', temDado === true);

  v('nenhuma violação de CSP', csp.length === 0, csp.join(' | '));
  v('nenhuma exceção de JavaScript', erros.length === 0, erros.slice(0, 2).join(' | '));

  const dest = 'C:/Users/SUPORTE/Desktop/deashboard servidor/capturas/noc';
  mkdirSync(dest, { recursive: true });
  const m = await cmd('Page.getLayoutMetrics');
  const foto = await cmd('Page.captureScreenshot', {
    format: 'png',
    clip: { x: 0, y: 0, width: 1700, height: Math.min(Math.ceil(m.cssContentSize.height), 1600), scale: 1 },
    captureBeyondViewport: true,
  });
  if (foto?.data) writeFileSync(join(dest, 'producao.png'), Buffer.from(foto.data, 'base64'));

  ws.close();
} catch (e) {
  falhas.push('exceção');
  console.log(`EXCEÇÃO: ${e.message}`);
} finally {
  try { proc.kill(); } catch { /* já morreu */ }
  try { rmSync(perfil, { recursive: true, force: true }); } catch { /* ocupado */ }
}

console.log(`\n${passou} ok, ${falhas.length} falha(s)`);
if (falhas.length) process.exit(1);
