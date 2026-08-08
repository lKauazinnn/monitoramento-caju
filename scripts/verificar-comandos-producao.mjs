// =============================================================================
// Verificacao: a fila de comandos EM PRODUCAO, por HTTPS
// =============================================================================
// Rode com:  node scripts/verificar-comandos-producao.mjs
//
// Publicar e facil. A pergunta que importa e "esta realmente no ar, entregando
// comando e recebendo resultado?", e essa so se responde tentando — contra o
// endereco real, pela Edge Function real, com token de maquina real.
//
// Difere do verificar-comandos.mjs em duas coisas que sao justamente onde a
// producao quebra sozinha: fala por HTTPS com a Edge Function (nao com o shim
// local), e usa a conexao pooler ao banco (nao `docker exec`).
//
// Cria uma marca, uma loja e uma maquina descartaveis EM PRODUCAO, e apaga tudo
// no fim, inclusive quando falha. Nao executa comando destrutivo, e nao roda o
// agente: quem "executa" aqui e este script, que finge ser o agente para provar
// o CONTRATO. A execucao de verdade ja esta provada em verificar-comandos.mjs.
// =============================================================================
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

const raiz = fileURLToPath(new URL('..', import.meta.url));
const env = readFileSync(join(raiz, '.env.producao'), 'utf8');
const INGEST = /INGEST_URL=(\S+)/.exec(env)[1];
const SEGREDO = /INGEST_SHARED_SECRET=(\S+)/.exec(env)[1];

// A senha do banco NAO fica em arquivo (regra 1: nada de credencial de servidor
// em artefato). Vem do ambiente, e sem ela o script para em vez de adivinhar.
const SENHA = process.env.PGPASSWORD_PRODUCAO;
if (!SENHA) {
  console.error('defina PGPASSWORD_PRODUCAO com a senha do banco de producao');
  process.exit(2);
}

const pooler = readFileSync(join(raiz, 'supabase/.temp/pooler-url'), 'utf8').trim();

// psql pelo container: evita exigir cliente postgres instalado nesta maquina.
const sql = (q, primeiraLinha = false) => {
  const saida = execFileSync('docker', [
    'run', '--rm', '-e', `PGPASSWORD=${SENHA}`, 'postgres:16',
    'psql', pooler, '-t', '-A', '-c', q,
  ], { encoding: 'utf8' }).trim();
  return primeiraLinha ? saida.split('\n')[0].trim() : saida;
};

let passou = 0; const falhas = [];
const verificar = (nome, ok, det = '') => {
  if (ok) { passou++; console.log(`  ok    ${nome}`); }
  else { falhas.push(nome); console.log(`  FALHA ${nome}\n        ${det}`); }
};

const COD = 'ZZPRODCMD';
const ADMIN = '55555555-5555-4555-8555-555555555555';

const limpar = () => {
  try {
    sql(`
      delete from public.events where site_id in (select id from public.sites where code='${COD}');
      delete from public.machines where site_id in (select id from public.sites where code='${COD}');
      delete from public.sites where code='${COD}';
      delete from public.brands where code='${COD}';
      delete from public.user_roles where user_id='${ADMIN}';
    `);
  } catch (_) { /* melhor esforco */ }
};

// Um ciclo do agente: telemetria + relatos, e devolve os comandos entregues.
async function ciclo(token, resultados = []) {
  const r = await fetch(INGEST, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-monitor-secret': SEGREDO,
      authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({
      agent_version: 'verificacao-producao',
      sent_at: new Date().toISOString(),
      machine: { label: 'PC-PROD-CMD' },
      samples: [{ t: new Date().toISOString(), cpu_pct: 3, mem_pct: 40, uptime_seconds: 900 }],
      command_results: resultados,
    }),
  });
  return { status: r.status, corpo: await r.json().catch(() => ({})) };
}

const estado = (id) => sql(`select status from public.agent_commands where id='${id}'`);

try {
  limpar();

  console.log(`\n== producao: ${INGEST} ==`);

  // ---------------------------------------------------- 0. a estrutura subiu
  verificar('a tabela agent_commands existe em producao',
    sql("select to_regclass('public.agent_commands')") === 'agent_commands');

  verificar('agent_commands esta com RLS ligada',
    sql("select relrowsecurity from pg_class where oid='public.agent_commands'::regclass") === 't');

  verificar('nao existe policy de escrita para role publica',
    sql(`select count(*) from pg_policies where tablename='agent_commands'
         and cmd in ('INSERT','UPDATE','DELETE')`) === '0');

  verificar('as funcoes novas levam search_path fixo',
    sql(`select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.prosecdef
           and p.proname in ('enfileirar_comando','agente_sincronizar','expirar_comandos',
                             'validar_comando','cancelar_comando','app_settings_bool')
           and not coalesce(array_to_string(p.proconfig,',') like '%search_path=public, pg_temp%', false)
    `) === '0');

  verificar('a expiracao esta agendada no pg_cron',
    sql("select active from cron.job where jobname='expirar-comandos'") === 't');

  // -------------------------------------------------------------- cenario
  sql(`
    insert into public.brands (code, name) values ('${COD}', 'verificacao producao');
    insert into public.sites (brand_id, code, name)
      select id, '${COD}', 'loja verificacao' from public.brands where code='${COD}';
    insert into public.machines (site_id, role_code, label, critical_services_override)
      select id, 'pdv', 'PC-PROD-CMD', array['Spooler'] from public.sites where code='${COD}';
    insert into public.user_roles (user_id, role, note) values ('${ADMIN}', 'admin', 'verificacao');
  `);

  const maq = sql(`select id from public.machines where label='PC-PROD-CMD'`);
  const token = sql(`select token from public.issue_agent_token('${maq}', 'verificacao producao')`);

  // ------------------------------------------ 1. o ciclo completo por HTTPS
  console.log('\n== 1. entrega e resultado, pela Edge Function ==');
  const id1 = JSON.parse(sql(
    `set local request.jwt.claim.sub = '${ADMIN}';
     select public.enfileirar_comando('${maq}', 'run_test_collection')`).split('\n').pop()).command_id;

  const c1 = await ciclo(token);
  verificar('a ingestao continua respondendo 200', c1.status === 200, JSON.stringify(c1.corpo));
  verificar('a Edge Function entregou o comando',
    (c1.corpo.comandos ?? []).length === 1, JSON.stringify(c1.corpo.comandos));
  verificar('o comando entregue e o que foi enfileirado',
    c1.corpo.comandos?.[0]?.command_id === id1);
  verificar('e ele virou "sent" no banco', estado(id1) === 'sent', estado(id1));

  const c2 = await ciclo(token, [{ command_id: id1, ok: true, texto: 'verificacao de producao' }]);
  verificar('o relato foi aceito', c2.status === 200, JSON.stringify(c2.corpo));
  verificar('o resultado fechou o comando', estado(id1) === 'succeeded', estado(id1));
  verificar('nao veio comando repetido', (c2.corpo.comandos ?? []).length === 0);
  verificar('a execucao virou evento auditavel',
    sql(`select count(*) from public.events
         where kind='command_result' and payload->>'command_id'='${id1}'`) === '1');

  // ------------------------------- 2. a telemetria nao depende da fila
  verificar('a telemetria foi gravada junto', Number(c1.corpo.accepted) === 1,
    JSON.stringify(c1.corpo));

  // ------------------------------------------- 3. entrada malformada = 400
  console.log('\n== 2. o contrato recusa lixo antes do banco ==');
  const ruim = await fetch(INGEST, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-monitor-secret': SEGREDO,
      authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({
      agent_version: 'verificacao-producao',
      sent_at: new Date().toISOString(),
      samples: [{ t: new Date().toISOString(), cpu_pct: 1 }],
      command_results: [{ command_id: 'nao-e-uuid', ok: true }],
    }),
  });
  verificar('command_id invalido vira 400, nao 500', ruim.status === 400, `${ruim.status}`);

  // ------------------------------ 4. agente antigo continua funcionando
  console.log('\n== 3. agente antigo nao quebra ==');
  // As lojas em producao rodam ps-1.1.0, que nao conhece command_results. Se a
  // atualizacao do servidor exigisse agente novo, o parque inteiro pararia de
  // reportar ate alguem visitar cada loja.
  const antigo = await fetch(INGEST, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-monitor-secret': SEGREDO,
      authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({
      agent_version: 'ps-1.1.0',
      sent_at: new Date().toISOString(),
      machine: { label: 'PC-PROD-CMD' },
      samples: [{ t: new Date().toISOString(), cpu_pct: 5, mem_pct: 30 }],
    }),
  });
  const corpoAntigo = await antigo.json().catch(() => ({}));
  verificar('envelope sem command_results e aceito', antigo.status === 200,
    JSON.stringify(corpoAntigo));
  verificar('e a telemetria dele foi gravada', Number(corpoAntigo.accepted) === 1,
    JSON.stringify(corpoAntigo));

} catch (e) {
  falhas.push('excecao');
  console.log(`\nEXCECAO: ${e.message}`);
  if (e.stdout) console.log(String(e.stdout).slice(-1200));
} finally {
  limpar();
}

console.log(`\n${passou} verificacoes ok, ${falhas.length} falha(s)`);
if (falhas.length) { falhas.forEach((f) => console.log(`  - ${f}`)); process.exit(1); }
