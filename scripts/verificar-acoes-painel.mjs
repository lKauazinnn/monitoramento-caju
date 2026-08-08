// =============================================================================
// Verificacao: os botoes de acao remota, num navegador de verdade
// =============================================================================
// Rode com:  node scripts/verificar-acoes-painel.mjs <email> <senha>
//
// O verificar-comandos.mjs prova o caminho servidor -> agente. Este prova o
// caminho tela -> servidor, que e onde mora outro tipo de defeito: botao que
// aparece para quem nao pode clicar, botao habilitado para maquina que nao sabe
// executar, dado do banco desenhado como HTML, e confirmacao que nao confirma
// nada.
//
// Clica de verdade, em Chrome de verdade, e confere no banco o que aconteceu.
// Nao dispara reinicio real: a caixa "simular" fica marcada, que e o padrao.
//
// Limpa o que criou mesmo quando falha.
// =============================================================================
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [email, senha] = process.argv.slice(2);
if (!email || !senha) {
  console.error('uso: node scripts/verificar-acoes-painel.mjs <email> <senha>');
  process.exit(2);
}

const raiz = fileURLToPath(new URL('..', import.meta.url));
const env = readFileSync(join(raiz, '.env'), 'utf8');
const webPort = /WEB_PORT=(\d+)/.exec(env)?.[1] ?? '8081';
const URL_DASH = `http://127.0.0.1:${webPort}`;

const sql = (q, primeira = false) => {
  const s = execFileSync('docker',
    ['exec', 'monitor-db', 'psql', '-U', 'postgres', '-t', '-A', '-c', q],
    { encoding: 'utf8' }).trim();
  return primeira ? s.split('\n')[0].trim() : s;
};

let passou = 0; const falhas = [];
const verificar = (nome, ok, det = '') => {
  if (ok) { passou++; console.log(`  ok    ${nome}`); }
  else { falhas.push(nome); console.log(`  FALHA ${nome}\n        ${det}`); }
};

const COD = 'ZZUICMD';
const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

const limparBanco = () => {
  try {
    sql(`
      delete from public.events where site_id in (select id from public.sites where code='${COD}');
      delete from public.machines where site_id in (select id from public.sites where code='${COD}');
      delete from public.sites where code='${COD}';
      delete from public.brands where code='${COD}';
    `);
  } catch (_) { /* melhor esforco */ }
};

const perfil = mkdtempSync(join(tmpdir(), 'uicmd-'));
const porta = 9381;
const proc = spawn('C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe', [
  '--headless=new', `--remote-debugging-port=${porta}`, `--user-data-dir=${perfil}`,
  '--no-first-run', '--disable-gpu', '--window-size=1700,1100', 'about:blank',
], { stdio: 'ignore' });

try {
  limparBanco();

  // Duas maquinas: uma com agente NOVO (executa) e uma com agente VELHO (nao).
  // A diferenca entre elas e o que a tela precisa saber mostrar.
  sql(`
    insert into public.brands (code, name) values ('${COD}', 'ui comandos');
    insert into public.sites (brand_id, code, name)
      select id, '${COD}', 'loja ui comandos' from public.brands where code='${COD}';
    insert into public.machines (site_id, role_code, label, critical_services_override,
                                 last_seen_at, agent_version)
      select id, 'pdv', 'PC-UI-NOVO', array['Spooler','Dhcp'], now(), 'ps-1.2.0'
      from public.sites where code='${COD}';
    insert into public.machines (site_id, role_code, label, critical_services_override,
                                 last_seen_at, agent_version)
      select id, 'pdv', 'PC-UI-VELHO', array['Spooler'], now(), 'ps-1.1.0'
      from public.sites where code='${COD}';
  `);

  const maqNova = sql(`select id from public.machines where label='PC-UI-NOVO'`);

  // --------------------------------------------------------------- navegador
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
  const cmd = (metodo, params = {}) => new Promise((res) => {
    const i = ++id; pend.set(i, res); ws.send(JSON.stringify({ id: i, method: metodo, params }));
  });
  const js = async (e) => (await cmd('Runtime.evaluate',
    { expression: e, returnByValue: true, awaitPromise: true }))?.result?.value;

  await cmd('Page.enable');
  await cmd('Runtime.enable');

  // Login
  await cmd('Page.navigate', { url: `${URL_DASH}/login.html?v=${Date.now()}` });
  await dormir(2500);
  await js(`
    document.getElementById('email').value = ${JSON.stringify(email)};
    document.getElementById('senha').value = ${JSON.stringify(senha)};
    document.querySelector('form').requestSubmit(); true
  `);
  await dormir(4500);
  await js(`location.href = '${URL_DASH}/?v=${Date.now()}'; true`);
  await dormir(4500);

  // Abre a maquina NOVA
  const abriu = await js(`
    (() => {
      const c = [...document.querySelectorAll('.host-quad')]
        .find(x => (x.getAttribute('aria-label')||'').includes('PC-UI-NOVO'));
      if (!c) return false;
      c.click();
      return true;
    })()
  `);
  verificar('painel da maquina abriu', abriu === true);
  await dormir(2500);

  // ------------------------------------------------ 1. o que a tela oferece
  console.log('\n== 1. a secao de acoes ==');
  const vis = (id_) => js(`getComputedStyle(document.getElementById('${id_}')).display`);

  verificar('a secao de acoes esta visivel para admin',
    (await vis('acoes')) !== 'none');

  verificar('a simulacao vem MARCADA por padrao',
    (await js("document.getElementById('acao-simular').checked")) === true);

  const opcoes = await js(
    "[...document.getElementById('acao-servico').options].map(o=>o.textContent).join(',')");
  verificar('a lista traz os servicos criticos DESTA maquina',
    opcoes === 'Spooler,Dhcp', opcoes);

  // ------------------------------------------- 2. um comando sai da tela
  console.log('\n== 2. clicar enfileira de verdade ==');
  await js("document.getElementById('btn-test-collection').click(); true");
  await dormir(2500);

  const cmd1 = sql(`select kind || '|' || status || '|' || dry_run || '|' || origem
                    from public.agent_commands where machine_id='${maqNova}'`);
  verificar('o clique criou o comando, como simulacao e pelo painel',
    cmd1 === 'run_test_collection|pending|true|painel', cmd1);

  // `length === 36`, e nao `!== nulo`: sem linha nenhuma o psql devolve string
  // vazia, que tambem e diferente de '(nulo)' — e a verificacao passaria sem
  // que existisse comando algum.
  verificar('e ele registrou QUEM pediu',
    sql(`select coalesce(created_by::text,'(nulo)') from public.agent_commands
         where machine_id='${maqNova}'`).length === 36);

  await dormir(1200);
  const hist = await js("document.getElementById('acao-historico').textContent");
  verificar('o historico mostra o comando na tela',
    /Testar coleta/.test(hist) && /simula/i.test(hist), hist.slice(0, 200));

  // -------------------------------- 3. desmarcar simulacao age de verdade
  console.log('\n== 3. desmarcar a simulacao muda o pedido ==');
  await js(`
    document.getElementById('acao-simular').checked = false;
    document.getElementById('btn-clear-temp').click(); true
  `);
  await dormir(2500);

  verificar('sem simulacao, o comando vai com dry_run falso',
    sql(`select dry_run from public.agent_commands
         where machine_id='${maqNova}' and kind='clear_temp'`) === 'f');

  // ------------------------------------ 4. reiniciar exige DOIS cliques
  console.log('\n== 4. reiniciar o PC pede confirmacao ==');
  await js("document.getElementById('btn-restart-machine').click(); true");
  await dormir(1500);

  verificar('UM clique nao enfileira reinicio nenhum',
    sql(`select count(*) from public.agent_commands
         where machine_id='${maqNova}' and kind='restart_machine'`) === '0');

  const rotulo = await js("document.getElementById('btn-restart-machine').textContent");
  verificar('e o botao passa a pedir confirmacao', /Confirmar/.test(rotulo), rotulo);

  await js("document.getElementById('btn-restart-machine').click(); true");
  await dormir(2500);

  verificar('o segundo clique enfileira',
    sql(`select count(*) from public.agent_commands
         where machine_id='${maqNova}' and kind='restart_machine'`) === '1');

  // -------------------------------- 5. cancelar tira o comando da fila
  console.log('\n== 5. cancelar ==');
  const idPend = sql(`select id from public.agent_commands
                      where machine_id='${maqNova}' and kind='run_test_collection'`, true);

  const clicou = await js(`
    (() => {
      // Ancorado no ITEM certo. A lista vem do mais novo para o mais velho, e
      // pegar "o primeiro Cancelar" cancelaria o reinicio — enquanto a
      // verificacao seguinte conferiria outro comando, e passaria por engano.
      const li = [...document.querySelectorAll('#acao-historico .comando')]
        .find(x => x.textContent.includes('Testar coleta'));
      const b = li && li.querySelector('.btn-mini');
      if (!b) return false;
      b.click();
      return true;
    })()
  `);
  verificar('ha um botao de cancelar para comando ainda na fila', clicou === true);
  await dormir(2500);

  verificar('o comando cancelado saiu da fila',
    sql(`select status from public.agent_commands where id='${idPend}'`) === 'canceled');

  // -------------------------- 6. maquina com agente velho nao oferece acao
  console.log('\n== 6. maquina que nao sabe executar ==');
  await js("document.getElementById('btn-fechar-painel').click(); true");
  await dormir(800);
  await js(`
    (() => {
      const c = [...document.querySelectorAll('.host-quad')]
        .find(x => (x.getAttribute('aria-label')||'').includes('PC-UI-VELHO'));
      if (c) c.click();
      return true;
    })()
  `);
  await dormir(2500);

  verificar('os botoes ficam desabilitados para agente antigo',
    (await js("document.getElementById('btn-restart-machine').disabled")) === true);

  const aviso = await js("document.getElementById('acao-aviso').textContent");
  verificar('e a tela explica por que, citando a versao',
    /ps-1\.1\.0/.test(aviso) && /Reinstale/.test(aviso), aviso);

  // ------------------------------------------------- 7. nada vira HTML
  console.log('\n== 7. dado do banco nao vira HTML ==');
  // Regra 7. Se o resultado de um comando fosse injetado com innerHTML, um
  // agente comprometido (ou um nome de servico malicioso) executaria script no
  // navegador de quem opera o parque inteiro.
  sql(`
    insert into public.agent_commands
      (machine_id, site_id, kind, params, status, expires_at, finished_at,
       result_ok, result_text)
    select '${maqNova}', site_id, 'run_test_collection', '{}'::jsonb, 'failed',
           now() + interval '10 min', now(), false,
           '<img src=x onerror="window.__xss=1">'
    from public.machines where id='${maqNova}';
  `);

  await js("document.getElementById('btn-fechar-painel').click(); true");
  await dormir(600);
  await js(`
    (() => {
      const c = [...document.querySelectorAll('.host-quad')]
        .find(x => (x.getAttribute('aria-label')||'').includes('PC-UI-NOVO'));
      if (c) c.click();
      return true;
    })()
  `);
  await dormir(2800);

  verificar('a tentativa de XSS NAO executou',
    (await js('window.__xss === undefined')) === true);

  verificar('e o texto aparece literal, como texto',
    /<img src=x/.test(await js("document.getElementById('acao-historico').textContent")));

  verificar('nenhuma excecao de JavaScript no caminho todo',
    erros.length === 0, erros.join(' | '));

  ws.close();
} catch (e) {
  falhas.push('excecao');
  console.log(`\nEXCECAO: ${e.message}`);
} finally {
  limparBanco();
  try { proc.kill(); } catch (_) { /* ja morreu */ }
  try { rmSync(perfil, { recursive: true, force: true }); } catch (_) { /* ocupado */ }
}

console.log(`\n${passou} verificacoes ok, ${falhas.length} falha(s)`);
if (falhas.length) { falhas.forEach((f) => console.log(`  - ${f}`)); process.exit(1); }
