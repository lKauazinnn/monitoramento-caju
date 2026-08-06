// =============================================================================
// Verificação da Edge Function ANTES de publicar
// =============================================================================
// Rode:  node scripts/verificar-edge-function.mjs
//
// Sobe o index.ts num contêiner Deno igual ao da plataforma e exercita as rotas.
// Precisa só de Docker — nada de conta, token ou projeto publicado.
//
// POR QUE VALE A PENA: o deploy é a hora errada de descobrir erro de código, e a
// LOJA é a hora ainda mais errada. Foi um BOM no início do instalar.ps1 que
// quebrou a primeira instalação real, e nenhuma verificação daquela época
// pegava, porque todas inspecionavam o texto e o problema era um caractere antes
// dele. Aqui quem julga é o próprio PowerShell.
//
// O banco NÃO é necessário: tudo o que se verifica aqui acontece antes de a
// função tocar no PostgREST. O caminho até o banco já é coberto pelo endpoint
// local, que importa o MESMO lib.ts.
// =============================================================================

import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { writeFileSync, mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const raiz = fileURLToPath(new URL('..', import.meta.url));
const funcDir = join(raiz, 'supabase', 'functions', 'ingest');
const PORTA = 8123;
const BASE = `http://127.0.0.1:${PORTA}`;
const SEGREDO = 'segredo-de-teste-com-mais-de-24-caracteres';
const NOME = 'verificar-edge-function';

let ok = 0;
const falhas = [];
const v = (nome, cond, det = '') => {
  if (cond) { ok++; console.log(`  ok    ${nome}`); }
  else { falhas.push(nome); console.log(`  FALHA ${nome}\n        ${det}`); }
};

const docker = (args, silencioso = true) =>
  spawnSync('docker', args, { encoding: 'utf8', stdio: silencioso ? 'pipe' : 'inherit' });

const dormir = (ms) => new Promise((r) => setTimeout(r, ms));
const tmp = mkdtempSync(join(tmpdir(), 'edge-'));

docker(['rm', '-f', NOME]);

console.log('\nsubindo a Edge Function num contêiner Deno...\n');

// Caminho NATIVO do Windows, sem a tradução //c/... que o bash do MSYS exige.
// Aqui quem chama é o Node, então não há shell reinterpretando nada — e o
// Docker Desktop aceita `C:\caminho:/destino` direto. O espaço em "deashboard
// servidor" também não é problema porque o argumento vai num array, não numa
// linha de comando montada por concatenação.
const montagem = `${funcDir}:/f`;

const subiu = docker([
  'run', '-d', '--name', NOME, '-p', `${PORTA}:8000`,
  '-v', montagem,
  '-e', 'SUPABASE_URL=http://nao-usado.invalid',
  '-e', 'SUPABASE_SERVICE_ROLE_KEY=chave-de-teste',
  '-e', `INGEST_SHARED_SECRET=${SEGREDO}`,
  '-e', 'PORT=8000',
  'denoland/deno:latest', 'run', '--allow-net', '--allow-env', '/f/index.ts',
]);

if (subiu.status !== 0) {
  console.error(`não consegui subir o contêiner: ${subiu.stderr || subiu.stdout}`);
  process.exit(1);
}

try {
  let noAr = false;
  for (let i = 0; i < 40; i++) {
    try { await fetch(`${BASE}/healthz`, { signal: AbortSignal.timeout(1500) }); noAr = true; break; }
    catch (_) { await dormir(500); }
  }

  if (!noAr) {
    const log = docker(['logs', NOME]);
    console.error(`a função não subiu:\n${log.stdout}\n${log.stderr}`);
    process.exit(1);
  }

  const log = docker(['logs', NOME]);
  v('a função sobe sob Deno sem erro',
    /Listening on/.test(log.stdout + log.stderr),
    (log.stdout + log.stderr).slice(0, 300));

  // ---- healthz -------------------------------------------------------------
  const h = await (await fetch(`${BASE}/healthz`)).json();
  v('healthz responde', h.ok === true, JSON.stringify(h));
  v('healthz sem segredo NÃO expõe o banco', h.db === undefined, JSON.stringify(h));

  // ---- os dois scripts -----------------------------------------------------
  for (const arq of ['agente.ps1', 'instalar.ps1']) {
    const r = await fetch(`${BASE}/${arq}`);
    const bruto = Buffer.from(await r.arrayBuffer());

    v(`GET /${arq}`, r.ok && bruto.length > 1000, `HTTP ${r.status}, ${bruto.length} bytes`);

    // O BOM aqui quebra `[scriptblock]::Create`: ele vira o primeiro caractere
    // do texto e `param()` deixa de ser a primeira instrução do bloco.
    v(`/${arq} servido SEM BOM`,
      !(bruto[0] === 0xEF && bruto[1] === 0xBB && bruto[2] === 0xBF),
      `primeiros bytes: ${[...bruto.slice(0, 3)].map((x) => x.toString(16)).join(' ')}`);

    // A verificação definitiva: quem julga é o PowerShell, não uma regex.
    const arqTmp = join(tmp, arq);
    writeFileSync(arqTmp, bruto);
    const ps = `
      $ErrorActionPreference = 'Stop'
      try {
        $t = Get-Content -Raw -LiteralPath '${arqTmp.replace(/'/g, "''")}'
        $null = [scriptblock]::Create($t)
        'OK'
      } catch { 'ERRO: ' + $_.Exception.Message.Split([char]10)[0] }`;

    let saida = '';
    try {
      saida = execFileSync('powershell',
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', ps],
        { encoding: 'utf8' }).trim();
    } catch (e) { saida = `ERRO: ${e.message}`; }

    v(`o PowerShell analisa /${arq} como scriptblock`, saida.startsWith('OK'), saida.slice(0, 200));
  }

  // ---- roteamento ----------------------------------------------------------
  // A plataforma serve em /functions/v1/<nome>; localmente a raiz é /. As duas
  // formas têm de cair na mesma rota.
  const rota = await fetch(`${BASE}/functions/v1/ingest/healthz`);
  v('rota no formato da plataforma funciona', rota.status === 200, `HTTP ${rota.status}`);

  const naoExiste = await fetch(`${BASE}/rota-que-nao-existe`);
  v('rota desconhecida devolve 404 honesto', naoExiste.status === 404, `HTTP ${naoExiste.status}`);

  // ---- as negações ---------------------------------------------------------
  // Acontecem ANTES de qualquer chamada ao banco — por isso este ensaio nem
  // precisa de banco, e por isso o segredo é a primeira coisa validada.
  const envelope = JSON.stringify({
    agent_version: 'teste-1.0.0',
    samples: [{ t: new Date().toISOString(), cpu_pct: 1 }],
  });

  const post = (cab, corpo = envelope) => fetch(BASE, {
    method: 'POST', headers: { 'content-type': 'application/json', ...cab }, body: corpo,
  });

  const errado = await post({ 'x-monitor-secret': 'errado', authorization: 'Bearer mon_x' });
  v('segredo errado -> 401', errado.status === 401, `HTTP ${errado.status}`);

  const semAuth = await post({ 'x-monitor-secret': SEGREDO });
  v('sem Authorization -> 401', semAuth.status === 401, `HTTP ${semAuth.status}`);

  const envelopeRuim = await post(
    { 'x-monitor-secret': SEGREDO, authorization: 'Bearer mon_x' }, '{"samples":[]}');
  v('envelope inválido -> 400', envelopeRuim.status === 400, `HTTP ${envelopeRuim.status}`);

  // ---- o embutido bate com a origem ----------------------------------------
  const origem = readFileSync(join(raiz, 'agent', 'agente-powershell.ps1'), 'utf8')
    .replace(/^﻿/, '').replace(/\r\n/g, '\n');
  const servido = await (await fetch(`${BASE}/agente.ps1`)).text();
  v('o agente servido é idêntico ao do repositório', servido === origem,
    `servido=${servido.length} origem=${origem.length}`);
} finally {
  docker(['rm', '-f', NOME]);
  try { rmSync(tmp, { recursive: true, force: true }); } catch (_) { /* ocupado */ }
}

console.log('');
if (falhas.length) {
  console.log(`FALHARAM ${falhas.length} de ${ok + falhas.length}: ${falhas.join(', ')}`);
  process.exit(1);
}
console.log(`AS ${ok} VERIFICACOES DA EDGE FUNCTION PASSARAM (sob Deno, sem publicar).`);
