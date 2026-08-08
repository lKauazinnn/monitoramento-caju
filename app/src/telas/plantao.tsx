// =============================================================================
// Tela 7 — Plantão
// =============================================================================
// A REGRA CENTRAL, do handoff: o app mostra só o que exige decisão humana em
// menos de 15 minutos. Tudo que a automação já resolveu vai para o resumo da
// manhã.
//
// É por isso que esta tela filtra de verdade, em vez de espelhar a frota: uma
// lista de 200 máquinas às 3 da manhã é a mesma coisa que nenhuma lista.
// =============================================================================

import * as React from 'react';
import { Botao, Ponto } from '@cajupar/sentinela-ds';
import * as api from './../api';
import type { Host } from './../api';
import { Bloco, desdeQuando } from './../comum';
import type { PropsTela } from './noc';

export function TelaPlantao({ hosts, abrirHost, avisar }: PropsTela) {
  const precisam = React.useMemo(
    () => hosts.filter((h) => {
      const e = api.estadoDe(h);
      // Manutenção declarada NÃO acorda ninguém — foi a equipe que a declarou.
      if (e === 'manutencao' || e === 'disabled') return false;
      return e === 'offline' || e === 'degradado';
    }),
    [hosts],
  );

  const lojasEmRisco = React.useMemo(() => {
    const m = new Map<string, { total: number; ruins: number; nome: string }>();
    for (const h of hosts) {
      const v = m.get(h.site_code) ?? { total: 0, ruins: 0, nome: h.site_name };
      v.total++;
      const e = api.estadoDe(h);
      if (e === 'offline' || e === 'degradado') v.ruins++;
      m.set(h.site_code, v);
    }
    return [...m].filter(([, v]) => v.ruins > 0).sort((a, b) => b[1].ruins - a[1].ruins);
  }, [hosts]);

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '392px minmax(0,1fr)', gap: 20, alignItems: 'start' }}>
      {/* --------------------------------------------------- telefone --- */}
      <div style={{
        borderRadius: 34, padding: 10, background: 'var(--pnl)',
        border: '1px solid var(--bd)', boxShadow: 'var(--sh)',
      }}>
        <div style={{
          borderRadius: 26, background: 'var(--bg)', overflow: 'hidden',
          border: '1px solid var(--bd2)', minHeight: 640,
          display: 'flex', flexDirection: 'column',
        }}>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 6,
            padding: '9px 16px 4px', fontSize: 10, color: 'var(--fg3)',
          }}>
            <span className="mono">{new Date().toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}</span>
            <span style={{ marginLeft: 'auto' }} className="mono">Sentinela</span>
          </div>

          <div style={{ padding: '10px 16px 14px', borderBottom: '1px solid var(--bd2)' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <div style={{ minWidth: 0 }}>
                <div style={{ fontSize: 15, fontWeight: 700 }}>Plantão</div>
                <div style={{ fontSize: 11, color: 'var(--fg3)' }}>
                  {precisam.length === 0 ? 'nada exigindo você agora' : 'precisa de decisão'}
                </div>
              </div>
              <span style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 6 }}>
                <Ponto tom={precisam.length ? 'ruim' : 'ok'} pulsando={precisam.length > 0} />
                <span className="mono" style={{
                  fontSize: 17, fontWeight: 600,
                  color: precisam.length ? 'var(--crit)' : 'var(--ok)',
                }}>
                  {precisam.length}
                </span>
              </span>
            </div>
          </div>

          <div style={{ padding: 14, display: 'grid', gap: 14, flex: 1 }}>
            <div>
              <div className="secao-lateral mono" style={{ marginBottom: 8 }}>
                Precisa de você agora
              </div>

              {precisam.length === 0 ? (
                <div style={{
                  padding: '18px 14px', borderRadius: 'var(--r-m)',
                  background: 'color-mix(in srgb, var(--ok) 8%, transparent)',
                  border: '1px solid color-mix(in srgb, var(--ok) 24%, transparent)',
                  fontSize: 12, color: 'var(--ok)', textAlign: 'center',
                }}>
                  Tudo sob controle. Volte a dormir.
                </div>
              ) : (
                <div style={{ display: 'grid', gap: 9 }}>
                  {precisam.slice(0, 3).map((h) => (
                    <CartaoPlantao key={h.machine_id} host={h}
                                   onAbrir={() => abrirHost(h.machine_id)} avisar={avisar} />
                  ))}
                  {precisam.length > 3 && (
                    <div style={{ fontSize: 10.5, color: 'var(--fg3)', textAlign: 'center' }}>
                      + {precisam.length - 3} no resumo da manhã
                    </div>
                  )}
                </div>
              )}
            </div>

            {lojasEmRisco.length > 0 && (
              <div>
                <div className="secao-lateral mono" style={{ marginBottom: 8 }}>Lojas em risco</div>
                <div style={{ display: 'grid', gap: 6 }}>
                  {lojasEmRisco.map(([cod, v]) => (
                    <div key={cod} style={{
                      display: 'flex', alignItems: 'center', gap: 8,
                      padding: '9px 11px', borderRadius: 'var(--r-m)',
                      background: 'var(--pnl2)', border: '1px solid var(--bd2)',
                    }}>
                      <span style={{ fontSize: 11.5 }}>{v.nome}</span>
                      <span className="mono" style={{
                        marginLeft: 'auto', fontSize: 11,
                        color: v.ruins === v.total ? 'var(--crit)' : 'var(--warn)',
                      }}>
                        {v.total - v.ruins}/{v.total}
                      </span>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>
        </div>
      </div>

      {/* ----------------------------------------------------- regras --- */}
      <div style={{ display: 'grid', gap: 14 }}>
        <Bloco titulo="A regra do plantão">
          <p style={{ margin: 0, fontSize: 12, color: 'var(--fg2)', textWrap: 'pretty', lineHeight: 1.7 }}>
            O app mostra <strong>só o que exige decisão humana em menos de 15 minutos</strong>.
            Tudo que a automação já resolveu vai para o resumo da manhã.
          </p>
          <p style={{ margin: '10px 0 0', fontSize: 11.5, color: 'var(--fg2)', textWrap: 'pretty', lineHeight: 1.7 }}>
            Máquina em manutenção declarada <strong>não acorda ninguém</strong>: foi a
            própria equipe que a declarou, e avisar sobre o que a equipe desligou é o
            caminho mais curto para o alerta ser ignorado.
          </p>
          <p style={{ margin: '10px 0 0', fontSize: 11.5, color: 'var(--fg3)', textWrap: 'pretty', lineHeight: 1.7 }}>
            Os botões de decisão têm 44px de altura — decisão de uma mão, no escuro.
          </p>
        </Bloco>

        <Bloco titulo="O que ainda não existe">
          <p style={{ margin: 0, fontSize: 11.5, color: 'var(--fg2)', textWrap: 'pretty', lineHeight: 1.7 }}>
            Esta tela é a <strong>visão</strong> do plantão, não o aplicativo. Não há
            push, nem escala de plantonistas, nem “soneca” que sobreviva a fechar a
            página — tudo isso exige servidor que não foi construído. O que está aqui
            já é útil: aberto num celular, mostra exatamente o que exige alguém agora.
          </p>
        </Bloco>
      </div>
    </div>
  );
}

function CartaoPlantao({
  host, onAbrir, avisar,
}: { host: Host; onAbrir: () => void; avisar: (t: string, tom?: 'ok' | 'warn' | 'crit' | 'info') => void }) {
  const e = api.estadoDe(host);
  const p = api.problemasDe(host);
  const cor = e === 'offline' ? 'crit' : 'warn';

  return (
    <div style={{
      padding: 12, borderRadius: 'var(--r-m)',
      background: `color-mix(in srgb, var(--${cor}) 8%, transparent)`,
      border: `1px solid color-mix(in srgb, var(--${cor}) 26%, transparent)`,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
        <Ponto tom={e === 'offline' ? 'ruim' : 'alerta'} />
        <span className="mono" style={{ fontSize: 12, fontWeight: 600 }}>{host.label}</span>
        <span className="mono" style={{ marginLeft: 'auto', fontSize: 9.5, color: 'var(--fg3)' }}>
          {desdeQuando(host.seconds_since_seen)}
        </span>
      </div>
      <div style={{ fontSize: 11, color: 'var(--fg2)', margin: '6px 0 10px' }}>
        {host.site_name} · {p[0] ?? e}
      </div>
      <div style={{ display: 'flex', gap: 8 }}>
        <button
          type="button"
          onClick={onAbrir}
          style={{
            flex: 1, minHeight: 44, borderRadius: 'var(--r-m)', cursor: 'pointer',
            border: `1px solid color-mix(in srgb, var(--${cor}) 40%, transparent)`,
            background: `color-mix(in srgb, var(--${cor}) 14%, transparent)`,
            color: `var(--${cor})`, fontFamily: 'var(--fonte)', fontSize: 12.5, fontWeight: 600,
          }}
        >
          Assumir
        </button>
        <button
          type="button"
          onClick={() => avisar('Soneca ainda não persiste — falta o servidor guardar o silêncio.', 'warn')}
          style={{
            flex: 1, minHeight: 44, borderRadius: 'var(--r-m)', cursor: 'pointer',
            border: '1px solid var(--bd)', background: 'transparent',
            color: 'var(--fg2)', fontFamily: 'var(--fonte)', fontSize: 12.5,
          }}
        >
          Soneca 30m
        </button>
      </div>
    </div>
  );
}
