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
const BUILD = '2026-08-10.40-usuarios';

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
  lojas: [],
  resumo: null,
  filtros: { marca: '', loja: '', status: '', busca: '' },
  maquinaAberta: null,
  ehAdmin: false,
  incidentes: null,
  incidenteNaFaixa: null,
  incidentesVistos: new Set(),
  primeiraCargaIncidentes: true,
  som: false,
  audio: null,
  faviconAtual: null,
  relatorio: null,
  faixa: '24h',        // faixa do painel de detalhe
  faixaFrota: '24h',   // faixa do gráfico de carga da frota
  modo: 'lojas',       // 'lojas' (cartão por loja) ou 'maquinas' (cartão por PC)
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
/**
 * Sair.
 *
 * Reaproveita o desmonte do `tokenRecusado`: parar o poll e fechar o canal de
 * realtime ANTES de navegar. Sem isso, o intervalo continua disparando durante a
 * navegacao e cada chamada volta 401 — o console enche de erro numa saida que
 * deu certo, e o proximo a depurar persegue um problema que nao existe.
 *
 * Sem confirmacao em dois cliques: sair nao destroi nada, e quem clicou por
 * engano volta com a senha.
 */
function sair() {
  descartarToken();

  if (Estado.timerPoll) { clearInterval(Estado.timerPoll); Estado.timerPoll = null; }
  if (Estado.canalRealtime) {
    try { Estado.canalRealtime.close(); } catch (_) { /* ja fechado */ }
    Estado.canalRealtime = null;
  }

  // `replace` e nao `href`: com href, o botao Voltar do navegador retorna ao
  // painel ja sem token e a pessoa ve a tela de falha em vez do login.
  window.location.replace('login.html');
}

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
    const [maquinas, resumo, lojas] = await Promise.all([
      api('/machines_status?select=*&order=site_code.asc,label.asc'),
      rpc('dashboard_summary'),
      // As lojas vêm de fonte PRÓPRIA, e não deduzidas das máquinas: uma loja
      // sem nenhuma máquina não apareceria em lugar nenhum da tela, e loja
      // invisível é loja que ninguém consegue remover nem cadastrar PC dentro.
      api('/sites_status?select=site_code,site_name,brand_code,brand_name,machines_total&order=site_code.asc'),
    ]);

    Estado.maquinas = maquinas || [];
    Estado.resumo = resumo || {};
    Estado.lojas = lojas || [];

    marcarConexao(true);
    desenharResumo();
    desenharFila();
    preencherFiltros();
    desenharMaquinas();
    verificarDadosDemo();

    // Depois de desenhar: a faixa e informacao de topo, mas a lista de maquinas
    // e o que a equipe precisa ver mesmo se esta consulta falhar.
    await carregarIncidentes();
    Estado.primeiraCargaIncidentes = false;

    txt($('rodape-atualizacao'), `atualizado ${new Date().toLocaleTimeString('pt-BR')}`);
  } catch (e) {
    marcarConexao(false, e.message);
    brinde(`Falha ao carregar: ${e.message}`, true);
  }

  // Fora do try acima de propósito: a carga da frota é a parte cara, e uma falha
  // nela não pode derrubar a lista de máquinas, que é o que a equipe realmente
  // precisa ver quando algo está quebrado.
  try {
    await carregarFrota();
  } catch (e) {
    txt($('carga-sub'), `série indisponível: ${e.message}`);
  }
}

function marcarConexao(ok, detalhe) {
  const p = $('indicador-conexao');
  if (ok) {
    txt(p, CFG.authMode === 'supabase' && CFG.realtime ? 'ao vivo' : `${CFG.pollSeconds}s`);
    p.className = 'selo mono selo-ok';
    p.title = '';
  } else {
    txt(p, 'sem conexão');
    p.className = 'selo mono selo-ruim';
    p.title = detalhe || '';
  }
}

// -----------------------------------------------------------------------------
// Resumo
// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------
// Estado derivado: "degradado"
// -----------------------------------------------------------------------------
// O banco conhece quatro estados (online, offline, never_seen, disabled). Falta
// o que a operação mais usa: a máquina que ESTÁ respondendo mas tem algo errado.
// Sem ele, um PDV com o Spooler parado aparece verde ao lado de um PDV saudável,
// e a tela deixa de responder "o que precisa de mim agora".
//
// Derivado aqui, e não no banco, porque os limiares são de apresentação: mudar
// "disco crítico" de 10% para 8% não deveria exigir migração.
const PISO_DISCO = 10;
const PISO_DISCO_ATENCAO = 20;
const TETO_TEMP = 85;
const TETO_CPU = 92;
const TETO_DESVIO_RELOGIO = 120;

/** Lista de problemas de uma máquina, do mais grave para o menos. */
function problemasDe(m) {
  const p = [];
  if (m.status !== 'online') return p;

  if (m.services_down > 0) {
    const nomes = Array.isArray(m.services_down_names) ? m.services_down_names.join(', ') : '';
    p.push({
      grau: 'crit',
      tipo: 'servico',
      titulo: `${m.services_down} serviço(s) parado(s)`,
      desc: nomes ? `Parados: ${nomes}.` : 'Serviço crítico do perfil não está em execução.',
    });
  }

  const disco = m.disk_min_free_pct;
  if (disco !== null && disco !== undefined) {
    if (disco <= PISO_DISCO) {
      p.push({
        grau: 'crit',
        tipo: 'disco',
        titulo: `Disco crítico em ${m.disk_worst_drive || 'volume desconhecido'}`,
        desc: `${round1(disco)}% livre`
          + (m.disk_worst_free_gb !== null && m.disk_worst_free_gb !== undefined
              ? ` (${gb(m.disk_worst_free_gb)} de ${gbNu(m.disk_worst_total_gb)}).`
              : '.'),
      });
    } else if (disco <= PISO_DISCO_ATENCAO) {
      p.push({
        grau: 'alerta',
        tipo: 'disco',
        titulo: `Disco apertado em ${m.disk_worst_drive || 'volume desconhecido'}`,
        desc: `${round1(disco)}% livre.`,
      });
    }
  }

  if (m.cpu_temp_c !== null && m.cpu_temp_c !== undefined && m.cpu_temp_c >= TETO_TEMP) {
    p.push({ grau: 'alerta', tipo: 'temp', titulo: 'Temperatura alta',
      desc: `${round1(m.cpu_temp_c)} °C na CPU.` });
  }

  if (m.cpu_pct !== null && m.cpu_pct !== undefined && m.cpu_pct >= TETO_CPU) {
    p.push({ grau: 'alerta', tipo: 'cpu', titulo: 'CPU saturada',
      desc: `${round1(m.cpu_pct)}% na última amostra.` });
  }

  const desvio = Math.abs(Number(m.clock_drift_seconds || 0));
  if (desvio >= TETO_DESVIO_RELOGIO) {
    p.push({ grau: 'alerta', tipo: 'relogio', titulo: 'Relógio fora de hora',
      desc: `${Math.round(desvio)}s de desvio — o histórico desta máquina sai torto.` });
  }

  return p;
}

/** Estado de exibição, que inclui "degradado". */
function estadoDe(m) {
  if (m.status !== 'online') return m.status;
  return problemasDe(m).length > 0 ? 'degradado' : 'online';
}

// -----------------------------------------------------------------------------
// Resumo: KPIs, selos do topo e contadores da barra lateral
// -----------------------------------------------------------------------------
function desenharResumo() {
  const ms = Estado.maquinas;
  const por = (e) => ms.filter((m) => estadoDe(m) === e);

  const online = por('online');
  const degradado = por('degradado');
  const offline = por('offline');
  const nunca = por('never_seen');
  const respondendo = online.length + degradado.length;

  const comServico = ms.filter((m) => m.status === 'online' && m.services_down > 0);
  const comDisco = ms.filter((m) => m.status === 'online'
    && m.disk_min_free_pct !== null && m.disk_min_free_pct !== undefined
    && m.disk_min_free_pct <= PISO_DISCO);

  // Zero apaga a tira. Um "0 degradados" aceso de laranja ensina a equipe a
  // ignorar laranja, que é o contrário do que a cor existe para fazer.
  const tira = (id, valor, nota) => {
    const n = Number(valor ?? 0);
    txt($(id), n);
    $(id).closest('.tira').classList.toggle('zero', n === 0);
    if (nota !== undefined) txt($(`${id}-nota`), nota);
  };

  txt($('kpi-total'), respondendo);
  $('kpi-total').closest('.tira').classList.toggle('zero', respondendo === 0);
  txt($('kpi-online-de'), `de ${ms.length}`);
  txt($('kpi-online-nota'), ms.length
    ? `${Math.round((respondendo / ms.length) * 100)}% da frota reportando`
    : 'nenhuma máquina cadastrada');

  tira('kpi-degradado', degradado.length,
    degradado.length ? resumirLojas(degradado) : 'nenhum problema em máquina online');
  tira('kpi-offline', offline.length,
    offline.length ? resumirLojas(offline) : 'todas com contato recente');
  tira('kpi-servicos', comServico.length,
    comServico.length ? resumirLojas(comServico) : 'serviços críticos em execução');
  tira('kpi-disco', comDisco.length,
    comDisco.length ? resumirLojas(comDisco) : `nenhuma abaixo de ${PISO_DISCO}% livre`);

  // Selos do topo.
  const selo = (id, n, cls) => {
    txt($(id), n);
    const s = $(id).closest('.selo');
    if (s) s.classList.toggle('zero', n === 0);
    return cls;
  };
  selo('selo-ok', online.length);
  selo('selo-degradado', degradado.length);
  selo('selo-offline', offline.length);

  // Contadores das vistas na barra lateral.
  const conta = { total: ms.length, offline: offline.length, degradado: degradado.length, nunca: nunca.length };
  for (const no of document.querySelectorAll('[data-cont]')) {
    const n = conta[no.getAttribute('data-cont')] ?? 0;
    txt(no, n);
    no.classList.toggle('zero', n === 0);
  }

  const lojas = new Set(ms.map((m) => m.site_code).filter(Boolean));
  txt($('marca-escopo'), `${lojas.size} loja(s) · ${ms.length} host(s)`);

  // As tiras contam a FROTA INTEIRA, sempre. É a escolha certa — filtrar por
  // "offline" e ver o contador de offline virar zero seria absurdo —, mas ela
  // engana quem acabou de filtrar por loja. Então a tela diz.
  const f = Estado.filtros;
  const filtrando = !!(f.marca || f.loja || f.status || f.busca.trim());
  const aviso = $('escopo-kpi');
  aviso.hidden = !filtrando;
  if (filtrando) txt(aviso, 'as tiras acima contam a frota inteira');

  desenharNavMarcas();

  // Título da aba: quem está com a janela em segundo plano vê o problema.
  const ruim = offline.length + degradado.length;
  document.title = ruim > 0
    ? `(${offline.length} off · ${degradado.length} deg) Operações`
    : 'Centro de operações';
}

/** "BSB-001, SP-002 e mais 3" — cabe na tira e diz onde olhar. */
function resumirLojas(lista) {
  const codigos = [...new Set(lista.map((m) => m.site_code).filter(Boolean))];
  if (codigos.length === 0) return '—';
  if (codigos.length <= 2) return codigos.join(', ');
  return `${codigos.slice(0, 2).join(', ')} e mais ${codigos.length - 2}`;
}

function desenharNavMarcas() {
  const nav = $('nav-marcas');
  limpar(nav);

  const marcas = new Map();
  for (const m of Estado.maquinas) {
    if (!m.brand_code) continue;
    if (!marcas.has(m.brand_code)) marcas.set(m.brand_code, { nome: m.brand_name, ruins: 0, total: 0 });
    const b = marcas.get(m.brand_code);
    b.total++;
    if (['offline', 'degradado'].includes(estadoDe(m))) b.ruins++;
  }

  if (marcas.size < 2) return;   // uma marca só não é navegação, é rótulo

  nav.appendChild(el('span', 'secao-lateral mono', 'Marcas'));

  const todas = el('button', `vista${Estado.filtros.marca ? '' : ' ativa'}`);
  todas.type = 'button';
  todas.appendChild(el('span', 'marca-cor'));
  todas.appendChild(el('span', 'vista-rot', 'Todas'));
  todas.appendChild(el('span', 'vista-num mono', String(Estado.maquinas.length)));
  todas.addEventListener('click', () => { Estado.filtros.marca = ''; $('filtro-marca').value = ''; aplicarFiltros(); });
  nav.appendChild(todas);

  for (const [cod, b] of [...marcas.entries()].sort((a, b2) => a[0].localeCompare(b2[0], 'pt-BR'))) {
    const bt = el('button', `vista${Estado.filtros.marca === cod ? ' ativa' : ''}`);
    bt.type = 'button';
    bt.appendChild(el('span', 'marca-cor'));
    bt.appendChild(el('span', 'vista-rot', b.nome || cod));
    const n = el('span', `vista-num mono${b.ruins ? ' ruim' : ''}`, String(b.ruins || b.total));
    bt.appendChild(n);
    bt.addEventListener('click', () => {
      Estado.filtros.marca = cod;
      $('filtro-marca').value = cod;
      aplicarFiltros();
    });
    nav.appendChild(bt);
  }
}

// -----------------------------------------------------------------------------
// Relatório mensal
// -----------------------------------------------------------------------------
async function abrirRelatorio() {
  $('rel-fundo').hidden = false;
  $('modal-relatorio').hidden = false;

  const sel = $('rel-mes');
  if (sel.options.length === 0) {
    let meses = [];
    try { meses = await rpc('meses_com_relatorio'); } catch (_) { meses = []; }

    // Mês corrente sempre presente, mesmo sem rollup ainda: o relatório dele é
    // legítimo (parcial), e uma lista vazia deixaria a tela sem saída.
    const agora = new Date().toISOString().slice(0, 7);
    if (!meses.includes(agora)) meses.unshift(agora);

    for (const m of meses) {
      const o = el('option', null, rotuloMes(m));
      o.value = m;
      sel.appendChild(o);
    }
    // Abre no mês passado quando ele existe: é o relatório que se pede.
    sel.value = meses.length > 1 ? meses[1] : meses[0];
  }

  await desenharRelatorio();
}

function rotuloMes(iso) {
  const [a, m] = iso.split('-');
  const nomes = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho',
    'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
  return `${nomes[Number(m) - 1]} de ${a}`;
}

async function desenharRelatorio() {
  const mes = $('rel-mes').value;
  const corpo = $('rel-corpo');
  const resumo = $('rel-resumo');

  limpar(corpo);
  limpar(resumo);
  txt($('rel-sub'), 'carregando…');

  let r;
  try {
    r = await rpc('relatorio_mensal', { p_mes: `${mes}-01` });
  } catch (e) {
    txt($('rel-sub'), `falhou: ${e.message}`);
    return;
  }

  Estado.relatorio = r;

  txt($('rel-sub'),
    `${r.mes} · ${r.resumo.maquinas} máquina(s), ${r.resumo.com_dado} com dado · `
    + `gerado ${new Date(r.gerado_em).toLocaleString('pt-BR')}`);

  const cartao = (num, rot, classe) => {
    const d = el('div', 'rr-item');
    const n = el('strong', `rr-num${classe ? ` ${classe}` : ''}`, num);
    d.appendChild(n);
    d.appendChild(el('span', 'rr-rot', rot));
    return d;
  };

  const disp = r.resumo.disponibilidade_media;
  resumo.appendChild(cartao(disp === null || disp === undefined ? '—' : `${disp}%`,
    'disponibilidade média', disp !== null && disp < 99 ? 'alerta' : 'ok'));
  resumo.appendChild(cartao(r.resumo.quedas ?? 0, 'quedas', r.resumo.quedas > 0 ? 'ruim' : null));
  resumo.appendChild(cartao(r.resumo.criticos ?? 0, 'alertas críticos', r.resumo.criticos > 0 ? 'ruim' : null));
  resumo.appendChild(cartao(r.resumo.alertas ?? 0, 'alertas no total'));
  resumo.appendChild(cartao(r.resumo.reinicios ?? 0, 'reinícios'));

  if (!r.maquinas || r.maquinas.length === 0) {
    const tr = el('tr');
    const td = el('td', 'rel-vazio', 'Nenhuma máquina no período.');
    td.colSpan = 9;
    tr.appendChild(td);
    corpo.appendChild(tr);
    return;
  }

  for (const m of r.maquinas) {
    const tr = el('tr');

    tr.appendChild(el('td', null, m.loja));
    tr.appendChild(el('td', null, m.maquina));

    const d = m.disponibilidade_pct;
    tr.appendChild(el('td', `num ${d === null ? '' : d >= 99 ? 'ok' : d >= 95 ? 'alerta' : 'ruim'}`,
      d === null || d === undefined ? 'sem dado' : `${d}%`));

    tr.appendChild(el('td', 'num', `${m.cpu_media}%`));
    tr.appendChild(el('td', `num${m.cpu_p95 >= 90 ? ' alerta' : ''}`, `${m.cpu_p95}%`));

    const disco = m.disco_min_pct;
    tr.appendChild(el('td', `num${disco !== null && disco <= 10 ? ' ruim' : ''}`,
      disco === null || disco === undefined ? '—' : `${round1(disco)}%`));

    tr.appendChild(el('td', 'num', m.reinicios));
    tr.appendChild(el('td', `num${m.criticos > 0 ? ' ruim' : ''}`, m.alertas));
    tr.appendChild(el('td', 'num', m.horas_em_alerta));

    corpo.appendChild(tr);
  }
}

function fecharRelatorio() {
  $('modal-relatorio').hidden = true;
  $('rel-fundo').hidden = true;
}

/**
 * Exporta em CSV, não em PDF.
 *
 * O relatório existe para ser trabalhado: filtrar por loja, ordenar por
 * disponibilidade, colar num e-mail. PDF é bonito e é um beco sem saída — e uma
 * equipe enxuta abre planilha, não gera relatório.
 *
 * `;` como separador e BOM UTF-8 no início: é o que faz o Excel em português
 * abrir o arquivo com as colunas separadas e os acentos certos, em vez de
 * despejar tudo numa coluna só.
 */
function baixarRelatorioCsv() {
  const r = Estado.relatorio;
  if (!r) return;

  const colunas = [
    ['marca', 'Marca'], ['loja', 'Loja'], ['loja_nome', 'Nome da loja'],
    ['maquina', 'Máquina'], ['disponibilidade_pct', 'Disponibilidade %'],
    ['amostras', 'Amostras'], ['esperadas', 'Esperadas'],
    ['cpu_media', 'CPU média %'], ['cpu_p95', 'CPU p95 %'], ['mem_media', 'Memória média %'],
    ['temp_max', 'Temp. máx C'], ['disco_min_pct', 'Disco mín %'],
    ['reinicios', 'Reinícios'], ['horas_com_servico_parado', 'Horas com serviço parado'],
    ['alertas', 'Alertas'], ['criticos', 'Críticos'], ['quedas', 'Quedas'],
    ['horas_em_alerta', 'Horas em alerta'],
  ];

  const campo = (v) => {
    if (v === null || v === undefined) return '';
    const s = String(v);
    // Decimal com vírgula: o Excel em português não reconhece ponto como
    // separador decimal e trataria 99.5 como texto.
    const n = /^-?\d+\.\d+$/.test(s) ? s.replace('.', ',') : s;
    return /[;"\n]/.test(n) ? `"${n.replace(/"/g, '""')}"` : n;
  };

  const linhas = [colunas.map(([, t]) => campo(t)).join(';')];
  for (const m of r.maquinas) linhas.push(colunas.map(([k]) => campo(m[k])).join(';'));

  const csv = `﻿${linhas.join('\r\n')}\r\n`;
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);

  const a = document.createElement('a');
  a.href = url;
  a.download = `monitoramento-${r.mes}.csv`;
  document.body.appendChild(a);
  a.click();
  a.remove();

  // Sem revoke, cada exportação vaza o blob até a aba fechar.
  setTimeout(() => URL.revokeObjectURL(url), 1000);

  brinde(`Planilha de ${r.mes} baixada.`);
}

// -----------------------------------------------------------------------------
// Faixa de incidente
// -----------------------------------------------------------------------------
// A fila de atenção (abaixo) é derivada do estado ATUAL e é imediata. Esta faixa
// é outra coisa: mostra o alerta FORMAL, o que passou pela histerese do
// avaliador e portanto se sustentou. É a diferença entre "um pico agora" e
// "isto está acontecendo há dez minutos".
//
// Só acende para CRÍTICO e NÃO RECONHECIDO. Reconhecer não fecha o alerta — ele
// continua aberto no histórico até a condição realmente se desfazer —, só cala a
// faixa. Sem esse escape, um problema que leva dois dias para ser resolvido
// deixaria a tela vermelha por dois dias, e no terceiro ninguém mais a veria.
async function carregarIncidentes() {
  let inc;
  try {
    inc = await rpc('incidentes_abertos');
  } catch (e) {
    // Nunca esconde a frota por causa disto. Mas também não finge que está tudo
    // bem: se a consulta falhou, a faixa some e o console registra.
    console.warn('[monitor] incidentes indisponíveis:', e.message);
    $('faixa-incidente').hidden = true;
    return;
  }

  Estado.incidentes = inc;

  const naFaixa = (inc.lista || []).filter((a) => a.severity === 'critical' && !a.reconhecido);
  const faixa = $('faixa-incidente');

  atualizarFavicon(naFaixa.length > 0, (inc.avisos || 0) > 0);
  tocarSeNovo(naFaixa);

  if (naFaixa.length === 0) {
    faixa.hidden = true;
    Estado.incidenteNaFaixa = null;
    return;
  }

  const primeiro = naFaixa[0];
  Estado.incidenteNaFaixa = primeiro;

  txt($('fi-titulo'), naFaixa.length === 1
    ? '1 incidente crítico'
    : `${naFaixa.length} incidentes críticos`);

  txt($('fi-detalhe'),
    `${primeiro.site_code || 'sem loja'} · ${primeiro.message}`
    + (naFaixa.length > 1 ? `  (+${naFaixa.length - 1} outro(s))` : ''));

  txt($('fi-reconhecer'), naFaixa.length > 1 ? 'Reconhecer este' : 'Reconhecer');
  faixa.hidden = false;
}

async function reconhecerIncidente() {
  const a = Estado.incidenteNaFaixa;
  if (!a) return;

  await rpc('reconhecer_alerta', { p_event_id: a.event_id });
  brinde(`${a.label}: alerta reconhecido. Continua aberto até normalizar.`);
  await carregarIncidentes();
}

function abrirMaquinaDoIncidente() {
  const a = Estado.incidenteNaFaixa;
  if (!a) return;

  const m = Estado.maquinas.find((x) => x.machine_id === a.machine_id);
  if (m) abrirPainel(m);
  else brinde('A máquina deste alerta não está na lista visível.', true);
}

// -----------------------------------------------------------------------------
// Aviso sonoro
// -----------------------------------------------------------------------------
// Desligado por padrão, e toca UMA vez por incidente novo — nunca em laço.
//
// Som repetido em painel de operação é desligado no primeiro dia, e com ele vai
// embora o recurso inteiro. Um toque curto quando algo NOVO aparece é o que
// funciona numa tela de parede que ninguém está encarando.
function tocarSeNovo(criticos) {
  const idsAgora = new Set(criticos.map((a) => a.event_id));

  const novos = [...idsAgora].filter((id) => !Estado.incidentesVistos.has(id));
  Estado.incidentesVistos = idsAgora;

  if (novos.length === 0 || !Estado.som) return;

  // Primeira carga da página não toca: a tela abrindo com três incidentes
  // antigos não é novidade nenhuma, é o estado do mundo.
  if (Estado.primeiraCargaIncidentes) return;

  apitar();
}

/**
 * Dois tons curtos, gerados na hora.
 *
 * Sem arquivo de áudio de propósito: um .mp3 seria mais um recurso para servir,
 * mais uma coisa para faltar, e a CSP teria de liberar media-src.
 */
function apitar() {
  try {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) return;

    const ctx = Estado.audio || (Estado.audio = new Ctx());
    if (ctx.state === 'suspended') ctx.resume();

    for (const [quando, hz] of [[0, 880], [0.18, 660]]) {
      const osc = ctx.createOscillator();
      const vol = ctx.createGain();
      osc.type = 'sine';
      osc.frequency.value = hz;

      // Envelope: um tom que corta seco estala no alto-falante.
      const t = ctx.currentTime + quando;
      vol.gain.setValueAtTime(0, t);
      vol.gain.linearRampToValueAtTime(0.13, t + 0.02);
      vol.gain.exponentialRampToValueAtTime(0.0001, t + 0.15);

      osc.connect(vol).connect(ctx.destination);
      osc.start(t);
      osc.stop(t + 0.16);
    }
  } catch (_) {
    // Navegador sem permissão de áudio: a faixa vermelha continua valendo.
  }
}

function alternarSom() {
  Estado.som = !Estado.som;
  try { localStorage.setItem('monitor.som', Estado.som ? '1' : '0'); } catch (_) { /* privado */ }

  txt($('btn-som-rot'), Estado.som ? 'Som: ligado' : 'Som: desligado');
  $('btn-som').setAttribute('aria-pressed', String(Estado.som));

  // Toca na hora de ligar: confirma que funciona, e o navegador exige um gesto
  // do usuário para liberar áudio — este clique é esse gesto.
  if (Estado.som) apitar();
}

// -----------------------------------------------------------------------------
// Favicon
// -----------------------------------------------------------------------------
// Quem deixa o painel numa aba de fundo não vê faixa nenhuma. O favicon é o
// único pixel que sobra, então ele carrega o estado.
function atualizarFavicon(critico, aviso) {
  const chave = `${critico}|${aviso}`;
  if (Estado.faviconAtual === chave) return;   // redesenhar a cada 20s é desperdício
  Estado.faviconAtual = chave;

  try {
    const c = document.createElement('canvas');
    c.width = 64;
    c.height = 64;
    const g = c.getContext('2d');

    const cor = critico ? '#ff5c6c' : aviso ? '#f5b544' : '#35d6a4';

    g.fillStyle = '#0c0e13';
    g.beginPath();
    g.roundRect(0, 0, 64, 64, 14);
    g.fill();

    g.fillStyle = cor;
    g.beginPath();
    g.arc(32, 32, critico ? 20 : 15, 0, Math.PI * 2);
    g.fill();

    let link = document.querySelector('link[rel="icon"]');
    if (!link) {
      link = document.createElement('link');
      link.rel = 'icon';
      document.head.appendChild(link);
    }
    link.href = c.toDataURL('image/png');
  } catch (_) {
    // roundRect não existe em navegador antigo: sem favicon, e tudo bem.
  }
}

// -----------------------------------------------------------------------------
// Fila de atenção
// -----------------------------------------------------------------------------
// Derivada do estado ATUAL, não de uma tabela de alertas: a avaliação de regras
// (fase 5) ainda não existe, e uma fila permanentemente vazia daria a impressão
// errada de que está tudo bem. Cada linha aponta para a máquina.
function desenharFila() {
  const lista = $('fila-alertas');
  limpar(lista);

  const itens = [];

  for (const m of Estado.maquinas) {
    const e = estadoDe(m);

    if (e === 'offline') {
      itens.push({ m, grau: 'crit', ordem: 0, tipo: 'offline',
        titulo: `${m.label} sem contato`,
        desc: `Última amostra ${desdeQuando(m.seconds_since_seen, m.status)}.`
          + (m.in_maintenance ? ' Em manutenção declarada.' : '') });
      continue;
    }

    if (e === 'never_seen') {
      itens.push({ m, grau: 'alerta', ordem: 2, tipo: 'nunca',
        titulo: `${m.label} nunca reportou`,
        desc: 'Cadastrada, mas o agente ainda não enviou nenhuma amostra.' });
      continue;
    }

    for (const p of problemasDe(m)) {
      itens.push({ m, grau: p.grau, ordem: p.grau === 'crit' ? 1 : 3, tipo: p.tipo,
        titulo: `${m.label}: ${p.titulo}`, desc: p.desc });
    }
  }

  itens.sort((a, b) => a.ordem - b.ordem
    || (a.m.site_code || '').localeCompare(b.m.site_code || '', 'pt-BR'));

  const criticos = itens.filter((i) => i.grau === 'crit').length;
  const cont = $('fila-cont');
  txt(cont, itens.length ? `${itens.length} em aberto` : 'tudo limpo');
  cont.className = `selo mono ${criticos ? 'selo-ruim' : itens.length ? 'selo-alerta' : 'selo-ok'}`;

  if (itens.length === 0) {
    const p = el('li', 'fila-vazia', 'Nenhuma máquina pedindo atenção agora.');
    lista.appendChild(p);
    return;
  }

  for (const it of itens.slice(0, 40)) {
    const li = el('li', `item-fila if-${it.grau}`);
    li.tabIndex = 0;
    li.setAttribute('role', 'button');
    li.setAttribute('aria-label', `${it.titulo}. Abrir detalhe.`);

    li.appendChild(iconeFila(it.tipo));

    const corpo = el('div', 'if-corpo');
    corpo.appendChild(el('div', 'if-titulo', it.titulo));
    corpo.appendChild(el('div', 'if-desc', it.desc));

    const tags = el('div', 'if-tags');
    if (it.m.site_code) tags.appendChild(el('span', 'if-tag', it.m.site_code));
    tags.appendChild(el('span', 'if-tag', it.tipo));
    corpo.appendChild(tags);
    li.appendChild(corpo);

    li.appendChild(el('span', 'if-quando', desdeQuando(it.m.seconds_since_seen, it.m.status)));

    const abrir = () => abrirPainel(it.m);
    li.addEventListener('click', abrir);
    li.addEventListener('keydown', (ev) => {
      if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); abrir(); }
    });

    lista.appendChild(li);
  }
}

/* Ícones em SVG montado por createElement: `innerHTML` com <svg> abriria a porta
   que a regra 7 fecha, mesmo sendo conteúdo nosso. Um caminho só, por tipo. */
const CAMINHO_ICONE = {
  offline: 'M12 2v10 M18.4 6.6a9 9 0 1 1-12.8 0',
  nunca:   'M12 8v5 M12 17h.01 M12 3 2 21h20L12 3z',
  servico: 'M6 3h12v4H6z M6 10h12v4H6z M9 17h6v4H9z',
  disco:   'M4 6h16v5H4z M4 13h16v5H4z M7 8.5h.01 M7 15.5h.01',
  temp:    'M14 14.8V4a2 2 0 1 0-4 0v10.8a4 4 0 1 0 4 0z',
  cpu:     'M6 6h12v12H6z M9 1v3 M15 1v3 M9 20v3 M15 20v3 M1 9h3 M1 15h3 M20 9h3 M20 15h3',
  relogio: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M12 7v5l3 2',
};

function iconeFila(tipo) {
  const NS = 'http://www.w3.org/2000/svg';
  const caixa = el('span', 'if-icone');
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('width', '15');
  svg.setAttribute('height', '15');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '1.9');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');

  for (const d of (CAMINHO_ICONE[tipo] || CAMINHO_ICONE.nunca).split(' M').map((s, i) => (i ? `M${s}` : s))) {
    const p = document.createElementNS(NS, 'path');
    p.setAttribute('d', d);
    svg.appendChild(p);
  }

  caixa.appendChild(svg);
  return caixa;
}

// -----------------------------------------------------------------------------
// Carga da frota e pulso da ingestão
// -----------------------------------------------------------------------------
async function carregarFrota() {
  const faixa = Estado.faixaFrota;

  const [op, onl] = await Promise.all([
    rpc('painel_operacao', { p_faixa: faixa }),
    rpc('serie_online', { p_faixa: faixa }),
  ]);

  // ------------------------------------------------------------------ pulso
  const pulso = (op && op.pulso) || {};
  txt($('pulso-min'), pulso.amostras_min ?? 0);
  txt($('kpi-ingest'), pulso.amostras_min ?? 0);

  const porHora = Number(pulso.amostras_hora || 0);
  txt($('pulso-nota'), `${porHora} na última hora · ${pulso.maquinas_reportando || 0} máquina(s) reportando`);
  txt($('kpi-ingest-nota'), `${pulso.maquinas_reportando || 0} máquina(s) enviando`);
  $('kpi-ingest').closest('.tira').classList.toggle('zero', !(pulso.amostras_min > 0));

  // A bolha verde só pisca quando dado está mesmo chegando. Verde fixo com a
  // ingestão parada seria a mentira mais cara desta tela.
  const bolha = $('pulso-bolha');
  bolha.className = pulso.amostras_min > 0 ? 'ponto ponto-ok' : 'ponto ponto-ruim';

  const lat = pulso.latencia_gw_media;
  txt($('lat-media'), lat === null || lat === undefined ? '—' : `${round1(lat)} ms`);
  txt($('lat-nota'), lat === null || lat === undefined
    ? 'nenhuma máquina online mediu o gateway'
    : 'ida e volta até o roteador da loja');

  faixinha('pulso-faixa', Array.isArray(pulso.serie) ? pulso.serie.map(Number) : []);
  faixinha('spark-ingest', Array.isArray(pulso.serie) ? pulso.serie.map(Number) : []);

  // ----------------------------------------------------------- hosts online
  const pontos = (onl && Array.isArray(onl.pontos)) ? onl.pontos : [];
  faixinha('spark-online', pontos.map((p) => Number(p.online || 0)));

  // ------------------------------------------------------------------ carga
  const carga = (op && Array.isArray(op.carga)) ? op.carga : [];

  if (carga.length === 0) {
    txt($('carga-sub'), 'sem amostras nesta faixa');
    if (Estado.graficos['grafico-frota']) {
      Estado.graficos['grafico-frota'].destroy();
      delete Estado.graficos['grafico-frota'];
    }
    return;
  }

  const ultimo = carga[carga.length - 1];
  txt($('carga-sub'),
    `CPU e memória médias · ${ultimo.maquinas} host(s) na última leitura · `
    + `agora ${round1(ultimo.cpu)}% CPU e ${round1(ultimo.mem)}% memória`);

  desenharFrota(
    carga.map((p) => formatarBalde(p.t, faixa)),
    carga.map((p) => (p.cpu === null ? null : Number(p.cpu))),
    carga.map((p) => (p.mem === null ? null : Number(p.mem))),
  );
}

/** Sparkline em barras. Reamostra para caber sem virar uma pilha de fios. */
function faixinha(id, valores) {
  const caixa = $(id);
  if (!caixa) return;
  limpar(caixa);

  const vals = (valores || []).filter((v) => Number.isFinite(v));
  if (vals.length === 0) {
    caixa.appendChild(el('span', 'spark-vazio', 'sem dados'));
    return;
  }

  const ALVO = 26;
  const passo = Math.max(1, Math.ceil(vals.length / ALVO));
  const barras = [];
  for (let i = 0; i < vals.length; i += passo) {
    const fatia = vals.slice(i, i + passo);
    barras.push(fatia.reduce((a, b) => a + b, 0) / fatia.length);
  }

  const max = Math.max(...barras, 1);
  for (const v of barras) {
    const b = el('span', v >= max * 0.85 ? 'alta' : null);
    // Mínimo de 8%: barra de altura zero some, e "zero" é informação.
    b.style.height = `${Math.max(8, (v / max) * 100)}%`;
    b.setAttribute('title', String(Math.round(v)));
    caixa.appendChild(b);
  }
}

function desenharFrota(rotulos, cpu, mem) {
  if (Estado.graficos['grafico-frota']) Estado.graficos['grafico-frota'].destroy();

  const css = getComputedStyle(document.documentElement);
  const corCpu = css.getPropertyValue('--info').trim() || '#6aa8ff';
  const corMem = css.getPropertyValue('--vio').trim() || '#a78bfa';
  const corTexto = css.getPropertyValue('--fg3').trim() || '#5c6a7e';
  const corGrade = css.getPropertyValue('--bd2').trim() || 'rgba(255,255,255,.05)';

  const ctx = $('grafico-frota').getContext('2d');

  const area = (cor) => {
    const g = ctx.createLinearGradient(0, 0, 0, 240);
    g.addColorStop(0, `${cor}55`);
    g.addColorStop(1, `${cor}00`);
    return g;
  };

  // Ponto visível quando a série é curta.
  //
  // Uma linha precisa de DOIS pontos para existir. Com `pointRadius: 0` e um
  // balde só — o caso de uma frota que acabou de começar a reportar — o gráfico
  // desenhava literalmente nada, e a leitura era "está quebrado" quando o certo
  // era "ainda não há histórico".
  const raio = rotulos.length < 4 ? 3 : 0;

  Estado.graficos['grafico-frota'] = new Chart(ctx, {
    type: 'line',
    data: {
      labels: rotulos,
      datasets: [
        { label: 'CPU média', data: cpu, borderColor: corCpu, backgroundColor: area(corCpu),
          borderWidth: 1.8, pointRadius: raio, tension: 0.3, fill: true, spanGaps: false },
        { label: 'Memória média', data: mem, borderColor: corMem, backgroundColor: area(corMem),
          borderWidth: 1.8, pointRadius: raio, tension: 0.3, fill: true, spanGaps: false },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      interaction: { mode: 'index', intersect: false },
      plugins: {
        legend: { position: 'top', align: 'start',
          labels: { boxWidth: 10, boxHeight: 10, color: corTexto, font: { size: 11 }, usePointStyle: true } },
        tooltip: { callbacks: { label: (c) => `${c.dataset.label}: ${c.parsed.y}%` } },
      },
      scales: {
        y: { min: 0, max: 100, grid: { color: corGrade }, border: { display: false },
          ticks: { color: corTexto, font: { size: 10 }, callback: (v) => `${v}%` } },
        x: { grid: { display: false }, border: { display: false },
          ticks: { color: corTexto, font: { size: 10 }, maxTicksLimit: 8, maxRotation: 0 } },
      },
    },
  });
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
    // Compara com o estado DERIVADO, senão o filtro "degradado" nunca casaria e
    // "online" traria também as máquinas com serviço parado.
    if (f.status && estadoDe(m) !== f.status) return false;

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

  txt($('frota-titulo'),
    Estado.modo === 'lojas' ? 'Lojas'
      : Estado.modo === 'tabela' ? 'Frota'
      : Estado.modo === 'heatmap' ? 'Parque inteiro' : 'Máquinas');

  // Zero máquinas NÃO significa zero a mostrar.
  //
  // No modo lojas, uma loja sem nenhuma máquina continua sendo uma loja: ela
  // precisa aparecer para poder receber um PC ou ser removida. A versão anterior
  // saía aqui e desenhava "nenhuma máquina corresponde ao filtro", e as lojas
  // vazias sumiam da tela outra vez — o mesmo defeito que eu tinha corrigido um
  // nível abaixo, reintroduzido por este atalho.
  const lojasVazias = Estado.modo === 'lojas' && lista.length === 0
    && !Estado.filtros.status && !Estado.filtros.busca.trim()
    && Estado.lojas.some((s) => (!Estado.filtros.marca || s.brand_code === Estado.filtros.marca)
      && (!Estado.filtros.loja || s.site_code === Estado.filtros.loja));

  if (lista.length === 0 && !lojasVazias) {
    const nada = Estado.maquinas.length === 0;
    txt($('frota-sub'), nada ? 'nenhuma máquina cadastrada' : 'nada corresponde ao filtro');
    conteudo.appendChild(el('p', 'vazio', nada
      ? 'Nenhuma máquina cadastrada ainda. Use "+ Adicionar PC" para começar.'
      : 'Nenhuma máquina corresponde ao filtro.'));
    return;
  }

  const lojasVisiveis = new Set(lista.map((m) => m.site_code).filter(Boolean));
  const ruins = lista.filter((m) => ['offline', 'degradado'].includes(estadoDe(m))).length;
  txt($('frota-sub'),
    `${lojasVisiveis.size} loja(s) · ${lista.length} host(s)`
    + (ruins ? ` · ${ruins} pedindo atenção` : ''));

  if (Estado.modo === 'heatmap') {
    desenharHeatmap(conteudo, lista);
    return;
  }

  if (Estado.modo === 'tabela') {
    desenharTabelaDensa(conteudo, lista);
    return;
  }

  if (Estado.modo === 'lojas') {
    desenharCartoesDeLoja(conteudo, lista);
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
  // Estado DERIVADO: uma máquina que responde mas está com o Spooler parado não
  // pode ficar verde ao lado de uma saudável.
  const e = estadoDe(m);

  const c = el('article', `cartao cartao-${e}`);
  c.tabIndex = 0;
  c.setAttribute('role', 'button');
  // aria-label recebe TEXTO, nunca markup — um hostname com < e > fica literal.
  c.setAttribute('aria-label', `${m.label}, ${rotuloStatus(e)}`);

  const topo = el('header', 'cartao-topo');
  topo.appendChild(el('span', 'cartao-nome', m.label));
  topo.appendChild(el('span', `bolha bolha-${e}`));
  c.appendChild(topo);

  // O hostname vem do agente e é o vetor do teste de aceite de XSS.
  const host = el('p', 'cartao-host', m.hostname || 'host desconhecido');
  c.appendChild(host);

  const linha = el('p', 'cartao-status');
  linha.appendChild(el('span', `etiqueta etiqueta-${e}`, rotuloStatus(e)));
  linha.appendChild(el('span', 'cartao-visto', desdeQuando(m.seconds_since_seen, m.status)));
  c.appendChild(linha);

  if (m.in_maintenance) {
    c.appendChild(el('p', 'cartao-manutencao', 'em manutenção'));
  }

  const metricas = el('div', 'metricas');
  metricas.appendChild(metrica('CPU', pct(m.cpu_pct), barra(m.cpu_pct, 90)));
  metricas.appendChild(metrica('Memória', pct(m.mem_pct), barra(m.mem_pct, 92)));
  // A barra continua sendo a porcentagem: ela e a escala visual e o eixo dos
  // limiares. O texto e GB, que e o que se entende sem saber o tamanho do disco.
  metricas.appendChild(metrica(
    m.disk_worst_drive ? `Disco livre (${m.disk_worst_drive})` : 'Disco livre',
    m.disk_worst_free_gb === null || m.disk_worst_free_gb === undefined
      ? pct(m.disk_min_free_pct)
      : `${gb(m.disk_worst_free_gb)} de ${gbNu(m.disk_worst_total_gb)}`,
    barra(m.disk_min_free_pct, null, 10)));
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

// -----------------------------------------------------------------------------
// Modo "lojas": um cartão por loja, com heatmap de hosts
// -----------------------------------------------------------------------------
// É o que faz a tela caber em dezenas de lojas sem virar rolagem infinita. Cada
// quadrado é uma máquina e abre o painel dela — a densidade não custa o acesso.

// ---------------------------------------------------------------------------
// Tabela densa
// ---------------------------------------------------------------------------
// A terceira forma de olhar a mesma frota. Cartão por loja responde "qual loja
// está ruim"; a tabela responde "quais máquinas, e quão ruins" — e é a única
// que cabe sessenta linhas numa tela.
//
// ORDENADA POR GRAVIDADE, não por nome: o que precisa de alguém vem primeiro.
// Dentro do mesmo estado, maior CPU primeiro.

const TD_COLUNAS = [
  ['Host', '1.5fr', false],
  ['Loja', '.85fr', false],
  ['Tipo', '.6fr', false],
  ['Estado', '.75fr', false],
  ['CPU', '.6fr', true],
  ['Mem', '.6fr', true],
  ['Disco livre', '.95fr', true],
  ['Temp', '.55fr', true],
  ['HB', '.7fr', true],
];

const TD_PESO = { offline: 0, degradado: 1, never: 2, online: 3, manutencao: 4, disabled: 5 };


// ---------------------------------------------------------------------------
// Heatmap
// ---------------------------------------------------------------------------
// Uma faixa por loja. É a vista que responde "onde está o problema" com o
// parque inteiro na tela — duzentos hosts cabem sem rolar, e um vermelho no
// meio de verdes salta aos olhos sem lista e sem procura.
//
// As cores são TINGIDAS (26% de fundo, 44% de borda), não sólidas. Um mosaico
// de cores saturadas cansa em minutos numa tela que fica aberta o turno inteiro.

const HM_TONS = {
  online: 'ok', degradado: 'warn', offline: 'crit',
  never: 'fg3', manutencao: 'fg3', disabled: 'fg3',
};

function desenharHeatmap(conteudo, lista) {
  // Legenda primeiro: sem ela o mosaico é bonito e ilegível.
  const leg = el('div', 'hm-legenda');
  for (const [estado, rot] of [['online', 'ok'], ['degradado', 'degradado'],
                               ['offline', 'offline'], ['manutencao', 'manutenção']]) {
    const s = el('span');
    const i = el('i');
    const t = HM_TONS[estado];
    i.style.background = 'color-mix(in srgb, var(--' + t + ') 26%, transparent)';
    i.style.border = '1px solid color-mix(in srgb, var(--' + t + ') 44%, transparent)';
    s.appendChild(i);
    s.appendChild(el('span', null, rot));
    leg.appendChild(s);
  }
  conteudo.appendChild(leg);

  // Agrupa por loja, mantendo a ordem por código.
  const porLoja = new Map();
  for (const m of lista) {
    const cod = m.site_code || '(sem loja)';
    if (!porLoja.has(cod)) porLoja.set(cod, { nome: m.site_name || cod, hosts: [] });
    porLoja.get(cod).hosts.push(m);
  }

  const ordenadas = [...porLoja.entries()].sort((a, b) => {
    // Loja com problema primeiro: é o que se quer ver ao abrir.
    const ruimA = a[1].hosts.filter((m) => ['offline', 'degradado'].includes(estadoDe(m))).length;
    const ruimB = b[1].hosts.filter((m) => ['offline', 'degradado'].includes(estadoDe(m))).length;
    if (ruimA !== ruimB) return ruimB - ruimA;
    return a[0].localeCompare(b[0], 'pt-BR');
  });

  for (const [cod, loja] of ordenadas) {
    const linha = el('div', 'hm-linha');

    const ident = el('div', 'hm-loja');
    ident.appendChild(el('div', 'hm-nome', loja.nome));
    ident.appendChild(el('div', 'hm-meta', cod));
    linha.appendChild(ident);

    const hosts = el('div', 'hm-hosts');
    for (const m of loja.hosts) {
      const e = estadoDe(m);
      const t = HM_TONS[e];
      const q = el('button', 'hm-quad');
      q.type = 'button';
      q.style.background = 'color-mix(in srgb, var(--' + t + ') 26%, transparent)';
      q.style.border = '1px solid color-mix(in srgb, var(--' + t + ') 44%, transparent)';
      // title e aria-label recebem TEXTO: um hostname com < e > fica literal.
      const resumo = m.label + ' · ' + rotuloStatus(e)
        + (m.cpu_pct !== null && m.cpu_pct !== undefined ? ' · cpu ' + Math.round(m.cpu_pct) + '%' : '');
      q.title = resumo;
      q.setAttribute('aria-label', resumo);
      q.addEventListener('click', () => abrirPainel(m));
      hosts.appendChild(q);
    }
    if (loja.hosts.length === 0) {
      hosts.appendChild(el('span', 'hm-vazio', 'sem máquinas'));
    }
    linha.appendChild(hosts);

    const online = loja.hosts.filter((m) => estadoDe(m) === 'online').length;
    const num = el('div', 'hm-num');
    const cont = el('span', 'mono', online + '/' + loja.hosts.length);
    if (online < loja.hosts.length) cont.style.color = 'var(--crit)';
    num.appendChild(cont);

    // CPU média das que reportam. Máquina sem CPU não entra na média — ela não
    // puxa o número para baixo fingindo zero.
    const comCpu = loja.hosts.filter((m) => m.cpu_pct !== null && m.cpu_pct !== undefined);
    if (comCpu.length > 0) {
      const media = comCpu.reduce((s, m) => s + m.cpu_pct, 0) / comCpu.length;
      const barra = el('div', 'hm-barra');
      const fill = el('i');
      fill.style.width = Math.max(0, Math.min(100, media)) + '%';
      if (media >= 85) fill.style.background = 'var(--crit)';
      else if (media >= 70) fill.style.background = 'var(--warn)';
      barra.appendChild(fill);
      num.appendChild(barra);
    }
    linha.appendChild(num);

    conteudo.appendChild(linha);
  }
}

function desenharTabelaDensa(conteudo, lista) {
  const grade = TD_COLUNAS.map((c) => c[1]).join(' ');

  const caixa = el('div', 'td-caixa');
  const wrap = el('div', 'td-grade');

  const cab = el('div', 'td-cab');
  cab.style.gridTemplateColumns = grade;
  for (const [rot, , dir] of TD_COLUNAS) {
    const s = el('span', dir ? 'td-dir' : null, rot);
    cab.appendChild(s);
  }
  wrap.appendChild(cab);

  const ordenada = [...lista].sort((a, b) => {
    const d = TD_PESO[estadoDe(a)] - TD_PESO[estadoDe(b)];
    if (d !== 0) return d;
    return (b.cpu_pct ?? -1) - (a.cpu_pct ?? -1);
  });

  for (const m of ordenada) {
    const e = estadoDe(m);
    const linha = el('button', 'td-linha');
    linha.type = 'button';
    linha.style.gridTemplateColumns = grade;
    linha.setAttribute('aria-label', m.label + ', ' + rotuloStatus(e));

    // Host, com a bolinha do estado.
    const host = el('span', 'td-host');
    const ponto = el('i', 'td-ponto');
    ponto.style.background = e === 'offline' ? 'var(--crit)'
      : e === 'degradado' ? 'var(--warn)'
      : e === 'online' ? 'var(--ok)' : 'var(--fg3)';
    host.appendChild(ponto);
    host.appendChild(el('span', null, m.label));
    linha.appendChild(host);

    linha.appendChild(el('span', 'td-fraco', m.site_code || '—'));
    linha.appendChild(el('span', 'td-fraco', m.role_code || '—'));

    const et = el('span', 'etiqueta etiqueta-' + e, rotuloStatus(e));
    const cel = el('span');
    cel.appendChild(et);
    linha.appendChild(cel);

    linha.appendChild(tdNum(m.cpu_pct, '%', 0, tomPct(m.cpu_pct, 85, 95)));
    linha.appendChild(tdNum(m.mem_pct, '%', 0, tomPct(m.mem_pct, 85, 95)));
    // Cor pela porcentagem, texto em GB: varrer sessenta linhas pede o numero
    // que dispensa conta.
    const dLivre = gb(m.disk_worst_free_gb);
    if (dLivre === null) {
      linha.appendChild(tdNum(m.disk_min_free_pct, '%', 0, tomDisco(m.disk_min_free_pct)));
    } else {
      const cel = el('span', 'td-dir mono', `${dLivre} / ${gbNu(m.disk_worst_total_gb)}`);
      const cor = tomDisco(m.disk_min_free_pct);
      if (cor) cel.style.color = cor;
      linha.appendChild(cel);
    }
    linha.appendChild(tdNum(m.cpu_temp_c, '\u00b0', 0, tomPct(m.cpu_temp_c, 75, 85)));

    const hb = el('span', 'td-dir mono td-fraco', desdeQuando(m.seconds_since_seen, e));
    linha.appendChild(hb);

    linha.addEventListener('click', () => abrirPainel(m));
    wrap.appendChild(linha);
  }

  caixa.appendChild(wrap);
  conteudo.appendChild(caixa);
}

/** Uma célula numérica — ou um travessão, que distingue "zero" de "não medido". */
function tdNum(v, sufixo, casas, cor) {
  const s = el('span', 'td-dir mono');
  if (v === null || v === undefined || Number.isNaN(v)) {
    s.textContent = '\u2014';
    s.style.color = 'var(--fg3)';
    return s;
  }
  s.textContent = Number(v).toFixed(casas) + sufixo;
  if (cor) s.style.color = cor;
  return s;
}

function tomPct(v, alerta, critico) {
  if (v === null || v === undefined) return null;
  if (v >= critico) return 'var(--crit)';
  if (v >= alerta) return 'var(--warn)';
  return null;
}

function tomDisco(livre) {
  if (livre === null || livre === undefined) return null;
  if (livre <= 5) return 'var(--crit)';
  if (livre <= 15) return 'var(--warn)';
  return null;
}

function desenharCartoesDeLoja(conteudo, lista) {
  const porLoja = new Map();
  for (const m of lista) {
    const chave = m.site_code || '(sem loja)';
    if (!porLoja.has(chave)) {
      porLoja.set(chave, { code: chave, nome: m.site_name, marca: m.brand_name, maquinas: [] });
    }
    porLoja.get(chave).maquinas.push(m);
  }

  // Lojas VAZIAS entram aqui. Sem isto elas somem da tela — e sumir não é o
  // mesmo que não existir: a loja continua no banco, contando nos filtros, e sem
  // nenhum caminho na interface para removê-la ou cadastrar um PC nela.
  //
  // Só quando não há filtro de status ou busca: se o operador pediu "offline",
  // uma loja sem máquina nenhuma não é resposta para a pergunta que ele fez.
  const semFiltroDeMaquina = !Estado.filtros.status && !Estado.filtros.busca.trim();

  if (semFiltroDeMaquina) {
    for (const s of Estado.lojas) {
      if (porLoja.has(s.site_code)) continue;
      if (Estado.filtros.marca && s.brand_code !== Estado.filtros.marca) continue;
      if (Estado.filtros.loja && s.site_code !== Estado.filtros.loja) continue;
      porLoja.set(s.site_code, {
        code: s.site_code, nome: s.site_name, marca: s.brand_name, maquinas: [],
      });
    }
  }

  const lojas = [...porLoja.values()];

  // Ordena por GRAVIDADE, não por código: numa tela com trinta lojas, a que está
  // em incidente não pode depender de rolagem para ser vista.
  const peso = (l) => {
    const e = l.maquinas.map(estadoDe);
    if (e.includes('offline')) return 0;
    if (e.includes('degradado')) return 1;
    if (e.includes('never_seen')) return 2;
    return 3;
  };
  lojas.sort((a, b) => peso(a) - peso(b) || a.code.localeCompare(b.code, 'pt-BR'));

  const grade = el('div', 'grade-lojas');
  for (const l of lojas) grade.appendChild(cartaoLoja(l));
  conteudo.appendChild(grade);
}

/**
 * Entrar na loja: filtra a frota para ela e troca para a vista por maquina.
 *
 * Reaproveita o filtro que ja existia (`Estado.filtros.loja` e o select
 * `#filtro-loja`) em vez de inventar um segundo caminho de navegacao. Dois
 * caminhos para o mesmo estado divergem: um limpa o filtro de marca, o outro
 * nao, e a tela passa a mostrar coisas diferentes conforme por onde se chegou.
 *
 * O clique no botao de modo e disparado de proposito, em vez de escrever
 * `Estado.modo = 'maquinas'`: o handler dele tambem grava a preferencia e ajusta
 * o aria-selected do controle segmentado. Atribuir direto deixaria os dois
 * dessincronizados — a tela na vista nova e o botao aceso na antiga.
 */
function acessarLoja(loja) {
  Estado.filtros.loja = loja.code;

  // A marca sai do caminho: se o filtro de marca estiver em outra marca, a loja
  // escolhida sumiria da lista e o clique pareceria nao ter funcionado.
  const ref = loja.maquinas[0];
  if (ref && Estado.filtros.marca && ref.brand_code !== Estado.filtros.marca) {
    Estado.filtros.marca = '';
  }

  preencherFiltros();

  const btnModo = document.querySelector('[data-modo="maquinas"]');
  if (btnModo) btnModo.click();

  aplicarFiltros();

  // A grade fica abaixo dos KPIs; sem isto, em tela pequena o clique filtra
  // fora do campo de visao e parece que nada aconteceu.
  $('conteudo').scrollIntoView({ block: 'start', behavior: 'smooth' });
  brinde(`Loja ${loja.code}: ${loja.maquinas.length} maquina(s).`);
}

function cartaoLoja(loja) {
  const estados = loja.maquinas.map(estadoDe);
  const offline = estados.filter((e) => e === 'offline').length;
  const degradado = estados.filter((e) => e === 'degradado').length;
  const online = estados.filter((e) => e === 'online').length;

  let situacao = 'estavel';
  let rotulo = 'estável';
  if (loja.maquinas.length === 0) { situacao = 'parada'; rotulo = 'sem máquinas'; }
  else if (offline > 0) { situacao = 'incidente'; rotulo = 'incidente'; }
  else if (degradado > 0) { situacao = 'atencao'; rotulo = 'atenção'; }
  else if (online === 0) { situacao = 'parada'; rotulo = 'sem dados'; }

  const c = el('article', `cartao-loja cl-${situacao}`);

  const cab = el('div', 'cl-cab');
  const ident = el('div');
  const nome = el('button', 'cl-nome cl-nome-btn', loja.nome || loja.code);
  nome.type = 'button';
  nome.title = `Ver as ${loja.maquinas.length} maquina(s) de ${loja.code}`;
  nome.addEventListener('click', (ev) => { ev.stopPropagation(); acessarLoja(loja); });
  ident.appendChild(nome);
  ident.appendChild(el('p', 'cl-meta', `${loja.marca || 'sem marca'} · ${loja.code}`));
  cab.appendChild(ident);

  const acoes = el('div', 'cl-cab-acoes');
  acoes.appendChild(el('span', `cl-selo cl-selo-${situacao}`, rotulo));

  const lixeira = el('button', 'cl-remover');
  lixeira.type = 'button';
  lixeira.title = `Remover a loja ${loja.code} e as ${loja.maquinas.length} máquina(s) dela`;
  lixeira.setAttribute('aria-label', lixeira.title);
  lixeira.appendChild(iconeLixeira());
  const lapis = el('button', 'btn-icone');
  lapis.type = 'button';
  lapis.title = `Corrigir código, nome ou fuso da loja ${loja.code}`;
  lapis.setAttribute('aria-label', lapis.title);
  lapis.appendChild(iconeLapis());
  // stopPropagation: o cabecalho do cartao inteiro e clicavel e filtraria a loja.
  lapis.addEventListener('click', (ev) => { ev.stopPropagation(); editarLoja(loja); });
  acoes.appendChild(lapis);

  armarLixeira(lixeira, () => removerLoja(loja));
  acoes.appendChild(lixeira);

  cab.appendChild(acoes);
  c.appendChild(cab);

  // ------------------------------------------------------------- heatmap
  const mapa = el('div', 'mapa-hosts');
  for (const m of [...loja.maquinas].sort((a, b) => (a.label || '').localeCompare(b.label || '', 'pt-BR'))) {
    const e = estadoDe(m);
    const q = el('button', `host-quad hq-${e}`);
    q.type = 'button';
    // O nome da máquina vem do banco: title e aria-label recebem TEXTO, nunca
    // markup — um hostname com < e > fica literal.
    const desc = `${m.label} — ${rotuloStatus(e)}`;
    q.title = desc;
    q.setAttribute('aria-label', desc);
    q.addEventListener('click', () => abrirPainel(m));
    mapa.appendChild(q);
  }
  c.appendChild(mapa);

  // -------------------------------------------------------------- números
  const medias = (campo) => {
    const v = loja.maquinas
      .filter((m) => m.status === 'online' && m[campo] !== null && m[campo] !== undefined)
      .map((m) => Number(m[campo]));
    return v.length ? v.reduce((a, b) => a + b, 0) / v.length : null;
  };

  const cpu = medias('cpu_pct');
  const rtt = medias('gw_latency_ms');

  // DISCO NAO E FILTRADO POR ONLINE, e isso e de proposito — mas exige aviso.
  //
  // CPU e RTT sao taxas instantaneas: de uma maquina desligada elas nao
  // existem, e por isso as duas mostram travessao. Espaco livre em disco e
  // ESTADO: disco nao se esvazia sozinho com o PC desligado. Um servidor que
  // caiu com 3% livre continua sendo o problema mais urgente da loja, e
  // esconder isso justamente quando ele para de reportar seria esconder o que
  // mais importa.
  //
  // O que NAO se pode e mostrar essa leitura como se fosse de agora. A janela da
  // view (status_lookback_hours) e de SETE DIAS, entao o numero pode ser de uma
  // semana atras. Daqui em diante ele vem com til e com a idade no title.
  const comDisco = loja.maquinas.filter(
    (m) => m.disk_min_free_pct !== null && m.disk_min_free_pct !== undefined);
  const pior = comDisco.length
    ? comDisco.reduce((a, b) => (Number(b.disk_min_free_pct) < Number(a.disk_min_free_pct) ? b : a))
    : null;
  const discoMin = pior === null ? null : Number(pior.disk_min_free_pct);
  // 'degradado' NAO conta como velho: a maquina responde, so tem algo errado —
  // a leitura dela e de agora. Velho e quem parou de reportar.
  const discoVelho = pior !== null
    && !['online', 'degradado'].includes(estadoDe(pior));

  const cels = el('div', 'cl-celulas');

  cels.appendChild(celula(
    'online', `${online + degradado}/${loja.maquinas.length}`,
    offline > 0 ? 'ruim' : null,
    `${online + degradado} de ${loja.maquinas.length} maquina(s) reportando. `
    + 'Conta as degradadas, que respondem mas tem algo errado.'));

  cels.appendChild(celula(
    'cpu', cpu === null ? '—' : `${Math.round(cpu)}%`,
    cpu !== null && cpu >= TETO_CPU ? 'alerta' : null,
    cpu === null
      ? 'Nenhuma maquina online agora, entao nao ha uso de CPU para medir.'
      : `Media de uso de CPU das maquinas online. Fica ambar a partir de ${TETO_CPU}%.`));

  cels.appendChild(celula(
    'disco livre',
    // GB primeiro, porcentagem no title. "24 GB de 238" nao precisa de conta;
    // "10%" precisa saber o tamanho do disco para significar alguma coisa.
    discoMin === null ? '—' : (gb(pior.disk_worst_free_gb) ?? `${Math.round(discoMin)}%`),
    discoMin === null ? null : discoMin <= PISO_DISCO ? 'ruim' : discoMin <= PISO_DISCO_ATENCAO ? 'alerta' : null,
    discoMin === null
      ? 'Nenhuma maquina desta loja reportou disco ainda.'
      : `Espaco LIVRE no volume mais apertado da loja: ${pior.disk_worst_drive || 'volume'} `
        + `de ${pior.label}, com ${gb(pior.disk_worst_free_gb) ?? '?'} livres `
        + `de ${gbNu(pior.disk_worst_total_gb) ?? '?'} (${Math.round(discoMin)}%). `
        + `Quanto MENOR, pior: ambar abaixo de ${PISO_DISCO_ATENCAO}%, vermelho abaixo de ${PISO_DISCO}%.`
        // Um numero que muda sem explicacao e pior que um numero errado: se o
        // servidor descartou um volume, a tela diz isso em vez de simplesmente
        // mostrar outro numero do que mostrava ontem.
        + (pior.disk_volumes_ignorados > 0
            ? ` ${pior.disk_volumes_ignorados} volume(s) pequeno(s) fora da conta `
              + '(recuperacao, EFI, reservada do sistema): vivem cheios por natureza.'
            : '')
        // `desdeQuando` ja devolve "ha 4h": juntar "de ... atras" em volta
        // produzia "leitura de ha 4h atras".
        + (discoVelho
            ? ` Esta maquina parou de reportar: ultima leitura ${desdeQuando(pior.seconds_since_seen, estadoDe(pior))}, nao de agora.`
            : ''),
    discoVelho,
    discoMin === null ? null : `de ${gbNu(pior.disk_worst_total_gb) ?? '?'}`));

  cels.appendChild(celula(
    'rtt', rtt === null ? '—' : `${Math.round(rtt)}ms`, null,
    rtt === null
      ? 'Nenhuma maquina online agora, entao nao ha latencia para medir.'
      : 'Tempo de ida e volta ate o roteador da loja, medido pelas maquinas online. '
        + 'Mede a rede DE DENTRO da loja, nao a internet.'));

  c.appendChild(cels);

  // Clique em qualquer lugar do cartao entra na loja.
  //
  // O guarda e `closest('button')` e nao stopPropagation espalhado pelos filhos:
  // com stopPropagation, todo botao novo que alguem acrescentar ao cartao no
  // futuro passa a filtrar a loja por engano, e quem esquecer a linha nao
  // descobre — o sintoma e um clique que faz duas coisas. Aqui a regra e uma so,
  // num lugar so, e vale para botao que ainda nao existe.
  c.classList.add('cl-clicavel');
  c.addEventListener('click', (ev) => {
    if (ev.target.closest('button')) return;
    // Selecionar texto do cartao nao pode virar navegacao.
    const sel = window.getSelection();
    if (sel && String(sel).length > 0) return;
    acessarLoja(loja);
  });

  return c;
}

/** Lapis, pelo mesmo caminho da lixeira e pela mesma razao (regra 7). */
function iconeLapis() {
  const NS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '1.9');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  for (const d of ['M4 20h4l10.5-10.5a2.1 2.1 0 0 0-3-3L5 17v3Z', 'M13.5 6.5l4 4']) {
    const p = document.createElementNS(NS, 'path');
    p.setAttribute('d', d);
    svg.appendChild(p);
  }
  return svg;
}

/** Lixeira em SVG por createElementNS: `innerHTML` abriria a porta da regra 7. */
function iconeLixeira() {
  const NS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '2');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  for (const d of ['M3 6h18', 'M8 6V4h8v2', 'M19 6l-1 14H6L5 6', 'M10 11v6', 'M14 11v6']) {
    const p = document.createElementNS(NS, 'path');
    p.setAttribute('d', d);
    svg.appendChild(p);
  }
  return svg;
}

/**
 * Mesma ideia do armarPerigo, para um botão que é só ícone: o primeiro clique
 * troca a lixeira por um "×" sólido, o segundo remove.
 */
function armarLixeira(botao, acao) {
  let temporizador = null;

  const desarmar = () => {
    clearTimeout(temporizador);
    temporizador = null;
    botao.classList.remove('armado');
    limpar(botao);
    botao.appendChild(iconeLixeira());
  };

  botao.addEventListener('click', async (ev) => {
    ev.stopPropagation();

    if (!temporizador) {
      botao.classList.add('armado');
      limpar(botao);
      botao.appendChild(document.createTextNode('×'));
      temporizador = setTimeout(desarmar, ESPERA_CONFIRMA_MS);
      return;
    }

    desarmar();
    botao.disabled = true;
    try { await acao(); } catch (e) { brinde(e.message, true); } finally { botao.disabled = false; }
  });
}

/**
 * Uma celula do cartao de loja.
 *
 * `ajuda` NAO e enfeite. Estes rotulos sao de quatro a seis caracteres, e
 * "DISCO 10%" foi lido como "10% usado" — o oposto do que e. Quando um numero
 * fica vermelho justamente por ser BAIXO, o rotulo tem que dizer de que ele e
 * porcentagem, e no espaco que cabe isso so entra no title.
 *
 * `velho` marca valor que nao e de agora. Ver a explicacao em cartaoLoja.
 */
// ---------------------------------------------------------------------------
// Editar cadastro
// ---------------------------------------------------------------------------
// Um formulario generico. Cada chamada passa os campos e o que fazer ao salvar;
// o resto — montar, limpar, desabilitar o botao, mostrar o erro do servidor — e
// igual para maquina, loja e marca, e por isso mora aqui uma vez.
//
// OS LIMITES NAO SAO REPETIDOS AQUI. Nome repetido na loja, fuso invalido,
// codigo em uso: quem decide e o banco, nas funcoes editar_*. Validar de novo no
// navegador criaria uma segunda regra para divergir da primeira — e a do
// navegador e justamente a que nao vale, porque qualquer um pode contorna-la.

let edicaoAtual = null;

function fecharEdicao() {
  edicaoAtual = null;
  $('modal-editar').hidden = true;
  $('modal-editar-fundo').hidden = true;
}

/**
 * @param {object}   cfg
 * @param {string}   cfg.titulo
 * @param {string}   cfg.dica
 * @param {Array}    cfg.campos  {id, rotulo, valor, opcoes?, nota?}
 * @param {Function} cfg.salvar  recebe {id: valor} e chama a RPC
 */
function abrirEdicao(cfg) {
  edicaoAtual = cfg;

  txt($('editar-titulo'), cfg.titulo);
  txt($('editar-dica'), cfg.dica || '');
  $('editar-dica').hidden = !cfg.dica;
  $('editar-erro').hidden = true;

  const caixa = $('editar-campos');
  limpar(caixa);

  for (const c of cfg.campos) {
    const w = el('div', 'ed-campo');

    const rot = el('label', null, c.rotulo);
    rot.setAttribute('for', 'ed-' + c.id);
    w.appendChild(rot);

    let campo;
    if (c.opcoes) {
      campo = el('select');
      for (const o of c.opcoes) {
        const op = el('option', null, o.rotulo);
        op.value = o.valor;
        if (String(o.valor) === String(c.valor)) op.selected = true;
        campo.appendChild(op);
      }
    } else {
      campo = el('input');
      campo.type = 'text';
      campo.value = c.valor ?? '';
      campo.autocomplete = 'off';
      campo.spellcheck = false;
    }
    campo.id = 'ed-' + c.id;
    w.appendChild(campo);

    if (c.nota) w.appendChild(el('p', 'ed-nota', c.nota));
    caixa.appendChild(w);
  }

  $('modal-editar-fundo').hidden = false;
  $('modal-editar').hidden = false;

  // Foco no primeiro campo, com o texto selecionado: quem abriu para corrigir um
  // nome quer digitar por cima, nao posicionar cursor.
  const primeiro = caixa.querySelector('input, select');
  if (primeiro) {
    primeiro.focus();
    if (primeiro.select) primeiro.select();
  }
}

function ligarEdicao() {
  $('btn-fechar-editar').addEventListener('click', fecharEdicao);
  $('modal-editar-fundo').addEventListener('click', fecharEdicao);

  $('form-editar').addEventListener('submit', async (ev) => {
    ev.preventDefault();
    if (!edicaoAtual) return;

    const btn = $('btn-editar-salvar');
    const rotulo = btn.textContent;
    btn.disabled = true;
    txt(btn, 'Salvando...');
    $('editar-erro').hidden = true;

    const vals = {};
    for (const c of edicaoAtual.campos) vals[c.id] = $('ed-' + c.id).value;

    try {
      const r = await edicaoAtual.salvar(vals);
      fecharEdicao();
      brinde(r && r.nada_a_fazer ? 'Nada mudou.' : 'Cadastro corrigido.');
      // Recarrega tudo: o nome novo aparece no cartao, na lista, na paleta e na
      // gaveta. Atualizar so o campo visivel deixaria a paleta buscando pelo
      // nome antigo e a gaveta com o cabecalho velho.
      await carregar();
    } catch (e) {
      txt($('editar-erro'), e.message);
      $('editar-erro').hidden = false;
    } finally {
      btn.disabled = false;
      txt(btn, rotulo);
    }
  });
}

async function editarMaquinaAberta() {
  const m = Estado.maquinaAberta;
  if (!m) return;

  // Perfis e lojas vem do servidor, filtrados pelo escopo de quem esta logado:
  // oferecer uma loja que a pessoa nao pode usar seria montar um formulario cujo
  // unico destino e falhar ao salvar.
  if (!opcoesCadastro) {
    try { opcoesCadastro = await rpc('opcoes_cadastro'); } catch (_) { opcoesCadastro = null; }
  }
  const lojas = (opcoesCadastro && opcoesCadastro.lojas) || [];
  const perfis = (opcoesCadastro && opcoesCadastro.perfis) || [];

  abrirEdicao({
    titulo: 'Editar ' + m.label,
    dica: 'Renomear nao reinstala nada: a maquina e identificada por um GUID, e o '
        + 'agente ja instalado continua reportando com o nome novo.',
    campos: [
      { id: 'label', rotulo: 'Nome da máquina', valor: m.label,
        nota: 'Precisa ser único dentro da loja.' },
      { id: 'role_code', rotulo: 'Perfil', valor: m.role_code,
        opcoes: perfis.length
          ? perfis.map((p) => ({ valor: p.code, rotulo: p.name + ' (' + p.code + ')' }))
          : [{ valor: m.role_code, rotulo: m.role_code }],
        nota: 'O perfil define quais serviços são vigiados nesta máquina.' },
      { id: 'site_id', rotulo: 'Loja', valor: m.site_id,
        opcoes: lojas.length
          ? lojas.map((l) => ({ valor: l.id, rotulo: l.code + ' — ' + l.name }))
          : [{ valor: m.site_id, rotulo: m.site_code + ' — ' + m.site_name }],
        nota: 'Mover a máquina leva o histórico dela junto.' },
    ],
    salvar: (v) => rpc('editar_maquina', {
      p_machine_id: m.machine_id,
      p_label: v.label,
      p_role_code: v.role_code,
      p_site_id: v.site_id,
    }),
  });
}

// Os fusos do Brasil, e nao a lista inteira do sistema: uma rede de lojas em
// Brasilia e Sao Paulo nao precisa rolar por quatrocentos nomes para achar o seu.
// Quem precisar de outro edita pelo SQL — o CHECK da tabela aceita qualquer fuso
// valido.
const FUSOS = [
  'America/Sao_Paulo', 'America/Bahia', 'America/Fortaleza', 'America/Recife',
  'America/Belem', 'America/Manaus', 'America/Cuiaba', 'America/Campo_Grande',
  'America/Boa_Vista', 'America/Porto_Velho', 'America/Rio_Branco', 'America/Noronha',
];

function editarLoja(loja) {
  // O cartao agrupa maquinas; os dados da loja moram em qualquer uma delas.
  const ref = loja.maquinas[0];
  if (!ref) { brinde('Esta loja nao tem maquina para identificar o cadastro.', true); return; }

  const fusoAtual = ref.site_timezone || 'America/Sao_Paulo';

  abrirEdicao({
    titulo: 'Editar a loja ' + loja.code,
    dica: 'O fuso decide a hora do reinício agendado e o fechamento do relatório '
        + 'mensal. Errado, a máquina reinicia na hora errada.',
    campos: [
      { id: 'code', rotulo: 'Código', valor: loja.code,
        nota: 'Letras, números, ponto e hífen. É o que aparece nos cartões.' },
      { id: 'name', rotulo: 'Nome', valor: ref.site_name || '' },
      { id: 'timezone', rotulo: 'Fuso horário', valor: fusoAtual,
        // Se a loja estiver num fuso fora da lista, ele entra para nao ser
        // trocado em silencio ao salvar outro campo.
        opcoes: (FUSOS.includes(fusoAtual) ? FUSOS : [fusoAtual, ...FUSOS])
          .map((t) => ({ valor: t, rotulo: t })) },
    ],
    salvar: (v) => rpc('editar_loja', {
      p_site_id: ref.site_id,
      p_code: v.code,
      p_name: v.name,
      p_timezone: v.timezone,
    }),
  });
}

// ---------------------------------------------------------------------------
// Usuários
// ---------------------------------------------------------------------------
// Papel e escopo saem por RPC normal. CRIAR CONTA e TROCAR SENHA saem pela Edge
// Function admin-usuarios, porque as duas exigem a service_role — e a regra 1 diz
// que ela nunca chega ao navegador.
//
// Nada aqui decide quem pode o quê. O botão só aparece para admin porque oferecer
// o que vai falhar é ruim de usar, mas quem RECUSA é o banco: esconder botão não
// é autorização.

let usuariosCache = null;

/**
 * Endereço da função, derivado do authUrl.
 *
 * Não é uma constante nova no config: o projeto já teve um defeito de endereço
 * duplicado (o '/ingest' que eu apaguei sem querer e quebrou só em produção).
 * Um endereço só, derivado, não pode divergir de si mesmo.
 */
function urlAdminUsuarios() {
  const base = String(CFG.authUrl || '').replace(/\/+$/, '');
  if (!base) throw new Error('authUrl nao configurado');
  return base.replace(/\/auth\/v1$/, '/functions/v1/admin-usuarios');
}

async function chamarAdminUsuarios(corpo) {
  const r = await fetch(urlAdminUsuarios(), {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: CFG.anonKey || '',
      Authorization: 'Bearer ' + (Estado.token || ''),
    },
    body: JSON.stringify(corpo),
  });

  let d = null;
  try { d = await r.json(); } catch (_) { d = null; }

  if (!r.ok) {
    // A função devolve 'conserto' quando a conta ficou criada e só o papel
    // falhou. Perder essa frase deixaria o admin achando que nada aconteceu e
    // tentando de novo com o mesmo e-mail.
    const msg = (d && (d.erro || d.message)) || ('a funcao respondeu ' + r.status);
    throw new Error(d && d.conserto ? msg + ' — ' + d.conserto : msg);
  }
  return d;
}

function papelBonito(code) {
  return code === 'admin' ? 'Administrador'
    : code === 'operator' ? 'Operador'
    : 'Somente leitura';
}

function desenharLojasEscolhidas(caixa, lojas, marcadas, inerte) {
  limpar(caixa);
  caixa.classList.toggle('inerte', !!inerte);

  for (const l of lojas) {
    const rot = el('label', 'us-loja');
    const cx = el('input');
    cx.type = 'checkbox';
    cx.value = l.id;
    cx.checked = marcadas.includes(l.id);
    if (cx.checked) rot.classList.add('marcada');
    cx.addEventListener('change', () => rot.classList.toggle('marcada', cx.checked));
    rot.appendChild(cx);
    rot.appendChild(el('span', null, l.code));
    rot.title = l.name;
    caixa.appendChild(rot);
  }

  if (lojas.length === 0) caixa.appendChild(el('span', 'us-vazio', 'nenhuma loja cadastrada'));
}

function lojasMarcadas(caixa) {
  return [...caixa.querySelectorAll('input:checked')].map((c) => c.value);
}

async function abrirUsuarios() {
  $('modal-usuarios-fundo').hidden = false;
  $('modal-usuarios').hidden = false;
  $('us-erro').hidden = true;
  $('us-senha').hidden = true;

  const lista = $('us-lista');
  limpar(lista);
  lista.appendChild(el('p', 'us-vazio', 'carregando...'));

  try {
    usuariosCache = await rpc('usuarios_do_painel');
  } catch (e) {
    limpar(lista);
    lista.appendChild(el('p', 'us-vazio', e.message));
    return;
  }

  const papeis = usuariosCache.papeis || [];
  const lojas = usuariosCache.lojas || [];

  // Formulário de criação
  const sel = $('us-papel');
  limpar(sel);
  for (const p of papeis) {
    const o = el('option', null, p.nome);
    o.value = p.code;
    o.title = p.descricao;
    if (p.code === 'viewer') o.selected = true;   // o menor privilégio, por padrão
    sel.appendChild(o);
  }

  const caixaLojas = $('us-lojas');
  const sincronizarLojas = () => {
    const admin = sel.value === 'admin';
    desenharLojasEscolhidas(caixaLojas, lojas, [], admin);
    txt($('us-lojas-nota'), admin
      ? 'Administrador vê todas as lojas: o escopo não se aplica.'
      : 'Sem nenhuma marcada, a pessoa entra e não vê loja alguma.');
  };
  sel.onchange = sincronizarLojas;
  sincronizarLojas();

  desenharListaUsuarios(usuariosCache);
}

function desenharListaUsuarios(dados) {
  const lista = $('us-lista');
  limpar(lista);

  const usuarios = dados.usuarios || [];
  const lojas = dados.lojas || [];
  const papeis = dados.papeis || [];

  if (usuarios.length === 0) {
    lista.appendChild(el('p', 'us-vazio', 'ninguém cadastrado.'));
    return;
  }

  for (const u of usuarios) {
    const linha = el('div', 'us-linha');
    const souEu = u.user_id === dados.eu;

    const quem = el('div', 'us-quem');
    quem.appendChild(el('div', 'us-email', u.email || u.user_id));
    const meta = el('div', 'us-meta');
    txt(meta, (u.nome ? u.nome + ' · ' : '')
      + (u.todas_as_lojas
        ? 'todas as lojas'
        : (u.lojas || []).length + ' loja(s): '
          + ((u.lojas || []).map((l) => l.code).join(', ') || 'nenhuma'))
      + (souEu ? ' · você' : ''));
    if (souEu) meta.classList.add('us-eu');
    quem.appendChild(meta);
    linha.appendChild(quem);

    const acoes = el('div', 'us-acoes');

    const selPapel = el('select');
    for (const p of papeis) {
      const o = el('option', null, p.nome);
      o.value = p.code;
      if (p.code === u.role) o.selected = true;
      selPapel.appendChild(o);
    }
    selPapel.setAttribute('aria-label', 'Papel de ' + (u.email || u.user_id));
    acoes.appendChild(selPapel);

    // Escopo: uma gaveta por usuário, fechada. Vinte lojas por vinte usuários
    // abertas de uma vez viraria uma parede de caixinhas.
    const det = el('details');
    const sum = el('summary', 'btn-secundario', 'Lojas');
    det.appendChild(sum);
    const caixa = el('div', 'us-lojas');
    caixa.style.marginTop = '8px';
    det.appendChild(caixa);
    det.addEventListener('toggle', () => {
      if (det.open) {
        desenharLojasEscolhidas(caixa, lojas,
          (u.lojas || []).map((l) => l.id), u.role === 'admin' || selPapel.value === 'admin');
      }
    });
    acoes.appendChild(det);

    const salvar = el('button', 'btn-secundario', 'Salvar');
    salvar.type = 'button';
    salvar.addEventListener('click', async () => {
      salvar.disabled = true;
      try {
        // 'null' quando a gaveta nunca foi aberta: assim salvar o PAPEL não
        // apaga o escopo de ninguém. É o par null/vazio da migração 0035, e é o
        // motivo de ele existir.
        const escopo = det.open ? lojasMarcadas(caixa) : null;
        await rpc('definir_acesso_usuario', {
          p_user_id: u.user_id,
          p_role: selPapel.value,
          p_site_ids: escopo,
        });
        brinde('Acesso atualizado.');
        await abrirUsuarios();
      } catch (e) {
        brinde(e.message, true);
      } finally {
        salvar.disabled = false;
      }
    });
    acoes.appendChild(salvar);

    const senha = el('button', 'btn-secundario', 'Nova senha');
    senha.type = 'button';
    armarPerigo(senha, 'Confirmar', async () => {
      const r = await chamarAdminUsuarios({ acao: 'senha', user_id: u.user_id });
      mostrarSenha(r.senha_temporaria);
      brinde('Senha redefinida.');
    });
    acoes.appendChild(senha);

    // Sem botão de revogar em si mesmo: o banco recusa (MON09), e oferecer um
    // botão que só existe para dar erro é pior que não ter botão.
    if (!souEu) {
      const rev = el('button', 'btn-perigo', 'Revogar');
      rev.type = 'button';
      armarPerigo(rev, 'Confirmar', async () => {
        await rpc('remover_acesso_usuario', { p_user_id: u.user_id });
        brinde('Acesso revogado.');
        await abrirUsuarios();
      });
      acoes.appendChild(rev);
    }

    linha.appendChild(acoes);
    lista.appendChild(linha);
  }
}

function mostrarSenha(valor) {
  txt($('us-senha-valor'), valor || '');
  $('us-senha').hidden = !valor;
  $('us-senha').scrollIntoView({ block: 'nearest' });
}

function ligarUsuarios() {
  const fechar = () => {
    $('modal-usuarios').hidden = true;
    $('modal-usuarios-fundo').hidden = true;
    // A senha sai da tela ao fechar. Deixá-la ali faria a próxima abertura
    // mostrar a senha de outra pessoa.
    txt($('us-senha-valor'), '');
    $('us-senha').hidden = true;
  };

  $('btn-usuarios').addEventListener('click', abrirUsuarios);
  $('btn-fechar-usuarios').addEventListener('click', fechar);
  $('modal-usuarios-fundo').addEventListener('click', fechar);

  $('btn-copiar-senha').addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText($('us-senha-valor').textContent);
      brinde('Senha copiada.');
    } catch (_) {
      brinde('O navegador nao liberou a area de transferencia; copie na mao.', true);
    }
  });

  $('form-novo-usuario').addEventListener('submit', async (ev) => {
    ev.preventDefault();

    const btn = $('btn-criar-usuario');
    btn.disabled = true;
    txt(btn, 'Criando...');
    $('us-erro').hidden = true;
    $('us-senha').hidden = true;

    try {
      const papel = $('us-papel').value;
      const r = await chamarAdminUsuarios({
        acao: 'criar',
        email: $('us-email').value.trim(),
        nome: $('us-nome').value.trim(),
        role: papel,
        // Admin ignora escopo; mandar lista seria gravar um limite que não vale.
        site_ids: papel === 'admin' ? null : lojasMarcadas($('us-lojas')),
      });

      mostrarSenha(r.senha_temporaria);
      $('us-email').value = '';
      $('us-nome').value = '';
      brinde('Usuario criado.');

      // Recarrega a lista SEM apagar a senha da tela: ela aparece uma vez, e
      // fechar/reabrir a perderia.
      const antes = r.senha_temporaria;
      usuariosCache = await rpc('usuarios_do_painel');
      desenharListaUsuarios(usuariosCache);
      mostrarSenha(antes);
    } catch (e) {
      txt($('us-erro'), e.message);
      $('us-erro').hidden = false;
    } finally {
      btn.disabled = false;
      txt(btn, 'Criar e gerar senha');
    }
  });
}

function celula(rotulo, valor, classe, ajuda, velho, sub) {
  const d = el('div', 'cel');
  d.appendChild(el('span', 'cel-rot', rotulo));

  const v = el('span', `cel-val${classe ? ` ${classe}` : ''}`);
  v.appendChild(el('span', null, valor));

  if (velho) {
    // Um til antes do numero, e nao um asterisco depois: o til le como
    // "aproximadamente/desatualizado" no lugar onde o olho ja esta, antes de
    // acreditar no valor. Asterisco depois seria lido junto com a unidade.
    v.classList.add('cel-velho');
    const marca = el('span', 'cel-til', '~');
    marca.setAttribute('aria-hidden', 'true');
    v.insertBefore(marca, v.firstChild);
  }

  // "de 238" abaixo do valor, e nao ao lado: ao lado, a fileira de quatro
  // celulas perde o alinhamento na primeira loja com disco de 2 TB.
  if (sub) v.appendChild(el('span', 'cel-sub', sub));

  d.appendChild(v);

  if (ajuda) {
    // No elemento inteiro: quem passa o mouse mira o numero, nao o rotulo.
    d.title = ajuda;
    // O leitor de tela recebe rotulo, valor e explicacao numa frase, porque
    // "DISCO 10 por cento" sozinho tambem engana quem nao ve a cor.
    d.setAttribute('aria-label', `${rotulo}: ${valor}. ${ajuda}`);
  }

  return d;
}

// -----------------------------------------------------------------------------
// Remoção
// -----------------------------------------------------------------------------
// CONFIRMAÇÃO EM DOIS CLIQUES, e não `confirm()` do navegador.
//
// O diálogo nativo é fácil de dispensar no piloto automático, some da tela sem
// deixar rastro e trava a página inteira. Aqui o botão vira "Confirmar" em
// vermelho sólido, pulsando, e desarma sozinho em 5 segundos — quem não quis
// remover só precisa não clicar de novo.
const ESPERA_CONFIRMA_MS = 5000;

/**
 * Transforma um botão em botão de duas etapas.
 * A ação só roda no segundo clique, e o rótulo diz exatamente o que vai sumir.
 */

// ---------------------------------------------------------------------------
// Paleta de comandos (Ctrl K)
// ---------------------------------------------------------------------------
// Busca máquinas e destinos ao mesmo tempo. Num parque de duzentas máquinas,
// achar "PDV 07 da Asa Norte" por navegação custa quatro cliques e a memória de
// onde ela está; por busca custa três letras.
//
// Nada aqui usa innerHTML (regra 7): hostname e nome de loja vêm do banco, e um
// nome com < e > tem que aparecer literal, não virar marcação.

const ICO_PAL = {
  host:  '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  vista: '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
  acao:  '<path d="M3 12h4l3 8 4-16 3 8h4"/>',
};

function itensDaPaleta() {
  const itens = [];

  // Destinos: os mesmos filtros da barra lateral, para quem prefere digitar.
  for (const b of document.querySelectorAll('.vistas .vista')) {
    const rot = b.querySelector('.vista-rot');
    if (!rot) continue;
    const texto = rot.textContent;
    itens.push({
      titulo: texto,
      sub: 'filtro da barra lateral',
      cat: 'vista',
      ico: 'vista',
      cor: 'var(--info)',
      chaves: texto.toLowerCase(),
      agir: () => b.click(),
    });
  }

  // Ações que existem no rodapé da lateral.
  const acoes = [
    ['btn-tema', 'Alternar tema', 'claro e escuro'],
    ['btn-som', 'Alternar som do alerta', 'liga e desliga o aviso sonoro'],
    ['btn-relatorio', 'Relatório mensal', 'abrir o relatório'],
    ['btn-adicionar', 'Adicionar PC', 'cadastrar uma máquina nova'],
  ];
  for (const [id, titulo, sub] of acoes) {
    const alvo = document.getElementById(id);
    if (!alvo) continue;
    itens.push({
      titulo, sub, cat: 'ação', ico: 'acao', cor: 'var(--vio)',
      chaves: (titulo + ' ' + sub).toLowerCase(),
      agir: () => alvo.click(),
    });
  }

  // As máquinas.
  for (const m of Estado.maquinas) {
    const e = estadoDe(m);
    itens.push({
      titulo: m.label,
      sub: [m.site_code, m.ip_lan, e].filter(Boolean).join(' · '),
      cat: 'host',
      ico: 'host',
      cor: e === 'offline' ? 'var(--crit)' : e === 'degradado' ? 'var(--warn)' : 'var(--ok)',
      peso: e === 'offline' ? 3 : e === 'degradado' ? 2 : 1,
      chaves: [m.label, m.hostname, m.ip_lan, m.site_code, m.site_name, m.mac_address]
        .filter(Boolean).join(' ').toLowerCase(),
      agir: () => { fecharPaleta(); abrirPainel(m); },
    });
  }

  return itens;
}

function desenharPaleta() {
  const lista = $('paleta-lista');
  const termo = ($('paleta-busca').value || '').trim().toLowerCase();
  limpar(lista);

  let r = itensDaPaleta();

  if (termo) {
    r = r.filter((i) => i.chaves.includes(termo)).slice(0, 30);
  } else {
    // Busca vazia: os destinos, e as máquinas que mais pedem atenção — por
    // gravidade, não em ordem alfabética. Uma lista alfabética às 3 da manhã
    // não ajuda ninguém.
    const hosts = r.filter((i) => i.cat === 'host')
      .sort((a, b) => (b.peso || 0) - (a.peso || 0)).slice(0, 5);
    r = r.filter((i) => i.cat !== 'host').concat(hosts);
  }

  txt($('paleta-conta'), r.length + ' resultado(s)');

  if (r.length === 0) {
    const vazio = el('div', 'pal-vazio', 'Nada encontrado para \u00ab' + termo + '\u00bb');
    lista.appendChild(vazio);
    return;
  }

  r.forEach((i, n) => {
    const b = el('button', 'pal-item' + (n === 0 ? ' alvo' : ''));
    b.type = 'button';

    const ico = el('span', 'pal-ico');
    ico.style.color = i.cor;
    // innerHTML SÓ com marcação nossa, constante — nunca com dado do banco.
    ico.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true">' + ICO_PAL[i.ico] + '</svg>';
    b.appendChild(ico);

    const texto = el('span', 'pal-texto');
    texto.appendChild(el('span', 'pal-titulo', i.titulo));
    const sub = el('span', 'pal-sub mono', i.sub);
    texto.appendChild(sub);
    b.appendChild(texto);

    b.appendChild(el('span', 'pal-cat mono', i.cat));
    b.addEventListener('click', i.agir);
    lista.appendChild(b);
  });
}

function abrirPaleta() {
  $('paleta-fundo').hidden = false;
  $('paleta').hidden = false;
  $('paleta-busca').value = '';
  desenharPaleta();
  // ~20ms: o campo só existe depois de o navegador pintar o diálogo, e focar
  // antes disso não faz nada — a paleta abriria sem cursor.
  setTimeout(() => $('paleta-busca').focus(), 20);
}

function fecharPaleta() {
  $('paleta').hidden = true;
  $('paleta-fundo').hidden = true;
}

function ligarPaleta() {
  $('paleta-fundo').addEventListener('click', fecharPaleta);
  $('paleta-busca').addEventListener('input', desenharPaleta);

  $('paleta-busca').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      const primeiro = $('paleta-lista').querySelector('.pal-item');
      if (primeiro) primeiro.click();
    }
  });

  // O campo de busca do cabeçalho passa a abrir a paleta: são a mesma pergunta.
  const busca = $('busca');
  if (busca) {
    busca.addEventListener('focus', (e) => { e.target.blur(); abrirPaleta(); });
  }

  window.addEventListener('keydown', (e) => {
    if ((e.metaKey || e.ctrlKey) && (e.key === 'k' || e.key === 'K')) {
      e.preventDefault();
      if ($('paleta').hidden) abrirPaleta(); else fecharPaleta();
      return;
    }
    if (e.key === 'Escape' && !$('paleta').hidden) fecharPaleta();
  });
}

function armarPerigo(botao, rotuloConfirma, acao) {
  // Capturado ao ARMAR, não ao ligar o botão. O rótulo de alguns botões muda em
  // tempo de uso (o de ação remota vira "Simular: ..."), e guardar o texto de
  // uma vez só faria o desarme restaurar um rótulo que não descreve mais o que
  // o clique vai fazer.
  let original = botao.textContent;
  let temporizador = null;

  const desarmar = () => {
    clearTimeout(temporizador);
    temporizador = null;
    botao.classList.remove('armado');
    txt(botao, original);
  };

  botao.addEventListener('click', async () => {
    if (!temporizador) {
      original = botao.textContent;
      botao.classList.add('armado');
      txt(botao, rotuloConfirma);
      temporizador = setTimeout(desarmar, ESPERA_CONFIRMA_MS);
      return;
    }

    desarmar();
    botao.disabled = true;
    try {
      await acao();
    } catch (e) {
      brinde(e.message, true);
    } finally {
      botao.disabled = false;
    }
  });

  return desarmar;
}

// ---------------------------------------------------------------------------
// Ações remotas
// ---------------------------------------------------------------------------
// Nada aqui monta comando: monta um PEDIDO. O painel escolhe um tipo de uma
// lista fechada e informa parâmetros; quem valida, autoriza e aplica os limites
// é o servidor. Se este arquivo fosse adulterado no navegador, o pior que
// conseguiria é pedir — e receber "não pode".

const NOME_DA_ACAO = {
  restart_service: 'Reiniciar serviço',
  clear_temp: 'Limpar temporários',
  restart_machine: 'Reiniciar o PC',
  wake_machine: 'Ligar o PC',
  sleep_machine: 'Suspender o PC',
  run_test_collection: 'Testar coleta',
};

const NOME_DO_ESTADO = {
  pending: 'na fila',
  sent: 'entregue',
  acked: 'em execução',
  succeeded: 'concluído',
  failed: 'falhou',
  expired: 'expirou',
  canceled: 'cancelado',
};

/** Monta a seção de ações a partir do que o SERVIDOR disse ser possível. */
async function desenharAcoes(m) {
  const secao = $('acoes');
  const aviso = $('acao-aviso');

  let a;
  try {
    a = await rpc('acoes_da_maquina', { p_machine_id: m.machine_id });
  } catch (_) {
    // Falha ao perguntar não pode virar botão habilitado: some com a seção.
    secao.hidden = true;
    return;
  }

  // Quem não pode agir não vê os botões. Mostrar um botão que vai responder
  // "apenas administradores" é convidar para a frustração.
  secao.hidden = a.pode !== true;
  if (!a.pode) return;

  const sel = $('acao-servico');
  limpar(sel);
  const servicos = Array.isArray(a.servicos) ? a.servicos : [];
  for (const s of servicos) sel.appendChild(el('option', null, s));
  sel.disabled = servicos.length === 0;

  // Só é possível reiniciar serviço que o perfil da máquina declara como
  // crítico — no servidor. Aqui o botão apenas reflete isso.
  $('btn-restart-service').disabled = servicos.length === 0;

  const motivos = [];
  if (a.agente_suporta !== true) {
    motivos.push(`O agente desta máquina (${a.agent_version || 'versão desconhecida'}) `
      + 'não executa comandos. Reinstale-o pelo comando de adicionar PC para atualizar.');
  }
  if (a.status !== 'online') {
    motivos.push(`A máquina está ${a.status}: o comando fica na fila e expira em 30 min `
      + 'se ela não voltar antes.');
  }
  if (a.reboot_liberado_em) {
    motivos.push('Esta máquina foi reiniciada há pouco. '
      + `Novo reinício liberado às ${horaCurta(a.reboot_liberado_em)}.`);
  }
  if (a.pendentes > 0) {
    motivos.push(`${a.pendentes} comando(s) aguardando o próximo ciclo do agente.`);
  }

  // Ligar remotamente. Três coisas têm que ser verdade ao mesmo tempo, e cada
  // uma que falta tem um motivo diferente: dizer qual é a diferença entre a
  // pessoa resolver e a pessoa desistir.
  const lig = a.ligar || {};
  $('linha-ligar').hidden = lig.aplicavel !== true;

  if (lig.aplicavel) {
    const podeLigar = lig.tem_mac === true && !!lig.vizinho;
    $('btn-wake').disabled = !podeLigar;

    if (lig.wifi) {
      motivos.push('Não dá para ligar esta máquina: ela está em Wi-Fi, e Wake-on-LAN '
        + 'por Wi-Fi não funciona na prática. Só por cabo.');
    } else if (!lig.tem_mac) {
      motivos.push('Não dá para ligar esta máquina: ela nunca reportou o endereço '
        + 'da placa de rede (precisa de um ciclo com o agente ps-1.3.0 ou mais novo).');
    } else if (!lig.vizinho) {
      motivos.push('Não dá para ligar esta máquina: o pacote tem que sair de dentro '
        + 'da loja, e não há nenhuma outra máquina online lá para enviá-lo.');
    } else {
      motivos.push(`Ligar usa ${lig.vizinho}, que está online na mesma loja.`);
    }
  }

  // Suspender. É a alternativa a desligar quando não se pode ir ao BIOS da
  // loja: acordar de suspensão depende do Windows, não do firmware.
  const sus = a.suspender || {};
  const podeVoltar = sus.tem_mac === true && sus.tem_vizinho === true;
  $('linha-suspender').hidden = sus.aplicavel !== true;

  if (sus.aplicavel) {
    $('btn-sleep').disabled = !podeVoltar;

    if (!sus.tem_mac) {
      motivos.push('Suspender está bloqueado: sem o MAC desta máquina não haveria '
        + 'como acordá-la depois.');
    } else if (!sus.tem_vizinho) {
      motivos.push('Suspender está bloqueado: nenhuma outra máquina online nesta loja '
        + 'para mandar o pacote de volta. Ela ficaria inacessível.');
    } else if (!sus.ja_acordou) {
      motivos.push('Esta máquina nunca foi acordada pela rede ainda. '
        + 'Suspender é reversível em teoria, mas só o primeiro teste prova.');
    }
  }

  // Dias sem reiniciar, PRIMEIRO na lista de avisos: é a informação que decide
  // qual botão a pessoa vai apertar. Suspender não zera isso — o sistema volta
  // do mesmo lugar, com a mesma memória suja.
  const up = a.uptime || {};
  if (up.dias !== null && up.dias !== undefined) {
    const d = Math.round(Number(up.dias));
    const texto = d < 1 ? 'reiniciada hoje' : `${d} dia(s) sem reiniciar`;
    motivos.unshift(up.passou
      ? `${texto} — passou do limite de ${up.limiar}. Vale agendar um reinício.`
      : texto + '.');
  }

  txt(aviso, motivos.join(' '));
  aviso.hidden = motivos.length === 0;

  // Agente que não executa: os botões viram enfeite. Desligar é mais honesto
  // que deixar clicar e a pessoa esperar por um resultado que não vem.
  for (const id of ['btn-restart-service', 'btn-clear-temp',
                    'btn-test-collection', 'btn-restart-machine']) {
    if (a.agente_suporta !== true) $(id).disabled = true;
  }
  if (a.agente_suporta === true) {
    $('btn-clear-temp').disabled = false;
    $('btn-test-collection').disabled = false;
    $('btn-restart-machine').disabled = false;
    $('btn-restart-service').disabled = servicos.length === 0;
  }

  // Depois de habilitar: os rótulos precisam refletir o modo já na abertura, e
  // não só quando alguém mexe na caixa.
  refletirModoSimulacao();

  await carregarComandos(m.machine_id);
}

/**
 * Escreve o modo NO BOTÃO.
 *
 * Uma caixa de seleção acima dos botões não compete com o botão que a pessoa
 * está olhando na hora de clicar: ela clica em "Reiniciar o PC", lê "Reiniciar
 * o PC", e descobre que simulou só depois. O rótulo é o último lugar onde o
 * aviso ainda chega a tempo.
 */
function refletirModoSimulacao() {
  const simular = $('acao-simular').checked;

  const rotulos = {
    'btn-restart-service': 'Reiniciar serviço',
    'btn-clear-temp': 'Limpar temporários',
    'btn-test-collection': 'Testar coleta',
    'btn-restart-machine': 'Reiniciar o PC',
    'btn-wake': 'Ligar o PC',
    'btn-sleep': 'Suspender o PC',
    'btn-agendar-reinicio': 'Agendar reinício para as 4h',
  };

  for (const [id, base] of Object.entries(rotulos)) {
    const b = $(id);
    // `armarPerigo` guarda o rótulo original no primeiro clique para restaurar
    // depois. Mexer no texto enquanto o botão está armado desfaria a
    // confirmação pela metade, então desarma antes.
    if (b.classList.contains('armado')) continue;
    txt(b, simular ? `Simular: ${base.toLowerCase()}` : base);
  }

  $('acoes').classList.toggle('modo-simulacao', simular);
}

function horaCurta(iso) {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? '—'
    : d.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
}

/** Histórico de comandos. textContent em tudo: nada daqui vira HTML. */
async function carregarComandos(machineId) {
  const ul = $('acao-historico');
  limpar(ul);

  let lista;
  try {
    lista = await api(`/comandos_da_maquina?machine_id=eq.${machineId}`
      + '&order=created_at.desc&limit=12');
  } catch (_) {
    ul.appendChild(el('li', 'vazio', 'Não consegui ler o histórico de comandos.'));
    return;
  }

  if (!lista.length) {
    ul.appendChild(el('li', 'vazio', 'Nenhum comando ainda.'));
    return;
  }

  let emAndamento = false;

  for (const c of lista) {
    if (c.em_andamento) emAndamento = true;

    const li = el('li', `comando cmd-${c.status}`);

    const topo = el('div', 'cmd-topo');
    topo.appendChild(el('strong', null,
      (NOME_DA_ACAO[c.kind] || c.kind) + (c.dry_run ? ' (simulação)' : '')));
    topo.appendChild(el('span', 'cmd-estado', NOME_DO_ESTADO[c.status] || c.status));
    li.appendChild(topo);

    const quando = el('div', 'cmd-quando',
      `${horaCurta(c.created_at)}${c.origem !== 'painel' ? ` · ${c.origem}` : ''}`);
    li.appendChild(quando);

    if (c.result_text) li.appendChild(el('div', 'cmd-texto', c.result_text));

    // Cancelar só faz sentido antes de o agente retirar: depois disso ele pode
    // estar executando neste instante, e dizer que cancelou seria mentira.
    if (c.status === 'pending') {
      const btn = el('button', 'btn-mini', 'Cancelar');
      btn.type = 'button';
      btn.addEventListener('click', async () => {
        btn.disabled = true;
        try {
          await rpc('cancelar_comando', { p_id: c.id });
          brinde('Comando cancelado.');
          await carregarComandos(machineId);
        } catch (e) { brinde(e.message, true); btn.disabled = false; }
      });
      li.appendChild(btn);
    }

    ul.appendChild(li);
  }

  // Enquanto houver comando em voo, a lista se atualiza sozinha: o resultado
  // chega no ciclo seguinte do agente, e ninguém deve precisar apertar F5 para
  // descobrir se o que pediu funcionou.
  clearTimeout(carregarComandos._t);
  if (emAndamento && Estado.maquinaAberta?.machine_id === machineId) {
    carregarComandos._t = setTimeout(() => carregarComandos(machineId), 10000);
  }
}

/** Enfileira um comando e devolve o retorno do servidor. */
async function pedirAcao(kind, params, confirmado) {
  const m = Estado.maquinaAberta;
  if (!m) return;

  const simular = $('acao-simular').checked;

  const r = await rpc('enfileirar_comando', {
    p_machine_id: m.machine_id,
    p_kind: kind,
    p_params: params || {},
    p_dry_run: simular,
    p_confirmado: confirmado === true,
  });

  brinde(r.aviso
    ? `${NOME_DA_ACAO[kind]}: ${r.aviso}`
    : `${NOME_DA_ACAO[kind]} enviado${simular ? ' em modo simulação' : ''}.`);

  await carregarComandos(m.machine_id);
  await desenharAcoes(m);
}


// ---------------------------------------------------------------------------
// Atualizar os agentes
// ---------------------------------------------------------------------------
// A versão alvo é uma constante deste arquivo, e não um número que o painel
// descobre sozinho. É deliberado: agente e painel viajam no mesmo repositório e
// no mesmo deploy, então esta linha SEMPRE conhece a versão que a Edge Function
// está servindo. Descobrir isso em tempo de execução seria uma chamada a mais
// para responder algo que já se sabe.
//
// AO PUBLICAR UM AGENTE NOVO, SUBA ESTA LINHA JUNTO.
const VERSAO_ALVO_AGENTE = 'ps-1.4.1';

async function atualizarAgentes() {
  const r = await rpc('atualizar_frota', { p_versao_alvo: VERSAO_ALVO_AGENTE });

  const pulos = Array.isArray(r.pulos) ? r.pulos : [];
  const n = r.enfileiradas || 0;

  txt($('atualizar-resumo'),
    n === 0 && pulos.length === 0
      ? 'Toda a frota já está na ' + VERSAO_ALVO_AGENTE + '. Nada a fazer.'
      : n + ' máquina(s) vão se atualizar para ' + VERSAO_ALVO_AGENTE + ' no próximo '
        + 'ciclo do agente (até 1 min). Nenhuma reinicia; só o agente troca de versão.');

  const lista = $('atualizar-lista');
  limpar(lista);

  if (pulos.length > 0) {
    // Esta lista É o conteúdo que importa: são as máquinas que continuam
    // exigindo alguém abrindo o PC. Escondê-la num rodapé seria esconder o
    // trabalho que sobrou.
    lista.appendChild(el('div', 'at-titulo', pulos.length + ' precisam de atenção manual'));

    for (const p of pulos) {
      const linha = el('div', 'at-linha');
      const esq = el('div');
      esq.appendChild(el('div', 'at-nome', p.maquina));
      esq.appendChild(el('div', 'at-motivo', p.motivo));
      linha.appendChild(esq);
      linha.appendChild(el('span', 'at-versao', p.versao));
      lista.appendChild(linha);
    }

    const dica = el('p', 'dica');
    dica.style.marginTop = '14px';
    txt(dica, 'Nessas, rode o comando abaixo uma última vez — como Administrador, '
      + 'por RDP ou AnyDesk. A partir da ' + VERSAO_ALVO_AGENTE + ' a atualização é remota.');
    lista.appendChild(dica);

    const caixa = el('div', 'comando-caixa');
    // textContent, não innerHTML: o endereço vem do banco.
    caixa.appendChild(el('pre', null,
      "& ([scriptblock]::Create((irm '"
      + String(CFG.ingestUrl || '').replace(/\/+$/, '') + "/atualizar.ps1')))"));
    lista.appendChild(caixa);
  }

  $('modal-atualizar-fundo').hidden = false;
  $('modal-atualizar').hidden = false;

  if (n > 0) brinde(n + ' agente(s) vão se atualizar.');
}

// Confirmação em dois cliques, mas escrita à mão em vez de armarPerigo: aquela
// troca o textContent do BOTÃO, e este botão tem um ícone dentro. Usá-la aqui
// apagaria o SVG no primeiro clique e ele não voltaria no desarme.
function ligarBotaoAtualizar() {
  const botao = $('btn-atualizar-agentes');
  const rot = $('btn-atualizar-rot');
  let temporizador = null;

  const desarmar = () => {
    clearTimeout(temporizador);
    temporizador = null;
    botao.classList.remove('armado');
    txt(rot, 'Atualizar agentes');
  };

  botao.addEventListener('click', async () => {
    if (!temporizador) {
      botao.classList.add('armado');
      txt(rot, 'Confirmar');
      temporizador = setTimeout(desarmar, ESPERA_CONFIRMA_MS);
      return;
    }
    desarmar();
    botao.disabled = true;
    try {
      await atualizarAgentes();
    } catch (e) {
      brinde(e.message, true);
    } finally {
      botao.disabled = false;
    }
  });
}

async function removerMaquinaAberta() {
  const m = Estado.maquinaAberta;
  if (!m) return;

  const r = await rpc('remover_maquina_ui', { p_machine_id: m.machine_id });
  fecharPainel();
  brinde(`${r.label} removida (${r.amostras_removidas} amostra(s) apagadas).`);
  await carregar();
}

async function removerLoja(loja) {
  const qtd = loja.maquinas.length;
  const r = await rpc('remover_loja_ui', { p_site_code: loja.code, p_com_maquinas: true });
  brinde(`Loja ${r.site_code} removida com ${r.maquinas_removidas} máquina(s).`);
  if (qtd && Estado.maquinaAberta
      && loja.maquinas.some((x) => x.machine_id === Estado.maquinaAberta.machine_id)) {
    fecharPainel();
  }
  await carregar();
}

async function removerDemo() {
  const r = await rpc('remover_dados_demo');
  if (r.nada_a_remover) {
    brinde('Não havia dados de demonstração.');
  } else {
    brinde(`Demonstração removida: ${r.maquinas} máquina(s), ${r.lojas} loja(s).`);
  }
  await carregar();
}

/** Mostra a faixa de demonstração só quando ela existe, e só para admin. */
async function verificarDadosDemo() {
  const faixa = $('faixa-demo');
  try {
    const d = await rpc('tem_dados_demo');

    // Aproveita a mesma resposta para saber o papel: é o dado que decide se a
    // zona de remoção do painel aparece, e ele precisa estar pronto ANTES de o
    // operador abrir a primeira máquina.
    Estado.ehAdmin = d.is_admin === true;

    // Gerenciar usuario e privilegio de admin. Esconder o botao NAO e
    // autorizacao -- o banco recusa de qualquer forma -- mas oferecer o que vai
    // responder "apenas administradores" e convidar para a frustracao.
    $('btn-usuarios').hidden = !Estado.ehAdmin;

    const tem = (d.maquinas > 0 || d.lojas > 0) && d.is_admin === true;
    faixa.hidden = !tem;
    if (tem) {
      txt($('fd-titulo'),
        `${d.maquinas} máquina(s) e ${d.lojas} loja(s) são de demonstração`);
    }
  } catch (_) {
    // Nunca esconde a frota por causa disto: é informação secundária.
    faixa.hidden = true;
  }
}

/** Reaplica filtros e redesenha. Um ponto só, para vista, select e busca. */
function aplicarFiltros() {
  desenharResumo();
  desenharMaquinas();
  sincronizarVistas();
}

/** Marca a vista ativa na barra lateral a partir do filtro de status. */
function sincronizarVistas() {
  for (const b of document.querySelectorAll('.vista[data-vista]')) {
    b.classList.toggle('ativa', (b.getAttribute('data-vista') || '') === (Estado.filtros.status || ''));
  }
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
const rotulos = {
  online: 'online',
  degradado: 'degradado',
  offline: 'OFFLINE',
  never_seen: 'nunca vista',
  disabled: 'desativada',
};
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

/**
 * Espaco em disco para leitura humana.
 *
 * Sem casa decimal acima de 10 GB: "115 GB" e mais rapido de ler que
 * "115,5 GB", e meio giga nao muda decisao nenhuma. Abaixo de 10 a decima
 * importa — "0,8 GB" e "0 GB" sao situacoes bem diferentes.
 *
 * Acima de mil vira TB, porque "2048 GB" ninguem le de primeira.
 */
function gb(v) {
  if (v === null || v === undefined || Number.isNaN(Number(v))) return null;
  const n = Number(v);
  if (n >= 1024) return `${(n / 1024).toFixed(1).replace('.', ',')} TB`;
  if (n >= 10) return `${Math.round(n)} GB`;
  return `${n.toFixed(1).replace('.', ',')} GB`;
}

/** So o numero, para o "de 238" que acompanha o valor livre. */
function gbNu(v) {
  const s = gb(v);
  return s === null ? null : s.replace(/ (GB|TB)$/, '');
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
    // Sem MAC não há Wake-on-LAN, e sem esta linha não havia como responder
    // "o agente já reportou?" olhando a tela — que é a pergunta que se faz
    // logo depois de atualizar um agente.
    ['MAC da placa', m.mac_address
      ? m.mac_address + (m.mac_is_wifi ? ' (Wi-Fi — não acorda pela rede)' : '')
      : 'não reportado — agente anterior ao ps-1.3.1'],
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

  // A zona de remoção só existe para quem pode remover. Mostrar um botão que
  // vai responder "apenas administradores" é convidar para a frustração.
  $('zona-perigo').hidden = Estado.ehAdmin !== true;

  $('painel-fundo').hidden = false;
  $('painel').hidden = false;

  await Promise.all([
    carregarGraficos(m.machine_id),
    carregarEventos(m.machine_id),
    desenharAcoes(m),
  ]);
}

function fecharPainel() {
  Estado.maquinaAberta = null;
  // Sem isto, a atualização do histórico continuaria rodando para uma máquina
  // que ninguém está mais olhando, para sempre.
  clearTimeout(carregarComandos._t);
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

  // Sincroniza os campos da loja nova com o que ESTÁ selecionado agora.
  //
  // Sem esta linha, a visibilidade só era atualizada no evento `change` — e isso
  // quebrava nos dois sentidos:
  //
  //   1. Sem nenhuma loja cadastrada (produção recém-publicada), "+ criar loja
  //      nova" é a ÚNICA opção e já vem selecionada. O operador não muda nada,
  //      `change` não dispara, os campos ficam escondidos, e ao confirmar ele
  //      recebe "informe o código da loja nova" sem ter onde informar.
  //
  //   2. Escolher "criar loja nova", fechar e reabrir: o select volta para a
  //      primeira loja real, mas os campos continuavam visíveis.
  sincronizarLojaNova();

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

/**
 * Os campos "código" e "nome" da loja nova aparecem se, e somente se,
 * "+ criar loja nova" estiver selecionado.
 *
 * É um espelho do estado, não um alternador: chamada em qualquer momento, ela
 * deixa a tela coerente com o select. Foi o que faltava — a versão anterior só
 * reagia ao evento `change`, e evento que não dispara deixa a tela mentindo.
 */
function sincronizarLojaNova() {
  $('add-nova-loja').hidden = $('add-loja').value !== '__nova__';
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

  $('add-loja').addEventListener('change', () => {
    sincronizarLojaNova();
    if ($('add-loja').value === '__nova__') $('add-loja-codigo').focus();
  });

  $('add-nome').addEventListener('keydown', (ev) => {
    if (ev.key === 'Enter') { ev.preventDefault(); gerarComando(); }
  });
  $('btn-fechar-painel').addEventListener('click', fecharPainel);
  $('painel-fundo').addEventListener('click', fecharPainel);

  document.addEventListener('keydown', (ev) => {
    if (ev.key !== 'Escape') return;
    if (!$('modal-relatorio').hidden) { fecharRelatorio(); return; }
    if (!$('modal-add').hidden) { fecharModalAdd(); return; }
    if (!$('painel').hidden) fecharPainel();
  });

  $('filtro-marca').addEventListener('change', (ev) => {
    Estado.filtros.marca = ev.target.value;
    Estado.filtros.loja = '';
    preencherFiltros();
    aplicarFiltros();
  });

  for (const [id, campo] of [['filtro-loja', 'loja'], ['filtro-status', 'status']]) {
    $(id).addEventListener('change', (ev) => {
      Estado.filtros[campo] = ev.target.value;
      aplicarFiltros();
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

  // Vistas da barra lateral: cada uma é o filtro de status, com atalho visual.
  for (const b of document.querySelectorAll('.vista[data-vista]')) {
    b.addEventListener('click', () => {
      Estado.filtros.status = b.getAttribute('data-vista') || '';
      $('filtro-status').value = Estado.filtros.status;
      aplicarFiltros();
    });
  }

  // Modo de agrupamento: loja (denso, escala) ou máquina (detalhe).
  for (const b of document.querySelectorAll('.seg[data-modo]')) {
    b.addEventListener('click', () => {
      for (const o of document.querySelectorAll('.seg[data-modo]')) o.classList.remove('ativa');
      b.classList.add('ativa');
      Estado.modo = b.getAttribute('data-modo');
      try { localStorage.setItem('monitor.modo', Estado.modo); } catch (_) { /* modo privado */ }
      desenharMaquinas();
    });
  }

  // Faixa do gráfico da frota. Separada da faixa do painel de detalhe: são dois
  // gráficos independentes, e um `.faixa` genérico mexia nos dois ao mesmo tempo.
  for (const b of document.querySelectorAll('.faixa[data-frota]')) {
    b.addEventListener('click', async () => {
      for (const o of document.querySelectorAll('.faixa[data-frota]')) o.classList.remove('ativa');
      b.classList.add('ativa');
      Estado.faixaFrota = b.getAttribute('data-frota');
      try { await carregarFrota(); } catch (e) { txt($('carga-sub'), `falhou: ${e.message}`); }
    });
  }

  for (const b of document.querySelectorAll('.faixa[data-faixa]')) {
    b.addEventListener('click', () => {
      for (const o of document.querySelectorAll('.faixa[data-faixa]')) o.classList.remove('ativa');
      b.classList.add('ativa');
      Estado.faixa = b.getAttribute('data-faixa');
      if (Estado.maquinaAberta) carregarGraficos(Estado.maquinaAberta.machine_id);
    });
  }

  $('btn-tema').addEventListener('click', () => trocarTema());
  $('btn-som').addEventListener('click', alternarSom);

  $('btn-relatorio').addEventListener('click', abrirRelatorio);
  $('btn-fechar-rel').addEventListener('click', fecharRelatorio);
  $('rel-fundo').addEventListener('click', fecharRelatorio);
  $('rel-mes').addEventListener('change', desenharRelatorio);
  $('btn-rel-csv').addEventListener('click', baixarRelatorioCsv);
  $('fi-abrir').addEventListener('click', abrirMaquinaDoIncidente);

  armarPerigo($('fi-reconhecer'), 'Confirmar', reconhecerIncidente);

  // Remoção: dois cliques, e o rótulo do segundo diz o que vai sumir.
  armarPerigo($('btn-remover-demo'), 'Confirmar remoção', removerDemo);
  armarPerigo($('btn-remover-maquina'), 'Confirmar: apagar tudo', removerMaquinaAberta);

  // Sair so existe onde ha de onde sair: no modo Supabase.
  if (CFG.authMode === 'supabase') {
    $('btn-sair').hidden = false;
    $('btn-sair').addEventListener('click', sair);
  }

  ligarUsuarios();
  ligarEdicao();
  $('btn-editar-maquina').addEventListener('click', editarMaquinaAberta);

  ligarBotaoAtualizar();

  $('btn-fechar-atualizar').addEventListener('click', () => {
    $('modal-atualizar').hidden = true;
    $('modal-atualizar-fundo').hidden = true;
  });
  $('modal-atualizar-fundo').addEventListener('click', () => {
    $('modal-atualizar').hidden = true;
    $('modal-atualizar-fundo').hidden = true;
  });

  ligarPaleta();

  // Ações não destrutivas: um clique. Fazer alguém confirmar duas vezes para
  // testar a coleta ensina a clicar duas vezes em tudo, e aí a confirmação do
  // reinício deixa de significar alguma coisa.
  $('btn-restart-service').addEventListener('click', () =>
    pedirAcao('restart_service', { servico: $('acao-servico').value })
      .catch((e) => brinde(e.message, true)));

  $('btn-clear-temp').addEventListener('click', () =>
    pedirAcao('clear_temp', { dias_minimos: 7 })
      .catch((e) => brinde(e.message, true)));

  $('btn-test-collection').addEventListener('click', () =>
    pedirAcao('run_test_collection', {})
      .catch((e) => brinde(e.message, true)));

  // Reiniciar o PC derruba a loja por alguns minutos: dois cliques, como
  // remover. E o servidor exige a confirmação de novo, por conta dele.
  armarPerigo($('btn-restart-machine'), 'Confirmar: reiniciar o PC', () =>
    pedirAcao('restart_machine', {}, true));

  $('acao-simular').addEventListener('change', refletirModoSimulacao);

  // Suspender derruba a loja ate alguem acordar a maquina: dois cliques, como
  // reiniciar.
  // Agendar NAO derruba nada agora: um clique basta. Fazer confirmar uma acao
  // que so acontece as 4h da manha ensina a confirmar sem ler.
  $('btn-agendar-reinicio').addEventListener('click', async () => {
    const m = Estado.maquinaAberta;
    if (!m) return;
    const b = $('btn-agendar-reinicio');
    b.disabled = true;
    try {
      const r = await rpc('agendar_reinicio', {
        p_machine_id: m.machine_id,
        p_hora: 4,
        p_dry_run: $('acao-simular').checked,
      });
      brinde(r.nota);
      await carregarComandos(m.machine_id);
    } catch (e) {
      brinde(e.message, true);
    } finally {
      b.disabled = false;
    }
  });

  armarPerigo($('btn-sleep'), 'Confirmar: suspender', () =>
    pedirAcao('sleep_machine', { modo: 'suspender' }, true));

  // Ligar o PC vai por caminho próprio: quem escolhe o vizinho que manda o
  // pacote é o servidor, não a tela. A tela só sabe o alvo.
  $('btn-wake').addEventListener('click', async () => {
    const m = Estado.maquinaAberta;
    if (!m) return;
    const b = $('btn-wake');
    b.disabled = true;
    try {
      const r = await rpc('ligar_maquina', {
        p_alvo: m.machine_id,
        p_dry_run: $('acao-simular').checked,
      });
      brinde(r.nota);
      await carregarComandos(m.machine_id);
    } catch (e) {
      brinde(e.message, true);
    } finally {
      b.disabled = false;
    }
  });

  // "/" foca a busca, como em toda ferramenta de operação. Não sequestra a tecla
  // quando o foco já está num campo — senão seria impossível digitar uma barra.
  document.addEventListener('keydown', (ev) => {
    if (ev.key !== '/' || ev.ctrlKey || ev.altKey || ev.metaKey) return;
    const a = document.activeElement;
    if (a && ['INPUT', 'TEXTAREA', 'SELECT'].includes(a.tagName)) return;
    ev.preventDefault();
    $('busca').focus();
  });
}

// -----------------------------------------------------------------------------
// Tema
// -----------------------------------------------------------------------------
// Claro existe porque loja tem tela em balcão com sol batendo, onde o escuro
// vira espelho. A escolha fica no navegador de quem usa.
function aplicarTema(tema) {
  document.documentElement.setAttribute('data-tema', tema);
  txt($('btn-tema-rot'), tema === 'light' ? 'Tema escuro' : 'Tema claro');

  // O gráfico lê as cores do CSS na hora de desenhar, então precisa ser
  // redesenhado — senão fica com a paleta do tema anterior.
  if (Estado.maquinas.length) {
    carregarFrota().catch(() => { /* a faixa de erro já cobre */ });
  }
}

function trocarTema() {
  const atual = document.documentElement.getAttribute('data-tema') === 'light' ? 'light' : 'dark';
  const novo = atual === 'light' ? 'dark' : 'light';
  try { localStorage.setItem('monitor.tema', novo); } catch (_) { /* modo privado */ }
  aplicarTema(novo);
}

function restaurarPreferencias() {
  let tema = 'dark';
  let modo = 'lojas';
  try {
    tema = localStorage.getItem('monitor.tema') || 'dark';
    modo = localStorage.getItem('monitor.modo') || 'lojas';
    Estado.som = localStorage.getItem('monitor.som') === '1';
  } catch (_) { /* modo privado bloqueia storage */ }

  txt($('btn-som-rot'), Estado.som ? 'Som: ligado' : 'Som: desligado');
  $('btn-som').setAttribute('aria-pressed', String(Estado.som));

  document.documentElement.setAttribute('data-tema', tema);
  txt($('btn-tema-rot'), tema === 'light' ? 'Tema escuro' : 'Tema claro');

  Estado.modo = modo === 'maquinas' ? 'maquinas' : 'lojas';
  for (const b of document.querySelectorAll('.seg[data-modo]')) {
    b.classList.toggle('ativa', b.getAttribute('data-modo') === Estado.modo);
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

  const nome = Estado.usuario || '';
  txt($('rotulo-usuario'), nome);
  txt($('usuario-iniciais'), iniciaisDe(nome));

  await carregar();
  iniciarAtualizacao();
}

/** "Kaua Larsson" -> "KL"; "kaua@cajupar.com" -> "KA". */
function iniciaisDe(nome) {
  const limpo = String(nome || '').trim();
  if (!limpo) return '··';

  const antesDoArroba = limpo.split('@')[0];
  const partes = antesDoArroba.split(/[\s._-]+/).filter(Boolean);

  if (partes.length >= 2) return (partes[0][0] + partes[1][0]).toUpperCase();
  return antesDoArroba.slice(0, 2).toUpperCase();
}

async function principal() {
  restaurarPreferencias();
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

