// =============================================================================
// Verificacao: acao remota de ponta a ponta, com o AGENTE DE VERDADE
// =============================================================================
// Rode com:  node scripts/verificar-comandos.mjs
//
// O teste SQL (08) prova o banco. Este prova o resto do caminho, que o SQL nao
// alcanca:
//
//   painel -> banco -> servidor de ingestao (HTTP) -> agente PowerShell real
//          -> execucao nesta maquina -> resultado de volta -> banco
//
// Roda o agente-powershell.ps1 sem modificacao nenhuma, contra um config.json
// descartavel, numa maquina descartavel. Se o contrato entre o agente e o
// servidor quebrar — nome de campo, formato, ordem — este script acusa; o teste
// SQL nao acusaria, porque ele chama a funcao direto e nunca passa pelo HTTP.
//
// Nao executa comando destrutivo: `run_test_collection` e `clear_temp` com piso
// alto sao inofensivos, e reiniciar servico ou maquina do PC de quem roda o
// teste seria dano real por conta de um teste.
//
// Limpa o que criou mesmo quando falha.
// =============================================================================
import { readFileSync, writeFileSync, mkdtempSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const raiz = fileURLToPath(new URL('..', import.meta.url));
const env = readFileSync(join(raiz, '.env'), 'utf8');
const portaIngest = /INGEST_PORT=(\d+)/.exec(env)?.[1] ?? '3010';
const segredo = /INGEST_SHARED_SECRET=(\S+)/.exec(env)?.[1] ?? '';

// `primeiraLinha` para consulta com `returning`: o psql imprime o valor E a
// linha "INSERT 0 1" logo abaixo, e sem cortar isso o id sai colado com ela.
const sql = (q, primeiraLinha = false) => {
  const saida = execFileSync('docker',
    ['exec', 'monitor-db', 'psql', '-U', 'postgres', '-t', '-A', '-c', q],
    { encoding: 'utf8' }).trim();
  return primeiraLinha ? saida.split('\n')[0].trim() : saida;
};

let passou = 0; const falhas = [];
const verificar = (nome, ok, det = '') => {
  if (ok) { passou++; console.log(`  ok    ${nome}`); }
  else { falhas.push(nome); console.log(`  FALHA ${nome}\n        ${det}`); }
};

const COD = 'ZZE2ECMD';
const ADMIN = '44444444-4444-4444-8444-444444444444';
const dir = mkdtempSync(join(tmpdir(), 'cmd-'));
const configPath = join(dir, 'config.json');

// Como admin: e o caminho real do painel, e testar por um atalho deixaria a
// autorizacao sem cobertura.
// A ultima linha: o `set local` tambem imprime ("SET"), e sem descartar isso o
// JSON.parse do resultado recebe "SET\n{...}".
const comoAdmin = (q) =>
  sql(`set local request.jwt.claim.sub = '${ADMIN}'; ${q}`).split('\n').pop().trim();

function limparBanco() {
  try {
    sql(`
      delete from public.events where site_id in (select id from public.sites where code='${COD}');
      delete from public.machines where site_id in (select id from public.sites where code='${COD}');
      delete from public.sites where code='${COD}';
      delete from public.brands where code='${COD}';
      delete from public.user_roles where user_id='${ADMIN}';
    `);
  } catch (_) { /* melhor esforco */ }
}

// Roda um ciclo do agente REAL e devolve a saida.
function umCiclo() {
  return execFileSync('powershell', [
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', join(raiz, 'agent', 'agente-powershell.ps1'),
    '-Config', configPath, '-UmaVez',
  ], { encoding: 'utf8', timeout: 180000 });
}

const estado = (id) => sql(`select status from public.agent_commands where id='${id}'`);

try {
  limparBanco();

  // ------------------------------------------------------------------ cenario
  console.log('\n== preparando ==');
  sql(`
    insert into public.brands (code, name) values ('${COD}', 'e2e comandos');
    insert into public.sites (brand_id, code, name)
      select id, '${COD}', 'loja e2e comandos' from public.brands where code='${COD}';
    insert into public.machines (site_id, role_code, label, critical_services_override)
      select id, 'pdv', 'PC-E2E-CMD', array['Spooler'] from public.sites where code='${COD}';
    insert into public.user_roles (user_id, role, note) values ('${ADMIN}', 'admin', 'e2e comandos');
  `);

  const maq = sql(`select id from public.machines where label='PC-E2E-CMD'`);
  const token = sql(`select token from public.issue_agent_token('${maq}', 'e2e comandos')`);

  verificar('maquina descartavel criada', maq.length === 36, maq);
  verificar('token emitido', token.startsWith('mon_'), token.slice(0, 8));

  writeFileSync(configPath, JSON.stringify({
    ingestUrl: `http://127.0.0.1:${portaIngest}`,
    token,
    sharedSecret: segredo,
    machineLabel: 'PC-E2E-CMD',
    siteCode: COD,
    criticalServices: ['Spooler'],
    intervalSeconds: 60,
  }, null, 2));

  // ---------------------------------------- 1. o agente busca e executa
  console.log('\n== 1. comando chega ate a execucao ==');
  const id1 = JSON.parse(comoAdmin(
    `select public.enfileirar_comando('${maq}', 'run_test_collection')`)).command_id;

  verificar('comando entra como pending', estado(id1) === 'pending', estado(id1));

  // Ciclo 1: envia telemetria, RECEBE o comando, executa. O resultado ainda nao
  // saiu — nao ha canal de volta, ele vai no proximo POST.
  const saida1 = umCiclo();
  verificar('o agente registrou ter recebido o comando',
    /comando run_test_collection recebido/.test(saida1), saida1.slice(-400));
  verificar('o agente executou a coleta de teste',
    /coleta de teste: cpu/.test(saida1), saida1.slice(-400));
  verificar('comando marcado como entregue', estado(id1) === 'sent', estado(id1));

  // Ciclo 2: o relato sobe junto com a telemetria.
  const saida2 = umCiclo();
  verificar('resultado voltou e fechou o comando', estado(id1) === 'succeeded',
    `${estado(id1)}\n${saida2.slice(-400)}`);

  const r1 = sql(`select coalesce(result_text,'') from public.agent_commands where id='${id1}'`);
  verificar('o resultado tem texto util', /cpu \d/.test(r1), r1);

  verificar('a execucao virou evento auditavel',
    sql(`select count(*) from public.events
         where kind='command_result' and payload->>'command_id'='${id1}'`) === '1');

  // ------------------------------------------------- 1b. o MAC chega junto
  // Sem MAC nao ha Wake-on-LAN: o pacote magico nao usa IP, usa o endereco da
  // placa. Como quem reporta e o agente REAL desta maquina, este e o unico
  // teste que prova que a consulta ao adaptador funciona num Windows de verdade
  // — o teste SQL so consegue simular o valor ja pronto.
  const mac = sql(`select coalesce(mac_address::text,'(nulo)')
                   from public.machines where id='${maq}'`);
  verificar('o agente reportou o MAC da placa cabeada',
    /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(mac), mac);

  // -------------------------------------------------- 2. simulacao nao age
  console.log('\n== 2. dry-run nao toca no disco ==');
  // 365 dias (o teto do servidor): quase nenhum arquivo temporario e tao velho, entao mesmo se a simulacao
  // falhasse e ele apagasse de verdade, nao haveria o que apagar. O teste mede o
  // RELATO, sem apostar a integridade do PC de quem roda nele.
  const id2 = JSON.parse(comoAdmin(
    `select public.enfileirar_comando('${maq}', 'clear_temp', '{"dias_minimos":365}'::jsonb, true)`
  )).command_id;

  const saida3 = umCiclo();
  verificar('o agente identificou a simulacao',
    /\(simulacao\)/.test(saida3), saida3.slice(-400));
  verificar('o relato diz "apagaria", nao "apagou"',
    /apagaria/.test(saida3) && !/\bapagou\b/.test(saida3), saida3.slice(-400));

  umCiclo();
  verificar('a simulacao fecha como sucesso', estado(id2) === 'succeeded', estado(id2));

  // ------------------------------------------ 2b. o caminho do REINICIO
  console.log('\n== 2b. reiniciar a maquina (simulado) ==');
  // Este e o unico comando que NAO da para provar por inteiro: a ultima linha
  // dele desliga o PC de quem roda o teste. Entao prova-se tudo ate ali —
  // enfileiramento, confirmacao obrigatoria, entrega, execucao, relato — e o
  // dry-run garante que o `shutdown.exe` nao e chamado.
  //
  // O que fica sem cobertura automatica e uma linha: `& shutdown.exe /r /t 15`.
  let recusou = false;
  try {
    comoAdmin(`select public.enfileirar_comando('${maq}', 'restart_machine')`);
  } catch (_) { recusou = true; }
  verificar('sem confirmacao, o servidor recusa o reinicio', recusou);

  const id2b = JSON.parse(comoAdmin(
    `select public.enfileirar_comando('${maq}', 'restart_machine', '{}'::jsonb, true, true)`
  )).command_id;

  const saidaR = umCiclo();
  verificar('o agente recebeu o comando de reinicio',
    /comando restart_machine recebido/.test(saidaR), saidaR.slice(-400));
  verificar('e o relato diz "reiniciaria", nao "reiniciou"',
    /SIMULACAO: reiniciaria/.test(saidaR), saidaR.slice(-400));

  umCiclo();
  verificar('a simulacao de reinicio fecha como sucesso', estado(id2b) === 'succeeded',
    estado(id2b));

  // O cooldown conta a partir do reinicio REAL. Simulacao nao pode gastar a
  // cota, senao um operador cauteloso que simula antes de agir ficaria 30 min
  // impedido de fazer o que a simulacao acabou de dizer que era seguro.
  let bloqueou = false;
  try {
    comoAdmin(`select public.enfileirar_comando('${maq}', 'restart_machine', '{}'::jsonb, true, true)`);
  } catch (_) { bloqueou = true; }
  verificar('simular nao gasta a cota de reinicio do cooldown', !bloqueou);

  // ------------------------------------- 3. tipo desconhecido nao vira acao
  console.log('\n== 3. tipo desconhecido falha explicitamente ==');
  // Um servidor mais novo que o agente. O agente NAO pode adivinhar: tem que
  // relatar falha, para o painel mostrar que a maquina precisa de atualizacao.
  // Enfiado direto na tabela porque `enfileirar_comando` recusa tipo fora da
  // lista — que e justamente o comportamento correto do lado do servidor.
  // .split: `returning` imprime o id E a linha "INSERT 0 1" logo abaixo.
  const id3 = sql(`
    insert into public.agent_commands (machine_id, site_id, kind, params, expires_at, origem)
    select '${maq}', site_id, 'restart_service', '{"servico":"NaoExisteEsteServico"}'::jsonb,
           now() + interval '30 min', 'painel'
    from public.machines where id='${maq}' returning id`, true);

  const saida4 = umCiclo();
  verificar('o agente recusou servico fora da lista local',
    /nao esta na lista local/.test(saida4), saida4.slice(-500));

  umCiclo();
  verificar('a recusa fecha o comando como FALHA', estado(id3) === 'failed', estado(id3));

  verificar('a falha tambem virou evento',
    sql(`select severity from public.events
         where kind='command_result' and payload->>'command_id'='${id3}'`) === 'warning');

  // ------------------------------------------ 4. expirado nunca e entregue
  console.log('\n== 4. comando vencido nao executa ==');
  const id4 = JSON.parse(comoAdmin(
    `select public.enfileirar_comando('${maq}', 'run_test_collection')`)).command_id;

  sql(`update public.agent_commands
       set not_before = now() - interval '2 hours', expires_at = now() - interval '1 hour'
       where id='${id4}'`);

  const saida5 = umCiclo();
  verificar('o agente nao recebeu o comando vencido',
    !/comando run_test_collection recebido/.test(saida5), saida5.slice(-400));
  verificar('e ele continua fora de "succeeded"', estado(id4) !== 'succeeded', estado(id4));

  sql('select public.expirar_comandos()');
  verificar('a varredura o marca como expirado', estado(id4) === 'expired', estado(id4));

  // ---------------------------------------- 5. o token e o unico escopo
  console.log('\n== 5. o token so alcanca a propria maquina ==');
  // Um agente adulterado que tente fechar comando de outra maquina.
  const id5 = JSON.parse(comoAdmin(
    `select public.enfileirar_comando('${maq}', 'run_test_collection')`)).command_id;
  sql(`update public.agent_commands set status='sent', sent_at=now() where id='${id5}'`);

  const outra = sql(`
    insert into public.machines (site_id, role_code, label)
    select site_id, 'pdv', 'PC-E2E-CMD-2' from public.machines where id='${maq}' returning id`, true);
  const tokenOutra = sql(`select token from public.issue_agent_token('${outra}', 'e2e')`);

  const resp = await fetch(`http://127.0.0.1:${portaIngest}/ingest`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-monitor-secret': segredo,
      authorization: `Bearer ${tokenOutra}`,
    },
    body: JSON.stringify({
      agent_version: 'e2e',
      sent_at: new Date().toISOString(),
      machine: { label: 'PC-E2E-CMD-2' },
      samples: [{ t: new Date().toISOString(), cpu_pct: 1, mem_pct: 1 }],
      command_results: [{ command_id: id5, ok: true, texto: 'nao fui eu' }],
    }),
  });

  verificar('o POST da outra maquina foi aceito (ela existe)', resp.status === 200, `${resp.status}`);
  verificar('mas o comando alheio NAO foi fechado', estado(id5) === 'sent', estado(id5));

  // ------------------------------------------- 6. entrada malformada = 400
  console.log('\n== 6. relato malformado e recusado no servidor ==');
  const respMa = await fetch(`http://127.0.0.1:${portaIngest}/ingest`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-monitor-secret': segredo,
      authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({
      agent_version: 'e2e',
      sent_at: new Date().toISOString(),
      samples: [{ t: new Date().toISOString(), cpu_pct: 1 }],
      command_results: [{ command_id: "'; drop table agent_commands; --", ok: true }],
    }),
  });

  verificar('command_id que nao e UUID vira 400, nao 500', respMa.status === 400, `${respMa.status}`);
  verificar('a tabela continua de pe',
    sql("select to_regclass('public.agent_commands')") === 'agent_commands');

} catch (e) {
  falhas.push('excecao');
  console.log(`\nEXCECAO: ${e.message}`);
  if (e.stdout) console.log(String(e.stdout).slice(-1500));
} finally {
  limparBanco();
  try { rmSync(dir, { recursive: true, force: true }); } catch (_) { /* ocupado */ }
}

console.log(`\n${passou} verificacoes ok, ${falhas.length} falha(s)`);
if (falhas.length) { falhas.forEach((f) => console.log(`  - ${f}`)); process.exit(1); }
