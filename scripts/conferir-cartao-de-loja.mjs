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

const perfil = mkdtempSync(join(tmpdir(), 'v3-'));
const cdp = 9401;
const proc = spawn(nav, ['--headless=new', `--remote-debugging-port=${cdp}`,
  `--user-data-dir=${perfil}`, '--no-first-run', '--disable-gpu', '--hide-scrollbars',
  '--window-size=1500,1200', 'about:blank'], { stdio: 'ignore' });
const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

try {
  let ws;
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${cdp}/json/list`);
      const p = (await r.json()).find((a) => a.type === 'page');
      if (p?.webSocketDebuggerUrl) { ws = p.webSocketDebuggerUrl; break; }
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
      const c = [...document.querySelectorAll('.cartao-loja')];
      const p = c[0];
      const met = p ? [...p.querySelectorAll('.cl-met')] : [];
      return JSON.stringify({
        cartoes: c.length,
        colEsq: document.querySelectorAll('.cl-col-estado').length,
        colDir: document.querySelectorAll('.cl-col-dados').length,
        faixas: document.querySelectorAll('.cl-faixa').length,
        fracao: p ? p.querySelector('.cl-fracao-n')?.textContent : '',
        metricas: met.length,
        rotulos: met.map(m => m.querySelector('.cl-met-rot').textContent).join(','),
        valores: met.map(m => m.querySelector('.cl-met-val').textContent).join(' | '),
        comBarra: met.filter(m => m.querySelector('.cl-met-fundo')).length,
        // Por rotulo, e nao a contagem: a contagem depende de quantas metricas
        // tem leitura nesta loja. Num cartao offline a CPU e '—' e NAO ter barra
        // e o comportamento certo -- foi essa suposicao que fez o teste falhar.
        barraPor: JSON.stringify(Object.fromEntries(met.map(m => [
          m.querySelector('.cl-met-rot').textContent,
          !!m.querySelector('.cl-met-fundo'),
        ]))),
        semValor: JSON.stringify(Object.fromEntries(met.map(m => [
          m.querySelector('.cl-met-rot').textContent,
          m.querySelector('.cl-met-val').textContent === '—',
        ]))),
        colunas: p ? getComputedStyle(p).gridTemplateColumns : '',
        alca: document.querySelectorAll('.cl-alca').length,
        lapis: document.querySelectorAll('.cl-cab-acoes .btn-icone').length,
      });
    })()
  `));

  console.log(`  ${st.cartoes} cartoes | colunas ${st.colunas}`);
  console.log(`  fracao "${st.fracao}" | metricas: ${st.rotulos}`);
  console.log(`  valores: ${st.valores}`);

  ok(st.colEsq === st.cartoes, `coluna de estado em cada cartao (${st.colEsq})`);
  ok(st.colDir === st.cartoes, `coluna de dados em cada cartao (${st.colDir})`);
  ok(st.faixas === st.cartoes, `faixa de situacao em cada cartao (${st.faixas})`);
  ok(/^96px/.test(st.colunas), `grade 96px + resto (${st.colunas})`);
  // As QUATRO do handoff sao um prefixo obrigatorio: 'saúde' pode vir depois
  // (quando ha medida), mas nunca pode empurrar nem reordenar as quatro.
  const rots = st.rotulos.split(',');
  ok(rots.slice(0, 4).join(',') === 'online,cpu,disco livre,rtt',
    `as quatro do handoff, nesta ordem (${st.rotulos})`);
  ok(rots.length === 4 || (rots.length === 5 && rots[4] === 'saúde'),
    `nada alem da saude foi acrescentado (${rots.length} linhas)`);
  // Saude so entra medida. '—' ali seria promessa de um dado que a maquina nao deu.
  const iSaude = rots.indexOf('saúde');
  if (iSaude >= 0) {
    const vals = st.valores.split(' | ');
    ok(/%$/.test(vals[iSaude]), `saude com valor medido ("${vals[iSaude]}")`);
  }
  // Handoff: "RTT: sem barra". Latencia nao tem escala de 0 a 100.
  const barra = JSON.parse(st.barraPor);
  const vazio = JSON.parse(st.semValor);
  ok(barra.rtt === false, 'rtt sem barra, como o handoff manda');
  ok(barra.online === true, 'online com barra (sempre tem leitura)');
  // Regra geral: barra existe exatamente quando ha leitura. Metrica com valor '—'
  // nao pode ter barra (seria uma barra de 0% mentindo que mediu zero), e metrica
  // com valor medido nao pode ficar sem, tirando o rtt.
  const coerente = Object.keys(barra).filter((r) => r !== 'rtt')
    .every((r) => barra[r] === !vazio[r]);
  ok(coerente, `barra existe exatamente quando ha leitura (${st.barraPor})`);
  ok(!!st.fracao, `fracao online presente ("${st.fracao}")`);
  // O que existia antes nao pode ter sumido.
  ok(st.alca === st.cartoes, `alca de arrasto preservada (${st.alca})`);
  ok(st.lapis === st.cartoes, `lapis de editar preservado (${st.lapis})`);

  const r2 = await cmd('Page.captureScreenshot', { format: 'png' });
  if (r2?.data) {
    writeFileSync(join(raiz, 'capturas', '15-handoff-v3.png'), Buffer.from(r2.data, 'base64'));
    console.log('\n  capturas/15-handoff-v3.png');
  }

  console.log(falhas === 0 ? '\nO cartao v3 esta conforme o handoff.' : `\n${falhas} falha(s).`);
  sock.close();
  process.exit(falhas === 0 ? 0 : 1);
} catch (e) {
  console.error('erro:', e.message);
  process.exit(1);
} finally {
  try { proc.kill(); } catch (_) { /* ja morreu */ }
  try { rmSync(perfil, { recursive: true, force: true }); } catch (_) { /* ocupado */ }
}
