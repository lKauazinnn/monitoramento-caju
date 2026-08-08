// =============================================================================
// Build do @cajupar/sentinela-ds
// =============================================================================
// O PONTO DESTE ARQUIVO: o CSS nao e escrito aqui. Ele e COPIADO do
// dashboard/styles.css que ja roda em producao.
//
// Reescrever a folha de estilo criaria duas versoes da mesma linguagem visual,
// que e como as duas divergem — o painel muda, a biblioteca nao, e os desenhos
// feitos com ela passam a mostrar um produto que nao existe. Copiando, a
// biblioteca e sempre um espelho do que esta no ar.
//
// Duas adaptacoes sao necessarias, e so duas:
//
//   1. o tema claro esta preso a `html[data-tema="light"]`, e aqui o tema e
//      aplicado num <div> (o componente Sentinela). O seletor passa a valer
//      para qualquer elemento.
//
//   2. `html, body { ... }` pinta a pagina inteira. Numa ferramenta de desenho
//      isso sequestraria o fundo do editor, entao vira uma regra escopada.
//
// Rode:  npm run build
// =============================================================================

import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import * as esbuild from 'esbuild';

const aqui = dirname(fileURLToPath(import.meta.url));
const origemCss = join(aqui, '..', 'dashboard', 'styles.css');
const destinoCss = join(aqui, 'src', 'sentinela.css');

// ---------------------------------------------------------------- 1. o CSS
let css = readFileSync(origemCss, 'utf8');
const bytesOrigem = css.length;

// (1) tema claro: de `html[data-tema=...]` para qualquer elemento.
const antesTema = css;
css = css.replace(/html\[data-tema="light"\]/g, '[data-tema="light"]');
if (css === antesTema) {
  // Falhar aqui e melhor que entregar uma biblioteca sem tema claro: se o
  // seletor mudou no painel, esta adaptacao precisa mudar junto.
  throw new Error('nao encontrei html[data-tema="light"] no styles.css de origem');
}

// (2) `html, body` deixa de pintar a pagina do hospedeiro.
const antesBody = css;
css = css.replace(
  /html,\s*body\s*\{[^}]*\}/,
  '/* `html, body` do painel foi escopado no build: numa ferramenta de desenho\n' +
  '   ele sequestraria o fundo do editor. O componente Sentinela aplica o\n' +
  '   mesmo fundo no proprio elemento. */\n' +
  '.sentinela-raiz { margin: 0; padding: 0; background: var(--bg); }',
);
if (css === antesBody) {
  throw new Error('nao encontrei a regra `html, body` no styles.css de origem');
}

const cabecalho = `/* =============================================================================
 * GERADO — nao edite este arquivo.
 * =============================================================================
 * Copia de dashboard/styles.css (${bytesOrigem} bytes na origem), com duas
 * adaptacoes feitas por build.mjs. Para mudar o visual, mude o painel: esta
 * biblioteca e um espelho, nao uma segunda fonte da verdade.
 * ========================================================================== */

`;

mkdirSync(dirname(destinoCss), { recursive: true });
writeFileSync(destinoCss, cabecalho + css, 'utf8');

// ------------------------------------------------------------ 2. o bundle
rmSync(join(aqui, 'dist'), { recursive: true, force: true });

const r = await esbuild.build({
  entryPoints: [join(aqui, 'src', 'index.ts')],
  outfile: join(aqui, 'dist', 'index.js'),
  bundle: true,
  format: 'esm',
  target: ['es2020'],
  jsx: 'automatic',
  // React fica de FORA: quem consome ja tem o seu, e embutir um segundo daria
  // dois React na mesma pagina — hooks quebram de um jeito dificil de explicar.
  external: ['react', 'react-dom', 'react/jsx-runtime'],
  loader: { '.css': 'css' },
  minify: false,   // legivel de proposito: alguem vai ler isto para entender
  sourcemap: false,
  metafile: true,
});

// esbuild nomeia o CSS a partir do outfile: index.css. O package.json aponta
// para sentinela.css, entao renomeia.
const cssGerado = join(aqui, 'dist', 'index.css');
try {
  const conteudo = readFileSync(cssGerado, 'utf8');
  writeFileSync(join(aqui, 'dist', 'sentinela.css'), conteudo, 'utf8');
  rmSync(cssGerado, { force: true });
} catch {
  throw new Error('esbuild nao emitiu o CSS — o import em src/index.ts sumiu?');
}

// -------------------------------------------------------------- 3. os tipos
execFileSync(process.execPath, [join(aqui, 'node_modules', 'typescript', 'bin', 'tsc')], {
  cwd: aqui, stdio: 'inherit',
});

// ------------------------------------------------------------------ resumo
const saidas = Object.entries(r.metafile.outputs);
console.log('\nbuild ok');
for (const [arq, meta] of saidas) {
  console.log(`  ${arq.replace(/\\/g, '/')}  ${(meta.bytes / 1024).toFixed(1)} kB`);
}
console.log(`  dist/sentinela.css  ${(readFileSync(join(aqui, 'dist', 'sentinela.css')).length / 1024).toFixed(1)} kB`);
