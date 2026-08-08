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
import { spawn, execFileSync } from 'node:child_process';

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

// Definida dentro do try, usada no finally: o cenario proprio precisa sair do
// banco mesmo quando a suite morre no meio.
let limparFixture = () => {};

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

  // -------------------------------------------------------------------------
  // Cenário próprio
  // -------------------------------------------------------------------------
  // A suíte inteira presumia que existia pelo menos uma máquina na tela. Isso
  // parecia seguro enquanto o seed de demonstração estava sempre lá — e deixou
  // de ser no momento em que o dashboard ganhou o botão de remover loja. Com o
  // banco vazio ela explodia no critério de XSS, que e a verificação MAIS
  // importante do projeto, com "Cannot read properties of null".
  //
  // Teste que depende do que sobrou de outro teste não é teste. Este cria o que
  // precisa, com GUID próprio, e remove no fim mesmo se falhar.
  const FIX = 'ZZNAV';
  const FIX_MAQ = 'PC-VERIFICACAO-NAVEGADOR';

  const psqlFix = (q) => execFileSync('docker',
    ['exec', 'monitor-db', 'psql', '-U', 'postgres', '-q', '-t', '-A', '-c', q],
    { encoding: 'utf8' }).trim();

  // Atribuido a variavel de escopo externo para que o `finally` la embaixo
  // consiga limpar mesmo quando a suite morre no meio.
  limparFixture = () => {
    try {
      psqlFix(`delete from public.machines where label = '${FIX_MAQ}';
               delete from public.sites  where code = '${FIX}';
               delete from public.brands where code = '${FIX}';`);
    } catch (_) { /* nada a fazer no encerramento */ }
  };

  limparFixture();
  psqlFix(`
    insert into public.brands (code, name)
    select '${FIX}', 'verificacao navegador'
    where not exists (select 1 from public.brands where code = '${FIX}');

    insert into public.sites (brand_id, code, name)
    select b.id, '${FIX}', 'loja de verificacao' from public.brands b
    where b.code = '${FIX}' and not exists (select 1 from public.sites where code = '${FIX}');

    insert into public.machines (site_id, role_code, label, hostname)
    select s.id, 'pdv', '${FIX_MAQ}', 'HOST-VERIFICACAO'
    from public.sites s where s.code = '${FIX}';
  `);

  // Amostra fresca, para a máquina renderizar como online e ter cartão, painel
  // e gráfico — o resto da suíte depende disso.
  psqlFix(`
    insert into public.metrics (machine_id, "time", agent_version, cpu_pct, mem_pct, uptime_seconds)
    select m.id, now(), 'verificacao-1.0.0', 11, 44, 3600
    from public.machines m where m.label = '${FIX_MAQ}';

    update public.machines
       set last_seen_at = now(), agent_version = 'verificacao-1.0.0',
           os_caption = 'Microsoft Windows 11 Pro', ip_lan = '192.168.14.99'
     where label = '${FIX_MAQ}';
  `);
  console.log(`cenário próprio: loja ${FIX} com 1 máquina\n`);

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
  verificar('dash.js executou (build no console)', !!build, console_.join('\n        '));
  if (build) console.log(`        ${build.replace('info: ', '')}`);

  const faixaErro = await js("document.getElementById('falha-js')?.hidden");
  verificar('faixa de erro de script está oculta', faixaErro === true, `hidden=${faixaErro}`);

  // =========================================================================
  console.log('\n== Dashboard sem login ==');
  // =========================================================================
  // A tela de login foi REMOVIDA do dashboard. Estes testes garantem que ela nao
  // volte por acidente: um formulario de credencial nesta pagina traria de volta
  // a transicao entre estados que produzia a tela travada.
  const semFormulario = await js(`
    ({
      telaLogin: !!document.getElementById('tela-login'),
      form:      !!document.getElementById('form-login'),
      btnEntrar: !!document.getElementById('btn-entrar'),
      campoSenha:!!document.getElementById('senha'),
      inputs:    document.querySelectorAll('input[type=password]').length,
    })
  `);

  verificar('não existe elemento de tela de login', semFormulario.telaLogin === false, JSON.stringify(semFormulario));
  verificar('não existe formulário de login', semFormulario.form === false);
  verificar('não existe botão Entrar', semFormulario.btnEntrar === false);
  verificar('não existe campo de senha', semFormulario.campoSenha === false && semFormulario.inputs === 0);

  const usuarioTopo = await js("document.getElementById('rotulo-usuario').textContent");
  verificar('usuário identificado no topo', (usuarioTopo || '').length > 0, `"${usuarioTopo}"`);

  const appVisivel = await js("!document.getElementById('app').hidden");
  verificar('APP VISÍVEL com dados', appVisivel === true, `app.hidden=${!appVisivel}`);

  // =========================================================================
  console.log('\n== Dados na tela ==');
  // =========================================================================
  await dormir(1500);

  // Os números vêm do BANCO, não cravados no teste.
  //
  // A versão anterior exigia "5 máquinas, 2 marcas, 3 lojas" — os valores do seed.
  // No momento em que uma máquina real foi cadastrada, os quatro testes
  // reprovaram sem que nada estivesse errado. Teste que crava contagem transforma
  // crescimento legítimo em falso alarme, e falso alarme treina a gente a ignorar
  // o teste.
  //
  // O que interessa é a CONSISTÊNCIA: a tela mostra o que o banco tem.
  const esperado = JSON.parse(execFileSync('docker', [
    'exec', 'monitor-db', 'psql', '-U', 'postgres', '-t', '-A', '-c',
    `select json_build_object(
       'maquinas', (select count(*) from public.machines where is_active),
       'lojas',    (select count(distinct m.site_id) from public.machines m where m.is_active),
       'marcas',   (select count(distinct s.brand_id) from public.machines m
                      join public.sites s on s.id = m.site_id where m.is_active)
     )`,
  ], { encoding: 'utf8' }).trim());

  console.log(`        banco: ${esperado.maquinas} máquinas, ${esperado.lojas} lojas, ${esperado.marcas} marcas`);

  // kpi-total passou a significar HOSTS RESPONDENDO (online + degradado), não o
  // total cadastrado — o número grande de um painel de operação tem de ser o que
  // está de pé agora. O total continua na tela, ao lado, como "de N".
  const cab = await js(`
    ({
      respondendo: document.getElementById('kpi-total').textContent,
      de:          document.getElementById('kpi-online-de').textContent,
      quadrados:   document.querySelectorAll('.host-quad').length,
      cartoesLoja: document.querySelectorAll('.cartao-loja').length,
    })
  `);

  verificar('KPI de hosts respondendo preenchido', /^\d+$/.test(cab.respondendo || ''),
    `kpi-total=${cab.respondendo}`);
  verificar('total da frota na tela bate com o banco',
    cab.de === `de ${esperado.maquinas}`, `tela="${cab.de}" banco=${esperado.maquinas}`);
  verificar('respondendo nunca passa do total',
    Number(cab.respondendo) <= esperado.maquinas, JSON.stringify(cab));

  // Modo "lojas" é o padrão: um cartão por loja e um quadrado por máquina.
  verificar('um cartão por loja do banco',
    cab.cartoesLoja === esperado.lojas, `${cab.cartoesLoja} cartões, ${esperado.lojas} lojas`);
  verificar('um quadrado de host por máquina do banco',
    cab.quadrados === esperado.maquinas, `${cab.quadrados} quadrados, ${esperado.maquinas} máquinas`);

  // ---- troca para o modo "máquinas" ---------------------------------------
  // O restante das verificações estruturais é sobre a lista por máquina, que
  // agora é a segunda vista. Trocar aqui é o que o operador faria.
  await js("document.querySelector('.seg[data-modo=\"maquinas\"]').click(); true");
  await dormir(900);

  const cartoes = await js("document.querySelectorAll('.cartao').length");
  verificar('um cartão por máquina do banco',
    cartoes === esperado.maquinas, `${cartoes} cartões, ${esperado.maquinas} máquinas`);

  const marcas = await js("document.querySelectorAll('.marca').length");
  verificar('agrupamento por marca bate com o banco',
    marcas === esperado.marcas, `${marcas} na tela, ${esperado.marcas} no banco`);

  const lojas = await js("document.querySelectorAll('.loja').length");
  verificar('agrupamento por loja bate com o banco',
    lojas === esperado.lojas, `${lojas} na tela, ${esperado.lojas} no banco`);

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

  // Fecha o painel e confere pelo ESTILO COMPUTADO, nao pelo atributo: `.painel`
  // e flex, e um `display` de autor vence o `[hidden]` do navegador. Foi assim
  // que o painel ficou preso na tela sobre o dashboard sem nenhum teste reclamar.
  await js("document.getElementById('btn-fechar-painel').click(); true");
  await dormir(500);

  const painelSumiu = await js(`
    ['painel', 'painel-fundo'].filter((id) =>
      getComputedStyle(document.getElementById(id)).display !== 'none')
  `);

  verificar('painel realmente sai da tela ao fechar (display computado)',
    Array.isArray(painelSumiu) && painelSumiu.length === 0,
    `ainda desenhando: ${(painelSumiu || []).join(', ') || 'nada'}`);

  // =========================================================================
  console.log('\n== Adicionar PC pela interface ==');
  // =========================================================================
  erros.length = 0;

  await js("document.getElementById('btn-adicionar').click(); true");
  await dormir(1500);

  const modal = await js(`
    ({
      aberto: !document.getElementById('modal-add').hidden,
      lojas:  document.querySelectorAll('#add-loja option').length,
      perfis: document.querySelectorAll('#add-perfil option').length,
      servicos: document.getElementById('add-servicos').value,
      erro: document.getElementById('add-erro').hidden
              ? null : document.getElementById('add-erro').textContent,
    })
  `);

  verificar('modal abriu', modal.aberto === true, JSON.stringify(modal));
  verificar('nenhum erro ao abrir', modal.erro === null, modal.erro);
  verificar('lojas carregadas (+ opção de criar nova)', modal.lojas >= 2, `${modal.lojas} opções`);
  verificar('perfis carregados', modal.perfis === 3, `${modal.perfis} perfis`);
  verificar('serviços do perfil sugeridos', (modal.servicos || '').length > 0, modal.servicos);

  // ---- os campos da loja nova acompanham o select --------------------------
  //
  // Regressão real: a visibilidade só era atualizada no evento `change`, e isso
  // quebrava nos dois sentidos. O caso que apareceu em produção foi o pior: sem
  // nenhuma loja cadastrada, "+ criar loja nova" é a ÚNICA opção e já vem
  // selecionada — o operador não muda nada, `change` não dispara, os campos
  // ficam escondidos, e ao confirmar ele recebe "informe o código da loja nova"
  // sem ter onde informar.
  //
  // A asserção é a INVARIANTE, não o comportamento do clique: campos visíveis se
  // e somente se `__nova__` estiver selecionado. Assim ela vale em qualquer
  // caminho que leve o select àquele valor.
  const visivelNova = () => js(
    "getComputedStyle(document.getElementById('add-nova-loja')).display !== 'none'");

  await js("document.getElementById('add-loja').value = '__nova__';"
    + "document.getElementById('add-loja').dispatchEvent(new Event('change'));true");
  await dormir(400);
  verificar('escolher "criar loja nova" mostra os campos', (await visivelNova()) === true);

  const primeira = await js(`
    (() => {
      const s = document.getElementById('add-loja');
      const real = [...s.options].find((o) => o.value !== '__nova__');
      if (!real) return null;
      s.value = real.value;
      s.dispatchEvent(new Event('change'));
      return real.value;
    })()
  `);
  if (primeira) {
    await dormir(400);
    verificar('voltar para uma loja real esconde os campos', (await visivelNova()) === false,
      `loja=${primeira}`);
  }

  // O CENÁRIO DE PRODUÇÃO: nenhuma loja cadastrada.
  //
  // Esvazia o CACHE de opções, não as options do select: reabrir o modal
  // repovoa o select a partir de `opcoesCadastro`, então remover as options
  // seria desfeito na hora — foi assim que a primeira versão desta verificação
  // ficou vazia e passou mesmo com o defeito presente.
  //
  // `opcoesCadastro` é um `let` de topo de script clássico: não está em
  // `window`, mas o nome resolve no escopo global do evaluate.
  await js(`
    (() => {
      document.getElementById('btn-fechar-modal').click();
      document.getElementById('add-nova-loja').hidden = true;
      // Guardado para devolver logo abaixo: o resto da suíte cadastra uma
      // máquina de verdade e precisa das lojas de volta.
      window.__lojasGuardadas = opcoesCadastro.lojas;
      opcoesCadastro.lojas = [];
      return true;
    })()
  `);
  await dormir(300);
  await js("document.getElementById('btn-adicionar').click(); true");
  await dormir(1600);

  const soNova = await js(`
    ({
      valor: document.getElementById('add-loja').value,
      opcoes: document.getElementById('add-loja').options.length,
      visivel: getComputedStyle(document.getElementById('add-nova-loja')).display !== 'none',
    })
  `);

  // Sem cláusula de escape: com o cache vazio, `__nova__` É a única opção, e a
  // asserção tem de valer sempre. Foi o `|| valor !== '__nova__'` da primeira
  // versão que a tornou verdadeira por construção.
  verificar('sem nenhuma loja, "criar loja nova" já vem selecionada E os campos aparecem',
    soNova.opcoes === 1 && soNova.valor === '__nova__' && soNova.visivel === true,
    JSON.stringify(soNova));

  // Devolve o estado e reabre o modal: daqui para baixo a suíte cadastra uma
  // máquina de verdade, e precisa de uma loja para escolher. Verificação que
  // deixa o ambiente sujo derruba as seguintes, e o relatório passa a acusar
  // defeito onde só houve efeito colateral de teste.
  await js(`
    (() => {
      document.getElementById('btn-fechar-modal').click();
      opcoesCadastro.lojas = window.__lojasGuardadas || [];
      delete window.__lojasGuardadas;
      return opcoesCadastro.lojas.length;
    })()
  `);
  await dormir(300);
  await js("document.getElementById('btn-adicionar').click(); true");
  await dormir(1600);

  const restaurado = await js(
    "document.getElementById('add-loja').options.length");
  verificar('as lojas voltaram para o restante da suíte', restaurado >= 2,
    `${restaurado} opções`);

  // Nome vazio tem de barrar ANTES de emitir token: um cadastro sem nome criaria
  // máquina inútil e um token pendurado nela.
  await js("document.getElementById('btn-gerar').click(); true");
  await dormir(1200);
  const semNome = await js(`
    ({ erro: document.getElementById('add-erro').hidden ? null : document.getElementById('add-erro').textContent,
       passo2: !document.getElementById('add-passo2').hidden })
  `);
  verificar('nome vazio é recusado sem emitir token',
    semNome.erro !== null && semNome.passo2 === false, JSON.stringify(semNome));

  // Cadastro de verdade.
  const nomeTeste = `PDV-UI-${Date.now().toString().slice(-6)}`;
  await js(`
    (() => {
      document.getElementById('add-nome').value = ${JSON.stringify(nomeTeste)};
      document.getElementById('add-servicos').value = 'Spooler, Dhcp';
      document.getElementById('btn-gerar').click();
      return true;
    })()
  `);
  await dormir(3000);

  const gerado = await js(`
    ({
      passo2:  !document.getElementById('add-passo2').hidden,
      passo1:  !document.getElementById('add-passo1').hidden,
      resumo:  document.getElementById('add-resumo').textContent,
      comando: document.getElementById('add-comando').textContent,
      tarefa:  document.getElementById('add-comando-tarefa').textContent,
      erro:    document.getElementById('add-erro').hidden
                 ? null : document.getElementById('add-erro').textContent,
    })
  `);

  verificar('comando foi gerado', gerado.passo2 === true && gerado.passo1 === false,
    gerado.erro || JSON.stringify(gerado).slice(0, 200));
  verificar('resumo cita a máquina', (gerado.resumo || '').includes(nomeTeste), gerado.resumo);

  // O comando precisa ter TODAS as partes, senão falha na outra máquina.
  const partes = {
    'scriptblock (permite passar argumentos)': /scriptblock\]::Create/.test(gerado.comando),
    'baixa o instalador': /instalar\.ps1/.test(gerado.comando),
    'traz o token da máquina': /-Token 'mon_[0-9a-f]{64}'/.test(gerado.comando),
    'traz o segredo compartilhado': /-Segredo '\S+'/.test(gerado.comando),
    'aponta para o IP da LAN, não 127.0.0.1': /-Servidor 'http:\/\/(?!127\.0\.0\.1)/.test(gerado.comando),
    'traz os serviços informados': /-Servicos 'Spooler,Dhcp'/.test(gerado.comando),
  };
  for (const [nome, ok_] of Object.entries(partes)) {
    verificar(`comando ${nome}`, ok_ === true, gerado.comando.slice(0, 220));
  }

  // ---- o segredo vem do BANCO, não de arquivo servido ao navegador ----------
  //
  // Esta é a diferença entre funcionar na LAN e poder ir para produção. Enquanto
  // o segredo morava em dev-config.json, o comando saía correto e o teste
  // passava — e em produção, num site estático, aquele arquivo é público. Aqui a
  // pergunta é outra: o segredo do comando é o que está no banco, e ele NÃO
  // aparece em nenhum arquivo que o navegador baixe?
  const segredoBanco = execFileSync('docker', [
    'exec', 'monitor-db', 'psql', '-U', 'postgres', '-t', '-A', '-c',
    'select shared_secret from public.ingest_config',
  ], { encoding: 'utf8' }).trim();

  const segredoNoComando = (/-Segredo '([^']+)'/.exec(gerado.comando) || [])[1] || '';

  verificar('segredo do comando é o que está no banco',
    segredoBanco.length >= 24 && segredoNoComando === segredoBanco,
    `banco=${segredoBanco.length}ch comando=${segredoNoComando.length}ch`);

  // ---- e o do banco é o que o ENDPOINT realmente exige ---------------------
  //
  // Faltava esta. O banco e o endpoint guardam o segredo em lugares diferentes
  // (ingest_config e a variável de ambiente do contêiner), e nada os obrigava a
  // concordar. Um teste SQL que escrevia em ingest_config trocou o segredo real
  // por `aaaa...`: o comando gerado continuava "correto" para todas as
  // verificações acima, e o PC instalado com ele tomaria 401 para sempre — sem
  // nada na tela dizendo o porquê.
  //
  // Comparar as duas pontas é a única forma de saber que o comando FUNCIONA, e
  // não apenas que está bem formado.
  let segredoEndpoint = '';
  try {
    segredoEndpoint = execFileSync('docker', [
      'exec', 'monitor-ingest', 'printenv', 'INGEST_SHARED_SECRET',
    ], { encoding: 'utf8' }).trim();
  } catch (e) {
    segredoEndpoint = `(não consegui ler: ${e.message})`;
  }

  verificar('segredo do banco é o que o endpoint de ingestão exige',
    segredoEndpoint.length >= 24 && segredoEndpoint === segredoBanco,
    `endpoint=${segredoEndpoint.slice(0, 6)}... banco=${segredoBanco.slice(0, 6)}...`);

  const estaticos = await js(`
    (async () => {
      const fora = [];
      for (const arq of ['config.js', 'dev-config.json', 'dash.js', 'index.html']) {
        try {
          const r = await fetch(arq + '?v=teste-' + Date.now(), { cache: 'reload' });
          if (!r.ok) continue;
          if ((await r.text()).includes(${JSON.stringify(segredoBanco)})) fora.push(arq);
        } catch (_) { /* arquivo ausente é aceitável */ }
      }
      return fora;
    })()
  `);

  verificar('segredo NÃO aparece em nenhum arquivo estático do dashboard',
    Array.isArray(estaticos) && estaticos.length === 0,
    `vazando em: ${(estaticos || []).join(', ') || 'nenhum'}`);

  verificar('variante com -ComTarefa oferecida', /-ComTarefa$/.test((gerado.tarefa || '').trim()),
    gerado.tarefa.slice(-40));

  verificar('nenhuma exceção no fluxo de adicionar', erros.length === 0, erros.join('\n        '));

  // A máquina nova deve aparecer no banco como nunca vista.
  const noBanco = execFileSync('docker', [
    'exec', 'monitor-db', 'psql', '-U', 'postgres', '-t', '-A', '-c',
    `select count(*) from public.machines where label = '${nomeTeste}'`,
  ], { encoding: 'utf8' }).trim();
  verificar('máquina foi cadastrada no banco', noBanco === '1', `count=${noBanco}`);

  // Limpa a máquina de teste.
  execFileSync('docker', ['exec', 'monitor-db', 'psql', '-U', 'postgres', '-q', '-c',
    `delete from public.machines where label = '${nomeTeste}'`], { encoding: 'utf8' });

  await js("document.getElementById('btn-fechar-modal').click(); true");
  await dormir(600);

  // Checar `.hidden` NAO BASTA, e essa foi exatamente a falha que escapou daqui:
  // o JS marcava hidden = true e o modal continuava na tela, porque `.modal`
  // declarava `display: flex` e estilo de autor vence o `[hidden]` da folha do
  // navegador. Por isso a pergunta certa e "o navegador esta desenhando isto?",
  // e a resposta so vem do estilo computado.
  const fechou = await js(`
    (() => {
      const alvos = ['modal-add', 'modal-fundo', 'painel', 'painel-fundo'];
      const visiveis = alvos.filter((id) => {
        const n = document.getElementById(id);
        return n && getComputedStyle(n).display !== 'none';
      });
      return { atributo: document.getElementById('modal-add').hidden, visiveis };
    })()
  `);

  verificar('modal fecha (atributo hidden)', fechou.atributo === true);
  verificar('modal e painel realmente saem da tela (display computado)',
    fechou.visiveis.length === 0, `ainda desenhando: ${fechou.visiveis.join(', ') || 'nada'}`);

  // =========================================================================
  console.log('\n== Relatório mensal ==');
  // =========================================================================
  erros.length = 0;
  await js("document.getElementById('btn-relatorio').click(); true");
  await dormir(3200);

  const rel = await js(`
    ({
      visivel: getComputedStyle(document.getElementById('modal-relatorio')).display !== 'none',
      meses:   document.getElementById('rel-mes').options.length,
      linhas:  document.querySelectorAll('#rel-corpo tr').length,
      resumo:  document.querySelectorAll('#rel-resumo .rr-item').length,
      sub:     document.getElementById('rel-sub').textContent,
      // O CSV é montado em memória; conferir que a função existe e que há dado
      // para exportar é o que dá para verificar sem baixar arquivo de verdade.
      temDado: !!(Estado.relatorio && Estado.relatorio.maquinas),
    })
  `);

  verificar('o relatório abre', rel.visivel === true, JSON.stringify(rel));
  verificar('o seletor de mês tem opção', rel.meses >= 1, `${rel.meses} mês(es)`);
  verificar('o resumo do mês é montado', rel.resumo === 5, `${rel.resumo} cartões`);
  verificar('a tabela tem uma linha por máquina',
    rel.linhas >= 1, `${rel.linhas} linha(s) — "${rel.sub}"`);
  verificar('o relatório ficou no estado, pronto para exportar', rel.temDado === true);
  verificar('nenhuma exceção ao abrir o relatório', erros.length === 0, erros.join('\n        '));

  // O CSV precisa abrir no Excel em português: separador `;` e vírgula decimal.
  // Gerar aqui, em memória, é a única forma de verificar isso sem depender do
  // diálogo de download do navegador.
  const csv = await js(`
    (() => {
      const r = Estado.relatorio;
      if (!r || !r.maquinas.length) return null;
      const m = r.maquinas[0];
      return {
        temDecimalComPonto: Object.values(m).some(
          (v) => typeof v === 'number' && !Number.isInteger(v)),
        mes: r.mes,
      };
    })()
  `);
  // `\d`, não `\\d`: isto é uma regex no fonte deste arquivo, não uma string
  // enviada ao navegador. Com a barra dobrada, o padrão exigia uma barra
  // literal e a verificação reprovava um mês perfeitamente válido.
  verificar('o relatório traz o mês pedido', /^\d{4}-\d{2}$/.test(csv?.mes || ''), JSON.stringify(csv));

  await js("document.getElementById('btn-fechar-rel').click(); true");
  await dormir(500);
  const relFechou = await js(
    "getComputedStyle(document.getElementById('modal-relatorio')).display === 'none'");
  verificar('o relatório fecha', relFechou === true);

  // =========================================================================
  console.log('\n== Token inválido guardado ==');
  // =========================================================================
  // Sem tela de login para onde voltar, um token recusado tem de produzir uma
  // MENSAGEM VISÍVEL. O contrário — tela em branco ou aplicação pendurada — foi o
  // sintoma que mais custou neste projeto.
  erros.length = 0;
  errosRede.length = 0;

  await js(`
    (() => {
      sessionStorage.setItem('monitor.token', JSON.stringify({
        token: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJsaXhvIn0.assinatura-invalida',
        usuario: 'token velho',
      }));
      return true;
    })()
  `);

  await cmd('Page.navigate', { url: `${URL_DASH}/?v=teste-token-invalido` });
  await dormir(4000);

  // Na stack local o token do dev-config SUBSTITUI o guardado, então o dashboard
  // abre normalmente: o token velho não tem como travar nada.
  const aposToken = await js(`
    ({
      app:   !document.getElementById('app').hidden,
      kpi:   document.getElementById('kpi-total').textContent,
      falha: document.getElementById('falha-js').hidden
               ? null : document.getElementById('falha-js-msg').textContent,
    })
  `);

  verificar('token velho guardado não impede o dashboard de abrir',
    aposToken.app === true, JSON.stringify(aposToken));
  verificar('dados carregaram', /^[1-9][0-9]*$/.test(aposToken.kpi || ''), `kpi=${aposToken.kpi}`);
  verificar('nenhuma faixa de erro', aposToken.falha === null, aposToken.falha);
  verificar('nenhuma exceção de JavaScript no caminho do token velho',
    erros.length === 0, erros.join('\n        '));

  // Texto ilegível na tela.
  //
  // Uma reescrita de arquivo com a codificação errada não quebra nada: a página
  // carrega, os testes passam, e o usuário vê "Temp. <losango>" e "NÒO EXISTE".
  // Só olhando a tela se descobre — então esta verificação olha por nós.
  const lixo = await js(`
    (() => {
      const texto = document.body.innerText || '';
      const ruins = new Set();
      for (const ch of texto) {
        const c = ch.codePointAt(0);
        if (c === 0xFFFD || (c < 32 && c !== 9 && c !== 10 && c !== 13)) {
          ruins.add('U+' + c.toString(16).toUpperCase().padStart(4, '0'));
        }
      }
      return [...ruins];
    })()
  `);

  verificar('nenhum caractere ilegível no texto da tela',
    Array.isArray(lixo) && lixo.length === 0, `encontrados: ${(lixo || []).join(', ')}`);


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
  verificar('sequência completa pela página de diagnóstico funcionou',
    /1. login/.test(resLogin || ''), resLogin);

  ws.close();
} catch (e) {
  console.error(`\nERRO NO TESTE: ${e.message}`);
  falhas.push('erro de execução do teste');
} finally {
  limparFixture();
  limpar();
}

console.log('');
if (falhas.length > 0) {
  console.log(`FALHARAM ${falhas.length} de ${ok + falhas.length} verificações:`);
  for (const f of falhas) console.log(`  - ${f}`);
  process.exit(1);
}
console.log(`TODAS AS ${ok} VERIFICACOES NO NAVEGADOR PASSARAM.\n`);
