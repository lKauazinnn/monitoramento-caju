// =============================================================================
// Login (modo Supabase)
// =============================================================================
// Extraido de login.html para que a Content-Security-Policy possa recusar
// script embutido. Uma pagina de credencial publicada na internet e exatamente
// onde 'unsafe-inline' nao deveria existir: ela e o alvo mais obvio de uma
// injecao, e a CSP e a ultima linha de defesa se algo passar.
//
// O caminho de autenticacao e o mesmo desde a primeira versao. O que entrou
// depois foi tela: tema, ver a senha, e dizer para qual ambiente se esta
// entrando.
// =============================================================================

'use strict';

var CFG = window.MONITOR_CONFIG || {};
var CHAVE_TOKEN = 'monitor.token';

function erro(msg) {
  var e = document.getElementById('erro');
  e.textContent = msg;   // textContent, nunca innerHTML (regra 7)
  e.hidden = false;
}

// -----------------------------------------------------------------------------
// Tema
// -----------------------------------------------------------------------------
// Mesma chave do painel: quem trabalha no claro nao deve ser jogado no escuro
// justamente na tela de entrada. Aplicado ANTES de qualquer outra coisa, para
// nao existir um quadro pintado no tema errado.
function aplicarTema(tema) {
  document.documentElement.setAttribute('data-tema', tema === 'light' ? 'light' : 'dark');
}

var temaSalvo = 'dark';
try { temaSalvo = localStorage.getItem('monitor.tema') || 'dark'; } catch (e) { /* modo privado */ }
aplicarTema(temaSalvo);

document.getElementById('lg-tema').addEventListener('click', function () {
  var novo = document.documentElement.getAttribute('data-tema') === 'light' ? 'dark' : 'light';
  aplicarTema(novo);
  try { localStorage.setItem('monitor.tema', novo); } catch (e) { /* modo privado */ }
});

// -----------------------------------------------------------------------------
// Ver a senha
// -----------------------------------------------------------------------------
document.getElementById('btn-ver-senha').addEventListener('click', function () {
  var campo = document.getElementById('senha');
  var mostrando = campo.type === 'text';
  campo.type = mostrando ? 'password' : 'text';
  this.setAttribute('aria-pressed', String(!mostrando));
  this.setAttribute('aria-label', mostrando ? 'Mostrar a senha' : 'Ocultar a senha');
  // O foco volta para o campo: quem clicou no olho estava digitando.
  campo.focus();
});

// -----------------------------------------------------------------------------
// Qual ambiente
// -----------------------------------------------------------------------------
// Entrar em producao achando que e a stack local e um erro barato de cometer e
// caro de descobrir: daqui saem comandos para maquina de loja. O aviso e ambar
// so quando e producao de fato.
//
// SEM O ENDERECO DO PROJETO. Ele nao e segredo — esta no config.js desta mesma
// pagina, no anon key e na URL de toda requisicao que o navegador faz, entao
// esconder do texto nao esconderia de ninguem. Sai porque nao serve: quem esta
// entrando ja sabe em que endereco esta, e o que ele precisa saber e se dali
// sai comando para maquina de loja. Mostrar infraestrutura antes do login e
// ruido para o operador e cortesia para quem estiver so olhando.
(function () {
  if (CFG.authMode !== 'supabase') return;
  var el = document.getElementById('lg-ambiente');
  el.textContent = 'Producao';
  el.setAttribute('data-producao', '1');
  el.hidden = false;
})();

// Na stack local esta pagina nao deveria ser aberta. Em vez de mostrar um
// formulario que nao serve para nada, manda direto para o dashboard.
if (CFG.authMode !== 'supabase') {
  var aviso = document.getElementById('aviso');
  aviso.textContent = 'Stack local nao usa login. Redirecionando para o dashboard...';
  aviso.hidden = false;
  setTimeout(function () { window.location.href = 'index.html?v=' + Date.now(); }, 1200);
}

document.getElementById('form-login').addEventListener('submit', async function (ev) {
  ev.preventDefault();

  var btn = document.getElementById('btn-entrar');
  var rotulo = btn.textContent;
  btn.disabled = true;
  btn.textContent = 'Entrando...';
  document.getElementById('erro').hidden = true;

  var email = document.getElementById('email').value.trim();
  var senha = document.getElementById('senha').value;

  // `novalidate` no formulario tirou a checagem do navegador para o desenho da
  // mensagem ser o nosso. Ela precisa existir aqui, senao um campo vazio vira
  // uma ida ao servidor para receber 'credenciais invalidas'.
  if (!email || !senha) {
    erro('preencha e-mail e senha');
    btn.disabled = false;
    btn.textContent = rotulo;
    (email ? document.getElementById('senha') : document.getElementById('email')).focus();
    return;
  }

  try {
    var base = (CFG.authUrl || '').replace(/\/+$/, '');
    if (!base) throw new Error('authUrl nao configurado em config.js');

    // Timeout explicito: sem ele, um endpoint inalcancavel deixa o fetch
    // pendurado e o usuario ve apenas o botao desabilitado, para sempre.
    var ctrl = new AbortController();
    var t = setTimeout(function () { ctrl.abort(); }, 15000);

    var resp = await fetch(base + '/token?grant_type=password', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: CFG.anonKey || '' },
      body: JSON.stringify({ email: email, password: senha }),
      signal: ctrl.signal,
    });
    clearTimeout(t);

    var dados = await resp.json();

    if (!resp.ok || !dados.access_token) {
      throw new Error(dados.error_description || dados.msg || 'credenciais invalidas');
    }

    // Senha fora do DOM antes de navegar.
    document.getElementById('senha').value = '';

    // O refresh_token vinha na resposta e era JOGADO FORA. Era a causa de a
    // sessao cair sozinha: o access_token do Supabase vale 1 hora, e sem o
    // refresh nao havia como renovar -- passada a hora, a API recusava e o
    // painel mandava para ca de novo, no meio do trabalho.
    //
    // localStorage e nao sessionStorage: em sessionStorage a sessao morre ao
    // fechar a aba, e a pessoa que fecha o navegador no fim do dia tem que
    // digitar senha na manha seguinte sem nenhum ganho de seguranca real.
    var expiraEm = Date.now() + ((dados.expires_in || 3600) * 1000);

    localStorage.setItem(CHAVE_TOKEN, JSON.stringify({
      token: dados.access_token,
      refresh: dados.refresh_token || null,
      expira_em: expiraEm,
      usuario: email,
    }));

    // A chave antiga sai de cena, senao um sessionStorage remanescente venceria
    // o localStorage novo na proxima abertura e a sessao voltaria a cair.
    try { sessionStorage.removeItem(CHAVE_TOKEN); } catch (e) { }

    window.location.href = 'index.html?v=' + Date.now();
  } catch (e) {
    erro(e.name === 'AbortError'
      ? 'o servidor de autenticacao nao respondeu em 15s'
      : e.message);
    document.getElementById('senha').value = '';
    document.getElementById('senha').focus();
  } finally {
    btn.disabled = false;
    btn.textContent = rotulo;
  }
});
