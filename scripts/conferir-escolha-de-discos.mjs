// =============================================================================
// Confere a escolha de volumes acompanhados pelo navegador de verdade (CDP)
// =============================================================================
// O que precisa ser verdade:
//
//   1. a gaveta lista os volumes com o interruptor "acompanhar" para admin
//   2. e SEM o interruptor para quem nao e admin -- mas ainda mostrando o estado
//   3. desmarcar um volume chama o servidor com o drive certo
//   4. e o cartao da loja passa a falar do OUTRO volume, na hora
//   5. o volume desmarcado continua na lista, apagado e marcado, para remarcar
//   6. a nota do cartao diz quantos volumes ficaram fora
//   7. desmarcado por ESCOLHA e "pequeno" por heuristica sao marcas diferentes
//   8. erro do servidor devolve a caixa ao estado anterior (nao ao clicado)
//
// O caso 8 e o que separa uma tela honesta de uma que mente: se o servidor
// recusa, a caixa NAO pode ficar marcada como a pessoa clicou -- senao a tela
// mostra uma escolha que nao existe no banco.
//
// Os dados vem de uma maquina que este teste injeta pelo proprio painel? Nao: ele
// finge as respostas do servidor no nivel do fetch. Testar contra a base exigiria
// dois volumes numa maquina local, e a base local tem um -- e um teste que so
// roda quando a base coopera nao roda.
// =============================================================================
import { readFileSync, mkdtempSync, rmSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';

const raiz = 'c:/Users/SUPORTE/Desktop/deashboard servidor';
const porta = /WEB_PORT=(\d+)/.exec(readFileSync(join(raiz, '.env'), 'utf8'))?.[1] ?? '8081';
mkdirSync(join(raiz, 'capturas'), { recursive: true });

let nav = null;
for (const c of ['C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
                 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe']) {
  try { readFileSync(c); nav = c; break; } catch (_) { /* proximo */ }
}
if (!nav) { console.error('sem navegador'); process.exit(2); }

const perfil = mkdtempSync(join(tmpdir(), 'vol-'));
const cdp = 9407;
const proc = spawn(nav, ['--headless=new', `--remote-debugging-port=${cdp}`,
  `--user-data-dir=${perfil}`, '--no-first-run', '--disable-gpu', '--hide-scrollbars',
  '--window-size=1500,1200', 'about:blank'], { stdio: 'ignore' });
const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

try {
  let ws;
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${cdp}/json/list`);
      const pg = (await r.json()).find((a) => a.type === 'page');
      if (pg?.webSocketDebuggerUrl) { ws = pg.webSocketDebuggerUrl; break; }
    } catch (_) { /* subindo */ }
    await dormir(200);
  }
  const sock = new WebSocket(ws);
  await new Promise((r) => { sock.onopen = r; });
  let id = 0; const pend = new Map();
  sock.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pend.has(m.id)) { pend.get(m.id)(m.result ?? m.error); pend.delete(m.id); }
  };
  const cmd = (method, params = {}) => new Promise((res) => {
    const meu = ++id; pend.set(meu, res);
    sock.send(JSON.stringify({ id: meu, method, params }));
  });
  const js = async (e) => {
    const r = await cmd('Runtime.evaluate',
      { expression: e, returnByValue: true, awaitPromise: true });
    if (r?.exceptionDetails) throw new Error(r.exceptionDetails.text + ' :: ' + e.slice(0, 100));
    return r?.result?.value;
  };

  await cmd('Page.enable'); await cmd('Runtime.enable');
  await cmd('Page.navigate', { url: `http://127.0.0.1:${porta}/?v=${Date.now()}` });
  await dormir(5500);

  let falhas = 0;
  const ok = (b, m) => { console.log((b ? '  ok     ' : '  FALHOU ') + m); if (!b) falhas++; };

  // ---- o dublê de servidor ---------------------------------------------------
  // Intercepta SO as duas RPC que interessam. Todo o resto passa para a rede de
  // verdade, para o painel continuar sendo o painel.
  await js(`
    (() => {
      window.__chamadas = [];
      window.__recusar = false;
      window.__discos = [
        { drive: 'C:', etiqueta: 'Sistema', fs: 'NTFS', total_gb: 240, free_gb: 96,
          free_pct: 40, tipo: 'SSD', saude_ok: true, desgaste_pct: 0,
          horas_ligado: 9000, realocados: 0, pendentes: 0,
          acompanhando: true, nota: null, pequeno: false },
        { drive: 'D:', etiqueta: 'Backup', fs: 'NTFS', total_gb: 2000, free_gb: 80,
          free_pct: 4, tipo: 'HDD', saude_ok: true, desgaste_pct: null,
          horas_ligado: 40000, realocados: 0, pendentes: 0,
          acompanhando: true, nota: null, pequeno: false },
        { drive: 'E:', etiqueta: 'Boot', fs: 'FAT32', total_gb: 1, free_gb: 0.5,
          free_pct: 50, tipo: 'SSD', saude_ok: true, desgaste_pct: null,
          horas_ligado: null, realocados: null, pendentes: null,
          acompanhando: true, nota: null, pequeno: true },
      ];

      const orig = window.fetch;
      window.fetch = async (url, opt) => {
        const u = String(url);
        if (u.includes('discos_da_maquina')) {
          return new Response(JSON.stringify({
            medido_em: new Date().toISOString(), discos: window.__discos,
          }), { status: 200, headers: { 'content-type': 'application/json' } });
        }
        if (u.includes('definir_volume_acompanhado')) {
          const corpo = JSON.parse(opt?.body || '{}');
          window.__chamadas.push(corpo);
          if (window.__recusar) {
            return new Response(JSON.stringify({ message: 'apenas administradores escolhem os volumes acompanhados' }),
              { status: 403, headers: { 'content-type': 'application/json' } });
          }
          const d = window.__discos.find(x => x.drive === String(corpo.p_drive).toUpperCase());
          if (d) d.acompanhando = corpo.p_acompanhar;
          return new Response(JSON.stringify({
            ok: true, drive: d ? d.drive : corpo.p_drive, acompanhar: corpo.p_acompanhar,
            volumes_acompanhados: window.__discos.filter(x => x.acompanhando).length,
            aviso: window.__discos.some(x => x.acompanhando) ? null
              : 'Nenhum volume acompanhado: esta máquina não terá número de disco no cartão nem alerta de disco.',
          }), { status: 200, headers: { 'content-type': 'application/json' } });
        }
        return orig(url, opt);
      };
      return true;
    })()
  `);

  // ---- 1 e 7 -----------------------------------------------------------------
  const idMaq = await js(`(Estado.maquinas[0] && Estado.maquinas[0].machine_id) || null`);
  if (!idMaq) throw new Error('a base local nao tem maquina para abrir a gaveta');

  await js(`Estado.ehAdmin = true; desenharDiscos(${JSON.stringify(idMaq)})`);
  await dormir(900);

  const g = JSON.parse(await js(`
    (() => {
      const l = [...document.querySelectorAll('.disco-linha')];
      return JSON.stringify({
        linhas: l.length,
        interruptores: document.querySelectorAll('.disco-acomp input').length,
        marcasFora: document.querySelectorAll('.disco-marca-fora').length,
        marcasPeq: document.querySelectorAll('.disco-marca-peq').length,
        pequenos: document.querySelectorAll('.disco-pequeno').length,
      });
    })()
  `));

  ok(g.linhas === 3, `a gaveta lista os 3 volumes (${g.linhas})`);
  ok(g.interruptores === 3, `um interruptor por volume, para admin (${g.interruptores})`);
  ok(g.marcasPeq === 1 && g.marcasFora === 0,
    `"pequeno" marcado (${g.marcasPeq}) e nada "fora" ainda (${g.marcasFora})`);

  // ---- 2: sem interruptor para quem nao e admin ------------------------------
  await js(`Estado.ehAdmin = false; desenharDiscos(${JSON.stringify(idMaq)})`);
  await dormir(700);
  const semAdmin = JSON.parse(await js(`
    JSON.stringify({
      interruptores: document.querySelectorAll('.disco-acomp input').length,
      linhas: document.querySelectorAll('.disco-linha').length,
    })
  `));
  ok(semAdmin.interruptores === 0 && semAdmin.linhas === 3,
    `nao-admin ve os volumes (${semAdmin.linhas}) e nenhum interruptor (${semAdmin.interruptores})`);

  // ---- 3 e 5: desmarcar o D: -------------------------------------------------
  await js(`Estado.ehAdmin = true; desenharDiscos(${JSON.stringify(idMaq)})`);
  await dormir(700);
  await js(`
    (() => {
      const alvo = [...document.querySelectorAll('.disco-linha')]
        .find(l => l.querySelector('.disco-letra')?.textContent === 'D:');
      alvo.querySelector('.disco-acomp input').click();
      return true;
    })()
  `);
  await dormir(2500);

  const dep = JSON.parse(await js(`
    (() => {
      const d = [...document.querySelectorAll('.disco-linha')]
        .find(l => l.querySelector('.disco-letra')?.textContent === 'D:');
      return JSON.stringify({
        chamada: window.__chamadas[0] || null,
        linhas: document.querySelectorAll('.disco-linha').length,
        dApagado: !!d && d.classList.contains('disco-fora'),
        dMarcado: !!d && !!d.querySelector('.disco-marca-fora'),
        dCaixa: !!d && d.querySelector('.disco-acomp input').checked,
      });
    })()
  `));

  ok(dep.chamada?.p_drive === 'D:' && dep.chamada?.p_acompanhar === false,
    `chamou o servidor com o volume certo (${JSON.stringify(dep.chamada)})`);
  ok(dep.linhas === 3 && dep.dApagado && dep.dMarcado && dep.dCaixa === false,
    'o D: continua na lista, apagado e marcado, para poder voltar');

  // ---- 4 e 6: o cartao muda -------------------------------------------------
  // A view do servidor e que decide o numero; aqui eu injeto o estado que ela
  // devolveria (D: fora) e confiro que o CARTAO le isso -- que e a parte que mora
  // no cliente e que eu escrevi.
  const cart = JSON.parse(await js(`
    (() => {
      // A maquina que o CARTAO usa e a que tem leitura de disco, nao a primeira
      // da lista -- Estado.maquinas[0] aqui e uma never_seen, e mutar ela nao
      // muda cartao nenhum. Foi essa suposicao que fez o teste falhar mostrando
      // 115 GB, o valor real da outra maquina.
      const m = Estado.maquinas.find(x => x.disk_min_free_pct !== null
                                       && x.disk_min_free_pct !== undefined)
             || Estado.maquinas[0];
      m.disk_worst_drive = 'C:';
      m.disk_min_free_pct = 40;
      m.disk_worst_free_gb = 96;
      m.disk_worst_total_gb = 240;
      m.disk_volumes_fora = 1;
      m.disk_drives_fora = 'D:';
      desenharMaquinas();
      const met = [...document.querySelectorAll('.cl-met')]
        .find(x => x.querySelector('.cl-met-rot')?.textContent === 'disco livre');
      return JSON.stringify({
        nota: met?.querySelector('.cl-met-nota')?.textContent || '',
        valor: met?.querySelector('.cl-met-val')?.textContent || '',
        dica: met?.title || '',
      });
    })()
  `));

  ok(/96 GB/.test(cart.valor), `o cartao passa a falar do C: (${cart.valor})`);
  ok(/1 fora/.test(cart.nota), `a nota diz quantos ficaram fora ("${cart.nota}")`);
  ok(/D:/.test(cart.dica) && /alertas/.test(cart.dica),
    'a dica nomeia o volume fora e avisa que ele saiu dos alertas');

  // A palavra "null" na tela. Uma captura mostrou "DISCO LIVRE null" nos cartoes
  // SEM leitura de disco: `null + ''` em JavaScript e a string "null", e a nota
  // era montada com `+`. Este caso olha a tela inteira, e nao so o cartao mexido,
  // porque o defeito estava exatamente nos OUTROS.
  const vazou = JSON.parse(await js(`
    (() => {
      const notas = [...document.querySelectorAll('.cl-met-nota')].map(n => n.textContent);
      return JSON.stringify({
        notas,
        ruins: notas.filter(t => /null|undefined|NaN/.test(t)),
      });
    })()
  `));
  ok(vazou.ruins.length === 0,
    `nenhuma nota com null/undefined/NaN (${vazou.ruins.join(', ') || 'nenhuma'})`);

  // ---- 8: recusa do servidor devolve a caixa --------------------------------
  await js(`window.__recusar = true; desenharDiscos(${JSON.stringify(idMaq)})`);
  await dormir(700);
  await js(`
    (() => {
      const alvo = [...document.querySelectorAll('.disco-linha')]
        .find(l => l.querySelector('.disco-letra')?.textContent === 'C:');
      alvo.querySelector('.disco-acomp input').click();
      return true;
    })()
  `);
  await dormir(1800);
  const recusa = JSON.parse(await js(`
    (() => {
      const c = [...document.querySelectorAll('.disco-linha')]
        .find(l => l.querySelector('.disco-letra')?.textContent === 'C:');
      const cx = c.querySelector('.disco-acomp input');
      return JSON.stringify({ marcada: cx.checked, travada: cx.disabled });
    })()
  `));
  ok(recusa.marcada === true && recusa.travada === false,
    `servidor recusou: a caixa voltou ao estado real e destravou (${JSON.stringify(recusa)})`);

  // ---- 9: servidor SEM a 0044 -----------------------------------------------
  // O painel pode ser publicado antes da migracao. Nessa ordem, o campo
  // `acompanhando` nao vem, e um interruptor que so sabe dar erro e pior que
  // nenhum. `undefined` e diferente de `false` -- e essa distincao que este caso
  // protege.
  await js(`
    (() => {
      window.__recusar = false;
      window.__discos = window.__discos.map(d => {
        const c = { ...d };
        delete c.acompanhando;
        return c;
      });
      return true;
    })()
  `);
  await js(`Estado.ehAdmin = true; desenharDiscos(${JSON.stringify(idMaq)})`);
  await dormir(900);
  const semMig = JSON.parse(await js(`
    JSON.stringify({
      interruptores: document.querySelectorAll('.disco-acomp input').length,
      linhas: document.querySelectorAll('.disco-linha').length,
      avisa: [...document.querySelectorAll('.disco-marca-peq')]
        .some(n => /0044/.test(n.textContent)),
    })
  `));
  ok(semMig.interruptores === 0 && semMig.linhas === 3,
    `servidor sem a 0044: nenhum interruptor (${semMig.interruptores}), discos ainda visiveis (${semMig.linhas})`);
  ok(semMig.avisa, 'e a tela diz que falta a migracao, em vez de calar');

  const r2 = await cmd('Page.captureScreenshot', { format: 'png' });
  if (r2?.data) {
    writeFileSync(join(raiz, 'capturas', '18-escolha-de-discos.png'), Buffer.from(r2.data, 'base64'));
    console.log('\n  capturas/18-escolha-de-discos.png');
  }

  console.log(falhas === 0
    ? '\nA escolha de volumes funciona na tela.'
    : `\n${falhas} falha(s).`);
  sock.close();
  process.exit(falhas === 0 ? 0 : 1);
} catch (e) {
  console.error('erro:', e.message);
  process.exit(1);
} finally {
  try { proc.kill(); } catch (_) { /* ja morreu */ }
  try { rmSync(perfil, { recursive: true, force: true }); } catch (_) { /* ocupado */ }
}
