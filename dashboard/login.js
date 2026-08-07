// =============================================================================
// Login (modo Supabase)
// =============================================================================
// Extraido de login.html para que a Content-Security-Policy possa recusar
// script embutido. Uma pagina de credencial publicada na internet e exatamente
// onde 'unsafe-inline' nao deveria existir: ela e o alvo mais obvio de uma
// injecao, e a CSP e a ultima linha de defesa se algo passar.
//
// O comportamento e identico ao que estava embutido.
// =============================================================================

'use strict';

var CFG = window.MONITOR_CONFIG || {};
var CHAVE_TOKEN = 'monitor.token';

function erro(msg) {
  var e = document.getElementById('erro');
  e.textContent = msg;   // textContent, nunca innerHTML (regra 7)
  e.hidden = false;
}

// Na stack local esta página não deveria ser aberta. Em vez de mostrar um
// formulário que não serve para nada, manda direto para o dashboard.
if (CFG.authMode !== 'supabase') {
  var aviso = document.getElementById('aviso');
  aviso.textContent = 'Stack local não usa login. Redirecionando para o dashboard…';
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

  try {
    var base = (CFG.authUrl || '').replace(/\/+$/, '');
    if (!base) throw new Error('authUrl não configurado em config.js');

    // Timeout explícito: sem ele, um endpoint inalcançável deixa o fetch
    // pendurado e o usuário vê apenas o botão desabilitado, para sempre.
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
      throw new Error(dados.error_description || dados.msg || 'credenciais inválidas');
    }

    // Senha fora do DOM antes de navegar.
    document.getElementById('senha').value = '';

    sessionStorage.setItem(CHAVE_TOKEN, JSON.stringify({
      token: dados.access_token,
      usuario: email,
    }));

    window.location.href = 'index.html?v=' + Date.now();
  } catch (e) {
    erro(e.name === 'AbortError'
      ? 'o servidor de autenticação não respondeu em 15s'
      : e.message);
    document.getElementById('senha').value = '';
    document.getElementById('senha').focus();
  } finally {
    btn.disabled = false;
    btn.textContent = rotulo;
  }
});
