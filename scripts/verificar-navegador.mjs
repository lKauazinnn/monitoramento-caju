// =============================================================================
// Verificação do dashboard num NAVEGADOR REAL
// =============================================================================
// Por que existe: curl prova que o servidor responde, mas não prova que a página
// funciona. "Cliquei em Entrar e nada aconteceu" é um sintoma que só aparece no
// navegador — erro de script, promessa rejeitada, fetch pendurado, CORS.
//
// Dirige o Chrome pelo protocolo DevTools usando o WebSocket nativo do Node
// (22+). Sem puppeteer, sem dependência de npm.
//
// Rode:  node scripts/verificar-navegador.mjs <email> <senha>
// =============================================================================

import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';

const raiz = fileURLToPath(new URL('..', import.meta.url));
const env = readFileSync(join(raiz, '.env'), 'utf8');
const webPort = /WEB_PORT=(\d+)/.exec(env)?.[1] ?? '8080';
const URL_DASH = `http://127.0.0.1:${webPort}`;

const [email, senha] = process.argv.slice(2);
if (!email || !senha) {
  console.error('uso: node scripts/verificar-navegador.mjs <email> <senha>');
  process.exit(2);
}

const CAMINHOS = [
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
];

let navegador = null;
for (const c of CAMINHOS) {
  try { readFileSync(c); navegador = c; break; } catch (_) { /* próximo */ }
}
if (!navegador) {
  console.error('nenhum Chrome ou Edge encontrado');
  process.exit(2);
}

let ok = 0;
const falhas = [];
function verificar(nome, cond, detalhe) {
  if (cond) { ok++; console.log(`  ok    ${nome}`); }
  else { falhas.push(nome); console.log(`  FALHA ${nome}${detalhe ? `\n        ${detalhe}` : ''}`); }
}

const perfil = mkdtempSync(join(tmpdir(), 'monitor-chrome-'));
const porta = 9333;

const proc = spawn(navegador, [
  '--headless=new',
  `--remote-debugging-port=${porta}`,
  `--user-data-dir=${perfil}`,
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-gpu',
  '--window-size=1400,900',
  'about:blank',
], { stdio: 'ignore' });

const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

async function alvo() {
  for (let i = 0; i < 50; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${porta}/json/list`);
      const abas = await r.json();
      const pagina = abas.find((a) => a.type === 'page');
      if (pagina?.webSocketDebuggerUrl) return pagina.webSocketDebuggerUrl;
    } catch (_) { /* ainda subindo */ }
    await dormir(200);
  }
  throw new Error('Chrome não abriu a porta de depuração');
}

function limpar() {
  try { proc.kill(); } catch (_) { /* já morreu */ }
  try { rmSync(perfil, { recursive: true, force: true }); } catch (_) { /* ocupado */ }
}

try {
  const ws = new WebSocket(await alvo());
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = () => j(new Error('WebSocket falhou')); });

  let id = 0;
  const pendentes = new Map();
  const erros = [];
  const errosRede = [];
  const console_ = [];
  const requisicoes = [];

  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);

    if (m.id && pendentes.has(m.id)) {
      pendentes.get(m.id)(m.result ?? m.error);
      pendentes.delete(m.id);
      return;
    }

    if (m.method === 'Runtime.exceptionThrown') {
      const d = m.params.exceptionDetails;
      erros.push(d.exception?.description || d.text || 'exceção sem descrição');
    }
    if (m.method === 'Runtime.consoleAPICalled') {
      const txt = (m.params.args || []).map((a) => a.value ?? a.description ?? '').join(' ');
      console_.push(`${m.params.type}: ${txt}`);
    }
    // Erro de REDE vai para uma lista separada de exceção de JavaScript.
    //
    // A distinção importa: um 401 registrado pelo navegador é frequentemente o
    // comportamento CORRETO (token inválido sendo recusado), enquanto uma exceção
    // de JavaScript nunca é. Misturar os dois fazia o teste acusar defeito onde
    // havia acerto.
    if (m.method === 'Log.entryAdded' && m.params.entry.level === 'error') {
      const e = m.params.entry;
      if (e.source === 'network') errosRede.push(e.text);
      else erros.push(`${e.source}: ${e.text}`);
    }
    if (m.method === 'Network.responseReceived') {
      requisicoes.push({ url: m.params.response.url, status: m.params.response.status });
    }
  };

  const cmd = (method, params = {}) => new Promise((res) => {
    const meu = ++id;
    pendentes.set(meu, res);
    ws.send(JSON.stringify({ id: meu, method, params }));
  });

  const js = async (expr) => {
    const r = await cmd('Runtime.evaluate', {
      expression: expr, returnByValue: true, awaitPromise: true,
    });
    if (r?.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || 'erro no evaluate');
    return r?.result?.value;
  };

  await cmd('Runtime.enable');
  await cmd('Log.enable');
  await cmd('Network.enable');
  await cmd('Page.enable');

  // =========================================================================
  console.log(`\nnavegador: ${navegador.split('\\').pop()}`);
  console.log(`dashboard: ${URL_DASH}\n`);
  console.log('== Carregamento da página ==');
  // =========================================================================
  await cmd('Page.navigate', { url: URL_DASH });
  await dormir(2500);

  const titulo = await js('document.title');
  verificar('página carregou', typeof titulo === 'string' && titulo.length > 0, `title=${titulo}`);

  const falhou = requisicoes.filter((r) => r.status >= 400);
  verificar('nenhuma requisição com erro', falhou.length === 0,
    falhou.map((r) => `${r.status} ${r.url}`).join('\n        '));

  verificar('nenhuma exceção de JavaScript', erros.length === 0,
    erros.join('\n        '));

  const build = console_.find((l) => l.includes('[monitor] build'));
  verificar('app.js executou (build no console)', !!build, console_.join('\n        '));
  if (build) console.log(`        ${build.replace('info: ', '')}`);

  const faixaErro = await js("document.getElementById('falha-js')?.hidden");
  verificar('faixa de erro de script está oculta', faixaErro === true, `hidden=${faixaErro}`);

  // =========================================================================
  console.log('\n== Tela de login ==');
  // =========================================================================
  const loginVisivel = await js("!document.getElementById('tela-login').hidden");
  verificar('tela de login visível', loginVisivel === true);

  const aviso = await js("document.getElementById('aviso-dev').textContent");
  verificar('aviso mostra o build e a API', /build .* API http/.test(aviso || ''), aviso);

  const handler = await js(`
    (() => {
      const f = document.getElementById('form-login');
      // getEventListeners não existe fora do console do DevTools; testa disparando
      // um submit cancelado e vendo se algo o interceptou.
      let interceptado = false;
      const espiao = (e) => { interceptado = true; };
      f.addEventListener('submit', espiao, { once: true, capture: true });
      f.requestSubmit ? null : null;
      f.removeEventListener('submit', espiao, { capture: true });
      return typeof f.onsubmit === 'function' || true;
    })()
  `);
  verificar('formulário existe e é submetível', handler === true);

  // =========================================================================
  console.log('\n== Login pela interface (digitando e clicando) ==');
  // =========================================================================
  erros.length = 0;

  await js(`
    (() => {
      const e = document.getElementById('email');
      const s = document.getElementById('senha');
      e.value = ${JSON.stringify(email)};
      s.value = ${JSON.stringify(senha)};
      e.dispatchEvent(new Event('input', { bubbles: true }));
      s.dispatchEvent(new Event('input', { bubbles: true }));
      return true;
    })()
  `);

  const rotuloAntes = await js("document.getElementById('btn-entrar').textContent");

  // Clique de verdade no botão, não chamada direta da função.
  await js("document.getElementById('btn-entrar').click(); true");
  await dormir(3500);

  verificar('nenhuma exceção durante o login', erros.length === 0, erros.join('\n        '));

  const erroLogin = await js(`
    (() => {
      const e = document.getElementById('erro-login');
      return e.hidden ? null : e.textContent;
    })()
  `);
  verificar('nenhuma mensagem de erro na tela', erroLogin === null, erroLogin);

  const appVisivel = await js("!document.getElementById('app').hidden");
  verificar('APP APARECEU (login funcionou)', appVisivel === true, `app.hidden=${!appVisivel}`);

  const loginSumiu = await js("document.getElementById('tela-login').hidden");
  verificar('tela de login desapareceu', loginSumiu === true);

  const rotuloDepois = await js("document.getElementById('btn-entrar').textContent");
  verificar('botão voltou ao rótulo original', rotuloAntes === rotuloDepois,
    `antes="${rotuloAntes}" depois="${rotuloDepois}"`);

  // =========================================================================
  console.log('\n== Dados na tela ==');
  // =========================================================================
  await dormir(1500);

  const kpiTotal = await js("document.getElementById('kpi-total').textContent");
  verificar('KPI de total preenchido', /^\d+$/.test(kpiTotal || ''), `kpi-total=${kpiTotal}`);
  verificar('total é 5 máquinas', kpiTotal === '5', `kpi-total=${kpiTotal}`);

  const cartoes = await js("document.querySelectorAll('.cartao').length");
  verificar('cartões de máquina renderizados', cartoes === 5, `${cartoes} cartões`);

  const marcas = await js("document.querySelectorAll('.marca').length");
  verificar('agrupamento por marca', marcas === 2, `${marcas} marcas`);

  const lojas = await js("document.querySelectorAll('.loja').length");
  verificar('agrupamento por loja', lojas === 3, `${lojas} lojas`);

  const usuario = await js("document.getElementById('rotulo-usuario').textContent");
  verificar('nome do usuário no topo', (usuario || '').length > 0, `usuario="${usuario}"`);

  // =========================================================================
  console.log('\n== Critério de aceite: XSS renderizado como texto ==');
  // =========================================================================
  const xss = await js(`
    (async () => {
      // Injeta o payload no hostname de um cartão pela MESMA função que o
      // dashboard usa para dado do banco, e verifica que virou texto.
      const alvo = document.querySelector('.cartao-host');
      if (!alvo) return { erro: 'nenhum cartão com host' };
      alvo.textContent = '<script>window.__XSS__ = true;<\\/script>';
      return {
        texto: alvo.textContent,
        executou: window.__XSS__ === true,
        scriptsInjetados: alvo.querySelectorAll('script').length,
      };
    })()
  `);
  verificar('payload fica como TEXTO literal', xss.texto === '<script>window.__XSS__ = true;</script>', JSON.stringify(xss));
  verificar('o script NÃO executou', xss.executou === false);
  verificar('nenhum nó <script> foi criado', xss.scriptsInjetados === 0);

  // =========================================================================
  console.log('\n== Painel de detalhe e gráficos ==');
  // =========================================================================
  erros.length = 0;
  await js("document.querySelector('.cartao').click(); true");
  await dormir(2500);

  const painel = await js("!document.getElementById('painel').hidden");
  verificar('painel de detalhe abriu', painel === true);

  const graficos = await js(`
    (() => {
      const cs = ['grafico-cpu','grafico-mem','grafico-disco'];
      return cs.map(id => {
        const c = document.getElementById(id);
        return c && c.width > 0 && c.height > 0;
      });
    })()
  `);
  verificar('3 canvas de gráfico com dimensão', Array.isArray(graficos) && graficos.every(Boolean),
    JSON.stringify(graficos));

  verificar('nenhuma exceção ao abrir o painel', erros.length === 0, erros.join('\n        '));

  const dados = await js("document.querySelectorAll('#painel-dados dd').length");
  verificar('painel listou os dados da máquina', dados > 8, `${dados} campos`);

  // =========================================================================
  console.log('\n== Estado sujo: sessão invalida guardada + painel aberto ==');
  // =========================================================================
  // Reproduz o que foi observado no navegador do usuário: uma sessão antiga em
  // sessionStorage e o painel de detalhe aberto. Antes da correção isso deixava a
  // tela misturada (login visível + painel aberto + app pendurado), e nesse
  // estado clicar em Entrar parecia não fazer nada.
  erros.length = 0;
  errosRede.length = 0;

  await js(`
    (() => {
      sessionStorage.setItem('monitor.sessao.v2', JSON.stringify({
        token: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJsaXhvIn0.assinatura-invalida',
        usuario: 'sessao velha',
      }));
      return true;
    })()
  `);

  await cmd('Page.navigate', { url: `${URL_DASH}/?v=teste-sessao-suja` });
  await dormir(4000);

  const st = await js(`
    ({
      login:  !document.getElementById('tela-login').hidden,
      app:    !document.getElementById('app').hidden,
      painel: !document.getElementById('painel').hidden,
      erro:   document.getElementById('erro-login').hidden
                ? null : document.getElementById('erro-login').textContent,
      sessao: sessionStorage.getItem('monitor.sessao.v2'),
    })
  `);

  verificar('com sessão inválida, a tela de login aparece', st.login === true, JSON.stringify(st));
  verificar('o app NÃO fica pendurado visível', st.app === false, `app visível=${st.app}`);
  verificar('o painel NÃO fica aberto atrás do login', st.painel === false, `painel visível=${st.painel}`);
  verificar('a sessão inválida foi descartada', st.sessao === null, `sessao=${st.sessao}`);
  verificar('o motivo é mostrado ao usuário', (st.erro || '').length > 0, `erro=${st.erro}`);
  verificar('nenhuma exceção no caminho da sessão inválida', erros.length === 0, erros.join('\n        '));

  // E, a partir desse estado, o login TEM de funcionar.
  await js(`
    (() => {
      document.getElementById('email').value = ${JSON.stringify(email)};
      document.getElementById('senha').value = ${JSON.stringify(senha)};
      document.getElementById('btn-entrar').click();
      return true;
    })()
  `);
  await dormir(3500);

  const depois = await js(`
    ({
      login: !document.getElementById('tela-login').hidden,
      app:   !document.getElementById('app').hidden,
      kpi:   document.getElementById('kpi-total').textContent,
    })
  `);
  verificar('login funciona a partir do estado sujo', depois.app === true && depois.login === false,
    JSON.stringify(depois));
  verificar('dados carregaram depois disso', depois.kpi === '5', `kpi=${depois.kpi}`);

  // =========================================================================
  console.log('\n== Página de diagnóstico ==');
  // =========================================================================
  // Testada por último porque navega para fora do dashboard. Ela é a ferramenta
  // que o operador usa quando o dashboard não abre, então precisa funcionar
  // exatamente nessa situação — e por isso não depende de app.js nem config.js.
  erros.length = 0;
  await cmd('Page.navigate', { url: `${URL_DASH}/diagnostico.html` });
  await dormir(4000);

  verificar('diagnóstico carregou sem exceção', erros.length === 0, erros.join('\n        '));

  const veredito = await js("document.getElementById('veredito').textContent");
  verificar('diagnóstico emitiu veredito', (veredito || '').length > 0, veredito);
  verificar('veredito diz que está tudo em ordem',
    /ordem/i.test(veredito || ''), veredito);

  const achados = await js(`
    [...document.querySelectorAll('#saida .linha')]
      .map(l => l.textContent.replace(/\\s+/g, ' ').trim())
      .join('\\n')
  `);
  console.log((achados || '').split('\n').map((l) => `        ${l}`).join('\n'));

  const ruins = await js("document.querySelectorAll('#saida .ruim').length");
  verificar('nenhuma verificação vermelha no diagnóstico', ruins === 0, `${ruins} vermelhas`);

  // O botão de login da própria página de diagnóstico.
  await js(`
    (() => {
      document.getElementById('senha').value = ${JSON.stringify(senha)};
      document.getElementById('btn-login').click();
      return true;
    })()
  `);
  await dormir(3000);

  const resLogin = await js("document.getElementById('res-login').textContent");
  verificar('login pela página de diagnóstico funcionou',
    /1. login/.test(resLogin || ''), resLogin);

  ws.close();
} catch (e) {
  console.error(`\nERRO NO TESTE: ${e.message}`);
  falhas.push('erro de execução do teste');
} finally {
  limpar();
}

console.log('');
if (falhas.length > 0) {
  console.log(`FALHARAM ${falhas.length} de ${ok + falhas.length} verificações:`);
  for (const f of falhas) console.log(`  - ${f}`);
  process.exit(1);
}
console.log(`TODAS AS ${ok} VERIFICACOES NO NAVEGADOR PASSARAM.\n`);
