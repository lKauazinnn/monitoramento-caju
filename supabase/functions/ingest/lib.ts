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

  // Relato de comandos executados. Opcional: agente antigo não manda, e um
  // agente antigo tem que continuar ingerindo normalmente.
  if (o.command_results !== undefined) {
    if (!Array.isArray(o.command_results)) {
      return { ok: false, message: "command_results não é array" };
    }

    // Teto próprio. O agente executa no máximo 5 comandos por ciclo; um lote
    // com centenas de resultados é agente adulterado ou defeituoso, e o banco
    // não é o lugar de descobrir isso.
    if (o.command_results.length > 50) {
      return { ok: false, message: "command_results acima de 50 itens" };
    }

    for (const r of o.command_results) {
      if (r === null || typeof r !== "object" || Array.isArray(r)) {
        return { ok: false, message: "command_results tem item que não é objeto" };
      }
      const item = r as Record<string, unknown>;
      // O id é UUID: validar aqui evita que uma string qualquer chegue ao cast
      // no SQL, onde viraria erro 500 em vez de 400.
      if (typeof item.command_id !== "string" ||
          !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(item.command_id)) {
        return { ok: false, message: "command_results tem command_id inválido" };
      }
      if (typeof item.ok !== "boolean") {
        return { ok: false, message: "command_results tem item sem 'ok' booleano" };
      }
    }
  }

  // Endereço da placa, para Wake-on-LAN. Opcional: agente antigo não manda.
  if (o.network !== undefined) {
    if (o.network === null || typeof o.network !== "object" || Array.isArray(o.network)) {
      return { ok: false, message: "network não é objeto" };
    }
    const mac = (o.network as Record<string, unknown>).mac;
    // `null` é legítimo: máquina só com Wi-Fi não tem MAC cabeado para reportar.
    if (mac !== undefined && mac !== null) {
      if (typeof mac !== "string" || mac.length > 32) {
        return { ok: false, message: "network.mac inválido" };
      }
    }
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

/**
 * Sufixo de rota, a partir do caminho completo da requisição.
 *
 * A plataforma serve a função em `/functions/v1/ingest`, e é o que vem DEPOIS
 * disso que decide a rota. Vive aqui, e não dentro do `Deno.serve`, para poder
 * ser testado sem Deno: errar este recorte é a falha mais provável no primeiro
 * deploy, e ela se manifesta como 404 em tudo — sintoma que não diz onde está o
 * problema.
 *
 * Casos que precisam funcionar:
 *   /functions/v1/ingest              -> ""           (POST de métricas)
 *   /functions/v1/ingest/            -> "/"           (idem, com barra)
 *   /functions/v1/ingest/healthz     -> "/healthz"
 *   /functions/v1/ingest/agente.ps1  -> "/agente.ps1"
 *   /ingest                          -> ""            (shim local)
 */
export function routeSuffix(pathname: string): string {
  // Âncora no ÚLTIMO "/ingest" e não no primeiro: um projeto hospedado sob um
  // caminho que contenha "ingest" (por exemplo /ingestao/functions/v1/ingest)
  // faria o recorte no lugar errado, e a rota sairia como "ao/functions/v1".
  const i = pathname.lastIndexOf("/ingest");
  if (i < 0) return pathname;

  const resto = pathname.slice(i + "/ingest".length);

  // "/ingest" e "/ingest/" são a mesma rota: a raiz.
  if (resto === "" || resto === "/") return resto;

  // "/ingestao" NÃO é "/ingest" com sufixo "ao": sem isto, um caminho parecido
  // cairia numa rota inexistente em vez de 404 honesto.
  if (!resto.startsWith("/")) return pathname;

  return resto.replace(/\/+$/, "");
}
