// Modal — a caixa central, para o que interrompe o fluxo.
import * as React from 'react';
import { Modal, Botao, CaixaComando } from '@cajupar/sentinela-ds';

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

const COMANDO =
  "& ([scriptblock]::Create((irm 'https://zrdglshzhlflnakflnki.supabase.co/functions/v1/ingest/instalar.ps1'))) " +
  "-Token 'mon_a1b2c3d4e5f6a7b8c9d0'";

/**
 * Cadastrar um PC: dois passos e nada mais.
 *
 * Preencher o nome e copiar um comando. Gerar token, montar configuracao e
 * baixar o agente acontece do outro lado — quem esta na loja nao precisa saber
 * que isso existe.
 */
export const AdicionarPC = () => (
  <Palco altura={380}>
    <Modal titulo="Adicionar um PC ao monitoramento">
      <p className="dica">
        A máquina foi cadastrada. Rode este comando no PC da loja, como
        Administrador. O token aparece uma única vez.
      </p>
      <CaixaComando comando={COMANDO} />
      <div style={{ display: 'flex', gap: 8, marginTop: 16, justifyContent: 'flex-end' }}>
        <Botao variante="secundario">Fechar</Botao>
        <Botao variante="primario">Copiar comando</Botao>
      </div>
    </Modal>
  </Palco>
);
