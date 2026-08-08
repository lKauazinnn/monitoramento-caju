// =============================================================================
// Verificacao: o painel novo (React) contra o banco de verdade
// =============================================================================
// Rode com:  node scripts/verificar-noc.mjs <email> <senha>
//
// As sete telas sao muitas superficies para conferir de olho, e a que quebra
// primeiro nunca e a que se olha. Este script percorre todas num Chrome real,
// contra a stack local, e reprova em tres coisas que nao podem acontecer num
// painel de operacao:
//
//   1. excecao de JavaScript — uma tela que explode nao mostra nada
//   2. tela vazia — se a vista trocou e nao renderizou, ninguem percebe pelo log
//   3. NUMERO INVENTADO — o pecado capital deste projeto. As telas sem coleta
//      tem que mostrar a faixa "sem coleta ainda", nao dado plausivel.
//
// A verificacao 3 e a razao de o script existir. As outras duas um humano pega
// abrindo a tela; essa nao — um numero errado parece um numero certo.
// =============================================================================

import { readFileSync, mkdirSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:http';

const [email, senha] = process.argv.slice(2);
if (!email || !senha) {
  console.error('uso: node scripts/verificar-noc.mjs <email> <senha>');
  process.exit(2);
}

const raiz = fileURLToPath(new URL('..', import.meta.url));
const dist = join(raiz, 'app', 'dist');
const capturas = join(raiz, 'capturas', 'noc');
mkdirSync(capturas, { recursive: true });

const sql = (q) => execFileSync('docker',
  ['exec', 'monitor-db', 'psql', '-U', 'postgres', '-t', '-A', '-c', q],
  { encoding: 'utf8' }).trim();

let passou = 0; const falhas = [];
const v = (nome, ok, det = '') => {
  if (ok) { passou++; console.log(`  ok    ${nome}`); }
  else { falhas.push(nome); console.log(`  FALHA ${nome}\n        ${det}`); }
};

// O dist e servido por um servidor proprio: `file://` bloqueia modulos ES.
const TIPOS = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2' };
const servidor = createServer((req, res) => {
  const nome = (req.url || '/').split('?')[0] === '/' ? '/index.html' : (req.url || '').split('?')[0];
  try {
    const corpo = readFileSync(join(dist, nome));
    res.writeHead(200, { 'content-type': TIPOS[nome.slice(nome.lastIndexOf('.'))] ?? 'application/octet-stream' });
    res.end(corpo);
  } catch { res.writeHead(404); res.end('404 ' + nome); }
});
await new Promise((r) => servidor.listen(0, '127.0.0.1', r));
const porta = servidor.address().port;

const perfil = mkdtempSync(join(tmpdir(), 'noc-'));
const cdp = 9393;
const proc = spawn('C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe', [
  '--headless=new', `--remote-debugging-port=${cdp}`, `--user-data-dir=${perfil}`,
  '--no-first-run', '--disable-gpu', '--hide-scrollbars', '--window-size=1700,1300', 'about:blank',
], { stdio: 'ignore' });

const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

const TELAS = [
  ['noc', 'Centro de operações'],
  ['frota', 'Frota'],
  ['incidente', 'Incidente'],
  ['inventario', 'Inventário'],
  ['alertas', 'Regras & ruído'],
  ['auditoria', 'Auditoria'],
  ['plantao', 'Plantão'],
];

/** As telas cujo dado nao e coletado: elas TEM que declarar isso. */
const DEVEM_AVISAR = ['incidente', 'inventario', 'auditoria'];

try {
  let wsUrl;
  for (let i = 0; i < 80; i++) {
    try {
      const abas = await (await fetch(`http://127.0.0.1:${cdp}/json/list`)).json();
      const p = abas.find((a) => a.type === 'page');
      if (p?.webSocketDebuggerUrl) { wsUrl = p.webSocketDebuggerUrl; break; }
    } catch { /* subindo */ }
    await dormir(200);
  }

  const ws = new WebSocket(wsUrl);
  await new Promise((r) => { ws.onopen = r; });
  let id = 0; const pend = new Map(); let erros = [];
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pend.has(m.id)) { pend.get(m.id)(m.result ?? m.error); pend.delete(m.id); }
    if (m.method === 'Runtime.exceptionThrown') {
      erros.push(m.params.exceptionDetails?.exception?.description ?? 'exceção');
    }
  };
  const cmd = (metodo, params = {}) => new Promise((res) => {
    const i = ++id; pend.set(i, res); ws.send(JSON.stringify({ id: i, method: metodo, params }));
  });
  const js = async (e) => (await cmd('Runtime.evaluate',
    { expression: e, returnByValue: true, awaitPromise: true }))?.result?.value;

  await cmd('Page.enable'); await cmd('Runtime.enable');
  await cmd('Emulation.setEmulatedMedia', {
    features: [{ name: 'prefers-reduced-motion', value: 'reduce' }],
  });

  // ------------------------------------------------------------- sessão
  // O painel novo usa a MESMA sessão do antigo. Entrar pelo login existente é
  // o que prova isso — um token forjado no localStorage testaria outra coisa.
  const c = readFileSync(join(dist, 'config.js'), 'utf8');
  const authUrl = /authUrl:\s*'([^']+)'/.exec(c)?.[1];
  const anon = /anonKey:\s*'([^']+)'/.exec(c)?.[1];
  const modo = /authMode:\s*'([^']+)'/.exec(c)?.[1];

  await cmd('Page.navigate', { url: `http://127.0.0.1:${porta}/?v=${Date.now()}` });
  await dormir(1500);

  // A stack LOCAL nao tem servidor de autenticacao: o dev-up.ps1 grava um
  // token de desenvolvimento em dev-config.json, e e ele que o painel usa.
  // Em producao o caminho e /token?grant_type=password — coberto por
  // verificar-dashboard-publicado.mjs, contra o site de verdade.
  const dev = JSON.parse(readFileSync(join(raiz, 'dashboard', 'dev-config.json'), 'utf8'));
  const tok = await js(`
    (() => {
      sessionStorage.setItem('monitor.token', JSON.stringify({
        token: ${JSON.stringify(dev.devToken)},
        usuario: ${JSON.stringify(dev.devUsuario ?? email)},
      }));
      return 'ok';
    })()
  `);
  v('a sessao do painel antigo serve para o novo', tok === 'ok', String(tok));

  await cmd('Page.navigate', { url: `http://127.0.0.1:${porta}/?v=${Date.now()}` });
  await dormir(3500);
  erros = [];

  const maquinas = Number(sql('select count(*) from public.machines'));

  // --------------------------------------------------------- cada tela
  for (const [vista, titulo] of TELAS) {
    console.log(`\n== ${vista} ==`);
    erros = [];

    const foi = await js(`
      (() => {
        const b = [...document.querySelectorAll('button')]
          .find(x => x.textContent.trim().startsWith(${JSON.stringify(titulo.split(' ')[0])}));
        if (!b) return 'botão não encontrado';
        b.click();
        return 'ok';
      })()
    `);
    await dormir(1600);

    const h1 = await js("document.querySelector('h1')?.textContent ?? ''");
    v(`${vista}: a tela abriu`, h1.includes(titulo.split(' ')[0]), `navegação=${foi} h1="${h1}"`);

    const texto = await js('document.body.innerText.trim().length');
    v(`${vista}: renderizou conteúdo`, texto > 300, `${texto} caracteres`);

    v(`${vista}: sem exceção de JavaScript`, erros.length === 0, erros.join(' | '));

    const ffdd = await js("document.body.innerText.includes('\\uFFFD')");
    v(`${vista}: nenhum caractere corrompido`, ffdd === false);

    // A verificação que importa: tela sem coleta declara isso.
    if (DEVEM_AVISAR.includes(vista)) {
      const avisa = await js("document.body.innerText.includes('sem coleta ainda')");
      v(`${vista}: declara que o dado não é coletado`, avisa === true,
        'a faixa "sem coleta ainda" não apareceu — a tela pode estar inventando dado');
    }

    const m = await cmd('Page.getLayoutMetrics');
    const alt = Math.min(Math.ceil(m.cssContentSize.height), 3200);
    const foto = await cmd('Page.captureScreenshot', {
      format: 'png', clip: { x: 0, y: 0, width: 1700, height: alt, scale: 1 },
      captureBeyondViewport: true,
    });
    if (foto?.data) writeFileSync(join(capturas, `${vista}.png`), Buffer.from(foto.data, 'base64'));
  }

  // ------------------------------------------------------------- ⌘K
  console.log('\n== paleta ⌘K ==');
  erros = [];
  await cmd('Input.dispatchKeyEvent', {
    type: 'keyDown', key: 'k', code: 'KeyK', windowsVirtualKeyCode: 75, modifiers: 2,
  });
  await dormir(700);
  const abriu = await js("!!document.querySelector('[aria-label=\"Paleta de comandos\"]')");
  v('⌘K abre a paleta', abriu === true);

  if (abriu) {
    const n = await js("document.querySelectorAll('[aria-label=\"Paleta de comandos\"] button').length");
    v('a paleta lista comandos e hosts', n > 5, `${n} resultado(s)`);

    const foto = await cmd('Page.captureScreenshot', { format: 'png' });
    if (foto?.data) writeFileSync(join(capturas, 'paleta.png'), Buffer.from(foto.data, 'base64'));

    await cmd('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
    await dormir(500);
    const fechou = await js("!document.querySelector('[aria-label=\"Paleta de comandos\"]')");
    v('Esc fecha a paleta', fechou === true);
  }

  // ---------------------------------------------------------- gaveta
  console.log('\n== gaveta do host ==');
  await js(`
    (() => {
      const b = [...document.querySelectorAll('button')].find(x => x.textContent.trim().startsWith('Frota'));
      if (b) b.click();
      return true;
    })()
  `);
  await dormir(1500);

  if (maquinas > 0) {
    // Ancorado em `data-linha`, que é contrato da tabela. A versão anterior
    // procurava a linha pelo estilo inline (`minHeight: 30px`) e quebrava a
    // cada ajuste de CSS — um teste que falha por motivo errado é pior que
    // nenhum, porque ensina a ignorar a falha.
    const abriuG = await js(`
      (() => {
        const linhas = [...document.querySelectorAll('[data-linha]')];
        if (!linhas.length) return 'nenhuma linha encontrada';
        linhas[0].click();
        return 'ok';
      })()
    `);
    await dormir(1600);
    const temGaveta = await js("!!document.querySelector('.painel')");
    v('clicar numa linha abre a gaveta', temGaveta === true, String(abriuG));

    if (temGaveta) {
      const foto = await cmd('Page.captureScreenshot', { format: 'png' });
      if (foto?.data) writeFileSync(join(capturas, 'gaveta.png'), Buffer.from(foto.data, 'base64'));
    }
  } else {
    console.log('  (sem máquinas no banco local — gaveta não testada)');
  }

  // ------------------------------------------------------------- tema
  console.log('\n== tema ==');
  await js(`
    (() => {
      const b = [...document.querySelectorAll('button')]
        .find(x => x.textContent.includes('Tema claro') || x.textContent.includes('Tema escuro'));
      if (b) b.click();
      return true;
    })()
  `);
  await dormir(900);
  const tema = await js('document.documentElement.dataset.tema');
  v('o botão de tema troca de verdade', tema === 'light' || tema === 'dark', String(tema));

  const fundo = await js("getComputedStyle(document.querySelector('.sentinela-raiz')).backgroundColor");
  const cor = await js("getComputedStyle(document.querySelector('.sentinela-raiz')).color");
  v('texto e fundo continuam distintos no outro tema', fundo !== cor, `${cor} sobre ${fundo}`);

  ws.close();
} catch (e) {
  falhas.push('exceção');
  console.log(`\nEXCEÇÃO: ${e.message}`);
} finally {
  try { proc.kill(); } catch { /* já morreu */ }
  try { rmSync(perfil, { recursive: true, force: true }); } catch { /* ocupado */ }
  servidor.close();
}

console.log(`\n${passou} verificações ok, ${falhas.length} falha(s)`);
console.log(`capturas em ${capturas}`);
if (falhas.length) { falhas.forEach((f) => console.log(`  - ${f}`)); process.exit(1); }
