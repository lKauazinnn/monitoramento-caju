// =============================================================================
// Verificação do login local
// =============================================================================
// Exercita o caminho real: POST /rpc/local_sign_in como o navegador faz, e usa o
// token devolvido para ler dados protegidos por RLS.
//
// Rode:  node scripts/verificar-login.mjs <email> <senha>
// =============================================================================

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

const raiz = fileURLToPath(new URL('..', import.meta.url));
const cfg = JSON.parse(readFileSync(join(raiz, 'dashboard', 'dev-config.json'), 'utf8'));
const REST = cfg.restUrl;

const [email, senha] = process.argv.slice(2);
if (!email || !senha) {
  console.error('uso: node scripts/verificar-login.mjs <email> <senha>');
  process.exit(2);
}

let ok = 0;
const falhas = [];

function verificar(nome, condicao, detalhe) {
  if (condicao) { ok++; console.log(`  ok    ${nome}`); }
  else { falhas.push(nome); console.log(`  FALHA ${nome}${detalhe ? `\n        ${detalhe}` : ''}`); }
}

const login = async (e, s) => {
  const r = await fetch(`${REST}/rpc/local_sign_in`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_email: e, p_password: s }),
  });
  const t = await r.text();
  let corpo = {};
  try { corpo = JSON.parse(t); } catch (_) { corpo = { raw: t }; }
  return { status: r.status, corpo };
};

const psql = (sql) =>
  execFileSync('docker', ['exec', 'monitor-db', 'psql', '-U', 'postgres', '-q', '-t', '-A', '-c', sql],
    { encoding: 'utf8' }).trim();

console.log(`\nAPI: ${REST}\n`);

// =============================================================================
console.log('== Credencial correta ==');
// =============================================================================
const bom = await login(email, senha);
verificar('login devolve 200 com ok:true', bom.status === 200 && bom.corpo.ok === true, `HTTP ${bom.status} ${JSON.stringify(bom.corpo)}`);
verificar('resposta traz access_token', typeof bom.corpo.access_token === 'string');
verificar('resposta traz e-mail e nome', !!bom.corpo.user?.email, JSON.stringify(bom.corpo.user));
verificar('resposta NÃO traz hash de senha',
  !JSON.stringify(bom.corpo).includes('$2a$') && !JSON.stringify(bom.corpo).includes('$2b$'));

const token = bom.corpo.access_token;

// Estrutura do JWT: três partes base64url, sem '=' nem '+' nem '/'.
const partes = (token || '').split('.');
verificar('token tem 3 partes', partes.length === 3);
verificar('token é base64url puro (sem +, / ou =)',
  !/[+/=]/.test(token || 'x'), token?.slice(0, 40));

if (partes.length === 3) {
  const claims = JSON.parse(Buffer.from(partes[1], 'base64url').toString('utf8'));
  verificar('claim role = authenticated', claims.role === 'authenticated', JSON.stringify(claims));
  verificar('claim sub é UUID',
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(claims.sub || ''), claims.sub);
  verificar('claim exp no futuro', claims.exp > Math.floor(Date.now() / 1000));
  verificar('claim exp não é eterno (<= 30 dias)',
    claims.exp - claims.iat <= 60 * 60 * 24 * 30, `ttl=${claims.exp - claims.iat}s`);
}

// =============================================================================
console.log('\n== O token funciona nas rotas protegidas ==');
// =============================================================================
const cab = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };

const resumo = await fetch(`${REST}/rpc/dashboard_summary`, { method: 'POST', headers: cab, body: '{}' });
const dados = resumo.ok ? await resumo.json() : null;
verificar('dashboard_summary aceita o token', resumo.ok, `HTTP ${resumo.status}`);

// Contagem do BANCO, não cravada. Cravar "5" fez o teste reprovar no instante em
// que uma máquina real entrou no sistema.
const totalNoBanco = Number(psql('select count(*) from public.machines where is_active;'));
verificar('admin vê todas as máquinas do banco',
  dados?.machines_total === totalNoBanco,
  `resumo=${dados?.machines_total} banco=${totalNoBanco}`);

const maquinas = await fetch(`${REST}/machines_status?select=label,status`, { headers: cab });
verificar('machines_status aceita o token', maquinas.ok, `HTTP ${maquinas.status}`);

// =============================================================================
console.log('\n== Credenciais inválidas ==');
// =============================================================================
const senhaErrada = await login(email, senha + 'x');
verificar('senha errada é rejeitada', senhaErrada.corpo.ok !== true, JSON.stringify(senhaErrada.corpo));
verificar('senha errada não devolve token', !senhaErrada.corpo.access_token);

const inexistente = await login('naoexiste@cajupar.com', 'QualquerCoisa123');
verificar('e-mail inexistente é rejeitado', inexistente.corpo.ok !== true, JSON.stringify(inexistente.corpo));

// Mensagem IDÊNTICA nos dois casos: diferenciar transformaria o formulário num
// verificador de quais e-mails existem na empresa.
verificar('mensagem é idêntica para senha errada e e-mail inexistente',
  senhaErrada.corpo.message === inexistente.corpo.message,
  `"${senhaErrada.corpo.message}" vs "${inexistente.corpo.message}"`);

verificar('mensagem não revela se o e-mail existe',
  /inv[áa]lid/i.test(senhaErrada.corpo.message || '') &&
  !/senha incorreta|usu[áa]rio n[ãa]o|not found/i.test(senhaErrada.corpo.message || ''),
  senhaErrada.corpo.message);

const vazia = await login(email, '');
verificar('senha vazia é rejeitada', vazia.corpo.ok !== true, JSON.stringify(vazia.corpo));

// =============================================================================
console.log('\n== Bloqueio por força bruta ==');
// =============================================================================
psql(`update public.app_users set failed_attempts = 0, locked_until = null where lower(email) = lower('${email}');`);

let bloqueou = false;
for (let i = 0; i < 6; i++) {
  const r = await login(email, `errada-${i}`);
  if (/bloqueada/i.test(r.corpo.message || '')) { bloqueou = true; break; }
}
verificar('conta bloqueia após 5 tentativas erradas', bloqueou);

// Mesmo com a senha CORRETA, a conta bloqueada não entra.
const durante = await login(email, senha);
verificar('senha correta não entra enquanto bloqueada', durante.corpo.ok !== true && !durante.corpo.access_token, JSON.stringify(durante.corpo));

// Destravar é o que o operador faz recriando a senha.
psql(`update public.app_users set failed_attempts = 0, locked_until = null where lower(email) = lower('${email}');`);
const apos = await login(email, senha);
verificar('login volta a funcionar após destravar', apos.corpo.ok === true, JSON.stringify(apos.corpo));

// =============================================================================
console.log('\n== A senha não está em claro em lugar nenhum ==');
// =============================================================================
const hash = psql(`select password_hash from public.app_users where lower(email) = lower('${email}');`);
verificar('banco guarda bcrypt (prefixo $2)', hash.startsWith('$2'), hash.slice(0, 7));
verificar('hash tem 60 caracteres', hash.length === 60, `${hash.length}`);
verificar('hash usa custo 12', /^\$2[aby]\$12\$/.test(hash), hash.slice(0, 7));
verificar('a senha não aparece no hash', !hash.includes(senha));

const colunas = psql(`
  select count(*) from information_schema.columns
  where table_schema = 'public' and table_name = 'app_users'
    and column_name in ('password', 'senha', 'password_plain');`);
verificar('não existe coluna de senha em claro', colunas === '0');

// Nenhuma view pode projetar o hash.
const views = psql(`
  select count(*) from information_schema.columns
  where table_schema = 'public' and column_name = 'password_hash'
    and table_name in (select table_name from information_schema.views where table_schema = 'public');`);
verificar('nenhuma view expõe password_hash', views === '0');

// =============================================================================
console.log('\n== anon não escapa pelo login ==');
// =============================================================================
const anonUsers = await fetch(`${REST}/app_users?select=email,password_hash`);
verificar('anon não lê app_users', !anonUsers.ok, `HTTP ${anonUsers.status}`);

const anonCfg = await fetch(`${REST}/local_auth_config?select=jwt_secret`);
verificar('anon não lê o segredo de assinatura', !anonCfg.ok, `HTTP ${anonCfg.status}`);

const authUsers = await fetch(`${REST}/app_users?select=email,password_hash`, { headers: cab });
if (authUsers.ok) {
  const lista = await authUsers.json();
  verificar('nem admin autenticado recebe o hash pela API',
    !JSON.stringify(lista).includes('$2'),
    JSON.stringify(lista).slice(0, 120));
} else {
  verificar('app_users protegido para authenticated também', true);
}

const anonUpsert = await fetch(`${REST}/rpc/upsert_local_user`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ p_email: 'invasor@x.com', p_password: 'SenhaForte123' }),
});
verificar('anon não cria usuário', !anonUpsert.ok, `HTTP ${anonUpsert.status}`);

const authUpsert = await fetch(`${REST}/rpc/upsert_local_user`, {
  method: 'POST',
  headers: cab,
  body: JSON.stringify({ p_email: 'invasor@x.com', p_password: 'SenhaForte123' }),
});
verificar('nem admin do dashboard cria usuário (só service_role)', !authUpsert.ok, `HTTP ${authUpsert.status}`);

console.log('');
if (falhas.length > 0) {
  console.log(`FALHARAM ${falhas.length} de ${ok + falhas.length} verificações:`);
  for (const f of falhas) console.log(`  - ${f}`);
  process.exit(1);
}
console.log(`TODAS AS ${ok} VERIFICACOES DE LOGIN PASSARAM.\n`);
