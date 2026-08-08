// =============================================================================
// Pagina de conferencia — NAO faz parte do pacote
// =============================================================================
// Existe para eu OLHAR o resultado num navegador de verdade e comparar com o
// painel em producao, em vez de imaginar como ficou. Uma biblioteca que
// renderiza diferente do produto renderiza errado em todo desenho feito com
// ela, para sempre.
// =============================================================================

import * as React from 'react';
import { createRoot } from 'react-dom/client';
import {
  Sentinela, Marca, Vista, CartaoLateral, Tira, Cartao, CartaoLoja, Selo, Botao,
  FaixaIncidente, Comando, Evento, ListaEventos, Segmentado, Ficha, ZonaPerigo,
  ItemFila, Brinde, CaixaComando, Barra, Spark,
} from '../src/index';

const COMANDO_EXEMPLO =
  "& ([scriptblock]::Create((irm 'https://exemplo.supabase.co/functions/v1/ingest/instalar.ps1'))) -Token 'mon_a1b2c3'";

function Demo({ tema }: { tema: 'escuro' | 'claro' }) {
  return (
    <Sentinela tema={tema}>
      <div style={{ display: 'grid', gridTemplateColumns: '224px 1fr', minHeight: '100vh' }}>
        <aside className="lateral">
          <Marca escopo="12 lojas · 47 máquinas" />
          <nav className="vistas">
            <span className="secao-lateral mono">Operação</span>
            <Vista rotulo="Visão geral" contagem={47} ativa />
            <Vista rotulo="Offline" contagem={3} tom="ruim" />
            <Vista rotulo="Degradados" contagem={5} tom="alerta" />
            <Vista rotulo="Nunca vistas" contagem={0} />
          </nav>
          <CartaoLateral
            titulo="Ingestão" valor="182" unidade="amostras/min" tom="ok"
            nota="fluxo normal" spark={[4, 7, 6, 9, 8, 10, 9, 11, 9, 10]}
          />
          <CartaoLateral titulo="Latência ao gateway" valor="11.3 ms" nota="média das online" />
        </aside>

        <main className="principal">
          <header className="topo">
            <div className="topo-titulo">
              <span className="mono etiqueta-micro">Cajupar · tempo real</span>
              <h1>Centro de operações</h1>
            </div>
            <div className="topo-estado">
              <Selo tom="ok" valor={39}>ok</Selo>
              <Selo tom="alerta" valor={5}>degradados</Selo>
              <Selo tom="ruim" valor={3}>offline</Selo>
              <Botao variante="primario">+ Adicionar PC</Botao>
            </div>
          </header>

          <FaixaIncidente
            titulo="BSB-004 · PDV 02 sem contato há 14 min"
            descricao="A loja tem outras 3 máquinas respondendo normalmente."
            tags={['BSB-004', 'PDV 02', 'crítico']}
            quando="14 min"
            onReconhecer={() => {}}
          />

          <div className="tiras">
            <Tira rotulo="Frota online" valor="39" unidade="de 47"
                  nota="83% da frota reportando" spark={[30, 33, 36, 38, 39, 39, 38, 39]} />
            <Tira rotulo="Degradados" valor="5" tom="alerta" nota="serviço parado ou disco baixo" />
            <Tira rotulo="Offline" valor="3" tom="ruim" nota="BSB-004, SP-011" />
            <Tira rotulo="Incidentes" valor="0" zero nota="nenhum aberto" />
          </div>

          <div style={{ margin: '14px 0' }}>
            <Segmentado
              valor="24h"
              onChange={() => {}}
              opcoes={[
                { valor: '24h', rotulo: '24 h' },
                { valor: '7d', rotulo: '7 d' },
                { valor: '30d', rotulo: '30 d' },
              ]}
            />
          </div>

          <div className="grade">
            <Cartao nome="PDV 01" estado="online" contexto="BSB-001 — Sudoeste"
                    visto="há 12s" servicos="3 de 3 serviços"
                    metricas={[{ rotulo: 'CPU', valor: '29%' }, { rotulo: 'MEM', valor: '61%' },
                               { rotulo: 'DISCO', valor: '22%', tom: 'alerta' }]} />
            <Cartao nome="PDV 02" estado="degradado" contexto="BSB-001 — Sudoeste"
                    visto="há 40s" servicos="2 de 3 serviços"
                    metricas={[{ rotulo: 'CPU', valor: '88%', tom: 'alerta' },
                               { rotulo: 'MEM', valor: '74%' }]} />
            <Cartao nome="CAIXA 01" estado="offline" contexto="BSB-004 — Asa Norte" visto="há 14 min" />
            <Cartao nome="ADM 01" estado="never" contexto="SP-011 — Pinheiros" />
          </div>

          <div className="grade-lojas" style={{ marginTop: 18 }}>
            <CartaoLoja
              nome="Sudoeste" codigo="BSB-001" situacao="estavel"
              hosts={[{ rotulo: 'PDV 01', estado: 'online' }, { rotulo: 'PDV 02', estado: 'online' },
                      { rotulo: 'PDV 03', estado: 'online' }, { rotulo: 'ADM', estado: 'online' }]}
              celulas={[{ rotulo: 'ONLINE', valor: '4/4', tom: 'ok' },
                        { rotulo: 'CPU', valor: '31%' }, { rotulo: 'DISCO', valor: '46%' }]}
            />
            <CartaoLoja
              nome="Asa Norte" codigo="BSB-004" situacao="incidente"
              hosts={[{ rotulo: 'PDV 01', estado: 'online' }, { rotulo: 'PDV 02', estado: 'offline' },
                      { rotulo: 'CAIXA', estado: 'degradado' }, { rotulo: 'ADM', estado: 'online' }]}
              celulas={[{ rotulo: 'ONLINE', valor: '2/4', tom: 'ruim' },
                        { rotulo: 'CPU', valor: '54%' }, { rotulo: 'DISCO', valor: '12%', tom: 'ruim' }]}
            />
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, marginTop: 18 }}>
            <div className="painel-caixa">
              <h3>Comandos recentes</h3>
              <ul className="comandos">
                <Comando acao="Reiniciar serviço" estado="succeeded" quando="13:34"
                         resultado="serviço 'Spooler': Stopped -> Running" />
                <Comando acao="Limpar temporários" estado="pending" quando="13:36"
                         simulacao onCancelar={() => {}} />
                <Comando acao="Reiniciar o PC" estado="failed" quando="12:02"
                         resultado="expirou sem ser executado" />
              </ul>
            </div>
            <div className="painel-caixa">
              <h3>Eventos recentes</h3>
              <ListaEventos>
                <Evento tipo="alert_open" mensagem="PDV 02: sem contato há 14 min"
                        quando="13:20" severidade="critical" />
                <Evento tipo="command_queued" mensagem="reiniciar Spooler em PDV 01" quando="13:34" />
                <Evento tipo="machine_first_seen" mensagem="primeiro contato do agente ps-1.3.1"
                        quando="11:02" />
              </ListaEventos>
            </div>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, marginTop: 18 }}>
            <div className="painel-caixa">
              <h3>Ficha</h3>
              <Ficha linhas={[
                { rotulo: 'Status', valor: 'online' },
                { rotulo: 'Hostname', valor: 'DESKTOP-K7N6IMC' },
                { rotulo: 'MAC da placa', valor: 'c8:7f:54:c6:c9:92' },
                { rotulo: 'Uptime', valor: '1h 57m' },
                { rotulo: 'Sinalizadores', valor: '' },
              ]} />
              <div style={{ marginTop: 12 }}><Barra pct={72} /></div>
              <div style={{ marginTop: 10 }}><Barra pct={95} /></div>
            </div>
            <div className="painel-caixa">
              <ZonaPerigo
                titulo="Remover esta máquina"
                aviso="Apaga o cadastro e todo o histórico dela. Não há como desfazer."
              >
                <Botao variante="perigo" largo>Remover máquina</Botao>
              </ZonaPerigo>
              <div style={{ marginTop: 14 }}>
                <CaixaComando comando={COMANDO_EXEMPLO} />
              </div>
              <ul className="fila" style={{ marginTop: 14 }}>
                <ItemFila titulo="PDV 02 · Spooler parado" detalhe="há 6 min" tom="alerta" />
                <ItemFila titulo="CAIXA 01 · offline" detalhe="há 14 min" tom="ruim" />
              </ul>
            </div>
          </div>

          <div style={{ marginTop: 20, display: 'flex', gap: 10, flexWrap: 'wrap', alignItems: 'center' }}>
            <Botao variante="primario">Primário</Botao>
            <Botao variante="secundario">Secundário</Botao>
            <Botao variante="acao">Ação</Botao>
            <Botao variante="perigo">Perigo</Botao>
            <Botao variante="perigo" armado>Confirmar: apagar tudo</Botao>
            <Spark valores={[3, 6, 4, 9, 7, 11, 8, 12, 10, 13]} />
          </div>
        </main>
      </div>
      <Brinde mensagem="Comando enviado em modo simulação." />
    </Sentinela>
  );
}

const tema = (new URLSearchParams(location.search).get('tema') as 'claro' | 'escuro') || 'escuro';
createRoot(document.getElementById('raiz')!).render(<Demo tema={tema} />);
