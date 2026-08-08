// =============================================================================
// Ícones — SVG inline, sem biblioteca externa
// =============================================================================
// Nenhuma dependência de ícones, e o motivo não é economia: a CSP do painel é
// `default-src 'none'`, então uma fonte de ícone ou um sprite remoto
// simplesmente não carregaria. Além disso, um painel de operação precisa abrir
// com a rede da loja ruim.
//
// Traço leve (1.8) de propósito: o ícone acompanha o número, não compete com
// ele. Num painel onde o dado é o conteúdo, ícone pesado vira ruído.
// =============================================================================

import * as React from 'react';

const D: Record<string, React.ReactNode> = {
  grade: <><rect x="3" y="3" width="7" height="7" rx="1.5" /><rect x="14" y="3" width="7" height="7" rx="1.5" /><rect x="3" y="14" width="7" height="7" rx="1.5" /><rect x="14" y="14" width="7" height="7" rx="1.5" /></>,
  servidor: <><rect x="3" y="4" width="18" height="7" rx="2" /><rect x="3" y="13" width="18" height="7" rx="2" /><path d="M7 7.5h.01M7 16.5h.01" /></>,
  loja: <><path d="M3 9.5 5 4h14l2 5.5" /><path d="M4 9.5V20h16V9.5" /><path d="M3 9.5a3 3 0 0 0 6 0 3 3 0 0 0 6 0 3 3 0 0 0 6 0" /></>,
  sino: <><path d="M18 8a6 6 0 1 0-12 0c0 7-3 8-3 8h18s-3-1-3-8" /><path d="M13.7 21a2 2 0 0 1-3.4 0" /></>,
  arquivo: <><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" /><path d="M14 2v6h6" /><path d="M8 13h8M8 17h5" /></>,
  escudo: <><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" /><path d="m9 12 2 2 4-4" /></>,
  cpu: <><rect x="5" y="5" width="14" height="14" rx="2" /><rect x="9" y="9" width="6" height="6" /><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3" /></>,
  disco: <><ellipse cx="12" cy="6" rx="8" ry="3" /><path d="M4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6" /><path d="M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3" /></>,
  atividade: <path d="M3 12h4l3 8 4-16 3 8h4" />,
  relogio: <><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></>,
  aviso: <><path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" /><path d="M12 9v4M12 17h.01" /></>,
  check: <path d="m4 12 5 5L20 6" />,
  monitor: <><rect x="2" y="4" width="20" height="13" rx="2" /><path d="M8 21h8M12 17v4" /></>,
  termometro: <><path d="M14 14.8V4a2 2 0 1 0-4 0v10.8a4 4 0 1 0 4 0z" /></>,
  wifiOff: <><path d="M2 2 22 22" /><path d="M8.5 16.4a5 5 0 0 1 7 0" /><path d="M5 12.9a10 10 0 0 1 4-2.4" /><path d="M15 10.5a10 10 0 0 1 4 2.4" /><path d="M12 20h.01" /></>,
  usuarios: <><circle cx="9" cy="8" r="3.5" /><path d="M2.5 20a6.5 6.5 0 0 1 13 0" /><path d="M16 5.2a3.5 3.5 0 0 1 0 5.6" /><path d="M17.5 20a6.5 6.5 0 0 0-2-4.7" /></>,
  medidor: <><path d="M12 14a2 2 0 1 0 0-4 2 2 0 0 0 0 4z" /><path d="M12 12 16 8" /><path d="M4 18a9 9 0 1 1 16 0" /></>,
  olho: <><path d="M2 12s3.5-6 10-6 10 6 10 6-3.5 6-10 6-10-6-10-6z" /><circle cx="12" cy="12" r="3" /></>,
  chave: <><path d="M15 7a4 4 0 1 1-4 4" /><path d="M11 11 3 19v2h3v-2h2v-2h2l2-2" /></>,
  caixa: <><path d="M21 8 12 3 3 8v8l9 5 9-5z" /><path d="M3 8l9 5 9-5M12 13v8" /></>,
  lista: <><path d="M8 6h13M8 12h13M8 18h13" /><path d="M3 6h.01M3 12h.01M3 18h.01" /></>,
  telefone: <><rect x="6" y="2" width="12" height="20" rx="3" /><path d="M11 18h2" /></>,
  lua: <path d="M20 14.5A8.5 8.5 0 1 1 9.5 4a6.6 6.6 0 0 0 10.5 10.5z" />,
  sol: <><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" /></>,
  enviar: <path d="M22 2 11 13M22 2l-7 20-4-9-9-4z" />,
  email: <><rect x="2" y="4" width="20" height="16" rx="2" /><path d="m2 7 10 6 10-6" /></>,
  refresh: <><path d="M21 12a9 9 0 1 1-3-6.7" /><path d="M21 3v5h-5" /></>,
  terminal: <><rect x="2" y="4" width="20" height="16" rx="2" /><path d="m7 9 3 3-3 3M13 15h4" /></>,
  radio: <><circle cx="12" cy="12" r="2" /><path d="M7.8 7.8a6 6 0 0 0 0 8.4M16.2 7.8a6 6 0 0 1 0 8.4" /><path d="M4.9 4.9a10 10 0 0 0 0 14.2M19.1 4.9a10 10 0 0 1 0 14.2" /></>,
  tomada: <><path d="M9 2v6M15 2v6" /><path d="M5 8h14v3a7 7 0 0 1-14 0z" /><path d="M12 18v4" /></>,
  busca: <><circle cx="11" cy="11" r="7" /><path d="m20 20-3.5-3.5" /></>,
  fechar: <path d="M18 6 6 18M6 6l12 12" />,
};

export function Ico({ n, tam = 15.5, cor }: { n: string; tam?: number; cor?: string }) {
  const d = D[n];
  if (!d) return null;
  return (
    <svg
      viewBox="0 0 24 24" width={tam} height={tam} aria-hidden="true"
      fill="none" stroke={cor ?? 'currentColor'} strokeWidth={1.85}
      strokeLinecap="round" strokeLinejoin="round"
      style={{ flex: '0 0 auto' }}
    >
      {d}
    </svg>
  );
}

/** O ícone de cada tipo de máquina, para o cabeçalho da gaveta. */
export const icoDoTipo = (roleCode: string): string => {
  const r = roleCode.toLowerCase();
  if (r.includes('pdv') || r.includes('caixa')) return 'monitor';
  if (r.includes('serv') || r.includes('sql')) return 'servidor';
  if (r.includes('kiosk') || r.includes('totem')) return 'monitor';
  return 'cpu';
};
