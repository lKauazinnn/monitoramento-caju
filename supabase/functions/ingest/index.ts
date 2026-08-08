// =============================================================================
// Edge Function — ingestão de métricas
// =============================================================================
//   POST /ingest    grava um lote de amostras
//   GET  /healthz   liveness (sem segredo) ou diagnóstico (com segredo)
//
// DEPLOY (a flag --no-verify-jwt é obrigatória e por isso a regra 6 existe):
//
//   supabase functions deploy ingest --no-verify-jwt
//
// Os agentes não possuem JWT do Supabase — eles têm o token próprio da máquina.
// Por isso a verificação de JWT do gateway é desligada, e em troca ESTA função
// valida um segredo compartilhado próprio em tempo constante ANTES de qualquer
// outra coisa. Sem esse segredo a função responde 401 e nem toca no banco.
//
// Segredos (Supabase > Edge Functions > Secrets — nunca no repositório):
//   SUPABASE_URL              injetado pela plataforma
//   SUPABASE_SERVICE_ROLE_KEY injetado pela plataforma; só existe aqui, no servidor
//   INGEST_SHARED_SECRET      definido por você; vai também no config.json do agente
//
// Zero dependências externas de propósito: `fetch` direto no PostgREST. Um
// import de CDN é uma superfície de supply chain e um cold start a mais.
// =============================================================================

import {
  extractBearer,
  httpStatusForSqlState,
  logLine,
  routeSuffix,
  safeErrorMessage,
  timingSafeEqual,
  tokenPrefixForLog,
  validateEnvelopeShape,
} from "./lib.ts";

import { AGENTE_PS1, INSTALAR_PS1 } from "./scripts-embutidos.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const INGEST_SHARED_SECRET = Deno.env.get("INGEST_SHARED_SECRET") ?? "";

// Teto local só para não desserializar um corpo absurdo. O teto real é
// app_settings.ingest_max_batch_size, aplicado no banco.
const MAX_BODY_BYTES = 4 * 1024 * 1024;
const MAX_BATCH_SHAPE = 5000;
const DB_TIMEOUT_MS = 15_000;

// Falha na PARTIDA, não na primeira requisição: uma função sem segredo
// configurado ficaria aberta, e é exatamente isso que a regra 6 proíbe.
// Sem fallback com valor padrão (regra 8, mesmo princípio do `${VAR:?}`).
const CONFIG_ERROR: string | null = (() => {
  const faltando: string[] = [];
  if (!SUPABASE_URL) faltando.push("SUPABASE_URL");
  if (!SERVICE_ROLE_KEY) faltando.push("SUPABASE_SERVICE_ROLE_KEY");
  if (!INGEST_SHARED_SECRET) faltando.push("INGEST_SHARED_SECRET");
  if (faltando.length > 0) return `configuração ausente: ${faltando.join(", ")}`;
  if (INGEST_SHARED_SECRET.length < 24) {
    return "INGEST_SHARED_SECRET com menos de 24 caracteres";
  }
  return null;
})();

if (CONFIG_ERROR) {
  console.error(logLine("error", "config_invalida", { motivo: CONFIG_ERROR }));
}

const JSON_HEADERS = { "content-type": "application/json; charset=utf-8" };

function json(body: unknown, status: number, extra: HeadersInit = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...JSON_HEADERS, ...extra },
  });
}

/** Chama um RPC no PostgREST com a service_role (server-side only). */
async function callRpc(
  fn: string,
  args: Record<string, unknown>,
): Promise<{ ok: true; data: unknown } | { ok: false; status: number; code?: string; message: string }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), DB_TIMEOUT_MS);

  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
      method: "POST",
      headers: {
        apikey: SERVICE_ROLE_KEY,
        authorization: `Bearer ${SERVICE_ROLE_KEY}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(args),
      signal: controller.signal,
    });

    const texto = await res.text();

    if (res.ok) {
      return { ok: true, data: texto ? JSON.parse(texto) : null };
    }

    // PostgREST devolve { code, message, details, hint }. `code` é o SQLSTATE,
    // que é justamente como MON01..MON04 chegam até aqui.
    let code: string | undefined;
    let message = texto;
    try {
      const err = JSON.parse(texto);
      code = err.code;
      message = err.message ?? texto;
    } catch {
      // corpo não-JSON: mantém o texto cru para o log
    }

    return { ok: false, status: httpStatusForSqlState(code), code, message };
  } catch (e) {
    const abortado = e instanceof DOMException && e.name === "AbortError";
    return {
      ok: false,
      status: abortado ? 504 : 502,
      message: abortado ? `timeout de ${DB_TIMEOUT_MS}ms no banco` : String(e),
    };
  } finally {
    clearTimeout(timer);
  }
}

// -----------------------------------------------------------------------------
// GET /healthz
// -----------------------------------------------------------------------------
async function handleHealthz(req: Request): Promise<Response> {
  const segredo = req.headers.get("x-monitor-secret");
  const autorizado = !CONFIG_ERROR && segredo !== null &&
    timingSafeEqual(segredo, INGEST_SHARED_SECRET);

  // Sem segredo: apenas liveness, para monitor de uptime externo. Nada sobre o
  // parque de máquinas vaza para quem só sabe a URL.
  if (!autorizado) {
    return json({ ok: CONFIG_ERROR === null, service: "ingest" }, CONFIG_ERROR ? 503 : 200);
  }

  const r = await callRpc("ingest_health", {});

  if (!r.ok) {
    console.error(logLine("error", "healthz_falhou", { status: r.status, message: r.message }));
    return json({ ok: false, error: "banco inacessível" }, 503);
  }

  return json({ ok: true, service: "ingest", db: r.data }, 200);
}

// -----------------------------------------------------------------------------
// GET /agente.ps1  e  GET /instalar.ps1
// -----------------------------------------------------------------------------
// Numa loja remota o comando de instalação é `irm https://.../instalar.ps1`. Esse
// endereço precisa existir em HTTPS, e esta função é o único componente do
// projeto que já está publicado em HTTPS — subir um segundo serviço para servir
// dois arquivos de texto seria uma peça a mais para manter no ar sem motivo.
//
// SEM SEGREDO, de propósito. Três razões:
//   1. o `irm` do comando de uma linha não manda header nenhum;
//   2. não há segredo NO conteúdo: token e segredo chegam como argumento, e o
//      script é o mesmo que está no repositório;
//   3. saber baixar o instalador não dá acesso a nada — a ingestão continua
//      exigindo o segredo compartilhado E o token da máquina.
//
// SEM BOM, e isto foi um erro meu na primeira versão.
//
// O raciocínio de lá estava certo para o caso errado: o PowerShell 5.1 realmente
// lê um .ps1 SEM BOM como ANSI, e um acento vira caractere que quebra a análise
// sintática. Só que isso vale para arquivo em DISCO. Aqui o conteúdo vai para
// `[scriptblock]::Create((irm ...))`, e o BOM vira o primeiro CARACTERE do texto
// — com algo antes dele, `param()` deixa de ser a primeira instrução do bloco:
//
//   Atributo 'CmdletBinding' inesperado.
//   Token 'param' inesperado na expressão ou instrução.
//
// Quem baixar com `Invoke-WebRequest -OutFile` e rodar do disco continua bem: o
// charset=utf-8 do header já diz como decodificar. E o agente que o instalador
// grava recebe BOM lá, no WriteAllText com UTF8Encoding($true), que é o lugar
// onde ele faz falta.
function servirScript(nome: "agente" | "instalar"): Response {
  const corpo = nome === "agente" ? AGENTE_PS1 : INSTALAR_PS1;

  return new Response(corpo, {
    status: 200,
    headers: {
      "content-type": "text/plain; charset=utf-8",
      // Curto de propósito: ao corrigir o agente, a loja seguinte já pega a
      // versão nova sem ninguém precisar limpar cache em lugar nenhum.
      "cache-control": "public, max-age=300",
      "x-content-type-options": "nosniff",
    },
  });
}

// -----------------------------------------------------------------------------
// POST /ingest
// -----------------------------------------------------------------------------
async function handleIngest(req: Request): Promise<Response> {
  const t0 = Date.now();

  // ---- 1. segredo compartilhado, em tempo constante, antes de tudo (regra 6)
  const segredo = req.headers.get("x-monitor-secret");
  if (segredo === null || !timingSafeEqual(segredo, INGEST_SHARED_SECRET)) {
    console.warn(logLine("warn", "segredo_invalido", {
      ip: req.headers.get("x-forwarded-for"),
      tem_header: segredo !== null,
    }));
    // Mensagem genérica: não confirma se o problema é o segredo ou o token.
    return json({ ok: false, error: "não autorizado" }, 401);
  }

  // ---- 2. token da máquina
  const token = extractBearer(req.headers.get("authorization"));
  if (!token) {
    return json({ ok: false, error: "header Authorization ausente" }, 401);
  }
  const prefixo = tokenPrefixForLog(token);

  // ---- 3. corpo
  const tamanho = Number(req.headers.get("content-length") ?? "0");
  if (tamanho > MAX_BODY_BYTES) {
    return json({ ok: false, error: `corpo acima de ${MAX_BODY_BYTES} bytes` }, 413);
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "corpo não é JSON válido" }, 400);
  }

  const forma = validateEnvelopeShape(body, MAX_BATCH_SHAPE);
  if (!forma.ok) {
    console.warn(logLine("warn", "envelope_invalido", {
      token_prefix: prefixo,
      motivo: forma.message,
    }));
    return json({ ok: false, error: forma.message }, 400);
  }

  // ---- 4. banco: token + rate limit + gravação, atomicamente
  const r = await callRpc("ingest_batch", { p_token: token, p_payload: body });

  const ms = Date.now() - t0;

  if (!r.ok) {
    // 5xx é problema nosso e vai completo para o log; 4xx é problema do agente
    // e a mensagem já é dirigida a ele.
    const nivel = r.status >= 500 ? "error" : "warn";
    console[nivel === "error" ? "error" : "warn"](logLine(nivel, "ingest_rejeitado", {
      token_prefix: prefixo,
      status: r.status,
      sqlstate: r.code,
      message: r.message,
      ms,
    }));

    const headers: Record<string, string> = {};
    if (r.status === 429) headers["retry-after"] = "60";

    // Regra 14: erro é erro. Em nenhum caminho daqui sai 200.
    return json(
      { ok: false, error: safeErrorMessage(r.code, r.message), code: r.code ?? null },
      r.status,
      headers,
    );
  }

  const d = (r.data ?? {}) as Record<string, unknown>;

  console.info(logLine("info", "ingest_ok", {
    token_prefix: prefixo,
    machine_id: d.machine_id,
    received: d.received,
    accepted: d.accepted,
    duplicates: d.duplicates,
    out_of_window: d.out_of_window,
    clock_drift_seconds: d.clock_drift_seconds,
    ms,
  }));

  // ---- 5. a fila de comandos, na MESMA resposta
  // O agente só faz conexão de saída: não há rota daqui até o PC da loja. Então
  // ele pergunta, e a pergunta pega carona neste POST que já acontece — sem
  // canal novo, sem porta nova, autenticado pelo mesmo token da máquina.
  //
  // DEPOIS da ingestão, e em chamada SEPARADA de propósito: `ingest_batch` é o
  // caminho que não pode quebrar. Se a fila falhar, a telemetria já está
  // gravada e o agente só fica sem comando neste ciclo.
  const resultados = (body as Record<string, unknown>)?.command_results;
  const s = await callRpc("agente_sincronizar", {
    p_token: token,
    p_resultados: Array.isArray(resultados) ? resultados : [],
  });

  if (!s.ok) {
    console.warn(logLine("warn", "sincronizar_falhou", {
      token_prefix: prefixo,
      status: s.status,
      sqlstate: s.code,
      message: s.message,
    }));
    return json({ ...d, comandos: [] }, 200);
  }

  const comandos = (s.data as Record<string, unknown>)?.comandos ?? [];

  if (Array.isArray(comandos) && comandos.length > 0) {
    console.info(logLine("info", "comandos_entregues", {
      token_prefix: prefixo,
      machine_id: d.machine_id,
      // Só o tipo. O payload pode conter nome de serviço e caminho, e log de
      // Edge Function é retido fora do nosso controle.
      kinds: comandos.map((c) => (c as Record<string, unknown>).kind),
    }));
  }

  return json({ ...d, comandos }, 200);
}

// -----------------------------------------------------------------------------
// Roteamento
// -----------------------------------------------------------------------------
Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  // A plataforma serve em /functions/v1/<nome>; o sufixo é o que importa.
  // Recorte em lib.ts, testado sem Deno em lib.test.mjs.
  const rota = routeSuffix(url.pathname) || "/";

  try {
    if (req.method === "GET" && (rota === "/healthz" || rota === "/healthz/")) {
      return await handleHealthz(req);
    }

    if (req.method === "GET" && rota === "/agente.ps1") return servirScript("agente");
    if (req.method === "GET" && rota === "/instalar.ps1") return servirScript("instalar");

    if (req.method === "POST" && (rota === "/" || rota === "")) {
      if (CONFIG_ERROR) {
        console.error(logLine("error", "requisicao_com_config_invalida", { motivo: CONFIG_ERROR }));
        return json({ ok: false, error: "serviço mal configurado" }, 503);
      }
      return await handleIngest(req);
    }

    return json({ ok: false, error: `rota não encontrada: ${req.method} ${rota}` }, 404);
  } catch (e) {
    // Última rede: exceção não tratada não pode virar 200 nem derrubar o worker
    // para os outros agentes (regra 20).
    console.error(logLine("error", "excecao_nao_tratada", { erro: String(e) }));
    return json({ ok: false, error: "erro interno" }, 500);
  }
});
