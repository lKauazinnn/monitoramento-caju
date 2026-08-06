// =============================================================================
// Embute agente.ps1 e instalar.ps1 na Edge Function
// =============================================================================
// POR QUE EMBUTIR, e não ler o arquivo em tempo de execução:
//
// Numa loja remota o comando de instalação é `irm https://.../instalar.ps1`. Esse
// endereço tem de existir em HTTPS, e a Edge Function é o único componente do
// projeto que já está publicado em HTTPS — não vale a pena subir um segundo
// serviço só para servir dois arquivos de texto.
//
// Ler com `Deno.readTextFile` dependeria de a plataforma empacotar arquivos
// vizinhos da função, que é um comportamento que eu não consigo verificar daqui.
// String em módulo TypeScript funciona em qualquer runtime Deno, sem sistema de
// arquivos, e o resultado é conferível antes do deploy.
//
// O arquivo gerado É versionado: o deploy não depende de rodar isto antes. Em
// troca existe o modo --verificar, que reprova quando o gerado está velho, e o
// script de publicação o chama.
//
// Rode:  node scripts/gerar-scripts-embutidos.mjs
//        node scripts/gerar-scripts-embutidos.mjs --verificar
// =============================================================================

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { createHash } from 'node:crypto';

const raiz = fileURLToPath(new URL('..', import.meta.url));
const destino = join(raiz, 'supabase/functions/ingest/scripts-embutidos.ts');

const FONTES = [
  ['AGENTE_PS1', 'agent/agente-powershell.ps1'],
  ['INSTALAR_PS1', 'docker/ingest-local/instalar.ps1'],
];

const soVerificar = process.argv.includes('--verificar');

/**
 * Serializa como literal de template do TypeScript.
 *
 * Escapa a crase, a barra invertida e `${`. Sem isso, um `$(...)` do PowerShell
 * escaparia intacto (não é `${`), mas `${env:VAR}` não — e o resultado seria um
 * erro de sintaxe no deploy, ou pior, interpolação silenciosa.
 */
function comoTemplate(texto) {
  return texto
    .replace(/\\/g, '\\\\')
    .replace(/`/g, '\\`')
    .replace(/\$\{/g, '\\${');
}

const partes = [];
const resumo = [];

for (const [nome, caminho] of FONTES) {
  // Lido como texto UTF-8 e reemitido como UTF-8: nenhuma conversão de
  // codificação no meio, que é exatamente o que estragou os arquivos do
  // dashboard uma vez.
  const bruto = readFileSync(join(raiz, caminho), 'utf8');

  // Normaliza para LF. O PowerShell aceita os dois, mas CRLF dentro de um
  // literal de template infla o arquivo e polui o diff a cada edição no Windows.
  //
  // E TIRA O BOM: os .ps1 de origem têm BOM de propósito (sem ele o PowerShell
  // 5.1 lê o arquivo como ANSI e um acento quebra a análise sintática), e
  // `readFileSync(..., 'utf8')` entrega esse BOM como U+FEFF no início da
  // string. A Edge Function acrescenta o BOM ao servir, então mantê-lo aqui
  // produziria BOM DUPLICADO — e o segundo, agora no meio do arquivo, é um
  // caractere inválido que o PowerShell rejeita.
  const texto = bruto.replace(/^﻿/, '').replace(/\r\n/g, '\n');

  const hash = createHash('sha256').update(texto, 'utf8').digest('hex').slice(0, 16);
  resumo.push(`//   ${caminho}  (${texto.length} bytes, sha256:${hash})`);
  partes.push(`export const ${nome}: string = \`${comoTemplate(texto)}\`;`);
}

const conteudo = `// =============================================================================
// GERADO — não edite à mão
// =============================================================================
// Origem:
${resumo.join('\n')}
//
// Regerar:  node scripts/gerar-scripts-embutidos.mjs
//
// A Edge Function serve estes dois arquivos em HTTPS para que o comando de uma
// linha funcione numa loja remota, onde o endpoint local da LAN não existe.
// =============================================================================

${partes.join('\n\n')}
`;

if (soVerificar) {
  let atual = null;
  try { atual = readFileSync(destino, 'utf8'); } catch (_) { /* não existe */ }

  if (atual === conteudo) {
    console.log('scripts-embutidos.ts está em dia');
    process.exit(0);
  }

  console.error('scripts-embutidos.ts ESTA VELHO em relacao aos .ps1 de origem.');
  console.error('Rode: node scripts/gerar-scripts-embutidos.mjs');
  process.exit(1);
}

writeFileSync(destino, conteudo, 'utf8');
console.log(`gerado ${destino}`);
for (const l of resumo) console.log(l.replace('//   ', '  '));
