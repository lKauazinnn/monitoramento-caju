// =============================================================================
// Tela 6 — Auditoria
// =============================================================================
// Quem fez o quê, e quando. A trilha existe e é real: cada ação remota, cada
// remoção, cada mudança de configuração grava um evento com autor.
//
// O que NÃO existe é o encadeamento criptográfico. O handoff pede cada linha
// assinada com o hash da anterior; hoje uma linha pode ser alterada sem deixar
// rastro. A tela diz isso em vez de mostrar um hash inventado.
// =============================================================================

import * as React from 'react';
import { Botao } from '@cajupar/sentinela-ds';
import * as api from './../api';
import { Bloco, SemDado, Faceta, Tabela, dataHora, Erro } from './../comum';
import type { Coluna } from './../comum';
import type { PropsTela } from './noc';

type Categoria = 'tudo' | 'pessoas' | 'sistema' | 'seguranca' | 'mudancas';

const CATEGORIA_DE: Record<string, Exclude<Categoria, 'tudo'>> = {
  command_queued: 'pessoas', command_canceled: 'pessoas',
  machine_provisioned: 'mudancas', machine_removed: 'mudancas',
  site_removed: 'mudancas', machine_renamed: 'mudancas',
  demo_data_removed: 'mudancas', ingest_config_changed: 'mudancas',
  token_revoked: 'seguranca', token_rotated: 'seguranca',
  command_result: 'sistema', command_expired: 'sistema',
  alert_open: 'sistema', alert_recovered: 'sistema',
  rollup_run: 'sistema', retention_purge: 'sistema',
  partition_created: 'sistema', partition_dropped: 'sistema',
  machine_first_seen: 'sistema', agent_error: 'sistema',
  clock_drift: 'sistema', ingest_rejected: 'seguranca',
};

const COR_DA_CATEGORIA: Record<string, string> = {
  pessoas: 'var(--info)', sistema: 'var(--fg3)',
  seguranca: 'var(--crit)', mudancas: 'var(--vio)',
};

export function TelaAuditoria(_props: PropsTela) {
  const [eventos, setEventos] = React.useState<api.Evento[]>([]);
  const [cat, setCat] = React.useState<Categoria>('tudo');
  const [erro, setErro] = React.useState<string | null>(null);

  const buscar = React.useCallback(() => {
    api.eventos(400).then(setEventos).catch((e) => setErro((e as Error).message));
  }, []);

  React.useEffect(() => { buscar(); }, [buscar]);

  const contagens = React.useMemo(() => {
    const m = new Map<string, number>();
    for (const e of eventos) {
      const c = CATEGORIA_DE[e.kind] ?? 'sistema';
      m.set(c, (m.get(c) ?? 0) + 1);
    }
    return m;
  }, [eventos]);

  const filtrados = React.useMemo(
    () => (cat === 'tudo' ? eventos : eventos.filter((e) => (CATEGORIA_DE[e.kind] ?? 'sistema') === cat)),
    [eventos, cat],
  );

  if (erro) return <Erro msg={erro} onTentar={buscar} />;

  return (
    <>
      <SemDado ausencia={api.AUSENTE.cadeiaDeHash}>
        <p style={{ margin: '6px 0 0', fontSize: 11, color: 'var(--fg2)' }}>
          A trilha em si <strong>é real</strong>: {eventos.length} evento(s) com autor,
          alvo e horário. O que falta é a garantia de que ninguém a alterou depois.
        </p>
      </SemDado>

      <Bloco
        titulo="Trilha de auditoria"
        sub={`${filtrados.length} evento(s)`}
        acoes={
          <Botao
            variante="secundario"
            onClick={() => baixarCsv(filtrados)}
          >
            Exportar CSV
          </Botao>
        }
      >
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 14 }}>
          <Faceta rotulo="Tudo" contagem={eventos.length} ativo={cat === 'tudo'}
                  onClick={() => setCat('tudo')} />
          {(['pessoas', 'sistema', 'seguranca', 'mudancas'] as const).map((c) => (
            <Faceta
              key={c}
              rotulo={{ pessoas: 'Pessoas', sistema: 'Sistema', seguranca: 'Segurança', mudancas: 'Mudanças' }[c]}
              contagem={contagens.get(c) ?? 0}
              ativo={cat === c}
              onClick={() => setCat(c)}
            />
          ))}
        </div>

        <Tabela
          colunas={COLUNAS}
          linhas={filtrados}
          chaveDe={(e) => String(e.event_id)}
          vazio="Nenhum evento nesta categoria."
        />
      </Bloco>
    </>
  );
}

const COLUNAS: Coluna<api.Evento>[] = [
  { chave: 'quando', rotulo: 'Quando', largura: '110px',
    render: (e) => <span className="mono" style={{ fontSize: 10, color: 'var(--fg2)' }}>
      {dataHora(e.opened_at)}</span> },
  { chave: 'acao', rotulo: 'Ação', largura: '1fr',
    render: (e) => {
      const c = CATEGORIA_DE[e.kind] ?? 'sistema';
      return (
        <span className="mono" style={{
          padding: '3px 8px', borderRadius: 'var(--r-p)', fontSize: 9.5,
          background: `color-mix(in srgb, ${COR_DA_CATEGORIA[c]} 12%, transparent)`,
          border: `1px solid color-mix(in srgb, ${COR_DA_CATEGORIA[c]} 26%, transparent)`,
          color: COR_DA_CATEGORIA[c],
        }}>
          {e.kind}
        </span>
      );
    } },
  { chave: 'alvo', rotulo: 'Alvo', largura: '.9fr',
    render: (e) => <span style={{ color: 'var(--fg2)' }}>{e.machine_label ?? e.site_code ?? '—'}</span> },
  { chave: 'msg', rotulo: 'Detalhe', largura: '1.8fr',
    render: (e) => <span style={{ color: 'var(--fg2)' }}>{e.message}</span> },
  { chave: 'sev', rotulo: 'Severidade', largura: '.6fr', alinhaDireita: true,
    render: (e) => (
      <span className="mono" style={{
        fontSize: 10,
        color: e.severity === 'critical' ? 'var(--crit)'
          : e.severity === 'warning' ? 'var(--warn)' : 'var(--fg3)',
      }}>
        {e.severity}
      </span>
    ) },
];

/**
 * CSV gerado no navegador.
 *
 * Cada campo entre aspas com aspas internas dobradas: uma mensagem de evento
 * pode conter vírgula e aspas, e sem isso a coluna se desloca — a planilha
 * abriria com o dado no lugar errado, o que é pior que não abrir.
 */
function baixarCsv(eventos: api.Evento[]) {
  const esc = (v: unknown) => `"${String(v ?? '').replace(/"/g, '""')}"`;
  const linhas = [
    ['quando', 'tipo', 'severidade', 'maquina', 'loja', 'mensagem'].join(','),
    ...eventos.map((e) => [
      e.opened_at, e.kind, e.severity, e.machine_label, e.site_code, e.message,
    ].map(esc).join(',')),
  ];
  // BOM: sem ele o Excel abre UTF-8 como ANSI e todo acento vira caractere solto.
  const blob = new Blob(['\uFEFF' + linhas.join('\r\n')], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `auditoria-${new Date().toISOString().slice(0, 10)}.csv`;
  a.click();
  URL.revokeObjectURL(url);
}
