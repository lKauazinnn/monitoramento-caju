// =============================================================================
// A tela de login continua desenhada e continua ligada
// =============================================================================
// Este arquivo existe porque o login passou meses FUNCIONANDO e sem uma linha de
// CSS: `.tela-login` e `.caixa-login` estavam no HTML e nunca no styles.css.
// Ninguem notou porque todo teste que existia entrava pelo login e seguia para o
// painel — nenhum olhava a tela. Um formulario branco de navegador autentica
// perfeitamente.
//
// Duas conferencias, nas duas direcoes:
//
//   1. toda classe usada no login.html tem regra no styles.css
//      (pega o caso original: markup sem estilo)
//   2. todo id que o login.js procura existe no login.html
//      (pega o inverso: comportamento apontando para elemento que nao existe,
//      que falha em silencio porque `addEventListener` num null so explode
//      naquele clique)
//
// Nao valida credencial nem fala com servidor — para isso existe o
// verificar-login.mjs, que precisa de e-mail e senha de verdade.
// =============================================================================

import { readFileSync } from 'node:fs';

const base = new URL('../dashboard/', import.meta.url);
const html = readFileSync(new URL('login.html', base), 'utf8');
const css = readFileSync(new URL('styles.css', base), 'utf8');
const js = readFileSync(new URL('login.js', base), 'utf8');

let falhas = 0;
const falhar = (msg) => { console.log(`  FALHOU  ${msg}`); falhas++; };

// -----------------------------------------------------------------------------
// 1. Toda classe do HTML tem regra no CSS
// -----------------------------------------------------------------------------
const classes = new Set();
for (const m of html.matchAll(/class="([^"]+)"/g)) {
  for (const c of m[1].trim().split(/\s+/)) if (c) classes.add(c);
}

console.log('== classes com estilo ==');
for (const c of [...classes].sort()) {
  // Ancorado em `.classe` seguido do que pode fechar um seletor. Sem a ancora,
  // `.lg-ver` casaria dentro de `.lg-verde` e o teste passaria por engano.
  const re = new RegExp(`\\.${c.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![\\w-])`);
  if (!re.test(css)) falhar(`a classe "${c}" nao tem nenhuma regra no styles.css`);
}
console.log(`  ${classes.size} classes conferidas`);

// -----------------------------------------------------------------------------
// 2. Todo id que o JS procura existe no HTML
// -----------------------------------------------------------------------------
const idsNoHtml = new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]));
const idsNoJs = new Set([...js.matchAll(/getElementById\('([^']+)'\)/g)].map((m) => m[1]));

console.log('\n== ligacoes do login.js ==');
for (const id of [...idsNoJs].sort()) {
  if (!idsNoHtml.has(id)) falhar(`o login.js procura #${id}, que nao existe no login.html`);
}
console.log(`  ${idsNoJs.size} ids conferidos`);

// -----------------------------------------------------------------------------
// 3. O que a tela nao pode perder
// -----------------------------------------------------------------------------
// Estes quatro sao o login em si. Um redesenho pode mudar toda a aparencia, mas
// se qualquer um sair, a pagina para de autenticar.
console.log('\n== o essencial ==');
for (const [id, oque] of [
  ['form-login', 'o formulario que autentica'],
  ['email', 'o campo de e-mail'],
  ['senha', 'o campo de senha'],
  ['btn-entrar', 'o botao de entrar'],
  ['erro', 'onde a falha de credencial aparece'],
]) {
  if (!idsNoHtml.has(id)) falhar(`#${id} sumiu do login.html (${oque})`);
}
console.log('  5 elementos essenciais presentes');

// -----------------------------------------------------------------------------
// 4. Regras do projeto que valem em dobro numa pagina de credencial
// -----------------------------------------------------------------------------
console.log('\n== regras ==');

if (/<script(?![^>]*\ssrc=)/.test(html)) {
  falhar('script embutido no login.html: a CSP recusa, e esta e a pagina onde '
       + "'unsafe-inline' nao pode existir");
}

if (/\.innerHTML\s*=/.test(js)) {
  falhar('innerHTML no login.js (regra 7): use textContent');
}

if (!/autocomplete="current-password"/.test(html)) {
  falhar('o campo de senha perdeu autocomplete="current-password"');
}

// A senha nao pode sobrar no DOM depois do envio, nem no sucesso nem na falha.
const limpezas = (js.match(/getElementById\('senha'\)\.value\s*=\s*''/g) || []).length;
if (limpezas < 2) {
  falhar(`a senha e limpa do DOM em ${limpezas} lugar(es); precisa ser no sucesso E na falha`);
}

if (!/localStorage\.getItem\('monitor\.tema'\)/.test(js)) {
  falhar('o login parou de respeitar o tema salvo do painel');
}

console.log('  regras de CSP, XSS, senha e tema conferidas');

console.log(falhas === 0
  ? '\nA tela de login esta desenhada e ligada.'
  : `\n${falhas} problema(s).`);
process.exit(falhas === 0 ? 0 : 1);
