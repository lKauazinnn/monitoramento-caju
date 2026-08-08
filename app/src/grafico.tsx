// =============================================================================
// Gráficos em SVG
// =============================================================================
// SVG inline, sem biblioteca. Não é economia: a CSP do painel é
// `default-src 'none'`, então um script de terceiro simplesmente não carrega —
// e uma loja com link ruim precisa abrir o painel mesmo assim.
//
// Duas peças: a área de duas séries (carga da frota) e a série compacta de 52px
// (gaveta do host). As duas tratam BURACO como buraco: minuto sem amostra não
// vira linha reta ligando os dois lados, porque isso desenharia uma continuidade
// que não existe — e num painel de monitoramento, o buraco é justamente o dado.
// =============================================================================

import * as React from 'react';

export interface Ponto { t: number; v: number | null; }

/** Caminho SVG que QUEBRA no nulo, em vez de atravessá-lo. */
function caminho(pts: Ponto[], x: (t: number) => number, y: (v: number) => number): string {
  let d = '';
  let abertura = true;
  for (const p of pts) {
    if (p.v === null || Number.isNaN(p.v)) { abertura = true; continue; }
    d += `${abertura ? 'M' : 'L'}${x(p.t).toFixed(1)} ${y(p.v).toFixed(1)} `;
    abertura = false;
  }
  return d.trim();
}

// -----------------------------------------------------------------------------
// Carga da frota
// -----------------------------------------------------------------------------

export interface SerieNomeada {
  nome: string;
  cor: string;
  pontos: Ponto[];
}

export function GraficoDeCarga({
  series, altura = 190, marcasX = [],
}: { series: SerieNomeada[]; altura?: number; marcasX?: { t: number; rotulo: string }[] }) {
  const larg = 900;
  const pad = { esq: 34, dir: 10, topo: 12, base: 22 };

  const todos = series.flatMap((s) => s.pontos);
  const comValor = todos.filter((p) => p.v !== null) as { t: number; v: number }[];

  if (comValor.length === 0) {
    return (
      <div style={{
        height: altura, display: 'grid', placeItems: 'center',
        fontSize: 11.5, color: 'var(--fg3)',
        border: '1px dashed var(--bd2)', borderRadius: 'var(--r-m)',
      }}>
        Sem amostras no período.
      </div>
    );
  }

  const t0 = Math.min(...comValor.map((p) => p.t));
  const t1 = Math.max(...comValor.map((p) => p.t));
  const span = Math.max(1, t1 - t0);

  const x = (t: number) => pad.esq + ((t - t0) / span) * (larg - pad.esq - pad.dir);
  const y = (v: number) => pad.topo + (1 - v / 100) * (altura - pad.topo - pad.base);

  return (
    <svg viewBox={`0 0 ${larg} ${altura}`} width="100%" height={altura} role="img"
         aria-label={`Carga da frota: ${series.map((s) => s.nome).join(' e ')}`}>
      {/* Três linhas de grade, com o valor à esquerda. Sem eixo Y desenhado:
          o número já diz onde está a linha, e a linha vertical seria tinta a
          mais competindo com o dado. */}
      {[0, 50, 100].map((v) => (
        <g key={v}>
          <line x1={pad.esq} x2={larg - pad.dir} y1={y(v)} y2={y(v)}
                stroke="var(--bd2)" strokeWidth="1" />
          <text x={pad.esq - 7} y={y(v) + 3.5} textAnchor="end"
                fontSize="9" fill="var(--fg3)" fontFamily="var(--mono)">
            {v}
          </text>
        </g>
      ))}

      {series.map((s) => {
        const d = caminho(s.pontos, x, y);
        if (!d) return null;
        const base = altura - pad.base;
        // A área usa o MESMO caminho, fechado até a base. Como o caminho quebra
        // no nulo, a área também quebra — não há bloco pintado sobre o buraco.
        return (
          <g key={s.nome}>
            <path d={`${d} L${x(t1).toFixed(1)} ${base} L${x(t0).toFixed(1)} ${base} Z`}
                  fill={s.cor} opacity=".10" />
            <path d={d} fill="none" stroke={s.cor} strokeWidth="1.6"
                  strokeLinecap="round" strokeLinejoin="round" />
          </g>
        );
      })}

      {marcasX.map((m) => (
        <text key={m.rotulo} x={x(m.t)} y={altura - 6} textAnchor="middle"
              fontSize="9" fill="var(--fg3)" fontFamily="var(--mono)">
          {m.rotulo}
        </text>
      ))}
    </svg>
  );
}

// -----------------------------------------------------------------------------
// Série compacta (gaveta)
// -----------------------------------------------------------------------------

export function SerieCompacta({
  rotulo, pontos, cor, sufixo = '%',
}: { rotulo: string; pontos: Ponto[]; cor: string; sufixo?: string }) {
  const larg = 300; const alt = 52;
  const comValor = pontos.filter((p) => p.v !== null) as { t: number; v: number }[];

  if (comValor.length === 0) {
    return (
      <div style={{ marginBottom: 12 }}>
        <Cabecalho rotulo={rotulo} pico={null} media={null} sufixo={sufixo} />
        <div style={{
          height: alt, display: 'grid', placeItems: 'center',
          fontSize: 10.5, color: 'var(--fg3)',
          border: '1px dashed var(--bd2)', borderRadius: 'var(--r-p)',
        }}>
          sem amostras nas últimas 24 h
        </div>
      </div>
    );
  }

  const t0 = Math.min(...comValor.map((p) => p.t));
  const t1 = Math.max(...comValor.map((p) => p.t));
  const span = Math.max(1, t1 - t0);
  const teto = Math.max(100, ...comValor.map((p) => p.v));

  const x = (t: number) => 2 + ((t - t0) / span) * (larg - 4);
  const y = (v: number) => 4 + (1 - v / teto) * (alt - 10);

  const pico = Math.max(...comValor.map((p) => p.v));
  const media = comValor.reduce((s, p) => s + p.v, 0) / comValor.length;
  const d = caminho(pontos, x, y);

  return (
    <div style={{ marginBottom: 12 }}>
      <Cabecalho rotulo={rotulo} pico={pico} media={media} sufixo={sufixo} />
      <svg viewBox={`0 0 ${larg} ${alt}`} width="100%" height={alt} preserveAspectRatio="none"
           role="img" aria-label={`${rotulo}: pico ${pico.toFixed(0)}${sufixo}`}>
        <line x1="0" x2={larg} y1={y(media)} y2={y(media)}
              stroke="var(--bd2)" strokeWidth="1" strokeDasharray="3 3" />
        <path d={`${d} L${x(t1).toFixed(1)} ${alt} L${x(t0).toFixed(1)} ${alt} Z`}
              fill={cor} opacity=".12" />
        <path d={d} fill="none" stroke={cor} strokeWidth="1.4"
              strokeLinecap="round" strokeLinejoin="round" vectorEffect="non-scaling-stroke" />
      </svg>
    </div>
  );
}

function Cabecalho({
  rotulo, pico, media, sufixo,
}: { rotulo: string; pico: number | null; media: number | null; sufixo: string }) {
  return (
    <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, marginBottom: 4 }}>
      <span className="mono" style={{
        fontSize: 8.5, letterSpacing: '.12em', textTransform: 'uppercase', color: 'var(--fg3)',
      }}>
        {rotulo}
      </span>
      <span className="mono" style={{ marginLeft: 'auto', fontSize: 9.5, color: 'var(--fg3)' }}>
        {pico === null ? '—' : `pico ${pico.toFixed(0)}${sufixo} · méd ${media!.toFixed(0)}${sufixo}`}
      </span>
    </div>
  );
}
