// O enum das telas mora sozinho: se vivesse em App.tsx, cada tela que precisa
// do tipo importaria a casca, e a casca importa todas as telas — um ciclo.
export type Vistas =
  | 'noc' | 'frota' | 'incidente' | 'inventario' | 'alertas' | 'auditoria' | 'plantao';
