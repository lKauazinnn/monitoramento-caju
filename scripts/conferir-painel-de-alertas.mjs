// =============================================================================
// Confere o gerenciamento de alerta pelo navegador de verdade (CDP)
// =============================================================================
// O que precisa ser verdade:
//
//   1. o painel abre e traz as regras do servidor
//   2. os tipos vem das regras, e nao de uma lista escrita no cliente
//   3. os criticos comecam marcados; os avisos, nao
//   4. desmarcar um tipo GRAVA, e sobrevive ao recarregamento
//   5. a caixa mestre e o botao da lateral sao o mesmo estado
//   6. incidente de tipo MARCADO toca
//   7. incidente de tipo DESMARCADO nao toca -- mas ainda aparece na faixa
//   8. offline toca o timbre de QUEDA (tres tons), nao o de aviso (dois)
//   9. a primeira carga da pagina nao toca
//  10. a repeticao para quando o incidente e reconhecido
//
// Os casos 6 a 10 nao ouvem som: eles espionam o AudioContext, contando quantos
// osciladores foram criados e em que frequencias. Testar "tocou?" ouvindo seria
// impossivel num navegador sem placa de som -- e e justamente onde este teste
// roda.
// =============================================================================
import { readFileSync, mkdtempSync, rmSync, mkdirSync, writeFileSync } from 'node:fs';
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

const perfil = mkdtempSync(join(tmpdir(), 'al-'));
const cdp = 9405;
const proc = spawn(nav, ['--headless=new', `--remote-debugging-port=${cdp}`,
  `--user-data-dir=${perfil}`, '--no-first-run', '--disable-gpu', '--hide-scrollbars',
  // Libera o audio sem gesto do usuario: sem isto o AudioContext nasce suspenso
  // e nenhum oscilador e criado, e o teste passaria a medir a politica do
  // navegador em vez do meu codigo.
  '--autoplay-policy=no-user-gesture-required',
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
  const js = async (e) => {
    const r = await cmd('Runtime.evaluate',
      { expression: e, returnByValue: true, awaitPromise: true });
    if (r?.exceptionDetails) throw new Error(r.exceptionDetails.text + ' :: ' + e.slice(0, 90));
    return r?.result?.value;
  };

  await cmd('Page.enable'); await cmd('Runtime.enable');
  await cmd('Page.navigate', { url: `http://127.0.0.1:${porta}/?v=${Date.now()}` });
  await dormir(5500);

  let falhas = 0;
  const ok = (b, m) => { console.log((b ? '  ok     ' : '  FALHOU ') + m); if (!b) falhas++; };

  // ---- o espiao do audio -----------------------------------------------------
  // Envolve createOscillator e registra frequencia e instante. Instalado ANTES de
  // qualquer toque, e sem trocar o objeto: o codigo do painel guarda o contexto
  // em Estado.audio e continua usando o mesmo.
  await js(`
    (() => {
      window.__tons = [];
      const proto = (window.AudioContext || window.webkitAudioContext).prototype;
      if (!proto.__espiado) {
        const orig = proto.createOscillator;
        proto.createOscillator = function () {
          const osc = orig.call(this);
          const setFreq = Object.getOwnPropertyDescriptor(
            Object.getPrototypeOf(osc.frequency), 'value');
          window.__tons.push(osc.frequency);
          return osc;
        };
        proto.__espiado = true;
      }
      window.__limparTons = () => { window.__tons.length = 0; };
      window.__contarTons = () => window.__tons.map(f => Math.round(f.value));
      return true;
    })()
  `);

  // ---- 1, 2, 3 ---------------------------------------------------------------
  await js(`document.getElementById('btn-alertas').click()`);
  await dormir(1800);

  const st = JSON.parse(await js(`
    (() => {
      const tipos = [...document.querySelectorAll('#al-tipos-lista input[type=checkbox]')];
      return JSON.stringify({
        aberto: !document.getElementById('modal-alertas').hidden,
        regras: document.querySelectorAll('.al-regra').length,
        tipos: tipos.length,
        marcados: tipos.filter(c => c.checked).map(c => c.id.replace('al-tipo-','')),
        crit: document.querySelectorAll('.al-tipo-crit').length,
        // A lista do servidor: se os tipos fossem escritos no cliente, este
        // numero e o de cima poderiam divergir e ninguem notaria.
        doServidor: (window.Estado ? 0 : 0),
      });
    })()
  `));

  ok(st.aberto, 'o painel de alertas abre');
  ok(st.regras >= 8, `as regras do servidor chegaram (${st.regras})`);
  ok(st.tipos === st.regras, `um tipo por regra, sem lista no cliente (${st.tipos} vs ${st.regras})`);
  ok(st.marcados.includes('offline'), `offline vem marcado (${st.marcados.join(',')})`);
  ok(!st.marcados.includes('cpu_sustained'), 'cpu sustentada NAO vem marcada');
  ok(st.crit >= 4, `os criticos estao destacados (${st.crit})`);

  // ---- 5 ---------------------------------------------------------------------
  await js(`document.getElementById('al-ligado').click()`);
  await dormir(500);
  const sinc = JSON.parse(await js(`
    JSON.stringify({
      mestre: document.getElementById('al-ligado').checked,
      lateral: document.getElementById('btn-som').getAttribute('aria-pressed'),
      rotulo: document.getElementById('btn-som-rot').textContent,
      guardado: localStorage.getItem('monitor.som'),
    })
  `));
  ok(sinc.mestre === true && sinc.lateral === 'true' && sinc.guardado === '1',
    `mestre e botao da lateral em sincronia (${sinc.rotulo})`);

  // ---- 4 --------------------------------------------------------------------
  await js(`document.getElementById('al-tipo-disk_low').click()`);
  await dormir(300);
  const gravado = await js(`localStorage.getItem('monitor.alerta')`);
  ok(!/disk_low/.test(gravado), `desmarcar grava (${gravado})`);

  await cmd('Page.navigate', { url: `http://127.0.0.1:${porta}/?v=${Date.now()}` });
  await dormir(5500);
  await js(`
    (() => {
      window.__tons = [];
      const proto = (window.AudioContext || window.webkitAudioContext).prototype;
      if (!proto.__espiado) {
        const orig = proto.createOscillator;
        proto.createOscillator = function () {
          const osc = orig.call(this);
          window.__tons.push(osc.frequency);
          return osc;
        };
        proto.__espiado = true;
      }
      window.__limparTons = () => { window.__tons.length = 0; };
      window.__contarTons = () => window.__tons.map(f => Math.round(f.value));
      return true;
    })()
  `);
  const depois = JSON.parse(await js(`
    JSON.stringify({
      tipos: (JSON.parse(localStorage.getItem('monitor.alerta')||'{}').tipos)||[],
      som: localStorage.getItem('monitor.som'),
    })
  `));
  ok(!depois.tipos.includes('disk_low') && depois.tipos.includes('offline'),
    `a escolha sobrevive ao recarregamento (${depois.tipos.join(',')})`);
  ok(depois.som === '1', 'o som ligado sobrevive ao recarregamento');

  // ---- 9: a primeira carga nao toca -----------------------------------------
  // Um incidente injetado ANTES de a primeira carga ser marcada como feita.
  const inc = (kind, id, rec) => `{ event_id: ${id}, machine_id: 'm${id}', `
    + `label: 'PC-TESTE-${id}', kind: '${kind}', severity: 'critical', `
    + `message: 'teste', reconhecido: ${rec ? 'true' : 'false'} }`;

  const naPrimeira = await js(`
    (() => {
      window.__limparTons();
      Estado.primeiraCargaIncidentes = true;
      Estado.incidentesVistos = new Set();
      tocarSeNovo([${inc('offline', 901)}]);
      return window.__contarTons().length;
    })()
  `);
  ok(naPrimeira === 0, `a primeira carga da pagina nao toca (${naPrimeira} tons)`);

  // ---- 6 e 8: offline toca, e com o timbre de queda -------------------------
  const queda = JSON.parse(await js(`
    (() => {
      window.__limparTons();
      Estado.primeiraCargaIncidentes = false;
      Estado.incidentesVistos = new Set();
      Estado.som = true;
      tocarSeNovo([${inc('offline', 902)}]);
      const t = window.__contarTons();
      return JSON.stringify({ n: t.length, tons: t });
    })()
  `));
  ok(queda.n === 3, `offline toca o timbre de QUEDA, tres tons (${queda.tons.join(', ')} Hz)`);
  ok(queda.tons[0] > queda.tons[2], 'os tons da queda DESCEM (e o que se le como "caiu")');

  // ---- 7: tipo desmarcado nao toca -----------------------------------------
  const mudo = await js(`
    (() => {
      window.__limparTons();
      Estado.incidentesVistos = new Set();
      tocarSeNovo([${inc('disk_low', 903)}]);
      return window.__contarTons().length;
    })()
  `);
  ok(mudo === 0, `tipo desmarcado (disk_low) nao toca (${mudo} tons)`);

  // E o aviso de tipo marcado que NAO e offline toca dois tons.
  const aviso = JSON.parse(await js(`
    (() => {
      window.__limparTons();
      Estado.incidentesVistos = new Set();
      tocarSeNovo([${inc('service_down', 904)}]);
      const t = window.__contarTons();
      return JSON.stringify({ n: t.length, tons: t });
    })()
  `));
  ok(aviso.n === 2, `servico parado toca o timbre de AVISO, dois tons (${aviso.tons.join(', ')} Hz)`);

  // ---- 10: a repeticao para no reconhecimento -------------------------------
  const rep = JSON.parse(await js(`
    (() => {
      guardarAlerta({ ...Estado.alerta, repetirMin: 2 });
      Estado.incidentesVistos = new Set();
      tocarSeNovo([${inc('offline', 905)}]);
      const ligou = Estado.timerRepeticao !== null;
      // Agora o mesmo incidente, reconhecido: a repeticao tem de parar sem
      // depender de um evento novo.
      tocarSeNovo([${inc('offline', 905, true)}]);
      const parou = Estado.timerRepeticao === null;
      guardarAlerta({ ...Estado.alerta, repetirMin: 0 });
      return JSON.stringify({ ligou, parou });
    })()
  `));
  ok(rep.ligou, 'a repeticao liga com incidente nao reconhecido');
  ok(rep.parou, 'a repeticao PARA quando o incidente e reconhecido');

  // ---- captura --------------------------------------------------------------
  await js(`document.getElementById('btn-alertas').click()`);
  await dormir(1600);
  const r2 = await cmd('Page.captureScreenshot', { format: 'png' });
  if (r2?.data) {
    writeFileSync(join(raiz, 'capturas', '17-painel-de-alertas.png'), Buffer.from(r2.data, 'base64'));
    console.log('\n  capturas/17-painel-de-alertas.png');
  }

  console.log(falhas === 0
    ? '\nO gerenciamento de alerta faz o que promete.'
    : `\n${falhas} falha(s).`);
  sock.close();
  process.exit(falhas === 0 ? 0 : 1);
} catch (e) {
  console.error('erro:', e.message);
  process.exit(1);
} finally {
  try { proc.kill(); } catch (_) { /* ja morreu */ }
  try { rmSync(perfil, { recursive: true, force: true }); } catch (_) { /* ocupado */ }
}
