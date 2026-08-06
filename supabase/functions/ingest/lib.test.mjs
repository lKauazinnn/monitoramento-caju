// =============================================================================
// Testes da lógica pura da Edge Function
// =============================================================================
// Rode com:  node supabase/functions/ingest/lib.test.mjs
//
// Node 24 remove anotações de tipo nativamente, então o lib.ts é importado
// direto sem etapa de build. Cobre exatamente a parte da função que contém
// decisão — o resto do index.ts é encanamento HTTP.
// =============================================================================

import assert from "node:assert/strict";
import {
  extractBearer,
  httpStatusForSqlState,
  logLine,
  routeSuffix,
  safeErrorMessage,
  SQLSTATE_TO_HTTP,
  timingSafeEqual,
  tokenPrefixForLog,
  validateEnvelopeShape,
} from "./lib.ts";

let passou = 0;
const falhas = [];

function teste(nome, fn) {
  try {
    fn();
    passou++;
    console.log(`  ok   ${nome}`);
  } catch (e) {
    falhas.push({ nome, erro: e.message });
    console.log(`  FALHA ${nome}\n       ${e.message}`);
  }
}

console.log("\n== timingSafeEqual ==");

teste("iguais devolvem true", () => {
  assert.equal(timingSafeEqual("segredo-abc-123", "segredo-abc-123"), true);
});

teste("diferentes devolvem false", () => {
  assert.equal(timingSafeEqual("segredo-abc-123", "segredo-abc-124"), false);
});

teste("comprimentos diferentes devolvem false", () => {
  assert.equal(timingSafeEqual("abc", "abcd"), false);
  assert.equal(timingSafeEqual("abcd", "abc"), false);
});

teste("string vazia contra vazia devolve true", () => {
  assert.equal(timingSafeEqual("", ""), true);
});

teste("vazia contra não vazia devolve false", () => {
  assert.equal(timingSafeEqual("", "x"), false);
  assert.equal(timingSafeEqual("x", ""), false);
});

teste("prefixo correto não passa (era o bug do === )", () => {
  // O ponto central: acertar os 14 primeiros caracteres não pode dar true nem
  // responder mais rápido de forma detectável.
  assert.equal(timingSafeEqual("segredo-abc-123", "segredo-abc-12"), false);
});

teste("diferença só no último byte é detectada", () => {
  const a = "a".repeat(63) + "b";
  const b = "a".repeat(63) + "c";
  assert.equal(timingSafeEqual(a, b), false);
});

teste("acentuação e multibyte", () => {
  assert.equal(timingSafeEqual("São Paulo", "São Paulo"), true);
  assert.equal(timingSafeEqual("São Paulo", "Sao Paulo"), false);
});

teste("não faz curto-circuito no primeiro byte diferente", () => {
  // Diferença no primeiro byte com strings longas: o tempo deve ficar na mesma
  // ordem de grandeza de uma diferença no último byte. Limite folgado de 5x
  // para não virar teste instável em máquina compartilhada.
  const n = 4096;
  const base = "x".repeat(n);
  const difPrimeiro = "y" + "x".repeat(n - 1);
  const difUltimo = "x".repeat(n - 1) + "y";

  const medir = (b) => {
    const ini = process.hrtime.bigint();
    for (let i = 0; i < 2000; i++) timingSafeEqual(base, b);
    return Number(process.hrtime.bigint() - ini);
  };

  medir(difPrimeiro); // aquecimento do JIT
  medir(difUltimo);

  const tPrimeiro = medir(difPrimeiro);
  const tUltimo = medir(difUltimo);
  const razao = Math.max(tPrimeiro, tUltimo) / Math.min(tPrimeiro, tUltimo);

  assert.ok(
    razao < 5,
    `tempo variou ${razao.toFixed(2)}x entre diferença no início e no fim ` +
      `(${tPrimeiro} vs ${tUltimo} ns) — indica curto-circuito`,
  );
});

console.log("\n== httpStatusForSqlState (regra 14) ==");

teste("MON01 -> 401", () => assert.equal(httpStatusForSqlState("MON01"), 401));
teste("MON02 -> 429", () => assert.equal(httpStatusForSqlState("MON02"), 429));
teste("MON03 -> 400", () => assert.equal(httpStatusForSqlState("MON03"), 400));
teste("MON04 -> 422", () => assert.equal(httpStatusForSqlState("MON04"), 422));

teste("SQLSTATE desconhecido -> 500, NUNCA 200", () => {
  for (const c of ["23505", "42501", "XX000", "", "MON99", null, undefined, 42, {}]) {
    const s = httpStatusForSqlState(c);
    assert.notEqual(s, 200, `código ${JSON.stringify(c)} devolveu 200`);
    assert.equal(s, 500);
  }
});

teste("nenhum status mapeado é 2xx", () => {
  for (const s of Object.values(SQLSTATE_TO_HTTP)) {
    assert.ok(s >= 400, `status ${s} não é de erro`);
  }
});

console.log("\n== safeErrorMessage ==");

teste("mensagem de MON* é repassada ao agente", () => {
  assert.equal(safeErrorMessage("MON01", "token revogado"), "token revogado");
});

teste("erro interno não vaza detalhe do banco", () => {
  const m = safeErrorMessage("42P01", 'relation "metrics_202609" does not exist');
  assert.equal(m, "erro interno na ingestão");
  assert.ok(!m.includes("metrics_202609"));
});

console.log("\n== extractBearer ==");

teste("Bearer com token", () => {
  assert.equal(extractBearer("Bearer mon_abc123"), "mon_abc123");
});

teste("bearer minúsculo também vale", () => {
  assert.equal(extractBearer("bearer mon_abc123"), "mon_abc123");
});

teste("token cru sem prefixo é repassado (banco decide)", () => {
  assert.equal(extractBearer("mon_abc123"), "mon_abc123");
});

teste("header ausente ou vazio devolve null", () => {
  assert.equal(extractBearer(null), null);
  assert.equal(extractBearer(""), null);
  assert.equal(extractBearer("   "), null);
});

teste("espaços extras são removidos", () => {
  assert.equal(extractBearer("Bearer    mon_abc123   "), "mon_abc123");
});

console.log("\n== validateEnvelopeShape ==");

const envelopeBom = {
  agent_version: "1.0.0",
  sent_at: "2026-08-04T22:00:00Z",
  samples: [{ t: "2026-08-04T22:00:00Z", cpu_pct: 10 }],
};

teste("envelope válido passa", () => {
  assert.deepEqual(validateEnvelopeShape(envelopeBom, 500), { ok: true });
});

teste("array no lugar de objeto é rejeitado", () => {
  assert.equal(validateEnvelopeShape([], 500).ok, false);
});

teste("null é rejeitado", () => {
  assert.equal(validateEnvelopeShape(null, 500).ok, false);
});

teste("agent_version ausente é rejeitado (regra 25)", () => {
  assert.equal(validateEnvelopeShape({ samples: [{}] }, 500).ok, false);
});

teste("agent_version numérico é rejeitado", () => {
  assert.equal(validateEnvelopeShape({ agent_version: 100, samples: [{}] }, 500).ok, false);
});

teste("samples não-array é rejeitado", () => {
  assert.equal(validateEnvelopeShape({ agent_version: "1.0.0", samples: "x" }, 500).ok, false);
});

teste("samples vazio é rejeitado", () => {
  assert.equal(validateEnvelopeShape({ agent_version: "1.0.0", samples: [] }, 500).ok, false);
});

teste("lote acima do teto é rejeitado com o número na mensagem", () => {
  const r = validateEnvelopeShape(
    { agent_version: "1.0.0", samples: new Array(501).fill({}) },
    500,
  );
  assert.equal(r.ok, false);
  assert.ok(r.message.includes("501"));
  assert.ok(r.message.includes("500"));
});

teste("exatamente no teto passa", () => {
  assert.equal(
    validateEnvelopeShape({ agent_version: "1.0.0", samples: new Array(500).fill({}) }, 500).ok,
    true,
  );
});

console.log("\n== log e prefixo de token ==");

teste("logLine é JSON de uma linha com ts e level", () => {
  const linha = logLine("info", "ingest_ok", { accepted: 3 });
  assert.ok(!linha.includes("\n"));
  const o = JSON.parse(linha);
  assert.equal(o.level, "info");
  assert.equal(o.event, "ingest_ok");
  assert.equal(o.accepted, 3);
  assert.ok(!Number.isNaN(Date.parse(o.ts)));
});

teste("tokenPrefixForLog corta em 16 e não registra credencial", () => {
  const token = "mon_" + "a".repeat(64);
  const p = tokenPrefixForLog(token);
  assert.equal(p.length, 16);
  assert.equal(p, "mon_aaaaaaaaaaaa");
  assert.notEqual(p, token);
  assert.ok(token.startsWith(p));
});

teste("tokenPrefixForLog aceita null", () => {
  assert.equal(tokenPrefixForLog(null), null);
});

// -----------------------------------------------------------------------------
// routeSuffix
// -----------------------------------------------------------------------------
// Errar este recorte é a falha mais provável no primeiro deploy, e ela aparece
// como 404 em TUDO — sintoma que não indica a causa. Testado aqui porque não
// precisa de Deno nem de projeto publicado.
teste("routeSuffix: raiz é POST de métricas", () => {
  assert.equal(routeSuffix("/functions/v1/ingest"), "");
  assert.equal(routeSuffix("/functions/v1/ingest/"), "/");
});

teste("routeSuffix: healthz", () => {
  assert.equal(routeSuffix("/functions/v1/ingest/healthz"), "/healthz");
  assert.equal(routeSuffix("/functions/v1/ingest/healthz/"), "/healthz");
});

teste("routeSuffix: scripts servidos em HTTPS", () => {
  assert.equal(routeSuffix("/functions/v1/ingest/agente.ps1"), "/agente.ps1");
  assert.equal(routeSuffix("/functions/v1/ingest/instalar.ps1"), "/instalar.ps1");
});

teste("routeSuffix: caminho do shim local", () => {
  assert.equal(routeSuffix("/ingest"), "");
  assert.equal(routeSuffix("/ingest/healthz"), "/healthz");
});

teste("routeSuffix ancora no ULTIMO /ingest", () => {
  // Com âncora no primeiro, isto sairia como "ao/functions/v1" e a função
  // responderia 404 para uma requisição perfeitamente válida.
  assert.equal(routeSuffix("/ingestao/functions/v1/ingest/healthz"), "/healthz");
});

teste("routeSuffix não confunde /ingestao com /ingest + sufixo", () => {
  // "ao" não começa com "/", então não é sufixo de rota: devolve o caminho
  // inteiro, que não casa com nenhuma rota e vira 404 honesto.
  assert.equal(routeSuffix("/functions/v1/ingestao"), "/functions/v1/ingestao");
});

teste("routeSuffix devolve o caminho quando não há /ingest", () => {
  assert.equal(routeSuffix("/functions/v1/outra"), "/functions/v1/outra");
});

console.log("");
if (falhas.length > 0) {
  console.log(`FALHARAM ${falhas.length} de ${passou + falhas.length} testes:`);
  for (const f of falhas) console.log(`  - ${f.nome}: ${f.erro}`);
  process.exit(1);
}
console.log(`TODOS OS ${passou} TESTES DA LÓGICA PURA PASSARAM.\n`);
