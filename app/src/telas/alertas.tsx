// =============================================================================
// Tela 5 — Regras & ruído
// =============================================================================
// A pergunta que esta tela responde não é "quais regras existem" — é "quais
// delas estão gastando a atenção de alguém sem motivo".
//
// A taxa de ruído é DERIVADA dos eventos: um alerta que abre e fecha sozinho
// em minutos, sem ninguém reconhecer, quase sempre é ruído. É uma aproximação,
// e a tela diz que é.
// =============================================================================

import * as React from 'react';
import * as api from './../api';
import type { Regra } from './../api';
import { Bloco, Erro } from './../comum';
import type { PropsTela } from './noc';

interface Ruido { total: number; reconhecidos: number; efemeros: number; }

export function TelaAlertas({ avisar }: PropsTela) {
  const [regras, setRegras] = React.useState<Regra[]>([]);
  const [ruido, setRuido] = React.useState<Map<string, Ruido>>(new Map());
  const [erro, setErro] = React.useState<string | null>(null);

  const buscar = React.useCallback(async () => {
    try {
      const [r, ev] = await Promise.all([
        api.regras(),
        api.ler<api.Evento[]>('events?kind=eq.alert_open&order=opened_at.desc&limit=1000'),
      ]);
      setRegras(r);

      const m = new Map<string, Ruido>();
      for (const e of ev) {
        const k = e.kind;
        const v = m.get(k) ?? { total: 0, reconhecidos: 0, efemeros: 0 };
        v.total++;
        if (e.acknowledged_at) v.reconhecidos++;
        // Abriu e fechou em menos de 5 min sem ninguém reconhecer: o sistema se
        // resolveu antes de a pessoa chegar. O alerta não serviu para nada.
        if (e.resolved_at && !e.acknowledged_at) {
          const dur = (+new Date(e.resolved_at) - +new Date(e.opened_at)) / 60000;
          if (dur < 5) v.efemeros++;
        }
        m.set(k, v);
      }
      setRuido(m);
      setErro(null);
    } catch (e) { setErro((e as Error).message); }
  }, []);

  React.useEffect(() => { buscar(); }, [buscar]);

  if (erro) return <Erro msg={erro} onTentar={buscar} />;

  return (
    <>
      <Bloco
        titulo="Regras de alerta"
        sub="Escopo mais específico vence: uma regra de máquina sobrepõe a da loja, que sobrepõe a global."
      >
        {regras.length === 0 && (
          <p style={{ margin: 0, fontSize: 12, color: 'var(--fg3)' }}>Nenhuma regra cadastrada.</p>
        )}

        {regras.map((r) => {
          const n = ruido.get(r.kind);
          const pct = n && n.total > 0 ? (100 * n.efemeros) / n.total : null;
          return (
            <div
              key={r.id}
              style={{
                display: 'grid', gridTemplateColumns: '1.5fr .85fr 1fr 70px 44px',
                gap: 12, alignItems: 'center',
                padding: '10px 0', borderBottom: '1px solid var(--bd2)',
              }}
            >
              <div style={{ minWidth: 0 }}>
                <div style={{ fontSize: 12.5, fontWeight: 600 }}>{r.name}</div>
                <div className="mono" style={{ fontSize: 9.5, color: 'var(--fg3)' }}>
                  {r.kind} {r.comparator} {r.threshold ?? ''}
                </div>
              </div>

              <span style={{
                justifySelf: 'start', padding: '3px 8px', borderRadius: 'var(--r-p)',
                border: '1px solid var(--bd)', background: 'var(--pnl2)',
                fontSize: 10, color: 'var(--fg2)',
              }}>
                {r.scope}
              </span>

              <div className="mono" style={{ fontSize: 10, color: 'var(--fg3)' }}>
                {r.consecutive_cycles} ciclo(s) · silêncio {r.cooldown_minutes}min
                {n ? ` · ${n.total} disparo(s)` : ''}
              </div>

              <div className="mono" style={{
                fontSize: 11, textAlign: 'right',
                color: pct === null ? 'var(--fg3)'
                  : pct >= 50 ? 'var(--crit)' : pct >= 25 ? 'var(--warn)' : 'var(--ok)',
              }}>
                {pct === null ? '—' : `${pct.toFixed(0)}%`}
              </div>

              <Interruptor
                ligado={r.is_active}
                onMudar={() => avisar(
                  'Ligar e desligar regra ainda não tem função no servidor — falta a chamada e o registro na auditoria.',
                  'warn',
                )}
              />
            </div>
          );
        })}

        <p style={{ margin: '14px 0 0', fontSize: 10.5, color: 'var(--fg3)', textWrap: 'pretty' }}>
          A coluna de percentual é <strong>ruído estimado</strong>: alertas que abriram e
          fecharam em menos de 5 minutos sem ninguém reconhecer. É aproximação — o número
          exato exigiria registrar se cada alerta levou a uma ação.
        </p>
      </Bloco>

      <Bloco titulo="Rota de escalada">
        <p style={{ margin: 0, fontSize: 11.5, color: 'var(--fg2)' }}>
          Hoje o alerta abre no painel e a faixa de incidente aparece na tela de quem
          estiver olhando. <strong>Não há escalada por tempo</strong> — nem push, nem
          ligação, nem e-mail. Foi decisão consciente: notificação externa sem alguém de
          plantão de verdade vira alarme ignorado.
        </p>
      </Bloco>
    </>
  );
}

function Interruptor({ ligado, onMudar }: { ligado: boolean; onMudar: () => void }) {
  return (
    <button
      type="button"
      onClick={onMudar}
      aria-pressed={ligado}
      style={{
        all: 'unset', cursor: 'pointer', position: 'relative',
        width: 34, height: 19, borderRadius: 19, justifySelf: 'end',
        background: ligado ? 'color-mix(in srgb, var(--ok) 34%, transparent)' : 'var(--pnl2)',
        border: `1px solid ${ligado ? 'color-mix(in srgb, var(--ok) 50%, transparent)' : 'var(--bd)'}`,
        transition: 'background .18s ease',
      }}
    >
      <i style={{
        position: 'absolute', top: 2, left: ligado ? 16 : 2,
        width: 13, height: 13, borderRadius: '50%',
        background: ligado ? 'var(--ok)' : 'var(--fg3)',
        transition: 'left .18s ease',
      }} />
    </button>
  );
}
