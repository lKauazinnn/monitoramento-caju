// O pacote extrai a folha de estilo para um arquivo separado, entao o app a
// importa explicitamente. As fontes vem junto: sem elas o painel cai na fonte
// generica do navegador em qualquer sistema que nao seja Windows.
import '@cajupar/sentinela-ds/styles.css';
import '../../design-system/fontes/fontes.css';

import * as React from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App';

const raiz = document.getElementById('raiz');
if (!raiz) throw new Error('#raiz não existe no HTML');
createRoot(raiz).render(<React.StrictMode><App /></React.StrictMode>);
