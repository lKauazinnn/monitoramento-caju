import { readFileSync, mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';

const raiz = 'c:/Users/SUPORTE/Desktop/deashboard servidor';
const porta = /WEB_PORT=(\d+)/.exec(readFileSync(join(raiz, '.env'), 'utf8'))?.[1] ?? '8081';
mkdirSync(join(raiz, 'capturas'), { recursive: true });

let nav = null;
for (const c of ['C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
                 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe']) {
  try { readFileSync(c); nav = c; break; } catch (_) { /* proximo */ }
}
if (!nav) { console.error('sem navegador'); process.exit(2); }

const perfil = mkdtempSync(join(tmpdir(), 'cab-'));
const cdp = 9403;
const proc = spawn(nav, ['--headless=new', `--remote-debugging-port=${cdp}`,
  `--user-data-dir=${perfil}`, '--no-first-run', '--disable-gpu', '--hide-scrollbars',
  '--window-size=1500,1200', 'about:blank'], { stdio: 'ignore' });
const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

try {
  let ws;
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${cdp}/json/list`);
      const pg = (await r.json()).find((a) => a.type === 'page');
      if (pg?.webSocketDebuggerUrl) { ws = pg.webSocketDebuggerUrl; break; }
    } catch (_) { /* subindo */ }
    await dormir(200);
  }
  const sock = new WebSocket(ws);
  await new Promise((r) => { sock.onopen = r; });
  let id = 0; const pend = new Map();
  sock.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pend.has(m.id)) { pend.get(m.id)(m.result ?? m.error); pend.delete(m.id); }
  };
  const cmd = (method, params = {}) => new Promise((res) => {
    const meu = ++id; pend.set(meu, res);
    sock.send(JSON.stringify({ id: meu, method, params }));
  });
  const js = async (e) => (await cmd('Runtime.evaluate',
    { expression: e, returnByValue: true, awaitPromise: true }))?.result?.value;

  await cmd('Page.enable'); await cmd('Runtime.enable');
  await cmd('Page.navigate', { url: `http://127.0.0.1:${porta}/?v=${Date.now()}` });
  await dormir(5500);

  let falhas = 0;
  const ok = (b, m) => { console.log((b ? '  ok     ' : '  FALHOU ') + m); if (!b) falhas++; };

  const st = JSON.parse(await js(`
    (() => {
      const selos = [...document.querySelectorAll('.sf-selo')];
      const grade = document.querySelector('.grade-lojas');
      return JSON.stringify({
        titulo: document.getElementById('frota-titulo').textContent,
        sub: document.getElementById('frota-sub').textContent,
        direitaVisivel: !document.getElementById('frota-direita').hidden,
        selos: selos.map(s => s.textContent).join(' | '),
        zeros: selos.filter(s => s.classList.contains('sf-selo-zero')).length,
        // Cada selo tem que ter dica: e onde o operador descobre o que "atencao" quer dizer.
        comDica: selos.filter(s => s.title).length,
        faixa: document.getElementById('frota-largura').value,
        colunas: grade ? getComputedStyle(grade).gridTemplateColumns : '',
      });
    })()
  `));

  console.log(`  titulo: "${st.titulo}"`);
  console.log(`  sub:    "${st.sub}"`);
  console.log(`  selos:  ${st.selos}`);

  ok(st.titulo === 'Lojas monitoradas', `titulo do handoff ("${st.titulo}")`);
  ok(/leitura/.test(st.sub), `resumo anuncia a cadencia ("${st.sub}")`);
  ok(st.direitaVisivel, 'direita do cabecalho visivel na vista de lojas');
  ok(st.selos.split(' | ').length === 3 || st.selos.split(' | ').length === 4,
    `tres selos (mais "sem dados" quando houver): ${st.selos.split(' | ').length}`);
  ok(st.comDica === st.selos.split(' | ').length, `todo selo tem dica (${st.comDica})`);
  ok(st.zeros >= 1, `selo em zero fica apagado (${st.zeros} apagado(s))`);
  ok(st.faixa === '300', `densidade abre em 300 ("${st.faixa}")`);

  // ---- a densidade muda a grade e sobrevive ao recarregamento ----------------
  await js(`
    (() => {
      const f = document.getElementById('frota-largura');
      f.value = '420';
      f.dispatchEvent(new Event('input', { bubbles: true }));
    })()
  `);
  await dormir(400);
  const dep = JSON.parse(await js(`
    JSON.stringify({
      colunas: getComputedStyle(document.querySelector('.grade-lojas')).gridTemplateColumns,
      saida: document.getElementById('frota-largura-val').textContent,
      guardado: localStorage.getItem('monitor.larguraCartaoLoja'),
    })
  `));
  const nCols = dep.colunas.split(' ').length;
  ok(dep.saida === '420', `a saida acompanha o arraste ("${dep.saida}")`);
  ok(dep.guardado === '420', `gravou a preferencia ("${dep.guardado}")`);
  ok(nCols < st.colunas.split(' ').length,
    `cartao mais largo => menos colunas (${st.colunas.split(' ').length} -> ${nCols})`);

  await cmd('Page.navigate', { url: `http://127.0.0.1:${porta}/?v=${Date.now()}` });
  await dormir(5500);
  const volta = await js(`document.getElementById('frota-largura').value`);
  ok(volta === '420', `a densidade sobrevive ao recarregamento ("${volta}")`);

  // ---- fora da vista de lojas, a direita esconde -----------------------------
  await js(`document.querySelector('[data-modo="tabela"]').click()`);
  await dormir(900);
  const escondeu = await js(`document.getElementById('frota-direita').hidden`);
  ok(escondeu === true, 'a direita esconde na tabela densa');

  const r2 = await cmd('Page.captureScreenshot', { format: 'png' });
  if (r2?.data) {
    writeFileSync(join(raiz, 'capturas', '16-handoff-cabecalho.png'), Buffer.from(r2.data, 'base64'));
    console.log('\n  capturas/16-handoff-cabecalho.png');
  }

  console.log(falhas === 0 ? '\nO cabecalho esta conforme o handoff.' : `\n${falhas} falha(s).`);
  sock.close();
  process.exit(falhas === 0 ? 0 : 1);
} catch (e) {
  console.error('erro:', e.message);
  process.exit(1);
} finally {
  try { proc.kill(); } catch (_) { /* ja morreu */ }
  try { rmSync(perfil, { recursive: true, force: true }); } catch (_) { /* ocupado */ }
}
