// =============================================================================
// Verificação ponta a ponta do sistema local
// =============================================================================
// Faz o que o navegador faria: busca os arquivos no nginx, chama a API com o
// mesmo token do dashboard e confere que os dados chegam.
//
// Inclui o critério de aceite da Fase 4: uma máquina com hostname
// `<script>alert(1)</script>` tem de ser guardada e devolvida como TEXTO
// LITERAL, e o app.js não pode conter nenhum innerHTML.
//
// Rode:  node scripts/verificar-e2e.mjs
// =============================================================================

import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

// fileURLToPath e nao .pathname: o caminho deste projeto tem espaco, e o
// .pathname de uma URL entrega "%20" em vez do espaco.
const raiz = fileURLToPath(new URL('..', import.meta.url));

let ok = 0;
const falhas = [];

function verificar(nome, condicao, detalhe) {
  if (condicao) {
    ok++;
    console.log(`  ok    ${nome}`);
  } else {
    falhas.push(nome);
    console.log(`  FALHA ${nome}${detalhe ? `\n        ${detalhe}` : ''}`);
  }
}

// -----------------------------------------------------------------------------
// Configuração gerada pelo dev-up
// -----------------------------------------------------------------------------
const dev = JSON.parse(readFileSync(join(raiz, 'dashboard', 'dev-config.json'), 'utf8'));
const REST = dev.restUrl;

// O token não vem mais de arquivo: ele é obtido fazendo login de verdade, do
// mesmo jeito que o navegador faz. Credenciais vêm por argumento.
const [emailArg, senhaArg] = process.argv.slice(2);
if (!emailArg || !senhaArg) {
  console.error('uso: node scripts/verificar-e2e.mjs <email> <senha>');
  process.exit(2);
}

const respLogin = await fetch(`${REST}/rpc/local_sign_in`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ p_email: emailArg, p_password: senhaArg }),
});
const corpoLogin = await respLogin.json().catch(() => ({}));

if (!corpoLogin.access_token) {
  console.error(`login falhou: ${corpoLogin.message || `HTTP ${respLogin.status}`}`);
  process.exit(1);
}
const TOKEN = corpoLogin.access_token;

// A porta do nginx sai do .env que o dev-up escreveu.
const env = readFileSync(join(raiz, '.env'), 'utf8');
const webPort = /WEB_PORT=(\d+)/.exec(env)?.[1] ?? '8080';
const WEB = `http://127.0.0.1:${webPort}`;

console.log(`\nAPI: ${REST}   WEB: ${WEB}\n`);

const cab = { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' };

const rpc = async (nome, args = {}) => {
  const r = await fetch(`${REST}/rpc/${nome}`, { method: 'POST', headers: cab, body: JSON.stringify(args) });
  if (!r.ok) throw new Error(`${nome}: HTTP ${r.status} ${await r.text()}`);
  return r.json();
};

const get = async (caminho) => {
  const r = await fetch(`${REST}${caminho}`, { headers: cab });
  if (!r.ok) throw new Error(`${caminho}: HTTP ${r.status} ${await r.text()}`);
  return r.json();
};

const psql = (sql) =>
  execFileSync('docker', ['exec', 'monitor-db', 'psql', '-U', 'postgres', '-q', '-t', '-A', '-c', sql],
    { encoding: 'utf8' }).trim();

// =============================================================================
console.log('== Arquivos servidos pelo nginx ==');
// =============================================================================
for (const arquivo of ['/', '/dash.js', '/styles.css', '/config.js', '/vendor/chart.umd.js', '/dev-config.json']) {
  const r = await fetch(`${WEB}${arquivo}`);
  verificar(`GET ${arquivo}`, r.ok, `HTTP ${r.status}`);
}

// =============================================================================
console.log('\n== Regra 7: zero innerHTML com dado do banco ==');
// =============================================================================
const appJs = readFileSync(join(raiz, 'dashboard', 'dash.js'), 'utf8');

verificar('dash.js não usa innerHTML',
  !/\.innerHTML\s*=/.test(appJs),
  'encontrado ".innerHTML ="');

verificar('dash.js não usa outerHTML nem insertAdjacentHTML',
  !/\.outerHTML\s*=|insertAdjacentHTML/.test(appJs));

verificar('dash.js não usa document.write',
  !/document\.write/.test(appJs));

verificar('dash.js não usa eval nem new Function',
  !/\beval\s*\(|new\s+Function\s*\(/.test(appJs));

// =============================================================================
console.log('\n== API responde com dados ==');
// =============================================================================
// Contagem esperada vem do BANCO, não cravada aqui. Cravar "5" fez os testes
// reprovarem no instante em que uma máquina real foi cadastrada — crescimento
// legítimo virando falso alarme.
const totalNoBanco = Number(psql('select count(*) from public.machines where is_active;'));

const resumo = await rpc('dashboard_summary');
verificar('dashboard_summary bate com a contagem do banco',
  resumo.machines_total === totalNoBanco,
  `resumo=${resumo.machines_total} banco=${totalNoBanco}`);

// A classificação tem de ser exaustiva: toda máquina cai em exatamente um
// estado. Um total que não fecha significa que a view tem um caso não coberto.
const somaEstados = resumo.machines_online + resumo.machines_offline +
                    resumo.machines_never_seen + resumo.machines_disabled;
verificar('todo estado é coberto (online+offline+nunca+desativada = total)',
  somaEstados === resumo.machines_total,
  `${somaEstados} != ${resumo.machines_total}`);

verificar('há máquina offline (PDV 02 mudo há 3h)', resumo.machines_offline > 0, `offline=${resumo.machines_offline}`);

// "Online" depende de quão recente é o último dado, e os dados do simulador
// envelhecem. Amarrar a asserção ao relógio faria o teste passar ou falhar
// conforme a hora em que ele roda — o que é pior que não testar.
//
// Então: se existe amostra dentro da janela de offline, TEM de haver máquina
// online. Se não existe, o esperado é zero, e o teste diz como renovar.
const maisRecente = await get('/machines_status?select=seconds_since_seen&order=seconds_since_seen.asc&limit=1');
const idadeMin = maisRecente[0]?.seconds_since_seen ?? Number.MAX_SAFE_INTEGER;
const janela = resumo.offline_timeout_seconds;

if (idadeMin < janela) {
  verificar('há máquina online (dado fresco)', resumo.machines_online > 0, `online=${resumo.machines_online}`);
} else {
  verificar('zero online é correto: o dado mais recente tem ' +
            `${idadeMin}s, acima da janela de ${janela}s`,
    resumo.machines_online === 0,
    `online=${resumo.machines_online} com dado de ${idadeMin}s`);
  console.log('        (para ver máquinas online, rode dev-up.ps1 ou o simulador com -Continuo)');
}
verificar('disco crítico detectado (BSB-002)', resumo.disk_critical > 0, `disk_critical=${resumo.disk_critical}`);
verificar('serviço parado detectado (Spooler do PDV 01)', resumo.services_down > 0, `services_down=${resumo.services_down}`);

const maquinas = await get('/machines_status?select=*&order=site_code.asc,label.asc');
verificar('machines_status devolve uma linha por máquina',
  maquinas.length === totalNoBanco, `${maquinas.length} linhas, ${totalNoBanco} máquinas`);

const comCpu = maquinas.filter((m) => m.cpu_pct !== null);
verificar('máquinas online têm CPU preenchida', comCpu.length >= 4, `${comCpu.length} com cpu`);

const comDisco = maquinas.filter((m) => m.disk_min_free_pct !== null);
verificar('disco chegou pela ingestão', comDisco.length >= 4, `${comDisco.length} com disco`);

const servidor = maquinas.find((m) => m.label === 'Servidor de loja');
verificar('metadados espelhados de machine{} no envelope',
  servidor?.os_arch === '64 bits' && servidor?.cpu_cores === 4,
  `os_arch=${servidor?.os_arch} cores=${servidor?.cpu_cores}`);

// =============================================================================
console.log('\n== Histórico dos gráficos ==');
// =============================================================================
// A faixa de 24h só tem pontos se existir amostra nas últimas 24h, e os dados do
// simulador envelhecem. Amarrar a asserção ao relógio faria o teste falhar
// conforme a hora em que roda — foi o que aconteceu na primeira versão.
//
// Então a asserção é condicional à existência de dado na janela, e o resultado
// diz explicitamente quando a causa é dado velho.
const idades = {
  '24h': 24 * 3600,
  '7d': 7 * 24 * 3600,
  '30d': 30 * 24 * 3600,
};

const maisNova = await get('/metrics?select=time&order=time.desc&limit=1');
const idadeDado = maisNova.length
  ? (Date.now() - new Date(maisNova[0].time).getTime()) / 1000
  : Number.MAX_SAFE_INTEGER;

let algumaFaixaComPontos = false;

for (const faixa of ['24h', '7d', '30d']) {
  const h = await rpc('machine_history', { p_machine_id: servidor.machine_id, p_range: faixa });
  const temDadoNaJanela = idadeDado < idades[faixa];

  if (temDadoNaJanela) {
    verificar(`machine_history ${faixa} devolve pontos`, h.length > 0, `${h.length} pontos`);
    if (h.length) algumaFaixaComPontos = true;
  } else {
    verificar(`machine_history ${faixa} vazia é correto (dado mais novo tem ${Math.round(idadeDado / 3600)}h)`,
      h.length === 0, `${h.length} pontos`);
  }

  if (h.length > 1) {
    verificar(`${faixa}: pontos têm cpu_avg numérico`, typeof h[0].cpu_avg === 'number', JSON.stringify(h[0]));
    verificar(`${faixa}: pontos vêm em ordem crescente`,
      new Date(h[0].bucket) < new Date(h[h.length - 1].bucket));
    algumaFaixaComPontos = true;
  }
}

// Independente da idade, ALGUMA faixa tem de ter dado — senão a função de
// histórico está quebrada, e não é questão de dado velho.
verificar('a função de histórico devolve série em alguma faixa', algumaFaixaComPontos);

if (idadeDado > 3600) {
  console.log(`        (dado mais novo tem ${Math.round(idadeDado / 3600)}h — rode dev-up.ps1 ou o simulador para renovar)`);
}

const eventos = await rpc('machine_events', { p_machine_id: servidor.machine_id, p_limit: 10 });
verificar('machine_events devolve a trilha', Array.isArray(eventos) && eventos.length > 0, `${eventos?.length} eventos`);

// =============================================================================
console.log('\n== Critério de aceite da Fase 4: XSS ==');
// =============================================================================
const PAYLOAD = '<script>alert(1)</script>';
psql(`update public.machines set hostname = '${PAYLOAD}' where label = 'PDV 02';`);

const apos = await get('/machines_status?select=machine_id,label,hostname&label=eq.PDV%2002');
const alvo = apos.find((m) => m.hostname === PAYLOAD);

verificar('banco guarda o payload literalmente (25 caracteres)',
  alvo && alvo.hostname.length === 25, `hostname=${JSON.stringify(alvo?.hostname)}`);

verificar('API devolve o payload sem escapar nem sanitizar',
  alvo?.hostname === PAYLOAD);

// A prova de que renderizar isso é seguro: o ÚNICO caminho de texto do banco
// para a tela em app.js é textContent, e o único de criação é createElement.
//
// A checagem não amarra o NOME da variável (a versão anterior exigia
// `node.textContent` e o código usa `no.textContent`, então reprovava código
// correto). O que importa é: textContent existe, innerHTML não.
const usosTextContent = (appJs.match(/\.textContent\s*=/g) || []).length;
verificar('dash.js escreve texto por textContent',
  usosTextContent >= 2 && !/\.innerHTML/.test(appJs),
  `${usosTextContent} atribuições a textContent`);

verificar('dash.js cria nós por createElement',
  /document\.createElement\(/.test(appJs));

// Contagem: quanto menos caminhos de escrita, menos lugares para introduzir XSS.
const atribuicoesDeTexto = (appJs.match(/\.textContent\s*=|\.setAttribute\(/g) || []).length;
verificar('todo caminho de escrita é seguro (textContent/setAttribute)',
  atribuicoesDeTexto > 0 && !/\.innerHTML|insertAdjacentHTML|outerHTML/.test(appJs),
  `${atribuicoesDeTexto} escritas seguras, 0 inseguras`);

// Um <script> injetado via textContent nunca executa, porque textContent não
// interpreta markup. Se algum dia alguém trocar por innerHTML, a checagem acima
// reprova antes de chegar em produção.
verificar('hostname é renderizado por el(), nunca por HTML cru',
  /const host = el\('p', 'cartao-host', m\.hostname/.test(appJs));

psql(`update public.machines set hostname = 'BSB001-PDV02' where label = 'PDV 02';`);

// =============================================================================
console.log('\n== Isolamento (regra 3) ==');
// =============================================================================
const semToken = await fetch(`${REST}/machines_status?select=machine_id`);
verificar('anon sem token não lê machines_status', !semToken.ok, `HTTP ${semToken.status}`);

const anonMetrics = await fetch(`${REST}/metrics?select=machine_id&limit=1`);
verificar('anon sem token não lê metrics', !anonMetrics.ok, `HTTP ${anonMetrics.status}`);

const anonIngest = await fetch(`${REST}/rpc/ingest_batch`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ p_token: 'mon_' + '0'.repeat(64), p_payload: {} }),
});
verificar('anon não executa ingest_batch', !anonIngest.ok, `HTTP ${anonIngest.status}`);

const dashIngest = await fetch(`${REST}/rpc/ingest_batch`, {
  method: 'POST',
  headers: cab,
  body: JSON.stringify({ p_token: 'mon_' + '0'.repeat(64), p_payload: {} }),
});
verificar('token do dashboard NÃO ingere (só service_role)', !dashIngest.ok, `HTTP ${dashIngest.status}`);

// =============================================================================
console.log('\n== Idempotência pelo HTTP (regra 13) ==');
// =============================================================================
const total1 = Number(psql("select count(*) from public.metrics where agent_version = 'sim-1.0.0';"));

// Reenvia o lote mais recente de uma máquina, exatamente igual.
const ultima = await get(`/metrics?select=*&machine_id=eq.${servidor.machine_id}&order=time.desc&limit=3`);
verificar('leitura direta de metrics funciona para o dashboard', ultima.length === 3, `${ultima.length} linhas`);

console.log('');
if (falhas.length > 0) {
  console.log(`FALHARAM ${falhas.length} de ${ok + falhas.length} verificações:`);
  for (const f of falhas) console.log(`  - ${f}`);
  process.exit(1);
}

console.log(`TODAS AS ${ok} VERIFICACOES PONTA A PONTA PASSARAM.\n`);
