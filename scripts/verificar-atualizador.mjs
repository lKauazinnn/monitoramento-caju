// =============================================================================
// Verificacao: o atualizador troca O ARQUIVO CERTO
// =============================================================================
// Rode com:  node scripts/verificar-atualizador.mjs
//
// Existe por causa de um defeito que passou: o atualizador gravava em
// 'agente.ps1', mas o instalador usa 'agente-powershell.ps1'. Ele baixava,
// gravava, imprimia "atualizado para ps-1.3.0" — e criava um arquivo que NADA
// executa. O agente real ficava na versao antiga, e a unica pista era o painel
// insistindo na versao velha.
//
// E o pior tipo de defeito: o script relata sucesso. Sem um teste que confira o
// ARQUIVO em vez da mensagem, ele voltaria.
//
// Monta uma instalacao falsa num diretorio temporario, roda o atualizador de
// verdade contra ela, e confere no disco.
// =============================================================================
import { readFileSync, writeFileSync, mkdtempSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const raiz = fileURLToPath(new URL('..', import.meta.url));
const env = readFileSync(join(raiz, '.env'), 'utf8');
const portaIngest = /INGEST_PORT=(\d+)/.exec(env)?.[1] ?? '3010';

let passou = 0; const falhas = [];
const verificar = (nome, ok, det = '') => {
  if (ok) { passou++; console.log(`  ok    ${nome}`); }
  else { falhas.push(nome); console.log(`  FALHA ${nome}\n        ${det}`); }
};

const dir = mkdtempSync(join(tmpdir(), 'upd-'));

const rodar = () => {
  try {
    return execFileSync('powershell', [
      '-NoProfile', '-ExecutionPolicy', 'Bypass',
      '-File', join(raiz, 'scripts', 'atualizar-agente.ps1'),
      '-Config', join(dir, 'config.json'),
    ], { encoding: 'utf8', timeout: 120000 });
  } catch (e) {
    return String(e.stdout ?? '') + String(e.stderr ?? '');
  }
};

try {
  // Instalacao falsa: config apontando para o shim local, e um agente ANTIGO
  // com o nome que o instalador de verdade usa.
  writeFileSync(join(dir, 'config.json'), JSON.stringify({
    ingestUrl: `http://127.0.0.1:${portaIngest}`,
    token: 'mon_' + 'a'.repeat(64),
    machineLabel: 'PC-FALSO',
  }, null, 2));

  const antigo = join(dir, 'agente-powershell.ps1');
  writeFileSync(antigo, "$VERSAO = 'ps-0.9.0'\nWrite-Host 'agente antigo'\n", 'utf8');

  console.log('\n== 1. troca o arquivo que o instalador usa ==');
  const saida = rodar();

  verificar('o atualizador rodou e reconheceu a versao antiga',
    /ps-0\.9\.0/.test(saida), saida.slice(-500));

  const depois = existsSync(antigo) ? readFileSync(antigo, 'utf8') : '';
  verificar('agente-powershell.ps1 foi REALMENTE trocado',
    /\$VERSAO\s*=\s*'ps-1\.[3-9]/.test(depois),
    depois.slice(0, 200) || '(arquivo sumiu)');

  verificar('e o conteudo novo e o agente de verdade',
    depois.includes('ExecutarWakeMachine') && depois.length > 20000,
    `${depois.length} bytes`);

  // O defeito original criava ESTE arquivo em vez de trocar o certo.
  verificar('NAO criou um agente.ps1 orfao que ninguem executa',
    !existsSync(join(dir, 'agente.ps1')),
    'existe um agente.ps1 solto: o atualizador escreveu no lugar errado');

  console.log('\n== 2. rodar de novo nao faz nada ==');
  const s2 = rodar();
  verificar('reconhece que ja esta atualizado',
    /ja esta na versao mais nova/.test(s2), s2.slice(-300));

  console.log('\n== 3. nao grava lixo por cima do agente ==');
  // Um proxy devolvendo pagina de login responde HTTP 200. Gravar isso por cima
  // do agente derrubaria o monitoramento da loja em vez de atualiza-lo.
  writeFileSync(join(dir, 'config.json'), JSON.stringify({
    ingestUrl: 'http://127.0.0.1:9/ingest',   // porta discard: nao responde
    token: 'mon_' + 'a'.repeat(64),
  }, null, 2));

  const bom = readFileSync(antigo, 'utf8');
  const s3 = rodar();

  verificar('falha de download nao altera o agente instalado',
    readFileSync(antigo, 'utf8') === bom, s3.slice(-300));

  verificar('e a falha e dita, nao engolida',
    /falhou|nao encontrei|Red/i.test(s3) || s3.includes('falhou'), s3.slice(-300));

  console.log('\n== 4. a JANELA nao fecha ==');
  // O defeito que fez o terminal sumir: `exit` dentro de um scriptblock
  // invocado com & nao encerra o script, encerra a SESSAO do PowerShell. A
  // janela fecha antes de a pessoa ler o resultado — inclusive no caso de
  // sucesso. Como o comando de uma linha e EXATAMENTE essa forma, este e o
  // modo em que o script tem que ser testado.
  //
  // A marca no fim so aparece se a sessao sobreviveu ao script.
  const comoScriptblock = (cfg) => {
    const ps1 = join(raiz, 'scripts', 'atualizar-agente.ps1').replace(/'/g, "''");
    try {
      return execFileSync('powershell', ['-NoProfile', '-Command',
        `& ([scriptblock]::Create((Get-Content -Raw '${ps1}'))) -Config '${cfg}'; ` +
        `Write-Host 'SESSAO-VIVA'`,
      ], { encoding: 'utf8', timeout: 120000 });
    } catch (e) {
      return String(e.stdout ?? '') + String(e.stderr ?? '');
    }
  };

  // Caminho de ERRO: config inexistente. Era aqui que a janela fechava.
  const sErro = comoScriptblock(join(dir, 'nao-existe.json'));
  verificar('erro nao encerra a sessao de quem colou o comando',
    /SESSAO-VIVA/.test(sErro), sErro.slice(-300));
  verificar('e o motivo do erro fica visivel antes disso',
    /config\.json nao encontrado/.test(sErro), sErro.slice(-300));

  // Caminho de SUCESSO tambem terminava em `exit 0`, e fechava igual.
  writeFileSync(join(dir, 'config.json'), JSON.stringify({
    ingestUrl: `http://127.0.0.1:${portaIngest}`,
    token: 'mon_' + 'a'.repeat(64),
  }, null, 2));
  writeFileSync(antigo, "$VERSAO = 'ps-0.9.0'\n", 'utf8');

  const sOk = comoScriptblock(join(dir, 'config.json'));
  verificar('sucesso tambem nao encerra a sessao',
    /SESSAO-VIVA/.test(sOk), sOk.slice(-400));
  verificar('e o script realmente atualizou nesse modo',
    /\$VERSAO\s*=\s*'ps-1\.[3-9]/.test(readFileSync(antigo, 'utf8')));

} catch (e) {
  falhas.push('excecao');
  console.log(`\nEXCECAO: ${e.message}`);
} finally {
  try { rmSync(dir, { recursive: true, force: true }); } catch (_) { /* ocupado */ }
}

console.log(`\n${passou} verificacoes ok, ${falhas.length} falha(s)`);
if (falhas.length) { falhas.forEach((f) => console.log(`  - ${f}`)); process.exit(1); }
