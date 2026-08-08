// =============================================================================
// Tela 4 — Inventário
// =============================================================================
// O handoff pede quatro agregações: sistema operacional, modelo de hardware,
// versão do agente e memória instalada.
//
// TRÊS DELAS EXISTEM: o agente já reporta SO, versão e memória. A quarta —
// modelo do equipamento — não é coletada, e as tabelas de software, fim de vida
// e deriva de configuração também não.
//
// Então esta tela mostra o que É medido, e diz explicitamente o que falta. Não
// é a tela inteira, mas cada número dela é verdadeiro.
// =============================================================================

import * as React from 'react';
import * as api from './../api';
import type { Host } from './../api';
import { Bloco, SemDado } from './../comum';
import type { PropsTela } from './noc';

export function TelaInventario({ hosts }: PropsTela) {
  const porSO = agrupar(hosts, (h) => h.os_caption ?? 'não reportado');
  const porAgente = agrupar(hosts, (h) => h.agent_version ?? 'sem agente');
  const porMemoria = agrupar(hosts, (h) =>
    h.mem_total_mb ? `${Math.round(h.mem_total_mb / 1024)} GB` : 'não reportado');
  const porCpu = agrupar(hosts, (h) => h.cpu_model ?? 'não reportado');

  return (
    <>
      <SemDado ausencia={api.AUSENTE.inventario}>
        <p style={{ margin: '6px 0 0', fontSize: 11, color: 'var(--fg2)' }}>
          O que aparece abaixo <strong>é medido</strong>: sistema operacional, versão do
          agente, memória e processador vêm do próprio agente a cada ciclo.
        </p>
      </SemDado>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))', gap: 14 }}>
        <Agregacao titulo="Sistema operacional" itens={porSO} />
        <Agregacao titulo="Versão do agente" itens={porAgente} />
        <Agregacao titulo="Memória instalada" itens={porMemoria} />
        <Agregacao titulo="Processador" itens={porCpu} />
      </div>

      <Bloco titulo="O que ainda não é inventariado">
        <ul style={{ margin: 0, paddingLeft: 18, fontSize: 11.5, color: 'var(--fg2)', lineHeight: 1.8 }}>
          <li><strong>Modelo do equipamento e fabricante</strong> — uma consulta a
            <span className="mono"> Win32_ComputerSystem</span> no agente resolve.</li>
          <li><strong>Ano de aquisição</strong> — não existe no Windows; precisa vir de
            uma planilha de patrimônio ou do BIOS (<span className="mono">Win32_BIOS</span>).</li>
          <li><strong>Software instalado e cobertura</strong> —
            <span className="mono"> Win32_Product</span> é lento e dispara reparo de MSI;
            o caminho certo é ler o registro de desinstalação.</li>
          <li><strong>Deriva de configuração</strong> — exige um baseline por marca para
            comparar, que também não existe.</li>
        </ul>
      </Bloco>
    </>
  );
}

function agrupar(hosts: Host[], chave: (h: Host) => string) {
  const m = new Map<string, number>();
  for (const h of hosts) m.set(chave(h), (m.get(chave(h)) ?? 0) + 1);
  return [...m].sort((a, b) => b[1] - a[1]);
}

function Agregacao({ titulo, itens }: { titulo: string; itens: [string, number][] }) {
  const maior = Math.max(1, ...itens.map(([, n]) => n));
  return (
    <Bloco titulo={titulo}>
      {itens.length === 0 && (
        <p style={{ margin: 0, fontSize: 11.5, color: 'var(--fg3)' }}>Nenhuma máquina no escopo.</p>
      )}
      {itens.map(([rot, n]) => (
        <div key={rot} style={{ marginBottom: 10 }}>
          <div style={{ display: 'flex', gap: 8, fontSize: 11, marginBottom: 4 }}>
            <span style={{
              color: rot.startsWith('não reportado') || rot === 'sem agente' ? 'var(--fg3)' : 'var(--fg2)',
              overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
            }}>
              {rot}
            </span>
            <span className="mono" style={{ marginLeft: 'auto', color: 'var(--fg3)' }}>{n}</span>
          </div>
          <div style={{ height: 4, borderRadius: 4, background: 'var(--pnl2)', overflow: 'hidden' }}>
            <div style={{
              height: '100%', width: `${(100 * n) / maior}%`,
              background: 'var(--info)', borderRadius: 4,
            }} />
          </div>
        </div>
      ))}
    </Bloco>
  );
}
