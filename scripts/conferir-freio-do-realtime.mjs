// =============================================================================
// Confere o FREIO do realtime
// =============================================================================
// O caso que custou a cota do Supabase.
//
// O painel assina UPDATE de `machines`, e `register_metrics` atualiza `machines`
// em TODA ingestao. Com 45 maquinas -- e o pulso do agente mandando ate 4 vezes
// por minuto cada -- sao ~180 mensagens de realtime por minuto. A versao anterior
// chamava carregar() em cada uma, e carregar() faz TRES requisicoes com a frota
// inteira: ~540 requisicoes por minuto, por aba aberta. Numa TV ligada o dia todo,
// isso consome a cota do plano gratuito em poucos dias.
//
// Este teste nao precisa de dado nenhum no banco -- de proposito. A primeira versao
// dele estava dentro do teste de discos e morria no "a base local nao tem maquina",
// que nao tem relacao com o que ele mede.
// =============================================================================
// O que precisa ser verdade:
//
//   1. a gaveta lista os volumes com o interruptor "acompanhar" para admin
//   2. e SEM o interruptor para quem nao e admin -- mas ainda mostrando o estado
//   3. desmarcar um volume chama o servidor com o drive certo
//   4. e o cartao da loja passa a falar do OUTRO volume, na hora
//   5. o volume desmarcado continua na lista, apagado e marcado, para remarcar
//   6. a nota do cartao diz quantos volumes ficaram fora
//   7. desmarcado por ESCOLHA e "pequeno" por heuristica sao marcas diferentes
//   8. erro do servidor devolve a caixa ao estado anterior (nao ao clicado)
//
// O caso 8 e o que separa uma tela honesta de uma que mente: se o servidor
// recusa, a caixa NAO pode ficar marcada como a pessoa clicou -- senao a tela
// mostra uma escolha que nao existe no banco.
//
// Os dados vem de uma maquina que este teste injeta pelo proprio painel? Nao: ele
// finge as respostas do servidor no nivel do fetch. Testar contra a base exigiria
// dois volumes numa maquina local, e a base local tem um -- e um teste que so
// roda quando a base coopera nao roda.
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

const perfil = mkdtempSync(join(tmpdir(), 'freio-'));
const cdp = 9409;
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
  const js = async (e) => {
    const r = await cmd('Runtime.evaluate',
      { expression: e, returnByValue: true, awaitPromise: true });
    if (r?.exceptionDetails) throw new Error(r.exceptionDetails.text + ' :: ' + e.slice(0, 100));
    return r?.result?.value;
  };

  await cmd('Page.enable'); await cmd('Runtime.enable');
  await cmd('Page.navigate', { url: `http://127.0.0.1:${porta}/?v=${Date.now()}` });
  await dormir(5500);

  let falhas = 0;
  const ok = (b, m) => { console.log((b ? '  ok     ' : '  FALHOU ') + m); if (!b) falhas++; };

  const existe = await js('typeof recarregarPeloRealtime');
  if (existe !== 'function') throw new Error('recarregarPeloRealtime nao existe no painel');

  const freio = JSON.parse(await js(`
    (() => {
      // Conta as chamadas em vez de deixar carregar() bater na rede.
      let n = 0;
      const orig = carregar;
      carregar = async () => { n++; };

      // Estado limpo, e a aba "visivel" para o freio nao curto-circuitar.
      realtimeUltimaCarga = 0;
      if (realtimeTimer) { clearTimeout(realtimeTimer); realtimeTimer = null; }

      for (let i = 0; i < 200; i++) recarregarPeloRealtime();
      const imediatas = n;
      const agendada = realtimeTimer !== null;

      carregar = orig;
      if (realtimeTimer) { clearTimeout(realtimeTimer); realtimeTimer = null; }
      return JSON.stringify({ imediatas, agendada });
    })()
  `));

  ok(freio.imediatas === 1,
    `200 mensagens de realtime = 1 recarga imediata (${freio.imediatas})`);
  // UMA agendada em cima dela, e isso esta CERTO -- minha primeira versao deste
  // caso exigia zero e falhou com razao. A rajada rende duas recargas no total:
  // a imediata (borda de subida, para a mudanca parecer instantanea) e uma no fim
  // da janela, que traz o estado FINAL da rajada. Sem a do fim, a ultima mudanca
  // de 200 mensagens so apareceria na varredura de 60 s.
  //
  // Duas recargas para 200 mensagens e o resultado: 100 vezes menos.
  ok(freio.agendada === true,
    'e UMA agendada para o fim da janela (traz o estado final da rajada)');

  // A SEGUNDA rajada, dentro da janela, tem de AGENDAR uma -- e uma so.
  const segunda = JSON.parse(await js(`
    (() => {
      let n = 0;
      const orig = carregar;
      carregar = async () => { n++; };

      realtimeUltimaCarga = Date.now();   // acabou de carregar
      if (realtimeTimer) { clearTimeout(realtimeTimer); realtimeTimer = null; }

      for (let i = 0; i < 200; i++) recarregarPeloRealtime();
      const r = { imediatas: n, agendada: realtimeTimer !== null };

      carregar = orig;
      if (realtimeTimer) { clearTimeout(realtimeTimer); realtimeTimer = null; }
      return JSON.stringify(r);
    })()
  `));

  ok(segunda.imediatas === 0 && segunda.agendada === true,
    `dentro da janela: nenhuma imediata, uma agendada (${JSON.stringify(segunda)})`);


  console.log('');
  console.log(falhas === 0
    ? 'O freio do realtime segura a rajada.'
    : falhas + ' falha(s).');
  sock.close();
  process.exit(falhas === 0 ? 0 : 1);
} catch (e) {
  console.error('erro:', e.message);
  process.exit(1);
} finally {
  try { proc.kill(); } catch (_) { /* ja morreu */ }
  try { rmSync(perfil, { recursive: true, force: true }); } catch (_) { /* ocupado */ }
}
