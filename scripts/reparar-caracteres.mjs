// =============================================================================
// Repara os caracteres estragados em index.html e dash.js
// =============================================================================
// Um `Set-Content -Encoding utf8` sobre bytes que já eram UTF-8 destruiu a
// pontuação tipográfica e os acentos MAIÚSCULOS destes dois arquivos. Sobraram
// pares como U+FFFD U+001D onde havia um travessão.
//
// O conserto é por MAPEAMENTO EXPLÍCITO, nunca por "adivinha a codificação": a
// tentativa anterior de round-trip latin1->utf8 foi justamente o que produziu
// este lixo. Cada par abaixo foi conferido no contexto da linha.
//
// Nos textos que aparecem na tela o substituto entra como ENTIDADE HTML (no
// .html) ou ESCAPE \uXXXX (no .js). Assim o arquivo-fonte fica ASCII naqueles
// pontos e nenhuma reescrita futura do PowerShell consegue estragá-lo de novo.
//
// Rode:  node scripts/reparar-caracteres.mjs
// =============================================================================

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

const raiz = fileURLToPath(new URL('..', import.meta.url));

const TRAVESSAO = '—'; // —
const VEZES = '×';     // ×
const RETICENCIA = '…'; // …

// Ordem importa: os pares de dois caracteres primeiro, senão o U+FFFD solto
// seria consumido antes de casar com o par a que pertence.
const COMUM = [
  ['�', TRAVESSAO],   // separador: "BSB-001 — Cajupar Asa Sul"
  ['�', TRAVESSAO],   // valor ausente
  ['�', VEZES],       // botão de fechar
  ['⬦', RETICENCIA],
  ['NÒO', 'NÃO'],      // NÒO -> NÃO
  ['�aMERO', 'ÚMERO'], // N?aMERO -> NÚMERO
  ['�aNICO', 'ÚNICO'],
  ['�altimo', 'Último'],
  ['�0 o', 'É o'],     // "seguranca. ? o" -> "É o"
  ['ENDERE�!O', 'ENDEREÇO'],
];

// Substitutos ASCII para o que o usuário LÊ na tela. Aplicados depois do
// mapeamento comum, sobre o caractere já correto.
const ASCII_HTML = [
  [`>${TRAVESSAO}<`, '>&mdash;<'],
  [`>${VEZES}<`, '>&times;<'],
  [`${RETICENCIA}<`, '&hellip;<'],
  [`) ${TRAVESSAO} ele muda`, ') &mdash; ele muda'],
  [`SYSTEM ${TRAVESSAO} e a`, 'SYSTEM &mdash; e a'],
  [`outra vez ${TRAVESSAO} o token`, 'outra vez &mdash; o token'],
];

const ASCII_JS = [
  [`'${TRAVESSAO}'`, "'\\u2014'"],
  ['`${m.site_code} ' + TRAVESSAO, '`${m.site_code} \\u2014'],
  ['} ' + TRAVESSAO + ' ${m.site_name}', '} \\u2014 ${m.site_name}'],
  ['${loja.code} ' + TRAVESSAO, '${loja.code} \\u2014'],
  ['${m.site_code} ' + TRAVESSAO, '${m.site_code} \\u2014'],
  [`'Último contato'`, "'\\u00daltimo contato'"],
  [`${RETICENCIA}\``, '\\u2026`'],
  [`'selecionado ${TRAVESSAO} Ctrl+C'`, "'selecionado \\u2014 Ctrl+C'"],
];

let falhou = false;

for (const [arq, extras] of [['dashboard/index.html', ASCII_HTML], ['dashboard/dash.js', ASCII_JS]]) {
  const caminho = join(raiz, arq);
  let s = readFileSync(caminho, 'utf8');
  const antes = s;
  let trocas = 0;

  for (const [de, para] of [...COMUM, ...extras]) {
    let n = 0;
    while (s.includes(de)) { s = s.replace(de, para); n++; if (n > 500) break; }
    trocas += n;
  }

  // Verificação: nada de substituição nem de controle pode sobrar. Sem isto o
  // script "funcionaria" deixando lixo que ninguém veria até abrir a tela.
  const restos = new Map();
  for (const ch of s) {
    const c = ch.codePointAt(0);
    if (c === 0xFFFD || (c < 32 && c !== 9 && c !== 10 && c !== 13) || c === 0x2B26 || c === 0x00D2) {
      restos.set(c, (restos.get(c) || 0) + 1);
    }
  }

  if (restos.size > 0) {
    falhou = true;
    console.log(`${arq}: AINDA HA LIXO -> ` +
      [...restos].map(([c, n]) => `U+${c.toString(16).toUpperCase().padStart(4, '0')}x${n}`).join(' '));
    continue;
  }

  if (s === antes) { console.log(`${arq}: ja estava limpo`); continue; }

  // Sem BOM: navegador lê pelo <meta charset>, e BOM em .js quebra parser estrito.
  writeFileSync(caminho, s, 'utf8');
  console.log(`${arq}: ${trocas} trocas, limpo`);
}

process.exit(falhou ? 1 : 0);
