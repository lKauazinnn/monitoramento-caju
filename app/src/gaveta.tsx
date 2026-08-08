// =============================================================================
// Gaveta de detalhe do host
// =============================================================================
// Abre de qualquer lugar: linha de tabela, quadradinho do heatmap, resultado da
// busca. Gaveta e não página, de propósito — quem investiga uma máquina não quer
// perder a grade de vista, porque a pergunta seguinte é sempre "é só essa ou a
// loja inteira?".
// =============================================================================

import * as React from 'react';
import { Painel, Ficha, Botao, Barra, Etiqueta, Comando, ListaEventos, Evento } from '@cajupar/sentinela-ds';
import * as api from './api';
import type { Host, ComandoDaMaquina } from './api';
import { Valor, tomDoPercentual, tomDoDisco, desdeQuando, uptime, hora, Bloco } from './comum';
import { Ico, icoDoTipo } from './icones';
import type { Aviso } from './App';

const NOME_DO_COMANDO: Record<string, string> = {
  restart_service: 'Reiniciar serviço',
  clear_temp: 'Limpar temporários',
  restart_machine: 'Reiniciar o PC',
  run_test_collection: 'Testar coleta',
  wake_machine: 'Ligar o PC',
  sleep_machine: 'Suspender o PC',
};

export function Gaveta({
  host, onFechar, avisar,
}: { host: Host; onFechar: () => void; avisar: (t: string, tom?: Aviso['tom']) => void }) {
  const [comandos, setComandos] = React.useState<ComandoDaMaquina[]>([]);
  const [eventos, setEventos] = React.useState<api.Evento[]>([]);
  const estado = api.estadoDe(host);
  const problemas = api.problemasDe(host);

  React.useEffect(() => {
    let vivo = true;
    api.comandosDa(host.machine_id).then((c) => vivo && setComandos(c)).catch(() => {});
    api.ler<api.Evento[]>(
      `events?machine_id=eq.${host.machine_id}&order=opened_at.desc&limit=8`,
    ).then((e) => vivo && setEventos(e)).catch(() => {});
    return () => { vivo = false; };
  }, [host.machine_id]);

  return (
    <Painel
      titulo={host.label}
      sub={`${host.site_code} · ${host.ip_lan ?? 'sem IP'} · ${host.agent_version ?? 'sem agente'}`}
      onFechar={onFechar}
    >
      {/* ------------------------------------------------------ chips --- */}
      <div style={{ display: 'flex', gap: 7, flexWrap: 'wrap', marginBottom: 14 }}>
        <Etiqueta estado={estado} />
        <Chip>{host.role_name ?? host.role_code}</Chip>
        <Chip>hb {desdeQuando(host.seconds_since_seen)}</Chip>
        {host.mac_address && <Chip mono>{host.mac_address}</Chip>}
      </div>

      {problemas.length > 0 && (
        <div
          style={{
            padding: '10px 12px', marginBottom: 14, borderRadius: 'var(--r-m)',
            background: `color-mix(in srgb, var(--${estado === 'offline' ? 'crit' : 'warn'}) 8%, transparent)`,
            border: `1px solid color-mix(in srgb, var(--${estado === 'offline' ? 'crit' : 'warn'}) 26%, transparent)`,
            fontSize: 11.5, color: 'var(--fg2)',
          }}
        >
          {problemas.join(' · ')}
        </div>
      )}

      {/* ----------------------------------------------------- medidas --- */}
      {/* Seis medidores, como o handoff pede. Cada um pode vir vazio: máquina
          offline não reporta nada, e o travessão diz isso melhor que um zero. */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 10, marginBottom: 16 }}>
        <Medidor rot="CPU" v={host.cpu_pct} suf="%" tom={tomDoPercentual(host.cpu_pct)} barra />
        <Medidor rot="Memória" v={host.mem_pct} suf="%" tom={tomDoPercentual(host.mem_pct)} barra />
        <Medidor rot="Disco livre" v={host.disk_min_free_pct} suf="%"
                 tom={tomDoDisco(host.disk_min_free_pct)}
                 nota={host.disk_worst_drive ?? undefined} />
        <Medidor rot="Temperatura" v={host.cpu_temp_c} suf="°C" casas={1}
                 tom={tomDoPercentual(host.cpu_temp_c, 75, 85)} />
        <Medidor rot="Uptime" texto={uptime(host.uptime_seconds)} />
        <Medidor rot="RTT gateway" v={host.gw_latency_ms} suf=" ms" casas={1} />
      </div>

      {/* -------------------------------------------------------- ficha --- */}
      <Ficha
        linhas={[
          { rotulo: 'Hostname', valor: host.hostname },
          { rotulo: 'Loja', valor: `${host.site_name} (${host.site_code})` },
          { rotulo: 'Marca', valor: host.brand_name },
          { rotulo: 'Sistema', valor: host.os_caption },
          { rotulo: 'CPU', valor: host.cpu_model },
          { rotulo: 'Núcleos', valor: host.cpu_cores },
          { rotulo: 'Memória física', valor: host.mem_total_mb ? `${(host.mem_total_mb / 1024).toFixed(1)} GB` : null },
          { rotulo: 'MAC da placa', valor: host.mac_address
              ? host.mac_address + (host.mac_is_wifi ? ' (Wi-Fi — não acorda pela rede)' : '')
              : 'não reportado — agente anterior ao ps-1.3.1' },
          { rotulo: 'Desvio de relógio', valor: host.clock_drift_seconds !== null ? `${host.clock_drift_seconds}s` : null },
          { rotulo: 'Último boot', valor: host.last_boot_at ? new Date(host.last_boot_at).toLocaleString('pt-BR') : null },
          { rotulo: 'GUID', valor: host.machine_id },
        ]}
      />

      {/* ---------------------------------------------------- serviços --- */}
      {host.services_down !== null && (
        <>
          <h3 style={{ margin: '20px 0 8px', fontSize: 12.5 }}>Serviços críticos</h3>
          <div style={{ fontSize: 11.5, color: 'var(--fg2)' }}>
            {host.services_down === 0
              ? <span style={{ color: 'var(--ok)' }}>Todos rodando.</span>
              : <span style={{ color: 'var(--warn)' }}>
                  {host.services_down} parado(s): {host.services_down_names?.join(', ')}
                </span>}
          </div>
        </>
      )}

      {/* ---------------------------------------------------- comandos --- */}
      <h3 style={{ margin: '20px 0 8px', fontSize: 12.5 }}>Ações remotas recentes</h3>
      {comandos.length === 0
        ? <p style={{ margin: 0, fontSize: 11.5, color: 'var(--fg3)' }}>Nenhuma ainda.</p>
        : (
          <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
            {comandos.map((c) => (
              <Comando
                key={c.id}
                acao={NOME_DO_COMANDO[c.kind] ?? c.kind}
                estado={c.status as never}
                quando={hora(c.created_at)}
                simulacao={c.dry_run}
                resultado={c.result_text ?? undefined}
              />
            ))}
          </ul>
        )}

      {/* ----------------------------------------------------- eventos --- */}
      <h3 style={{ margin: '20px 0 8px', fontSize: 12.5 }}>Eventos recentes</h3>
      <ListaEventos vazio="Nenhum evento registrado.">
        {eventos.map((e) => (
          <Evento
            key={e.event_id}
            tipo={e.kind}
            mensagem={e.message}
            quando={hora(e.opened_at)}
            severidade={e.severity}
          />
        ))}
      </ListaEventos>

      {/* ------------------------------------------------------- ações --- */}
      <div style={{ display: 'grid', gap: 8, marginTop: 22 }}>
        <Botao
          variante="acao" largo
          onClick={async () => {
            try {
              await api.rpc('enfileirar_comando', {
                p_machine_id: host.machine_id, p_kind: 'run_test_collection', p_dry_run: false,
              });
              avisar('Teste de coleta enfileirado.', 'ok');
            } catch (e) { avisar((e as Error).message, 'crit'); }
          }}
        >
          Testar coleta
        </Botao>
      </div>
    </Painel>
  );
}

function Chip({ children, mono }: { children: React.ReactNode; mono?: boolean }) {
  return (
    <span
      className={mono ? 'mono' : undefined}
      style={{
        padding: '4px 9px', borderRadius: 'var(--r-p)',
        border: '1px solid var(--bd)', background: 'var(--pnl2)',
        fontSize: mono ? 9.5 : 10.5, color: 'var(--fg2)',
      }}
    >
      {children}
    </span>
  );
}

function Medidor({
  rot, v, suf = '', casas = 0, tom, texto, nota, barra,
}: {
  rot: string; v?: number | null; suf?: string; casas?: number;
  tom?: string; texto?: string; nota?: string; barra?: boolean;
}) {
  return (
    <div style={{
      padding: '10px 11px', borderRadius: 'var(--r-m)',
      background: 'var(--pnl2)', border: '1px solid var(--bd2)', minWidth: 0,
    }}>
      <div className="mono" style={{
        fontSize: 8.5, letterSpacing: '.12em', textTransform: 'uppercase',
        color: 'var(--fg3)', marginBottom: 5,
      }}>
        {rot}
      </div>
      <div style={{ fontSize: 17, fontWeight: 600, letterSpacing: '-.02em' }}>
        {texto !== undefined
          ? <span className="mono">{texto}</span>
          : <Valor n={v} sufixo={suf} casas={casas} tom={tom} />}
      </div>
      {barra && v !== null && v !== undefined && (
        <div style={{ marginTop: 6 }}><Barra pct={v} /></div>
      )}
      {nota && <div style={{ fontSize: 10, color: 'var(--fg3)', marginTop: 4 }}>{nota}</div>}
    </div>
  );
}
