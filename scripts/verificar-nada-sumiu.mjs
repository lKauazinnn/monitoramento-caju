// =============================================================================
// A trava: NENHUMA função pode sumir numa mudança de interface
// =============================================================================
// Rode com:  node scripts/verificar-nada-sumiu.mjs
//
// POR QUE ESTE ARQUIVO EXISTE, escrito sem rodeio:
//
// Eu reconstruí o painel para melhorar a aparência e publiquei uma versão que
// tinha PERDIDO oito ações — reiniciar serviço, limpar temporários, reiniciar,
// ligar, suspender, agendar reinício, remover máquina e cancelar comando.
// Sobrou "Testar coleta". Os testes que eu tinha verificavam que a tela
// renderizava, que não explodia e que não inventava número. Nenhum deles
// verificava que ela continuava FAZENDO o que fazia.
//
// Esta lista é o contrato. Toda melhoria de interface roda isto antes de
// publicar, e ele reprova se qualquer controle desaparecer. Mudar o visual de
// um botão é livre; fazer o botão sumir, não.
//
// Para acrescentar uma função nova: acrescente a linha aqui junto.
// Para REMOVER uma de propósito: remova a linha aqui, no mesmo commit, e diga
// no commit por que ela deixou de existir. O que não pode é sumir calado.
// =============================================================================

import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

import { CONTROLES, COMPORTAMENTOS } from './contrato-do-painel.mjs';

const raiz = fileURLToPath(new URL('..', import.meta.url));
const html = readFileSync(join(raiz, 'dashboard', 'index.html'), 'utf8');
const dirPainel = join(raiz, 'dashboard');
const arquivosJs = readdirSync(dirPainel)
  .filter((f) => f.endsWith('.js') && f !== 'config.js' && f !== 'config.producao.js');
const js = arquivosJs.map((f) => readFileSync(join(dirPainel, f), 'utf8')).join('\n');



let passou = 0; const falhas = [];

console.log(`\n== ${arquivosJs.length} arquivo(s) de script lido(s): ${arquivosJs.join(', ')} ==`);
console.log('\n== controles da interface ==');
for (const [id, oQueFaz] of CONTROLES) {
  const existe = html.includes(`id="${id}"`);
  if (existe) { passou++; }
  else {
    falhas.push(`${id} — ${oQueFaz}`);
    console.log(`  SUMIU  ${id}\n         era: ${oQueFaz}`);
  }
}
console.log(`  ${passou} de ${CONTROLES.length} controles presentes`);

console.log('\n== comportamentos ==');
let passouC = 0;
for (const [marca, oQueFaz] of COMPORTAMENTOS) {
  if (js.includes(marca)) { passouC++; }
  else {
    falhas.push(`${marca} — ${oQueFaz}`);
    console.log(`  SUMIU  ${marca}\n         era: ${oQueFaz}`);
  }
}
console.log(`  ${passouC} de ${COMPORTAMENTOS.length} comportamentos presentes`);

if (falhas.length === 0) {
  console.log('\nNada sumiu. Pode publicar.');
} else {
  console.log(`\n${falhas.length} FUNÇÃO(ÕES) SUMIU(RAM):`);
  falhas.forEach((f) => console.log(`  - ${f}`));
  console.log('\nSe a remoção foi de propósito, apague a linha correspondente');
  console.log('neste arquivo NO MESMO COMMIT, com o motivo na mensagem.');
  process.exit(1);
}
