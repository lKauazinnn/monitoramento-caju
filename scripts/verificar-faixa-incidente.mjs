// =============================================================================
// Verificação da faixa de incidente
// =============================================================================
// Rode:  node scripts/verificar-faixa-incidente.mjs
//
// Provoca um incidente crítico de verdade, confere que a faixa acende, que
// reconhecer a CALA sem FECHAR o alerta, e que ela some quando a condição
// normaliza.
//
// POR QUE ESTE TESTE EXISTE: a faixa é o elemento mais gritante da tela, e o
// único com direito a isso. Se ela acender à toa, vira papel de parede em dois
// dias — e aí deixa de funcionar justamente no dia em que importa. As três
// coisas que a mantêm honesta (só crítico, só não reconhecido, some sozinha) não
// se verificam lendo o código.
// =============================================================================

import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
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

const FIX = 'ZZFAIXA';
const MAQ = 'PC-INCIDENTE';

const limpar = () => {
  try {
    sql(`delete from public.machines where label = '${MAQ}';
         delete from public.sites  where code = '${FIX}';
         delete from public.brands where code = '${FIX}';`);
  } catch (_) { /* nada a fazer */ }
};

limpar();

// Máquina com disco crítico: a regra global de disco é `critical` e não usa
// histerese, então o incidente aparece na primeira avaliação — sem esperar
// ciclos, o que manteria o teste lento e frágil.
sql(`
  insert into public.brands (code, name) select '${FIX}', 'faixa'
  where not exists (select 1 from public.brands where code = '${FIX}');

  insert into public.sites (brand_id, code, name)
  select b.id, '${FIX}', 'loja faixa' from public.brands b where b.code = '${FIX}'
    and not exists (select 1 from public.sites where code = '${FIX}');

  insert into public.machines (site_id, role_code, label, hostname, agent_version, last_seen_at)
  select s.id, 'pdv', '${MAQ}', 'HOST-INCIDENTE', 'ps-1.1.0', now()
  from public.sites s where s.code = '${FIX}';

  insert into public.metrics (machine_id, "time", agent_version, cpu_pct, mem_pct)
  select m.id, now(), 'ps-1.1.0', 5, 30 from public.machines m where m.label = '${MAQ}';

  insert into public.metrics_disks (machine_id, "time", drive, total_gb, free_gb, free_pct, media_type)
  select m.id, now(), 'C:', 200, 4, 2, 'SSD' from public.machines m where m.label = '${MAQ}';
`);

sql('select public.avaliar_alertas();');

// ISOLAMENTO. A faixa mostra o incidente mais urgente da FROTA, e este banco tem
// maquinas reais com problema real. Sem isolar, o teste media a faixa de outra
// maquina e o reconhecimento caia em cima dela — foi o que aconteceu na primeira
// execucao. Silencia os preexistentes, guarda quais eram, e devolve no fim.
const outrosCriticos = sql(`
  select coalesce(string_agg(e.id::text, ','), '')
  from public.events e
  left join public.machines m on m.id = e.machine_id
  where e.kind = 'alert_open' and e.resolved_at is null
    and e.severity = 'critical' and e.acknowledged_at is null
    and coalesce(m.label, '') <> '${MAQ}'`);

if (outrosCriticos) {
  sql(`update public.events set acknowledged_at = now()
        where id in (${outrosCriticos})`);
  console.log(`  (silenciados ${outrosCriticos.split(',').length} incidente(s) preexistente(s) para isolar)`);
}

const devolverOutros = () => {
  if (!outrosCriticos) return;
  try {
    sql(`update public.events set acknowledged_at = null, acknowledged_by = null
          where id in (${outrosCriticos})`);
  } catch (_) { /* nada a fazer no encerramento */ }
};

const abertoNoBanco = sql(`
  select count(*) from public.events e
  join public.machines m on m.id = e.machine_id
  where m.label = '${MAQ}' and e.kind = 'alert_open' and e.resolved_at is null
    and e.severity = 'critical'`);

console.log(`\ncenário: ${MAQ} com 2% de disco livre — ${abertoNoBanco} alerta(s) crítico(s) no banco\n`);

const CAMINHOS = [
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
];
let nav = null;
for (const c of CAMINHOS) { try { readFileSync(c); nav = c; break; } catch (_) { /* proximo */ } }
if (!nav) { console.error('sem navegador'); process.exit(2); }

const perfil = mkdtempSync(join(tmpdir(), 'faixa-'));
const dp = 9403;
const proc = spawn(nav, [
  '--headless=new', `--remote-debugging-port=${dp}`, `--user-data-dir=${perfil}`,
  '--no-first-run', '--disable-gpu', '--window-size=1700,1100', 'about:blank',
], { stdio: 'ignore' });

const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

try {
  v('o avaliador abriu o alerta crítico', abertoNoBanco === '1', `abertos=${abertoNoBanco}`);

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
  await cmd('Page.navigate', { url: `${URL_DASH}/?v=faixa-${Date.now()}` });
  await dormir(6500);

  // ---- 1. a faixa acende ---------------------------------------------------
  const acesa = await js(`
    ({
      visivel: getComputedStyle(document.getElementById('faixa-incidente')).display !== 'none',
      titulo:  document.getElementById('fi-titulo').textContent,
      detalhe: document.getElementById('fi-detalhe').textContent,
      favicon: (document.querySelector('link[rel="icon"]') || {}).href ? 'definido' : 'ausente',
    })
  `);

  v('a faixa acende com incidente crítico', acesa.visivel === true, JSON.stringify(acesa));
  v('a faixa diz quantos são', /incidente/i.test(acesa.titulo || ''), acesa.titulo);
  v('a faixa diz qual é o problema, e é o desta máquina',
    (acesa.detalhe || '').includes(FIX) && /disco/i.test(acesa.detalhe || ''), acesa.detalhe);
  v('o favicon foi redesenhado (aba de fundo)', acesa.favicon === 'definido', acesa.favicon);

  // ---- 2. um clique NAO reconhece ------------------------------------------
  await js("document.getElementById('fi-reconhecer').click(); true");
  await dormir(600);

  const meio = sql(`
    select count(*) from public.events e join public.machines m on m.id = e.machine_id
    where m.label = '${MAQ}' and e.acknowledged_at is not null`);
  v('um clique apenas ARMA, não reconhece', meio === '0', `reconhecidos=${meio}`);

  // ---- 3. dois cliques reconhecem, e a faixa cala --------------------------
  await js("document.getElementById('fi-reconhecer').click(); true");
  await dormir(3500);

  const reconhecido = sql(`
    select count(*) from public.events e join public.machines m on m.id = e.machine_id
    where m.label = '${MAQ}' and e.acknowledged_at is not null`);
  v('o segundo clique reconhece', reconhecido === '1', `reconhecidos=${reconhecido}`);

  const aindaAberto = sql(`
    select count(*) from public.events e join public.machines m on m.id = e.machine_id
    where m.label = '${MAQ}' and e.kind = 'alert_open' and e.resolved_at is null`);
  v('reconhecer NÃO fecha o alerta', aindaAberto === '1', `abertos=${aindaAberto}`);

  const calou = await js(
    "getComputedStyle(document.getElementById('faixa-incidente')).display === 'none'");
  v('a faixa cala depois do reconhecimento', calou === true);

  // ---- 4. some de vez quando a condição normaliza -------------------------
  // A amostra E o disco no MESMO instante.
  //
  // A view correlaciona disco e servicos com a metrica pelo timestamp exato
  // (`d.time = lm.time`) — eles chegam no mesmo envelope do agente. Inserir so o
  // disco, como esta verificacao fazia antes, deixa a linha orfa: ela existe na
  // tabela e a view continua enxergando a antiga. A propriedade do esquema esta
  // certa; o teste e que estava simulando uma coisa que o agente nunca faz.
  sql(`
    with t as (select now() + interval '1 minute' as quando),
         m as (select id from public.machines where label = '${MAQ}'),
         ins as (
           insert into public.metrics (machine_id, "time", agent_version, cpu_pct, mem_pct)
           select m.id, t.quando, 'ps-1.1.0', 5, 30 from m, t returning 1
         )
    insert into public.metrics_disks (machine_id, "time", drive, total_gb, free_gb, free_pct, media_type)
    select m.id, t.quando, 'C:', 200, 120, 60, 'SSD' from m, t;
  `);
  sql('select public.avaliar_alertas();');

  const fechado = sql(`
    select count(*) from public.events e join public.machines m on m.id = e.machine_id
    where m.label = '${MAQ}' and e.kind = 'alert_open' and e.resolved_at is null`);
  v('normalizado o disco, o alerta fecha', fechado === '0', `abertos=${fechado}`);

  const recuperou = sql(`
    select count(*) from public.events e join public.machines m on m.id = e.machine_id
    where m.label = '${MAQ}' and e.kind = 'alert_recovered'`);
  v('gera o aviso de recuperação', recuperou === '1', `recuperados=${recuperou}`);

  v('nenhuma exceção de JavaScript', erros.length === 0, erros.join(' | '));

  ws.close();
} finally {
  try { proc.kill(); } catch (_) { /* ja morreu */ }
  try { rmSync(perfil, { recursive: true, force: true }); } catch (_) { /* ocupado */ }
  limpar();
  devolverOutros();
}

console.log('');
if (falhas.length) {
  console.log(`FALHARAM ${falhas.length} de ${ok + falhas.length}: ${falhas.join(', ')}`);
  process.exit(1);
}
console.log(`AS ${ok} VERIFICACOES DA FAIXA DE INCIDENTE PASSARAM.`);
