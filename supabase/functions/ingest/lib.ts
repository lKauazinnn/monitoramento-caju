// =============================================================================
// Lógica pura da Edge Function de ingestão
// =============================================================================
// Isolada em módulo próprio de propósito: é a única parte da função que contém
// decisão, e assim ela é testável com `node lib.test.mjs` sem subir Deno nem
// Supabase. O index.ts fica sendo apenas encanamento.
// =============================================================================

const ENC = new TextEncoder();

/**
 * Comparação em tempo constante (regra 6).
 *
 * Um `===` sobre segredo vaza, pelo tempo de resposta, quantos caracteres
 * iniciais o atacante acertou — o que transforma força bruta de 62^32 em
 * 62*32 tentativas. Aqui o XOR percorre sempre o comprimento máximo e só o
 * acumulador decide o resultado.
 *
 * O comprimento em si vaza (o laço tem tamanho max(a,b)), e isso é aceito: o
 * tamanho do segredo não é a parte secreta.
 */
export function timingSafeEqual(a: string, b: string): boolean {
  const ea = ENC.encode(a);
  const eb = ENC.encode(b);
  const n = Math.max(ea.length, eb.length);

  // Diferença de comprimento entra no acumulador em vez de virar retorno
  // antecipado.
  let diff = ea.length ^ eb.length;

  for (let i = 0; i < n; i++) {
    const x = i < ea.length ? ea[i] : 0;
    const y = i < eb.length ? eb[i] : 0;
    diff |= x ^ y;
  }

  return diff === 0;
}

/**
 * SQLSTATE customizado -> status HTTP.
 *
 * Regra 14: o default é 500, nunca 200. Uma função que não sabe o que
 * aconteceu não pode dizer ao agente que deu certo, senão o agente apaga o
 * spool e o dado do incidente morre.
 */
export const SQLSTATE_TO_HTTP: Readonly<Record<string, number>> = Object.freeze({
  MON01: 401, // token inválido, revogado, expirado, máquina/loja inativa
  MON02: 429, // rate limit por agente
  MON03: 400, // payload malformado
  MON04: 422, // lote inteiro fora da janela temporal
});

export function httpStatusForSqlState(code: unknown): number {
  if (typeof code === "string" && code in SQLSTATE_TO_HTTP) {
    return SQLSTATE_TO_HTTP[code];
  }
  return 500;
}

/**
 * Mensagens de erro MON* são escritas para o operador e podem ir para o
 * agente. Qualquer outra coisa é detalhe interno do banco e fica só no log.
 */
export function safeErrorMessage(code: unknown, message: unknown): string {
  if (typeof code === "string" && code in SQLSTATE_TO_HTTP) {
    return typeof message === "string" ? message : "erro de ingestão";
  }
  return "erro interno na ingestão";
}

/**
 * Extrai o token do header Authorization. Aceita `Bearer <token>` e o token
 * cru, porque um agente mal configurado enviando o token sem prefixo deve
 * receber 401 do banco (token inválido) e não 400 aqui — o diagnóstico fica
 * no lugar certo.
 */
export function extractBearer(header: string | null): string | null {
  if (!header) return null;
  const trimmed = header.trim();
  if (trimmed.length === 0) return null;
  const m = /^Bearer\s+(.+)$/i.exec(trimmed);
  return m ? m[1].trim() : trimmed;
}

/**
 * Validação de FORMA do envelope, antes de gastar uma ida ao banco.
 *
 * Deliberadamente rasa: valida só o que evita round-trip inútil. A validação
 * de CONTEÚDO (janela temporal, faixas, tipos de cada campo) vive no
 * register_metrics, onde é atômica com a gravação e onde já existe suíte de
 * teste. Duplicar regra em duas linguagens é como as duas divergem.
 */
export function validateEnvelopeShape(
  body: unknown,
  maxBatch: number,
): { ok: true } | { ok: false; message: string } {
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    return { ok: false, message: "corpo deve ser um objeto JSON" };
  }

  const o = body as Record<string, unknown>;

  if (typeof o.agent_version !== "string" || o.agent_version.length === 0) {
    return { ok: false, message: "agent_version ausente ou não é string" };
  }

  if (!Array.isArray(o.samples)) {
    return { ok: false, message: "samples ausente ou não é array" };
  }

  if (o.samples.length === 0) {
    return { ok: false, message: "samples vazio" };
  }

  if (o.samples.length > maxBatch) {
    return {
      ok: false,
      message: `lote com ${o.samples.length} amostras excede o teto de ${maxBatch}`,
    };
  }

  return { ok: true };
}

/** Log estruturado em uma linha (regra 24). NUNCA recebe o token. */
export function logLine(
  level: "info" | "warn" | "error",
  event: string,
  fields: Record<string, unknown> = {},
): string {
  return JSON.stringify({
    ts: new Date().toISOString(),
    level,
    event,
    ...fields,
  });
}

/**
 * Só os 16 primeiros caracteres do token vão para o log: é exatamente o
 * `token_prefix` que já está em texto claro em agent_tokens, então identifica
 * o agente sem registrar credencial.
 */
export function tokenPrefixForLog(token: string | null): string | null {
  if (!token) return null;
  return token.slice(0, 16);
}
