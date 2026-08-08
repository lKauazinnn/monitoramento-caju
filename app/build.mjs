// Build do painel. esbuild direto: sem framework de build, sem plugin, sem
// configuracao que ninguem entende seis meses depois.
import * as esbuild from 'esbuild';
import { mkdirSync, copyFileSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const aqui = dirname(fileURLToPath(import.meta.url));
const saida = join(aqui, 'dist');
mkdirSync(saida, { recursive: true });

const r = await esbuild.build({
  entryPoints: [join(aqui, 'src', 'main.tsx')],
  outfile: join(saida, 'app.js'),
  assetNames: 'fontes/[name]',
  bundle: true, format: 'esm', target: ['es2022'], jsx: 'automatic',
  loader: { '.css': 'css', '.woff2': 'file' },
  minify: !process.argv.includes('--dev'),
  sourcemap: process.argv.includes('--dev'),
  metafile: true,
  logLevel: 'info',
});

for (const [arq, meta] of Object.entries(r.metafile.outputs)) {
  console.log(`  ${arq.split('\\').join('/')}  ${(meta.bytes / 1024).toFixed(1)} kB`);
}
