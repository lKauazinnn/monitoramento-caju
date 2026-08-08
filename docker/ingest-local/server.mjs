// =============================================================================
// Endpoint de ingestão para a stack local
// =============================================================================
// Faz LOCALMENTE o mesmo papel da Edge Function da Fase 2, e existe por uma razão
// de segurança, não de conveniência.
//
// Sem ele, um agente numa outra máquina precisaria chamar
// /rpc/ingest_batch direto no PostgREST — e esse RPC só é executável por
// service_role. Ou seja, cada PC de loja carregaria no disco uma credencial de
// acesso TOTAL ao banco. É exatamente o que a regra 1 proíbe.
//
// Com este servidor no meio:
//   * o agente carrega SOMENTE o token da própria máquina, revogável individualmente
//   * a credencial de service_role fica aqui, do lado servidor, em variável de ambiente
//   * o contrato HTTP é IDÊNTICO ao de produção, então o agente não muda ao migrar
//
// A lógica de decisão é importada de supabase/functions/ingest/lib.ts — o MESMO
// arquivo que a Edge Function usa. Reescrevê-la aqui criaria duas versões da
// mesma regra, que é como as duas divergem.
// =============================================================================

import { createServer } from 'node:http';
import { createHmac } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import {
  extractBearer,
  httpStatusForSqlState,
  logLine,
  safeErrorMessage,
  timingSafeEqual,
  tokenPrefixForLog,
  validateEnvelopeShape,
} from './lib.ts';

const PORTA = Number(process.env.PORT ?? 3001);
const POSTGREST = process.env.POSTGREST_URL ?? 'http://rest:3000';
const JWT_SECRET = process.env.JWT_SECRET ?? '';
const SEGREDO = process.env.INGEST_SHARED_SECRET ?? '';

const MAX_CORPO = 4 * 1024 * 1024;
const MAX_LOTE_FORMA = 5000;
const TIMEOUT_DB = 15_000;

// Falha na PARTIDA, não na primeira requisição. Um endpoint de ingestão sem
// segredo configurado ficaria aberto, e a regra 6 existe para impedir isso.
const problemas = [];
if (!JWT_SECRET) problemas.push('JWT_SECRET');
if (!SEGREDO) problemas.push('INGEST_SHARED_SECRET');
if (SEGREDO && SEGREDO.length < 24) problemas.push('INGEST_SHARED_SECRET com menos de 24 caracteres');

if (problemas.length > 0) {
  console.error(logLine('error', 'config_invalida', { faltando: problemas }));
  process.exit(1);
}

// -----------------------------------------------------------------------------
// Token de service_role
// -----------------------------------------------------------------------------
// Gerado AQUI a partir do JWT_SECRET, em vez de recebido pronto. Um token pronto
// passado por variável de ambiente expira e o serviço para de funcionar sem
// explicação; gerando sob demanda com validade curta, isso não acontece.
function tokenServico() {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const agora = Math.floor(Date.now() / 1000);
  const cabecalho = b64({ alg: 'HS256', typ: 'JWT' });
  const corpo = b64({
    aud: 'authenticated',
    role: 'service_role',
    iat: agora,
    exp: agora + 300,   // 5 minutos: só precisa durar a requisição
  });
  const assinatura = createHmac('sha256', JWT_SECRET)
    .update(`${cabecalho}.${corpo}`).digest('base64url');
  return `${cabecalho}.${corpo}.${assinatura}`;
}

// -----------------------------------------------------------------------------
function json(res, status, corpo, extra = {}) {
  const texto = JSON.stringify(corpo);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(texto),
    ...extra,
  });
  res.end(texto);
}

function lerCorpo(req) {
  return new Promise((resolve, reject) => {
    let tamanho = 0;
    const partes = [];

    req.on('data', (c) => {
      tamanho += c.length;
      if (tamanho > MAX_CORPO) {
        reject(Object.assign(new Error('corpo grande demais'), { grande: true }));
        req.destroy();
        return;
      }
      partes.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(partes).toString('utf8')));
    req.on('error', reject);
  });
}

async function chamarRpc(fn, args) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_DB);

  try {
    const tok = tokenServico();
    const r = await fetch(`${POSTGREST}/rpc/${fn}`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${tok}`,
        apikey: tok,
        'content-type': 'application/json',
      },
      body: JSON.stringify(args),
      signal: ctrl.signal,
    });

    const texto = await r.text();
    if (r.ok) return { ok: true, dados: texto ? JSON.parse(texto) : null };

    // PostgREST devolve { code, message, ... }; `code` é o SQLSTATE, que é como
    // MON01..MON04 chegam até aqui.
    let code;
    let message = texto;
    try {
      const err = JSON.parse(texto);
      code = err.code;
      message = err.message ?? texto;
    } catch { /* corpo não-JSON */ }

    return { ok: false, status: httpStatusForSqlState(code), code, message };
  } catch (e) {
    const abortado = e.name === 'AbortError';
    return {
      ok: false,
      status: abortado ? 504 : 502,
      message: abortado ? `timeout de ${TIMEOUT_DB}ms no banco` : String(e),
    };
  } finally {
    clearTimeout(timer);
  }
}

// -----------------------------------------------------------------------------
const servidor = createServer(async (req, res) => {
  // CORS não é necessário: quem chama aqui é agente, não navegador. Mas OPTIONS
  // é respondido para não confundir quem testar com ferramenta de API.
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'access-control-allow-origin': '*',
      'access-control-allow-methods': 'POST, GET, OPTIONS',
      'access-control-allow-headers': 'authorization, content-type, x-monitor-secret',
    });
    res.end();
    return;
  }

  const url = new URL(req.url, 'http://local');
  const rota = url.pathname.replace(/\/+$/, '') || '/';

  try {
    // ---------------------------------------------------------------- healthz
    if (req.method === 'GET' && (rota === '/healthz' || rota === '/ingest/healthz')) {
      const segredo = req.headers['x-monitor-secret'];
      const autorizado = typeof segredo === 'string' && timingSafeEqual(segredo, SEGREDO);

      // Sem o segredo: apenas liveness. Nada sobre o parque vaza para quem só
      // conhece a URL.
      if (!autorizado) {
        json(res, 200, { ok: true, service: 'ingest-local' });
        return;
      }

      const r = await chamarRpc('ingest_health', {});
      if (!r.ok) {
        json(res, 503, { ok: false, error: 'banco inacessível' });
        return;
      }
      json(res, 200, { ok: true, service: 'ingest-local', db: r.dados });
      return;
    }

    // ------------------------------------------------- arquivos de instalação
    // Servidos SEM segredo, de propósito: são o script do agente e o instalador,
    // que estão públicos no repositório do projeto. O que é secreto é o token, e
    // ele NÃO está aqui — vem no comando que o dashboard monta.
    //
    // Servir por este endpoint, e não pelo nginx do dashboard, é o que permite
    // manter o dashboard restrito a loopback: a única porta na rede continua
    // sendo esta.
    if (req.method === 'GET' && (rota === '/agente.ps1' || rota === '/instalar.ps1')) {
      const arquivo = rota === '/agente.ps1' ? '/app/agente.ps1' : '/app/instalar.ps1';
      try {
        const bruto = await readFile(arquivo);

        // SEM O BOM. Os .ps1 em disco carregam BOM UTF-8 de propósito — sem ele
        // o PowerShell 5.1 lê o ARQUIVO como ANSI e um acento quebra a análise
        // sintática. Mas o comando de instalação não salva este conteúdo em
        // disco: ele faz `[scriptblock]::Create((irm ...))`, e aí o BOM vira o
        // primeiro CARACTERE do texto. Com um caractere antes dele, `param()`
        // deixa de ser a primeira instrução do bloco e o PowerShell recusa:
        //
        //   Atributo 'CmdletBinding' inesperado.
        //   Token 'param' inesperado na expressão ou instrução.
        //
        // O agente que o instalador grava em disco recebe BOM de volta lá, no
        // WriteAllText com UTF8Encoding($true) — que é onde ele faz falta.
        const temBom = bruto[0] === 0xEF && bruto[1] === 0xBB && bruto[2] === 0xBF;
        const conteudo = temBom ? bruto.subarray(3) : bruto;

        res.writeHead(200, {
          'content-type': 'text/plain; charset=utf-8',
          'content-length': conteudo.length,
          'cache-control': 'no-store',
        });
        res.end(conteudo);
      } catch (e) {
        console.error(logLine('error', 'arquivo_indisponivel', { rota, erro: String(e) }));
        json(res, 404, { ok: false, error: `${rota} não disponível neste servidor` });
      }
      return;
    }

    // ----------------------------------------------------------------- ingest
    if (req.method === 'POST' && (rota === '/' || rota === '/ingest')) {
      const t0 = Date.now();

      // 1. segredo compartilhado, em tempo constante, ANTES de tudo (regra 6)
      const segredo = req.headers['x-monitor-secret'];
      if (typeof segredo !== 'string' || !timingSafeEqual(segredo, SEGREDO)) {
        console.warn(logLine('warn', 'segredo_invalido', {
          ip: req.socket.remoteAddress,
          tem_header: segredo !== undefined,
        }));
        // Mensagem genérica: não revela se o problema é o segredo ou o token.
        json(res, 401, { ok: false, error: 'não autorizado' });
        return;
      }

      // 2. token DA MÁQUINA
      const token = extractBearer(req.headers.authorization ?? null);
      if (!token) {
        json(res, 401, { ok: false, error: 'header Authorization ausente' });
        return;
      }
      const prefixo = tokenPrefixForLog(token);

      // 3. corpo
      let bruto;
      try {
        bruto = await lerCorpo(req);
      } catch (e) {
        json(res, e.grande ? 413 : 400, { ok: false, error: e.message });
        return;
      }

      let corpo;
      try {
        corpo = JSON.parse(bruto);
      } catch {
        json(res, 400, { ok: false, error: 'corpo não é JSON válido' });
        return;
      }

      const forma = validateEnvelopeShape(corpo, MAX_LOTE_FORMA);
      if (!forma.ok) {
        console.warn(logLine('warn', 'envelope_invalido', { token_prefix: prefixo, motivo: forma.message }));
        json(res, 400, { ok: false, error: forma.message });
        return;
      }

      // 4. banco: token + rate limit + gravação, atomicamente
      const r = await chamarRpc('ingest_batch', { p_token: token, p_payload: corpo });
      const ms = Date.now() - t0;

      if (!r.ok) {
        const nivel = r.status >= 500 ? 'error' : 'warn';
        console[nivel === 'error' ? 'error' : 'warn'](logLine(nivel, 'ingest_rejeitado', {
          token_prefix: prefixo, status: r.status, sqlstate: r.code, message: r.message, ms,
        }));

        const extra = r.status === 429 ? { 'retry-after': '60' } : {};
        // Regra 14: erro é erro. Daqui não sai 200 em nenhum caminho.
        json(res, r.status, {
          ok: false,
          error: safeErrorMessage(r.code, r.message),
          code: r.code ?? null,
        }, extra);
        return;
      }

      const d = r.dados ?? {};
      console.info(logLine('info', 'ingest_ok', {
        token_prefix: prefixo,
        machine_id: d.machine_id,
        received: d.received,
        accepted: d.accepted,
        duplicates: d.duplicates,
        clock_drift_seconds: d.clock_drift_seconds,
        ms,
      }));

      // 5. a fila de comandos, na mesma resposta — espelha a Edge Function.
      // Chamada separada e DEPOIS da ingestão: se a fila falhar, a telemetria
      // já está gravada e o agente só fica sem comando neste ciclo.
      let comandos = [];
      const s = await chamarRpc('agente_sincronizar', {
        p_token: token,
        p_resultados: Array.isArray(corpo.command_results) ? corpo.command_results : [],
      });

      if (s.ok) {
        comandos = s.dados?.comandos ?? [];
        if (comandos.length > 0) {
          console.info(logLine('info', 'comandos_entregues', {
            token_prefix: prefixo,
            machine_id: d.machine_id,
            // Só o tipo: params carregam nome de serviço e caminho.
            kinds: comandos.map((c) => c.kind),
          }));
        }
      } else {
        console.warn(logLine('warn', 'sincronizar_falhou', {
          token_prefix: prefixo, status: s.status, sqlstate: s.code, message: s.message,
        }));
      }

      json(res, 200, { ...d, comandos });
      return;
    }

    json(res, 404, { ok: false, error: `rota não encontrada: ${req.method} ${rota}` });
  } catch (e) {
    // Última rede: exceção não tratada não pode virar 200 nem derrubar o
    // processo para os outros agentes (regra 20).
    console.error(logLine('error', 'excecao_nao_tratada', { erro: String(e) }));
    try { json(res, 500, { ok: false, error: 'erro interno' }); } catch { /* resposta já enviada */ }
  }
});

// Escuta em todas as interfaces: é isto que permite agentes de OUTRAS maquinas
// alcancarem a ingestao. A porta do PostgreSQL continua nao publicada (regra 8),
// e o PostgREST continua so em loopback — quem vem de fora passa por aqui, e aqui
// exige o segredo compartilhado e o token da maquina.
servidor.listen(PORTA, '0.0.0.0', () => {
  console.info(logLine('info', 'ingest_local_no_ar', {
    porta: PORTA,
    postgrest: POSTGREST,
    segredo: `${SEGREDO.length} caracteres`,
  }));
});
