// =============================================================================
// Verificacao: remover maquina e remover loja pela interface
// =============================================================================
// Rode com:  node scripts/verificar-remocao.mjs
//
// Cria uma marca, uma loja e uma maquina descartaveis, exercita os dois botoes
// de remocao no navegador de verdade e confere no banco. Verifica tambem que UM
// clique nao remove nada — a confirmacao em duas etapas e a unica protecao
// contra apagar historico por engano, e protecao que ninguem testa nao e
// protecao.
//
// Limpa o que criou mesmo quando falha.
// =============================================================================
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn, execFileSync } from 'node:child_process';

import { fileURLToPath } from 'node:url';

const raiz = fileURLToPath(new URL('..', import.meta.url));
const env = readFileSync(join(raiz, '.env'), 'utf8');
const webPort = /WEB_PORT=(\d+)/.exec(env)?.[1] ?? '8081';
const URL_DASH = `http://127.0.0.1:${webPort}`;

const sql = (q) => execFileSync('docker',
  ['exec', 'monitor-db', 'psql', '-U', 'postgres', '-t', '-A', '-c', q],
  { encoding: 'utf8' }).trim();

let passou = 0; const falhas = [];
const verificar = (nome, ok, det = '') => {
  if (ok) { passou++; console.log(`  ok    ${nome}`); }
  else { falhas.push(nome); console.log(`  FALHA ${nome}\n        ${det}`); }
};

const perfil = mkdtempSync(join(tmpdir(), 'rem-'));
const porta = 9377;
const proc = spawn('C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe', [
  '--headless=new', `--remote-debugging-port=${porta}`, `--user-data-dir=${perfil}`,
  '--no-first-run', '--disable-gpu', '--window-size=1700,1100', 'about:blank',
], { stdio: 'ignore' });

const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

try {
  let wsUrl;
  for (let i = 0; i < 80; i++) {
    try {
      const abas = await (await fetch(`http://127.0.0.1:${porta}/json/list`)).json();
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
  const cmd = (method, params = {}) => new Promise((res) => {
    const i = ++id; pend.set(i, res); ws.send(JSON.stringify({ id: i, method, params }));
  });
  const js = async (e) => (await cmd('Runtime.evaluate',
    { expression: e, returnByValue: true, awaitPromise: true }))?.result?.value;

  await cmd('Page.enable'); await cmd('Runtime.enable');

  // ---- alvo descartavel, criado agora ------------------------------------
  const codigo = `ZZDEL${Date.now().toString().slice(-5)}`;
  sql(`insert into public.brands (code,name) values ('${codigo}','teste remocao') on conflict do nothing`);
  sql(`insert into public.sites (brand_id,code,name)
       select b.id,'${codigo}','loja de teste' from public.brands b where b.code='${codigo}'`);
  sql(`insert into public.machines (site_id,role_code,label)
       select s.id,'pdv','MAQ-TESTE-REMOCAO' from public.sites s where s.code='${codigo}'`);
  console.log(`  alvo criado: loja ${codigo} com 1 maquina`);

  await cmd('Page.navigate', { url: `${URL_DASH}/?v=rem-${Date.now()}` });
  await dormir(5000);

  // ---- 1. remover MAQUINA pelo painel ------------------------------------
  const abriu = await js(`
    (() => {
      const q = [...document.querySelectorAll('.host-quad')]
        .find(x => (x.getAttribute('aria-label')||'').includes('MAQ-TESTE-REMOCAO'));
      if (!q) return 'quadrado nao encontrado';
      q.click();
      return 'ok';
    })()
  `);
  verificar('quadrado do host abre o painel', abriu === 'ok', String(abriu));
  await dormir(2200);

  const zona = await js(`
    ({
      visivel: getComputedStyle(document.getElementById('zona-perigo')).display !== 'none',
      titulo: document.getElementById('painel-titulo').textContent,
      rotulo: document.getElementById('btn-remover-maquina').textContent,
    })
  `);
  verificar('zona de perigo aparece para admin', zona.visivel === true, JSON.stringify(zona));
  verificar('painel e o da maquina de teste', zona.titulo === 'MAQ-TESTE-REMOCAO', zona.titulo);

  // Um clique so ARMA: nao pode remover.
  await js("document.getElementById('btn-remover-maquina').click(); true");
  await dormir(500);

  const armado = await js(`
    ({
      classe: document.getElementById('btn-remover-maquina').className,
      rotulo: document.getElementById('btn-remover-maquina').textContent,
    })
  `);
  verificar('primeiro clique apenas ARMA', armado.classe.includes('armado'), JSON.stringify(armado));
  verificar('o rotulo avisa o que vai acontecer',
    /confirmar/i.test(armado.rotulo), armado.rotulo);

  const aindaExiste = sql(`select count(*) from public.machines where label='MAQ-TESTE-REMOCAO'`);
  verificar('um clique NAO remove nada', aindaExiste === '1', `count=${aindaExiste}`);

  // Segundo clique remove.
  await js("document.getElementById('btn-remover-maquina').click(); true");
  await dormir(3000);

  const removida = sql(`select count(*) from public.machines where label='MAQ-TESTE-REMOCAO'`);
  verificar('segundo clique remove a maquina', removida === '0', `count=${removida}`);

  const painelFechou = await js(
    "getComputedStyle(document.getElementById('painel')).display === 'none'");
  verificar('painel fecha depois de remover', painelFechou === true);

  // ---- 2. remover LOJA pelo cartao ---------------------------------------
  await dormir(1500);
  const achouLixeira = await js(`
    (() => {
      const c = [...document.querySelectorAll('.cartao-loja')]
        .find(x => x.textContent.includes('${codigo}'));
      if (!c) return 'cartao da loja nao encontrado';
      const b = c.querySelector('.cl-remover');
      if (!b) return 'sem botao de remover';
      b.click();
      return 'ok';
    })()
  `);
  verificar('cartao da loja tem botao de remover', achouLixeira === 'ok', String(achouLixeira));
  await dormir(500);

  const lojaAinda = sql(`select count(*) from public.sites where code='${codigo}'`);
  verificar('um clique na lixeira NAO remove a loja', lojaAinda === '1', `count=${lojaAinda}`);

  await js(`
    (() => {
      const c = [...document.querySelectorAll('.cartao-loja')]
        .find(x => x.textContent.includes('${codigo}'));
      c.querySelector('.cl-remover').click();
      return true;
    })()
  `);
  await dormir(3000);

  const lojaFoi = sql(`select count(*) from public.sites where code='${codigo}'`);
  verificar('segundo clique remove a loja', lojaFoi === '0', `count=${lojaFoi}`);

  const marcaFoi = sql(`select count(*) from public.brands where code='${codigo}'`);
  verificar('marca que ficou vazia sai junto', marcaFoi === '0', `count=${marcaFoi}`);

  // ---- 3. auditoria sobreviveu -------------------------------------------
  const trilha = sql(`select count(*) from public.events
    where kind in ('machine_removed','site_removed')
      and (payload->>'label' = 'MAQ-TESTE-REMOCAO' or payload->>'site_code' = '${codigo}')`);
  verificar('remocao ficou registrada em events', Number(trilha) >= 2, `eventos=${trilha}`);

  verificar('nenhuma excecao de JavaScript', erros.length === 0, erros.join(' | '));

  // limpeza de garantia
  sql(`delete from public.machines where label='MAQ-TESTE-REMOCAO'`);
  sql(`delete from public.sites where code='${codigo}'`);
  sql(`delete from public.brands where code='${codigo}'`);

  ws.close();
} finally {
  try { proc.kill(); } catch (_) { /* ja morreu */ }
  try { rmSync(perfil, { recursive: true, force: true }); } catch (_) { /* ocupado */ }
}

console.log('');
if (falhas.length) {
  console.log(`FALHARAM ${falhas.length} de ${passou + falhas.length}: ${falhas.join(', ')}`);
  process.exit(1);
}
console.log(`TODAS AS ${passou} VERIFICACOES DE REMOCAO PASSARAM.`);
