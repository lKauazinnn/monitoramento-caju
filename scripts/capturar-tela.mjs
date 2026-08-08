// =============================================================================
// Captura a tela do dashboard num navegador real
// =============================================================================
// Serve para OLHAR a interface em vez de imaginar como ela está. Salva PNGs em
// capturas/.
//
// Rode:  node scripts/capturar-tela.mjs
// =============================================================================

import { readFileSync, mkdirSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';

const raiz = fileURLToPath(new URL('..', import.meta.url));
const env = readFileSync(join(raiz, '.env'), 'utf8');
const webPort = /WEB_PORT=(\d+)/.exec(env)?.[1] ?? '8080';
const URL_DASH = `http://127.0.0.1:${webPort}`;
const destino = join(raiz, 'capturas');

mkdirSync(destino, { recursive: true });

const CAMINHOS = [
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
];
let navegador = null;
for (const c of CAMINHOS) {
  try { readFileSync(c); navegador = c; break; } catch (_) { /* próximo */ }
}
if (!navegador) { console.error('nenhum navegador encontrado'); process.exit(2); }

const perfil = mkdtempSync(join(tmpdir(), 'shot-'));
const porta = 9355;
const largura = Number(process.argv[2] ?? 1600);
const altura = Number(process.argv[3] ?? 1000);

const proc = spawn(navegador, [
  '--headless=new',
  `--remote-debugging-port=${porta}`,
  `--user-data-dir=${perfil}`,
  '--no-first-run', '--disable-gpu', '--hide-scrollbars',
  `--window-size=${largura},${altura}`,
  'about:blank',
], { stdio: 'ignore' });

const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

try {
  let wsUrl;
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${porta}/json/list`);
      const abas = await r.json();
      const p = abas.find((a) => a.type === 'page');
      if (p?.webSocketDebuggerUrl) { wsUrl = p.webSocketDebuggerUrl; break; }
    } catch (_) { /* subindo */ }
    await dormir(200);
  }

  const ws = new WebSocket(wsUrl);
  await new Promise((r) => { ws.onopen = r; });

  let id = 0;
  const pend = new Map();
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pend.has(m.id)) { pend.get(m.id)(m.result ?? m.error); pend.delete(m.id); }
  };
  const cmd = (method, params = {}) => new Promise((res) => {
    const meu = ++id; pend.set(meu, res);
    ws.send(JSON.stringify({ id: meu, method, params }));
  });
  const js = async (e) => (await cmd('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true }))?.result?.value;

  await cmd('Page.enable');
  await cmd('Runtime.enable');

  async function foto(nome, { paginaInteira = false } = {}) {
    const params = { format: 'png' };
    if (paginaInteira) {
      const m = await cmd('Page.getLayoutMetrics');
      const h = Math.min(Math.ceil(m.cssContentSize.height), 4000);
      params.clip = { x: 0, y: 0, width: largura, height: h, scale: 1 };
      params.captureBeyondViewport = true;
    }
    const r = await cmd('Page.captureScreenshot', params);
    if (!r?.data) { console.log(`  FALHOU ${nome}`); return; }
    const arq = join(destino, `${nome}.png`);
    writeFileSync(arq, Buffer.from(r.data, 'base64'));
    console.log(`  ${arq}`);
  }

  await cmd('Page.navigate', { url: `${URL_DASH}/?v=shot-${Date.now()}` });
  await dormir(4500);

  await foto('01-dashboard', { paginaInteira: true });

  // Painel de detalhe. `.host-quad` e o alvo na vista inicial (a grade por
  // loja); `.cartao` so existe quando um filtro esta ativo.
  await js("(document.querySelector('.host-quad') || document.querySelector('.cartao'))?.click(); true");
  await dormir(2800);
  await foto('02-painel');

  // A secao de acoes fica abaixo dos graficos: sem rolar, a foto do painel
  // mostra tudo menos o que mudou.
  await js("document.getElementById('acoes')?.scrollIntoView({ block: 'center' }); true");
  await dormir(900);
  await foto('02b-acoes');
  await js("document.getElementById('btn-fechar-painel')?.click(); true");
  await dormir(500);

  // Modal de adicionar PC
  await js("document.getElementById('btn-adicionar')?.click(); true");
  await dormir(1800);
  await foto('03-adicionar');

  // Modal passo 2, sem cadastrar de verdade: preenche os campos de exibição
  await js(`
    (() => {
      document.getElementById('add-passo1').hidden = true;
      document.getElementById('add-passo2').hidden = false;
      document.getElementById('add-resumo').textContent =
        'PDV 02 cadastrada em BSB-001. Token mon_a1b2c3d4e5f6…';
      document.getElementById('add-comando').textContent =
        "& ([scriptblock]::Create((irm 'http://192.168.14.222:3010/instalar.ps1'))) -Servidor 'http://192.168.14.222:3010' -Token 'mon_" + 'a'.repeat(64) + "' -Segredo 'exemplo' -Servicos 'Spooler,Dhcp'";
      return true;
    })()
  `);
  await dormir(700);
  await foto('04-comando');

  // Relatório mensal
  await js("document.getElementById('btn-fechar-modal')?.click(); true");
  await dormir(500);
  await js("document.getElementById('btn-relatorio')?.click(); true");
  await dormir(3000);
  await foto('05-relatorio');

  ws.close();
} catch (e) {
  console.error(`erro: ${e.message}`);
} finally {
  try { proc.kill(); } catch (_) { /* já morreu */ }
  try { rmSync(perfil, { recursive: true, force: true }); } catch (_) { /* ocupado */ }
}
