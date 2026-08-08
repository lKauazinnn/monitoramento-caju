// =============================================================================
// Conferencia visual da biblioteca, num Chrome de verdade
// =============================================================================
// Rode:  node conferir.mjs
//
// Uma biblioteca que renderiza diferente do produto renderiza errado em TODO
// desenho feito com ela, para sempre. Entao a conferencia nao pode ser "parece
// que ficou bom": ela abre a pagina de demonstracao num navegador, tira foto
// nos dois temas, e reprova se algo obviamente quebrou — texto invisivel,
// tela vazia, erro de JavaScript.
//
// A foto fica em capturas/ para eu OLHAR e comparar com o painel real.
// =============================================================================

import { readFileSync, mkdirSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:http';

const aqui = dirname(fileURLToPath(import.meta.url));
const destino = join(aqui, 'capturas');
mkdirSync(destino, { recursive: true });

const TIPOS = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css' };

// Servidor proprio: `file://` bloqueia modulos ES, e a demo e um modulo.
const servidor = createServer((req, res) => {
  const nome = (req.url || '/').split('?')[0] === '/' ? '/index.html' : (req.url || '').split('?')[0];
  try {
    const corpo = readFileSync(join(aqui, 'demo', nome));
    const ext = nome.slice(nome.lastIndexOf('.'));
    res.writeHead(200, { 'content-type': TIPOS[ext] ?? 'application/octet-stream' });
    res.end(corpo);
  } catch {
    res.writeHead(404); res.end('nao achei ' + nome);
  }
});
await new Promise((r) => servidor.listen(0, '127.0.0.1', r));
const porta = servidor.address().port;

const CAMINHOS = [
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
];
let navegador = null;
for (const c of CAMINHOS) { try { readFileSync(c); navegador = c; break; } catch { /* proximo */ } }
if (!navegador) { console.error('nenhum navegador encontrado'); process.exit(2); }

const perfil = mkdtempSync(join(tmpdir(), 'ds-'));
const portaCdp = 9391;
const proc = spawn(navegador, [
  '--headless=new', `--remote-debugging-port=${portaCdp}`, `--user-data-dir=${perfil}`,
  '--no-first-run', '--disable-gpu', '--hide-scrollbars', '--window-size=1600,2400', 'about:blank',
], { stdio: 'ignore' });

const dormir = (ms) => new Promise((r) => setTimeout(r, ms));
let passou = 0; const falhas = [];
const verificar = (nome, ok, det = '') => {
  if (ok) { passou++; console.log(`  ok    ${nome}`); }
  else { falhas.push(nome); console.log(`  FALHA ${nome}\n        ${det}`); }
};

try {
  let wsUrl;
  for (let i = 0; i < 80; i++) {
    try {
      const abas = await (await fetch(`http://127.0.0.1:${portaCdp}/json/list`)).json();
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
      erros.push(m.params.exceptionDetails?.exception?.description || 'excecao');
    }
  };
  const cmd = (metodo, params = {}) => new Promise((res) => {
    const i = ++id; pend.set(i, res); ws.send(JSON.stringify({ id: i, method: metodo, params }));
  });
  const js = async (e) => (await cmd('Runtime.evaluate',
    { expression: e, returnByValue: true, awaitPromise: true }))?.result?.value;

  await cmd('Page.enable'); await cmd('Runtime.enable');

  // CONGELA AS ANIMACOES antes de qualquer foto.
  //
  // Sem isto, um componente que pulsa e capturado num quadro qualquer: o botao
  // armado (`pulseDot` vai a opacidade .32 e escala .8) sai lavado e menor, e
  // parece defeito de contraste — cheguei a diagnosticar isso errado uma vez
  // olhando a foto. Numa ferramenta de desenho, onde o cartao do componente E
  // uma foto, isso viraria um componente que parece quebrado.
  //
  // O CSS do painel ja tem a saida pronta: ele respeita
  // `prefers-reduced-motion: reduce` desligando animacao e transicao. Basta
  // pedir. Ao vivo, no navegador de quem usa, a animacao continua existindo.
  await cmd('Emulation.setEmulatedMedia', {
    features: [{ name: 'prefers-reduced-motion', value: 'reduce' }],
  });

  for (const tema of ['escuro', 'claro']) {
    console.log(`\n== tema ${tema} ==`);
    erros = [];
    await cmd('Page.navigate', { url: `http://127.0.0.1:${porta}/?tema=${tema}&v=${Date.now()}` });
    await dormir(2500);

    verificar('a pagina montou sem excecao', erros.length === 0, erros.join(' | '));

    const n = await js("document.querySelectorAll('.cartao, .cartao-loja, .tira').length");
    verificar('os componentes renderizaram', n >= 8, `${n} elementos`);

    // O CSS chegou? Sem ele, `.cartao` nao teria borda nem fundo — e o defeito
    // seria "parece um site sem estilo", que e exatamente o que passa
    // despercebido numa conferencia por cima.
    const temEstilo = await js(`
      (() => {
        const c = document.querySelector('.cartao');
        if (!c) return 'sem cartao';
        const s = getComputedStyle(c);
        return s.borderLeftWidth + '|' + s.borderRadius + '|' + s.backgroundColor;
      })()
    `);
    verificar('o CSS do painel foi aplicado',
      typeof temEstilo === 'string' && !temEstilo.startsWith('0px|0px'), String(temEstilo));

    // Contraste: texto e fundo NAO podem ser a mesma cor. E o modo de falha do
    // tema claro quando o seletor de tema nao casa.
    const contraste = await js(`
      (() => {
        const r = document.querySelector('.sentinela-raiz');
        const s = getComputedStyle(r);
        return s.color + ' sobre ' + s.backgroundColor;
      })()
    `);
    const [cor, fundo] = String(contraste).split(' sobre ');
    verificar('texto e fundo sao cores diferentes', cor !== fundo, contraste);

    // O tema claro tem que MUDAR alguma coisa. Se as duas fotos forem iguais,
    // o data-tema nao esta pegando e metade da biblioteca e mentira.
    if (tema === 'claro') {
      verificar('o tema claro tem fundo claro de verdade',
        /^rgb\((2[0-9][0-9]|1[89][0-9])/.test(fundo || ''), fundo);
    }

    // O estado armado e o unico texto da interface que a pessoa le sob pressao,
    // decidindo se apaga historico. Ele NAO pode sair lavado numa foto.
    const opacidadeArmado = await js(`
      (() => {
        const b = document.querySelector('.btn-perigo.armado');
        return b ? getComputedStyle(b).opacity : 'sem botao armado';
      })()
    `);
    verificar('o botao armado esta opaco na captura (animacao congelada)',
      opacidadeArmado === '1', String(opacidadeArmado));

    const vazio = await js("document.body.innerText.trim().length");
    verificar('a tela tem texto', vazio > 400, `${vazio} caracteres`);

    // U+FFFD: a marca de arquivo salvo com a codificacao errada. Ja aconteceu
    // neste projeto uma vez.
    const ffdd = await js("document.body.innerText.includes('\\uFFFD')");
    verificar('nenhum caractere corrompido', ffdd === false);

    const m = await cmd('Page.getLayoutMetrics');
    const alt = Math.min(Math.ceil(m.cssContentSize.height), 4000);
    const foto = await cmd('Page.captureScreenshot', {
      format: 'png',
      clip: { x: 0, y: 0, width: 1600, height: alt, scale: 1 },
      captureBeyondViewport: true,
    });
    if (foto?.data) {
      const arq = join(destino, `ds-${tema}.png`);
      writeFileSync(arq, Buffer.from(foto.data, 'base64'));
      console.log(`  foto: ${arq}`);
    }
  }

  ws.close();
} catch (e) {
  falhas.push('excecao');
  console.log(`\nEXCECAO: ${e.message}`);
} finally {
  try { proc.kill(); } catch { /* ja morreu */ }
  try { rmSync(perfil, { recursive: true, force: true }); } catch { /* ocupado */ }
  servidor.close();
}

console.log(`\n${passou} verificacoes ok, ${falhas.length} falha(s)`);
if (falhas.length) { falhas.forEach((f) => console.log(`  - ${f}`)); process.exit(1); }
