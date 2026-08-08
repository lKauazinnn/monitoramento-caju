// =============================================================================
// Tela 3 — War-room do incidente
// =============================================================================
// O handoff descreve um SEV1 com timeline correlacionada, runbook e impacto
// financeiro. NADA disso existe no servidor ainda — é o pilar 2 da fase de ação
// remota, que não começou.
//
// Então esta tela mostra o layout, diz o que falta, e — em vez de inventar um
// incidente — apresenta o que EXISTE hoje: os alertas abertos, cada um por si.
// Ver os 12 alertas separados é justamente o argumento para construir a
// correlação que os agruparia em um.
// =============================================================================

import * as React from 'react';
import { FaixaIncidente, Botao } from '@cajupar/sentinela-ds';
import * as api from './../api';
import { Bloco, SemDado, desdeQuando, dataHora } from './../comum';
import type { PropsTela } from './noc';

export function TelaIncidente({ hosts, abrirHost, avisar }: PropsTela) {
  const [abertos, setAbertos] = React.useState<api.Evento[]>([]);

  React.useEffect(() => {
    let vivo = true;
    api.ler<api.Evento[]>(
      'events?kind=eq.alert_open&resolved_at=is.null&order=opened_at.desc&limit=40',
    ).then((e) => vivo && setAbertos(e)).catch(() => {});
    return () => { vivo = false; };
  }, [hosts]);

  const criticos = abertos.filter((a) => a.severity === 'critical');
  const pior = criticos[0] ?? abertos[0] ?? null;

  return (
    <>
      <SemDado ausencia={api.AUSENTE.incidentes} />

      {pior ? (
        <FaixaIncidente
          severidade={pior.severity === 'critical' ? 'critical' : 'warning'}
          titulo={`${pior.machine_label ?? 'Frota'} · ${pior.message}`}
          descricao={
            abertos.length > 1
              ? `Mais ${abertos.length - 1} alerta(s) aberto(s). Sem correlação, cada um é uma linha separada — é exatamente o problema que a correlação resolveria.`
              : 'Único alerta aberto no momento.'
          }
          tags={[pior.site_code ?? '—', pior.kind].filter(Boolean) as string[]}
          quando={dataHora(pior.opened_at)}
          onReconhecer={async () => {
            try {
              await api.rpc('reconhecer_alerta', { p_event_id: pior.event_id });
              avisar('Alerta reconhecido.', 'ok');
              setAbertos((a) => a.filter((x) => x.event_id !== pior.event_id));
            } catch (e) { avisar((e as Error).message, 'crit'); }
          }}
        />
      ) : (
        <Bloco>
          <p style={{ margin: 0, fontSize: 12.5, color: 'var(--ok)' }}>
            Nenhum alerta aberto. Nada a conduzir agora.
          </p>
        </Bloco>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1.35fr 1fr', gap: 14, alignItems: 'start' }}>
        <Bloco
          titulo="Alertas abertos"
          sub="Hoje cada um é independente. Com correlação, os da mesma loja e janela virariam um incidente só."
        >
          {abertos.length === 0
            ? <p style={{ margin: 0, fontSize: 12, color: 'var(--fg3)' }}>Nenhum.</p>
            : (
              <div style={{ display: 'grid', gap: 2 }}>
                {abertos.map((a) => (
                  <div
                    key={a.event_id}
                    onClick={() => {
                      const h = hosts.find((x) => x.machine_id === a.machine_id);
                      if (h) abrirHost(h.machine_id);
                    }}
                    style={{
                      display: 'grid', gridTemplateColumns: '52px 14px 1fr',
                      gap: 10, alignItems: 'start', padding: '9px 0',
                      borderBottom: '1px solid var(--bd2)',
                      cursor: a.machine_id ? 'pointer' : 'default',
                    }}
                  >
                    <span className="mono" style={{ fontSize: 10, color: 'var(--fg3)' }}>
                      {new Date(a.opened_at).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}
                    </span>
                    <span style={{ display: 'grid', justifyItems: 'center' }}>
                      <i style={{
                        width: 9, height: 9, borderRadius: '50%',
                        background: a.severity === 'critical' ? 'var(--crit)'
                          : a.severity === 'warning' ? 'var(--warn)' : 'var(--info)',
                      }} />
                    </span>
                    <span style={{ minWidth: 0 }}>
                      <span style={{ display: 'block', fontSize: 12.5, fontWeight: 700 }}>
                        {a.machine_label ?? 'frota'}
                      </span>
                      <span style={{ display: 'block', fontSize: 11.5, color: 'var(--fg2)' }}>
                        {a.message}
                      </span>
                      <span className="mono" style={{ fontSize: 9, color: 'var(--fg3)' }}>
                        {a.kind}{a.site_code ? ` · ${a.site_code}` : ''}
                      </span>
                    </span>
                  </div>
                ))}
              </div>
            )}
        </Bloco>

        <div style={{ display: 'grid', gap: 14 }}>
          <Bloco titulo="Runbook">
            <SemDado ausencia={api.AUSENTE.runbooks} />
            <p style={{ margin: 0, fontSize: 11.5, color: 'var(--fg2)' }}>
              Hoje as ações remotas existem e são auditadas uma a uma — reiniciar
              serviço, limpar temporários, reiniciar o PC. O que falta é
              encadeá-las numa sequência com escalonamento, e gravar o progresso.
            </p>
          </Bloco>

          <Bloco titulo="Máquinas sem contato" sub="O impacto que dá para medir hoje">
            {(() => {
              const off = hosts.filter((h) => api.estadoDe(h) === 'offline');
              if (off.length === 0) {
                return <p style={{ margin: 0, fontSize: 12, color: 'var(--ok)' }}>Nenhuma.</p>;
              }
              return (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(190px,1fr))', gap: 10 }}>
                  {off.map((h) => (
                    <button
                      key={h.machine_id}
                      type="button"
                      onClick={() => abrirHost(h.machine_id)}
                      style={{
                        all: 'unset', cursor: 'pointer', padding: '10px 11px',
                        borderRadius: 'var(--r-m)', background: 'var(--pnl2)',
                        border: '1px solid color-mix(in srgb, var(--crit) 24%, transparent)',
                      }}
                    >
                      <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
                        <i style={{ width: 7, height: 7, borderRadius: '50%', background: 'var(--crit)' }} />
                        <span className="mono" style={{ fontSize: 11.5, fontWeight: 600 }}>{h.label}</span>
                      </div>
                      <div style={{ fontSize: 10.5, color: 'var(--fg3)', marginTop: 4 }}>
                        {h.site_code} · sem contato {desdeQuando(h.seconds_since_seen)}
                      </div>
                    </button>
                  ))}
                </div>
              );
            })()}
          </Bloco>
        </div>
      </div>
    </>
  );
}
