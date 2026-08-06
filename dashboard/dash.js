// =============================================================================
// Dashboard de monitoramento
// =============================================================================
// REGRA 7, e é a restrição que molda este arquivo inteiro: NENHUM dado vindo do
// banco toca innerHTML. Tudo é textContent ou createElement.
//
// Existe uma única função que escreve texto na tela (`txt`) e uma única que cria
// elemento (`el`). Se um dia alguém introduzir innerHTML aqui, vai ter que
// escrever fora desse caminho — e o teste de aceite (hostname
// `<script>alert(1)</script>` renderizado como texto literal) vai reprovar.
// =============================================================================

'use strict';

// Marca visível da versão do arquivo. Serve para responder em um segundo a
// "o navegador está com o código novo?" — que foi exatamente a dúvida que
// custou mais tempo neste projeto.
const BUILD = '2026-08-06.13-ingest-servidor';

// -----------------------------------------------------------------------------
// Captura global de erro — registrada ANTES de qualquer outra coisa
// -----------------------------------------------------------------------------
// Sem isto, um erro de JavaScript em qualquer ponto produz o pior sintoma
// possível: o botão é clicado e nada acontece, sem mensagem em lugar nenhum.
// Escrito com DOM puro e sem depender de nenhuma função deste arquivo, porque
// ele precisa funcionar mesmo se o erro tiver ocorrido nas primeiras linhas.
function mostrarFalhaGlobal(titulo, detalhe) {
  try {
    const caixa = document.getElementById('falha-js');
    const msg = document.getElementById('falha-js-msg');
    if (!caixa || !msg) {
      // Nem o HTML carregou: alert é o último recurso, mas é melhor que silêncio.
      window.alert(`${titulo}\n\n${detalhe}`);
      return;
    }
    msg.textContent = `[build ${BUILD}] ${titulo}\n${detalhe}`;
    caixa.hidden = false;
  } catch (_) {
    // Se nem isto funcionar, não há mais nada a fazer.
  }
}

window.addEventListener('error', (ev) => {
  const e = ev.error;
  mostrarFalhaGlobal(
    ev.message || 'erro de script',
    e && e.stack ? e.stack : `${ev.filename || '?'}:${ev.lineno || '?'}`,
  );
});

window.addEventListener('unhandledrejection', (ev) => {
  const r = ev.reason;
  mostrarFalhaGlobal(
    'promessa rejeitada sem tratamento',
    r && r.stack ? r.stack : String(r),
  );
});

const CFG = window.MONITOR_CONFIG;

if (!CFG) {
  // config.js não carregou (bloqueado, 404, ou cache corrompido). Sem isto o
  // erro seria "Cannot read properties of undefined" no meio do código, longe
  // da causa.
  mostrarFalhaGlobal(
    'config.js não carregou',
    'window.MONITOR_CONFIG está indefinido. Verifique se dashboard/config.js está sendo servido.',
  );
  throw new Error('config.js ausente');
}

// Só o build e o modo aqui. A restUrl NÃO é logada neste ponto porque ela ainda
// é o valor padrão do config.js — descobrirApiLocal() a substitui depois. Logá-la
// aqui produzia uma linha enganosa (mostrava a porta 3000 quando a API estava na
// 3001), e diagnóstico que mente custa mais tempo que diagnóstico ausente.
console.info(`[monitor] build ${BUILD} | authMode=${CFG.authMode}`);

// -----------------------------------------------------------------------------
// Estado
// -----------------------------------------------------------------------------
const Estado = {
  token: null,
  usuario: null,
  maquinas: [],
  resumo: null,
  filtros: { marca: '', loja: '', status: '', busca: '' },
  maquinaAberta: null,
  faixa: '24h',
  graficos: {},
  timerPoll: null,
  canalRealtime: null,
};

// -----------------------------------------------------------------------------
// DOM
// -----------------------------------------------------------------------------
const $ = (id) => document.getElementById(id);

/** Escreve texto com segurança. É o ÚNICO caminho de texto do banco para a tela. */
function txt(no, valor) {
  no.textContent = valor === null || valor === undefined || valor === '' ? '\u2014' : String(valor);
}

/** Cria elemento. Aceita texto, nunca HTML. */
function el(tag, classe, texto) {
  const n = document.createElement(tag);
  if (classe) n.className = classe;
  if (texto !== undefined) n.textContent = texto === null || texto === '' ? '\u2014' : String(texto);
  return n;
}

function limpar(no) {
  while (no.firstChild) no.removeChild(no.firstChild);
}

function brinde(mensagem, erro) {
  const b = $('brinde');
  txt(b, mensagem);
  b.className = erro ? 'brinde brinde-erro' : 'brinde';
  b.hidden = false;
  clearTimeout(brinde._t);
  brinde._t = setTimeout(() => { b.hidden = true; }, erro ? 8000 : 3500);
}

// -----------------------------------------------------------------------------
// API
// -----------------------------------------------------------------------------
function cabecalhos() {
  const h = { 'Content-Type': 'application/json' };
  if (CFG.anonKey) h.apikey = CFG.anonKey;
  if (Estado.token) h.Authorization = `Bearer ${Estado.token}`;
  return h;
}

async function api(caminho, opcoes = {}) {
  const base = CFG.restUrl.replace(/\/+$/, '');
  const resp = await fetch(`${base}${caminho}`, { ...opcoes, headers: cabecalhos() });

  if (resp.status === 401 || resp.status === 403) {
    // Token expirado ou revogado: derruba a sessão em vez de mostrar tela vazia.
    tokenRecusado(`HTTP ${resp.status} em ${caminho}`);
    throw new Error('não autorizado');
  }

  const texto = await resp.text();

  if (!resp.ok) {
    let msg = texto;
    try { msg = JSON.parse(texto).message || texto; } catch (_) { /* corpo não-JSON */ }
    throw new Error(`HTTP ${resp.status}: ${msg}`);
  }

  return texto ? JSON.parse(texto) : null;
}

const rpc = (nome, args = {}) =>
  api(`/rpc/${nome}`, { method: 'POST', body: JSON.stringify(args) });

// -----------------------------------------------------------------------------
// Token
// -----------------------------------------------------------------------------
// NAO EXISTE TELA DE LOGIN NESTE ARQUIVO.
//
// O token vem do dev-config.json, gravado pelo dev-up.ps1, e o dashboard abre
// direto. Nada de formulario, nada de sessionStorage, nada de estado
// "deslogado" — era justamente a transicao entre esses estados que produzia a
// tela travada (formulario na frente, painel aberto atras, app pendurado).
//
// Para o modo Supabase, onde autenticacao e obrigatoria, existe login.html
// separado: ele autentica, guarda o token e redireciona para ca. O dashboard em
// si continua sem saber o que e um formulario de login.
const CHAVE_TOKEN = 'monitor.token';

function guardarToken(token, usuario) {
  Estado.token = token;
  Estado.usuario = usuario;
  try {
    sessionStorage.setItem(CHAVE_TOKEN, JSON.stringify({ token, usuario }));
  } catch (_) { /* modo privado bloqueia storage */ }
}

function lerTokenGuardado() {
  try {
    const bruto = sessionStorage.getItem(CHAVE_TOKEN);
    if (!bruto) return null;
    const s = JSON.parse(bruto);
    return s.token ? s : null;
  } catch (_) {
    return null;
  }
}

function descartarToken() {
  Estado.token = null;
  Estado.usuario = null;
  try { sessionStorage.removeItem(CHAVE_TOKEN); } catch (_) { /* nada a fazer */ }
}

/**
 * Token recusado pelo servidor.
 *
 * Sem tela de login para onde voltar, a unica coisa honesta e dizer o que houve
 * e como corrigir. No modo Supabase, manda para o login.html.
 */
function tokenRecusado(mensagem) {
  descartarToken();

  if (Estado.timerPoll) { clearInterval(Estado.timerPoll); Estado.timerPoll = null; }
  if (Estado.canalRealtime) {
    try { Estado.canalRealtime.close(); } catch (_) { /* ja fechado */ }
    Estado.canalRealtime = null;
  }

  if (CFG.authMode === 'supabase') {
    window.location.href = 'login.html';
    return;
  }

  mostrarFalhaGlobal(
    'A API recusou o token deste dashboard',
    `${mensagem}\n\nO token é gerado pelo dev-up. Rode:\n  .\\scripts\\dev-up.ps1`,
  );
}


/**
 * Descobre a URL da API no modo local.
 *
 * A porta é escolhida em tempo de execução (8080 e 3000 costumam estar ocupadas
 * por wslrelay em máquina com Docker Desktop), então ela vem de um arquivo
 * gerado pelo dev-up em vez de ficar cravada no config.js.
 */
async function descobrirApiLocal() {
  let d;

  try {
    const resp = await fetch('dev-config.json', { cache: 'no-store' });
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    d = await resp.json();
  } catch (e) {
    // FALHA ALTA, não silenciosa. A versão anterior engolia o erro e o dashboard
    // seguia com a URL padrão do config.js — que podia ser a porta de um serviço
    // completamente diferente. Ficar mudo aqui é o que transformava um problema
    // trivial de porta num "login não funciona" indecifrável.
    throw new Error(
      `dev-config.json não pôde ser lido (${e.message}).\n\n` +
      'Este arquivo diz em qual porta a API subiu. Rode:\n' +
      '  .\\scripts\\dev-up.ps1',
    );
  }

  if (!d.restUrl) {
    throw new Error('dev-config.json não contém restUrl. Rode .\\scripts\\dev-up.ps1 novamente.');
  }

  CFG.restUrl = d.restUrl;

  // Token de entrada direta e a preferência por exigir login, ambos vindos do
  // dev-up. Ficam em CFG para que principal() decida em um lugar só.
  CFG.devToken = d.devToken || null;
  CFG.devUsuario = d.devUsuario || null;
  CFG.pedirLogin = d.pedirLogin === true;

  // Endereço da ingestão na LAN, só para diagnóstico e para a mensagem de erro
  // saber o que sugerir.
  //
  // NÃO existe mais `ingestSecret` aqui, e a ausência é o ponto: este arquivo é
  // servido ao navegador antes de qualquer login. Endereço e segredo da ingestão
  // vêm do BANCO, na resposta de provisionar_maquina_ui, e só para admin.
  CFG.ingestUrlLan = d.ingestUrlLan || null;
}

// -----------------------------------------------------------------------------
// Carga de dados
// -----------------------------------------------------------------------------
async function carregar() {
  try {
    const [maquinas, resumo] = await Promise.all([
      api('/machines_status?select=*&order=site_code.asc,label.asc'),
      rpc('dashboard_summary'),
    ]);

    Estado.maquinas = maquinas || [];
    Estado.resumo = resumo || {};

    marcarConexao(true);
    desenharResumo();
    preencherFiltros();
    desenharMaquinas();

    txt($('rodape-atualizacao'), `atualizado ${new Date().toLocaleTimeString('pt-BR')}`);
  } catch (e) {
    marcarConexao(false, e.message);
    brinde(`Falha ao carregar: ${e.message}`, true);
  }
}

function marcarConexao(ok, detalhe) {
  const p = $('indicador-conexao');
  if (ok) {
    txt(p, CFG.authMode === 'supabase' && CFG.realtime ? 'ao vivo' : `polling ${CFG.pollSeconds}s`);
    p.className = 'pill pill-ok';
  } else {
    txt(p, 'sem conexão');
    p.className = 'pill pill-ruim';
    p.title = detalhe || '';
  }
}

// -----------------------------------------------------------------------------
// Resumo
// -----------------------------------------------------------------------------
function desenharResumo() {
  const r = Estado.resumo || {};

  // Zero apaga a tira. Um "0 alertas abertos" aceso de laranja ensina a equipe a
  // ignorar laranja, que e o contrario do que a cor existe para fazer.
  const kpi = (id, valor) => {
    const n = Number(valor ?? 0);
    txt($(id), n);
    $(id).parentElement.classList.toggle('zero', n === 0);
  };

  kpi('kpi-total', r.machines_total);
  kpi('kpi-online', r.machines_online);
  kpi('kpi-offline', r.machines_offline);
  kpi('kpi-nunca', r.machines_never_seen);
  kpi('kpi-alertas', r.open_alerts);
  kpi('kpi-disco', r.disk_critical);
  kpi('kpi-servicos', r.services_down);

  document.title = (r.machines_offline > 0)
    ? `(${r.machines_offline} offline) Monitoramento`
    : 'Monitoramento de Infraestrutura';
}

function preencherFiltros() {
  preencherSelect($('filtro-marca'), Estado.filtros.marca,
    unicos(Estado.maquinas.map((m) => [m.brand_code, m.brand_name])));
  preencherSelect($('filtro-loja'), Estado.filtros.loja,
    unicos(Estado.maquinas
      .filter((m) => !Estado.filtros.marca || m.brand_code === Estado.filtros.marca)
      .map((m) => [m.site_code, `${m.site_code} \u2014 ${m.site_name}`])));
}

function unicos(pares) {
  const mapa = new Map();
  for (const [valor, rotulo] of pares) {
    if (valor && !mapa.has(valor)) mapa.set(valor, rotulo || valor);
  }
  return [...mapa.entries()].sort((a, b) => a[0].localeCompare(b[0], 'pt-BR'));
}

function preencherSelect(sel, selecionado, itens) {
  limpar(sel);
  sel.appendChild(el('option', null, 'todas')).value = '';
  sel.firstChild.value = '';

  for (const [valor, rotulo] of itens) {
    const o = el('option', null, rotulo);
    o.value = valor;
    sel.appendChild(o);
  }
  sel.value = selecionado || '';
}

// -----------------------------------------------------------------------------
// Lista de máquinas, agrupada por marca e loja
// -----------------------------------------------------------------------------
function filtrar() {
  const f = Estado.filtros;
  const busca = f.busca.trim().toLowerCase();

  return Estado.maquinas.filter((m) => {
    if (f.marca && m.brand_code !== f.marca) return false;
    if (f.loja && m.site_code !== f.loja) return false;
    if (f.status && m.status !== f.status) return false;

    if (busca) {
      const alvo = [m.label, m.hostname, m.site_code, m.site_name, m.brand_name, m.ip_lan]
        .filter(Boolean).join(' ').toLowerCase();
      if (!alvo.includes(busca)) return false;
    }
    return true;
  });
}

function desenharMaquinas() {
  const conteudo = $('conteudo');
  limpar(conteudo);

  const lista = filtrar();

  if (lista.length === 0) {
    const p = el('p', 'vazio', 'Nenhuma máquina corresponde ao filtro.');
    conteudo.appendChild(p);
    return;
  }

  // Agrupa marca -> loja -> máquinas
  const porMarca = new Map();
  for (const m of lista) {
    const chaveMarca = m.brand_code || '(sem marca)';
    if (!porMarca.has(chaveMarca)) porMarca.set(chaveMarca, { nome: m.brand_name, lojas: new Map() });

    const marca = porMarca.get(chaveMarca);
    const chaveLoja = m.site_code || '(sem loja)';
    if (!marca.lojas.has(chaveLoja)) marca.lojas.set(chaveLoja, { nome: m.site_name, maquinas: [] });

    marca.lojas.get(chaveLoja).maquinas.push(m);
  }

  for (const [codMarca, marca] of [...porMarca.entries()].sort((a, b) => a[0].localeCompare(b[0], 'pt-BR'))) {
    const secMarca = el('section', 'marca');

    const cabMarca = el('h2', 'marca-titulo');
    cabMarca.appendChild(el('span', 'marca-cod', codMarca));
    cabMarca.appendChild(el('span', 'marca-nome', marca.nome));
    cabMarca.appendChild(contadorStatus([...marca.lojas.values()].flatMap((l) => l.maquinas)));
    secMarca.appendChild(cabMarca);

    for (const [codLoja, loja] of [...marca.lojas.entries()].sort((a, b) => a[0].localeCompare(b[0], 'pt-BR'))) {
      const secLoja = el('section', 'loja');

      const cabLoja = el('h3', 'loja-titulo');
      cabLoja.appendChild(el('span', 'loja-cod', codLoja));
      cabLoja.appendChild(el('span', 'loja-nome', loja.nome));
      cabLoja.appendChild(contadorStatus(loja.maquinas));
      secLoja.appendChild(cabLoja);

      const grade = el('div', 'grade');
      for (const m of loja.maquinas) grade.appendChild(cartao(m));
      secLoja.appendChild(grade);

      secMarca.appendChild(secLoja);
    }

    conteudo.appendChild(secMarca);
  }
}

function contadorStatus(maquinas) {
  const online = maquinas.filter((m) => m.status === 'online').length;
  const offline = maquinas.filter((m) => m.status === 'offline').length;

  const w = el('span', 'contador');
  w.appendChild(el('span', 'cont-ok', `${online} online`));
  const off = el('span', offline > 0 ? 'cont-ruim' : 'cont-neutro', `${offline} offline`);
  w.appendChild(off);
  return w;
}

function cartao(m) {
  const c = el('article', `cartao cartao-${m.status}`);
  c.tabIndex = 0;
  c.setAttribute('role', 'button');
  // aria-label recebe TEXTO, nunca markup — um hostname com < e > fica literal.
  c.setAttribute('aria-label', `${m.label}, ${rotuloStatus(m.status)}`);

  const topo = el('header', 'cartao-topo');
  topo.appendChild(el('span', 'cartao-nome', m.label));
  topo.appendChild(el('span', `bolha bolha-${m.status}`));
  c.appendChild(topo);

  // O hostname vem do agente e é o vetor do teste de aceite de XSS.
  const host = el('p', 'cartao-host', m.hostname || 'host desconhecido');
  c.appendChild(host);

  const linha = el('p', 'cartao-status');
  linha.appendChild(el('span', `etiqueta etiqueta-${m.status}`, rotuloStatus(m.status)));
  linha.appendChild(el('span', 'cartao-visto', desdeQuando(m.seconds_since_seen, m.status)));
  c.appendChild(linha);

  if (m.in_maintenance) {
    c.appendChild(el('p', 'cartao-manutencao', 'em manutenção'));
  }

  const metricas = el('div', 'metricas');
  metricas.appendChild(metrica('CPU', pct(m.cpu_pct), barra(m.cpu_pct, 90)));
  metricas.appendChild(metrica('Memória', pct(m.mem_pct), barra(m.mem_pct, 92)));
  metricas.appendChild(metrica('Disco livre', pct(m.disk_min_free_pct), barra(m.disk_min_free_pct, null, 10)));
  metricas.appendChild(metrica('Temp.', m.cpu_temp_c === null || m.cpu_temp_c === undefined ? null : `${round1(m.cpu_temp_c)} °C`, null));
  c.appendChild(metricas);

  // ANTES do rodapé: o aviso é conteúdo, e o rodapé é a linha de fecho do cartão.
  if (m.services_down > 0) {
    const s = el('p', 'cartao-servicos');
    // Nome de serviço também vem do banco: montado com textContent.
    const nomes = Array.isArray(m.services_down_names) ? m.services_down_names.join(', ') : '';
    txt(s, `${m.services_down} serviço(s) parado(s)${nomes ? `: ${nomes}` : ''}`);
    c.appendChild(s);
  }

  const pe = el('footer', 'cartao-pe');
  pe.appendChild(el('span', null, `uptime ${uptime(m.uptime_seconds)}`));
  pe.appendChild(el('span', null, m.agent_version ? `v${m.agent_version}` : 'sem agente'));
  c.appendChild(pe);

  const abrir = () => abrirPainel(m);
  c.addEventListener('click', abrir);
  c.addEventListener('keydown', (ev) => {
    if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); abrir(); }
  });

  return c;
}

function metrica(rotulo, valor, elBarra) {
  const w = el('div', 'metrica');
  w.appendChild(el('span', 'metrica-rot', rotulo));

  // A barra ocupa a coluna do meio SEMPRE, mesmo quando nao existe (temperatura
  // nao tem escala de 0 a 100). Sem o vao, o numero da temperatura subiria para
  // a coluna da barra e sairia do alinhamento das outras linhas do cartao.
  w.appendChild(elBarra || el('span', 'barra-vazia'));
  w.appendChild(el('span', 'metrica-val', valor));
  return w;
}

/** Barra de progresso. `tetoAlto` alerta quando passa; `pisoBaixo`, quando cai abaixo. */
function barra(valor, tetoAlto, pisoBaixo) {
  if (valor === null || valor === undefined) return null;

  const v = Math.max(0, Math.min(100, Number(valor)));
  const fora = (tetoAlto !== null && tetoAlto !== undefined && v >= tetoAlto)
            || (pisoBaixo !== null && pisoBaixo !== undefined && v <= pisoBaixo);

  const trilha = el('span', 'barra');
  const preenchida = el('span', fora ? 'barra-fill barra-fill-ruim' : 'barra-fill');
  preenchida.style.width = `${v}%`;
  trilha.appendChild(preenchida);
  return trilha;
}

// -----------------------------------------------------------------------------
// Formatação
// -----------------------------------------------------------------------------
const rotulos = { online: 'online', offline: 'OFFLINE', never_seen: 'nunca vista', disabled: 'desativada' };
const rotuloStatus = (s) => rotulos[s] || s || '?';

const round1 = (v) => (v === null || v === undefined ? null : Math.round(Number(v) * 10) / 10);
const pct = (v) => (v === null || v === undefined ? null : `${round1(v)}%`);

function uptime(segundos) {
  if (segundos === null || segundos === undefined || segundos < 0) return '\u2014';
  const s = Number(segundos);
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

function desdeQuando(segundos, status) {
  if (status === 'never_seen') return 'nunca reportou';
  if (segundos === null || segundos === undefined) return '\u2014';

  const s = Number(segundos);
  if (s < 90) return `há ${Math.round(s)}s`;
  if (s < 5400) return `há ${Math.round(s / 60)}min`;
  if (s < 172800) return `há ${Math.round(s / 3600)}h`;
  return `há ${Math.round(s / 86400)}d`;
}

// -----------------------------------------------------------------------------
// Painel de detalhe
// -----------------------------------------------------------------------------
async function abrirPainel(m) {
  Estado.maquinaAberta = m;

  txt($('painel-titulo'), m.label);
  txt($('painel-sub'), `${m.site_code} \u2014 ${m.site_name} · ${m.brand_name}`);

  const dl = $('painel-dados');
  limpar(dl);

  const campos = [
    ['Status', rotuloStatus(m.status)],
    ['Hostname', m.hostname],
    ['\u00daltimo contato', desdeQuando(m.seconds_since_seen, m.status)],
    ['Perfil', m.role_name || m.role_code],
    ['IP na LAN', m.ip_lan],
    ['Sistema', m.os_caption],
    ['CPU', m.cpu_model],
    ['Núcleos', m.cpu_cores],
    ['Memória total', m.mem_total_mb ? `${(m.mem_total_mb / 1024).toFixed(1)} GB` : null],
    ['Versão do agente', m.agent_version],
    ['Uptime', uptime(m.uptime_seconds)],
    ['Desvio de relógio', m.clock_drift_seconds === null || m.clock_drift_seconds === undefined
      ? null : `${m.clock_drift_seconds}s`],
    ['Latência gateway', m.gw_latency_ms === null || m.gw_latency_ms === undefined
      ? null : `${round1(m.gw_latency_ms)} ms`],
    ['Sinalizadores', Array.isArray(m.collect_flags) && m.collect_flags.length
      ? m.collect_flags.join(', ') : 'nenhum'],
    ['GUID', m.machine_id],
  ];

  for (const [rot, val] of campos) {
    dl.appendChild(el('dt', null, rot));
    dl.appendChild(el('dd', null, val));
  }

  $('painel-fundo').hidden = false;
  $('painel').hidden = false;

  await Promise.all([carregarGraficos(m.machine_id), carregarEventos(m.machine_id)]);
}

function fecharPainel() {
  Estado.maquinaAberta = null;
  $('painel').hidden = true;
  $('painel-fundo').hidden = true;
}

async function carregarEventos(machineId) {
  const ul = $('painel-eventos');
  limpar(ul);

  try {
    const eventos = await rpc('machine_events', { p_machine_id: machineId, p_limit: 15 });

    if (!eventos || eventos.length === 0) {
      ul.appendChild(el('li', 'evento-vazio', 'Nenhum evento registrado.'));
      return;
    }

    for (const e of eventos) {
      const li = el('li', `evento evento-${e.severity}`);
      li.appendChild(el('span', 'evento-quando', new Date(e.opened_at).toLocaleString('pt-BR')));
      li.appendChild(el('span', 'evento-tipo', e.kind));
      li.appendChild(el('span', 'evento-msg', e.message));
      ul.appendChild(li);
    }
  } catch (err) {
    ul.appendChild(el('li', 'evento-vazio', `Falha ao carregar eventos: ${err.message}`));
  }
}

async function carregarGraficos(machineId) {
  let dados;
  try {
    dados = await rpc('machine_history', { p_machine_id: machineId, p_range: Estado.faixa });
  } catch (err) {
    brinde(`Falha no histórico: ${err.message}`, true);
    return;
  }

  const rotulosX = (dados || []).map((d) => formatarBalde(d.bucket, Estado.faixa));

  desenhar('grafico-cpu', 'CPU e memória (%)', rotulosX, [
    { label: 'CPU média', data: (dados || []).map((d) => round1(d.cpu_avg)), cor: '#3b82f6' },
    { label: 'CPU máxima', data: (dados || []).map((d) => round1(d.cpu_max)), cor: '#93c5fd', tracejado: true },
    { label: 'Memória média', data: (dados || []).map((d) => round1(d.mem_avg)), cor: '#a855f7' },
  ], 0, 100);

  desenhar('grafico-mem', 'Temperatura (°C) e latência (ms)', rotulosX, [
    { label: 'Temperatura', data: (dados || []).map((d) => round1(d.temp_avg)), cor: '#f97316' },
    { label: 'Latência gateway', data: (dados || []).map((d) => round1(d.gw_latency_avg)), cor: '#14b8a6' },
  ]);

  desenhar('grafico-disco', 'Disco livre (%)', rotulosX, [
    { label: 'Menor volume', data: (dados || []).map((d) => round1(d.disk_min_free_pct)), cor: '#22c55e' },
  ], 0, 100);
}

function formatarBalde(iso, faixa) {
  const d = new Date(iso);
  if (faixa === '24h') return d.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
  if (faixa === '7d') return d.toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit' });
  return d.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' });
}

function desenhar(idCanvas, titulo, rotulosX, series, min, max) {
  // Destrói o gráfico anterior: sem isso o Chart.js acumula instâncias no mesmo
  // canvas e o consumo de memória cresce a cada abertura de painel.
  if (Estado.graficos[idCanvas]) Estado.graficos[idCanvas].destroy();

  const ctx = $(idCanvas).getContext('2d');

  Estado.graficos[idCanvas] = new Chart(ctx, {
    type: 'line',
    data: {
      labels: rotulosX,
      datasets: series.map((s) => ({
        label: s.label,
        data: s.data,
        borderColor: s.cor,
        backgroundColor: `${s.cor}22`,
        borderWidth: 2,
        borderDash: s.tracejado ? [4, 4] : undefined,
        pointRadius: 0,
        tension: 0.25,
        spanGaps: false,   // buraco na série aparece como buraco, não como reta
        fill: false,
      })),
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      interaction: { mode: 'index', intersect: false },
      plugins: {
        title: { display: true, text: titulo },
        legend: { position: 'bottom', labels: { boxWidth: 12, font: { size: 11 } } },
      },
      scales: {
        y: { min, max, ticks: { font: { size: 10 } } },
        x: { ticks: { maxTicksLimit: 10, font: { size: 10 } } },
      },
    },
  });
}

// -----------------------------------------------------------------------------
// Atualização: Realtime quando houver, polling sempre
// -----------------------------------------------------------------------------
function iniciarAtualizacao() {
  // O polling é o caminho garantido. Realtime, quando funciona, só antecipa.
  // Sem esse fallback, um WebSocket bloqueado pelo firewall da loja congelaria o
  // dashboard sem nenhum sinal visível.
  const ms = Math.max(5, Number(CFG.pollSeconds) || 20) * 1000;
  if (Estado.timerPoll) clearInterval(Estado.timerPoll);
  Estado.timerPoll = setInterval(() => {
    if (!document.hidden) carregar();
  }, ms);

  if (CFG.authMode === 'supabase' && CFG.realtime) conectarRealtime();
}

function conectarRealtime() {
  try {
    const url = CFG.restUrl.replace(/\/rest\/v1\/?$/, '').replace(/^http/, 'ws');
    const ws = new WebSocket(`${url}/realtime/v1/websocket?apikey=${encodeURIComponent(CFG.anonKey)}&vsn=1.0.0`);

    ws.onopen = () => {
      ws.send(JSON.stringify({
        topic: 'realtime:public:machines',
        event: 'phx_join',
        payload: { config: { postgres_changes: [{ event: 'UPDATE', schema: 'public', table: 'machines' }] } },
        ref: '1',
      }));
    };

    // Recarrega em vez de aplicar o delta: `machines_status` é uma view com
    // lateral joins, e reconstruí-la no cliente a partir de um UPDATE de
    // `machines` daria um estado divergente do servidor.
    ws.onmessage = (ev) => {
      try {
        const msg = JSON.parse(ev.data);
        if (msg.event === 'postgres_changes') carregar();
      } catch (_) { /* keepalive */ }
    };

    ws.onerror = () => marcarConexao(true);
    ws.onclose = () => { Estado.canalRealtime = null; };

    Estado.canalRealtime = ws;
  } catch (_) {
    // Realtime indisponível: o polling cobre.
  }
}

// -----------------------------------------------------------------------------
// Ligação de eventos
// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------
// Adicionar PC
// -----------------------------------------------------------------------------
// O comando gerado é a única coisa que o operador precisa levar para a outra
// máquina. Ele embute servidor, token e segredo, e o script baixa o agente do
// próprio endpoint de ingestão — não há pasta para copiar nem arquivo para editar.
let opcoesCadastro = null;

/**
 * Para onde o agente da máquina nova deve falar.
 *
 * Vem do SERVIDOR (`ingest_config`), não de arquivo estático. Assim o mesmo
 * dashboard serve para a fase de teste na LAN (`http://192.168.x.x:3010`) e para
 * produção (`https://…/functions/v1/ingest`) sem editar nada no navegador — quem
 * troca é o `definir_ingestao`, num lugar só.
 */
function ingestaoConfigurada() {
  const i = opcoesCadastro && opcoesCadastro.ingestao;
  return i && i.configurada === true ? i : null;
}

async function abrirModalAdd() {
  $('add-erro').hidden = true;
  $('add-passo1').hidden = false;
  $('add-passo2').hidden = true;
  $('modal-fundo').hidden = false;
  $('modal-add').hidden = false;

  if (!opcoesCadastro) {
    try {
      opcoesCadastro = await rpc('opcoes_cadastro');
    } catch (e) {
      erroAdd(`não foi possível carregar as opções: ${e.message}`);
      return;
    }
  }

  if (!opcoesCadastro.is_admin) {
    erroAdd('somente administradores podem cadastrar máquinas.');
    $('btn-gerar').disabled = true;
    return;
  }

  // Checado ANTES do formulário. Descobrir isto depois de confirmar deixaria uma
  // máquina cadastrada no banco e um operador sem comando para rodar nela.
  $('btn-gerar').disabled = false;

  if (!ingestaoConfigurada()) {
    erroAdd('a ingestão não está configurada. Rode scripts\\dev-up.ps1 (local) '
      + 'ou scripts\\publicar-supabase.ps1 (produção) antes de cadastrar.');
    $('btn-gerar').disabled = true;
    return;
  }

  const sel = $('add-loja');
  limpar(sel);
  for (const loja of opcoesCadastro.lojas) {
    const o = el('option', null, `${loja.code} \u2014 ${loja.name}`);
    o.value = loja.code;
    sel.appendChild(o);
  }
  const nova = el('option', null, '+ criar loja nova');
  nova.value = '__nova__';
  sel.appendChild(nova);

  const perfis = $('add-perfil');
  limpar(perfis);
  for (const p of opcoesCadastro.perfis) {
    const o = el('option', null, p.name);
    o.value = p.code;
    perfis.appendChild(o);
  }
  perfis.value = 'pdv';
  aplicarServicosDoPerfil();

  $('add-nome').focus();
}

function aplicarServicosDoPerfil() {
  const perfil = opcoesCadastro?.perfis?.find((p) => p.code === $('add-perfil').value);
  const svc = perfil?.services;
  // Sugere os serviços do perfil, mas não impõe: um PDV pode ter o serviço do ERP
  // que os outros não têm.
  $('add-servicos').value = Array.isArray(svc) && svc.length
    ? svc.join(', ')
    : 'Spooler, Dhcp, Dnscache';
}

function fecharModalAdd() {
  $('modal-add').hidden = true;
  $('modal-fundo').hidden = true;
}

function erroAdd(msg) {
  const e = $('add-erro');
  txt(e, msg);
  e.hidden = false;
}

async function gerarComando() {
  const nome = $('add-nome').value.trim();
  const loja = $('add-loja').value;
  const perfil = $('add-perfil').value;
  const servicos = $('add-servicos').value
    .split(',').map((s) => s.trim()).filter(Boolean);

  $('add-erro').hidden = true;

  if (!nome) { erroAdd('informe o nome da máquina'); $('add-nome').focus(); return; }

  let codigoLoja = loja;
  let nomeLoja = null;

  if (loja === '__nova__') {
    codigoLoja = $('add-loja-codigo').value.trim();
    nomeLoja = $('add-loja-nome').value.trim();
    if (!codigoLoja) { erroAdd('informe o código da loja nova'); return; }
  }

  const btn = $('btn-gerar');
  const rotulo = btn.textContent;
  btn.disabled = true;
  btn.textContent = 'Gerando...';

  try {
    const r = await rpc('provisionar_maquina_ui', {
      p_site_code: codigoLoja,
      p_label: nome,
      p_role_code: perfil,
      p_services: servicos.length ? servicos : null,
      p_site_name: nomeLoja,
    });

    if (!r?.token) throw new Error('resposta sem token');

    // Endereço e segredo vêm da MESMA resposta que o token: os três nascem no
    // servidor, na mesma transação, para o mesmo admin. Não existe caminho em que
    // o comando saia com token novo e endereço velho.
    const alvo = r.ingest_url;
    if (!alvo || !r.ingest_secret) {
      throw new Error(
        'a máquina foi cadastrada, mas a ingestão não está configurada no banco. '
        + 'Rode scripts\\publicar-supabase.ps1 (produção) ou scripts\\dev-up.ps1 '
        + '(local), e cadastre a máquina outra vez.',
      );
    }

    // scriptblock::Create e não `iex` direto: só assim é possível PASSAR
    // ARGUMENTOS a um script baixado. Com `iex`, os parâmetros seriam ignorados
    // em silêncio e o instalador rodaria sem token.
    const base = `& ([scriptblock]::Create((irm '${alvo}/instalar.ps1'))) `
      + `-Servidor '${alvo}' -Token '${r.token}' -Segredo '${r.ingest_secret}'`;

    const comServicos = servicos.length
      ? `${base} -Servicos '${servicos.join(',')}'`
      : base;

    txt($('add-comando'), comServicos);
    txt($('add-comando-tarefa'), `${comServicos} -ComTarefa`);

    // Diz em que fase o comando est\u00e1. Um comando apontando para IP de rede local
    // s\u00f3 funciona dentro dela, e descobrir isso j\u00e1 na loja \u00e9 tarde.
    const onde = r.ingest_https
      ? 'Vale em qualquer rede.'
      : 'Vale SO nesta rede local.';

    txt($('add-resumo'),
      `${r.label} cadastrada em ${r.site_code}${r.site_criada ? ' (loja criada agora)' : ''}. `
      + `Token ${r.token_prefix}\u2026 ${onde}`);

    $('add-passo1').hidden = true;
    $('add-passo2').hidden = false;

    // Atualiza a tela: a máquina nova já aparece como "nunca vista" até o
    // primeiro envio, o que é a informação correta.
    carregar();
  } catch (e) {
    erroAdd(e.message);
  } finally {
    btn.disabled = false;
    btn.textContent = rotulo;
  }
}

async function copiar(idOrigem, botao) {
  const texto = $(idOrigem).textContent;
  const original = botao.textContent;

  try {
    await navigator.clipboard.writeText(texto);
    botao.textContent = 'Copiado!';
  } catch (_) {
    // clipboard exige contexto seguro; em http:// pode falhar. Seleciona o texto
    // para o operador copiar com Ctrl+C em vez de deixá-lo sem saída.
    const faixa = document.createRange();
    faixa.selectNodeContents($(idOrigem));
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(faixa);
    botao.textContent = 'selecionado \u2014 Ctrl+C';
  }

  setTimeout(() => { botao.textContent = original; }, 2500);
}

function ligarEventos() {
  // Sem handler de formulário de login: ele não existe mais nesta página.
  $('btn-atualizar').addEventListener('click', () => carregar());

  $('btn-adicionar').addEventListener('click', abrirModalAdd);
  $('btn-fechar-modal').addEventListener('click', fecharModalAdd);
  $('modal-fundo').addEventListener('click', fecharModalAdd);
  $('btn-gerar').addEventListener('click', gerarComando);
  $('btn-add-outro').addEventListener('click', abrirModalAdd);
  $('btn-copiar-cmd').addEventListener('click', (ev) => copiar('add-comando', ev.currentTarget));
  $('btn-copiar-tarefa').addEventListener('click', (ev) => copiar('add-comando-tarefa', ev.currentTarget));

  $('add-perfil').addEventListener('change', aplicarServicosDoPerfil);

  $('add-loja').addEventListener('change', (ev) => {
    const nova = ev.target.value === '__nova__';
    $('add-nova-loja').hidden = !nova;
    if (nova) $('add-loja-codigo').focus();
  });

  $('add-nome').addEventListener('keydown', (ev) => {
    if (ev.key === 'Enter') { ev.preventDefault(); gerarComando(); }
  });
  $('btn-fechar-painel').addEventListener('click', fecharPainel);
  $('painel-fundo').addEventListener('click', fecharPainel);

  document.addEventListener('keydown', (ev) => {
    if (ev.key !== 'Escape') return;
    if (!$('modal-add').hidden) { fecharModalAdd(); return; }
    if (!$('painel').hidden) fecharPainel();
  });

  $('filtro-marca').addEventListener('change', (ev) => {
    Estado.filtros.marca = ev.target.value;
    Estado.filtros.loja = '';
    preencherFiltros();
    desenharMaquinas();
  });

  for (const [id, campo] of [['filtro-loja', 'loja'], ['filtro-status', 'status']]) {
    $(id).addEventListener('change', (ev) => {
      Estado.filtros[campo] = ev.target.value;
      desenharMaquinas();
    });
  }

  let tBusca;
  $('busca').addEventListener('input', (ev) => {
    clearTimeout(tBusca);
    const v = ev.target.value;
    tBusca = setTimeout(() => {
      Estado.filtros.busca = v;
      desenharMaquinas();
    }, 200);
  });

  for (const b of document.querySelectorAll('.faixa')) {
    b.addEventListener('click', () => {
      for (const o of document.querySelectorAll('.faixa')) o.classList.remove('ativa');
      b.classList.add('ativa');
      Estado.faixa = b.dataset.faixa;
      if (Estado.maquinaAberta) carregarGraficos(Estado.maquinaAberta.machine_id);
    });
  }
}

// -----------------------------------------------------------------------------
// Partida
// -----------------------------------------------------------------------------
/**
 * Sobe o dashboard. Sem estado intermediário: ou ele abre, ou a faixa vermelha
 * no topo diz por quê.
 */
async function iniciar() {
  $('app').hidden = false;
  txt($('rotulo-usuario'), Estado.usuario || '');

  await carregar();
  iniciarAtualizacao();
}

async function principal() {
  ligarEventos();

  // -------------------------------------------------------------------- token
  if (CFG.authMode === 'supabase') {
    // Em produção a autenticação é obrigatória. O login vive em login.html, que
    // guarda o token e volta para cá — o dashboard nunca desenha formulário.
    const guardado = lerTokenGuardado();
    if (!guardado) {
      window.location.href = 'login.html';
      return;
    }
    Estado.token = guardado.token;
    Estado.usuario = guardado.usuario;
  } else {
    // Stack local: a URL da API e o token vêm do dev-config.json.
    try {
      await descobrirApiLocal();
    } catch (e) {
      mostrarFalhaGlobal('Não foi possível descobrir o endereço da API', e.message);
      return;
    }

    console.info(`[monitor] API ${CFG.restUrl}`);

    if (!CFG.devToken) {
      mostrarFalhaGlobal(
        'dev-config.json não traz o token de acesso',
        'A stack local abre o dashboard sem login, e para isso precisa do token.\n'
        + 'Rode:  .\\scripts\\dev-up.ps1',
      );
      return;
    }

    guardarToken(CFG.devToken, CFG.devUsuario || 'stack local');
  }

  // -------------------------------------------------------------- dashboard
  try {
    await iniciar();
  } catch (e) {
    mostrarFalhaGlobal('Falha ao carregar o dashboard', e.message);
  }
}

principal();

