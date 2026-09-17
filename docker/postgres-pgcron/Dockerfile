# =============================================================================
# Postgres 16 + pg_cron — a imagem do banco para producao self-hosted
# =============================================================================
# A imagem oficial postgres:16 NAO traz pg_cron, e sem ele quatro coisas param
# de acontecer sozinhas:
#
#   avaliar-alertas      nenhuma maquina offline abre alerta
#   rollup-horario       o historico de 400 dias deixa de ser consolidado
#   monitor_maintenance  PARA DE CRIAR PARTICAO FUTURA -- e quando as futuras
#                        acabam, a INGESTAO PARA. Nao degrada: para.
#   expurgo              o banco cresce para sempre
#
# O terceiro e o que morde primeiro e mais forte: a 0011 cria partições com
# alguns meses de folga, entao o sistema funciona por um tempo e quebra depois,
# quando ninguem mais associa o problema a extensao que faltou no dia um.
#
# shared_preload_libraries so vale se estiver ativo ANTES do servidor subir --
# nao adianta `alter system` depois. Por isso vai no CMD, que o entrypoint
# oficial repassa ao postgres.
# =============================================================================
FROM postgres:16

RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-16-cron \
 && rm -rf /var/lib/apt/lists/*

CMD ["postgres", "-c", "shared_preload_libraries=pg_cron", "-c", "cron.database_name=postgres"]
