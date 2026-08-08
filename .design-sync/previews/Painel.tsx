// Painel — a gaveta de detalhe, que entra pela direita.
import * as React from 'react';
import { Painel, Ficha, Botao, ZonaPerigo, Comando } from '@cajupar/sentinela-ds';

/**
 * O PALCO.
 *
 * Gaveta, modal e brinde sao \`position: fixed\` — eles se posicionam pela
 * JANELA, nao pelo elemento que os contem. Dentro de um cartao de preview isso
 * os faz escapar para fora e renderizar sobre o fundo branco da pagina, com o
 * texto claro do tema escuro em cima: some.
 *
 * \`transform\` num ancestral cria um contexto de contencao — a partir dai
 * \`fixed\` passa a se posicionar por ELE. E o unico jeito de mostrar uma
 * sobreposicao dentro de um cartao sem mentir sobre o componente: ele continua
 * sendo o mesmo componente fixo, so que num palco do tamanho do cartao.
 *
 * No aplicativo de verdade nada disto e necessario — la a janela E o palco.
 */
const Palco = ({ children, altura = 420 }: { children: React.ReactNode; altura?: number }) => (
  <div
    style={{
      position: 'relative',
      transform: 'translateZ(0)',
      height: altura,
      overflow: 'hidden',
      borderRadius: 12,
      background: 'var(--bg)',
      border: '1px solid var(--bd2)',
    }}
  >
    {children}
  </div>
);

/**
 * A gaveta como ela e usada: aberta sobre a grade.
 *
 * Gaveta e nao pagina, de proposito. Quem investiga uma maquina nao quer perder
 * a grade de vista — o contexto de "e so essa ou a loja inteira?" continua
 * atras, e trocar de pagina custaria justamente essa resposta.
 */
export const DetalheDeMaquina = () => (
  <Palco altura={560}>
    <Painel titulo="PDV 02" sub="BSB-001 — Sudoeste · Cajupar">
      <Ficha
        linhas={[
          { rotulo: 'Status', valor: 'degradado' },
          { rotulo: 'Hostname', valor: 'PDV02-BSB001' },
          { rotulo: 'Último contato', valor: 'há 40s' },
          { rotulo: 'IP na LAN', valor: '192.168.15.42' },
          { rotulo: 'MAC da placa', valor: 'c8:7f:54:c6:c9:92' },
          { rotulo: 'Versão do agente', valor: 'ps-1.3.1' },
          { rotulo: 'Uptime', valor: '31 dias' },
        ]}
      />
      <h3 style={{ marginTop: 20, fontSize: 12.5 }}>Comandos recentes</h3>
      <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
        <Comando acao="Reiniciar serviço" estado="succeeded" quando="13:34"
                 resultado="serviço 'Spooler': Stopped -> Running" />
        <Comando acao="Testar coleta" estado="pending" quando="13:41" onCancelar={() => {}} />
      </ul>
      <ZonaPerigo
        titulo="Remover esta máquina"
        aviso="Apaga o cadastro e todo o histórico dela. Não há como desfazer."
      >
        <Botao variante="perigo" largo>Remover máquina</Botao>
      </ZonaPerigo>
    </Painel>
  </Palco>
);
