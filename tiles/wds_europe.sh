#!/usr/bin/env bash
# Cuadrícula WDS (nieve húmeda/seca, Copernicus HR-WSI) de toda Europa:
# recorre las cajas llamando a gfsc_daily.sh (el motor común de las capas de
# nieve diarias) con PRODUCT=wds y resume al final. Hermano de
# gfsc_europe.sh; ver README-wds.md.
#
#   ./wds_europe.sh                                   # todas las cajas, ayer UTC
#   DATE=2026-09-17 ./wds_europe.sh                   # fecha concreta
#   REGIONS="wds_iberia wds_nordic" ./wds_europe.sh   # relanzar solo algunas
#
# El resto de variables de gfsc_daily.sh (UPLOAD=0, DRY_RUN, MINZOOM…) pasan
# tal cual por el entorno.
#
# Secuencial a propósito y tolerante a fallos por caja, igual que
# gfsc_europe.sh. OJO con el código 3: en GFSC significa "aún no publicado,
# reintentar"; aquí puede ser definitivo — WDS solo tiene producto en las
# teselas con pasada de Sentinel-1 ese día (verificado 2026-09-18 contando
# por OData: p. ej. el 2026-09-17 medit y turkey tenían 0 productos y el 16
# tenían 54 y 40). La caja se queda sirviendo el último día con datos (su
# meta.json dice la fecha) hasta la siguiente pasada.
#
# Código de salida: 0 = todas ok (avisos incluidos); 1 = alguna caja falló.
set -uo pipefail
cd "$(dirname "$0")"

# ---------------------------------------------------------------- cuadrícula
# Mismos BORDES que REGION_TABLE de gfsc_europe.sh, solo cambia el prefijo
# del dataset: bordes idénticos = sin solapes ni huecos entre capas (regla
# DURA: las cajas comparten borde pero jamás área). Se mantienen las 9 cajas:
# a diferencia de SWS (solo montaña), WDS es pan-europeo (EEA38+UK, montaña
# y llanura) y el recuento OData de 2026-09-16/17 dio productos en TODAS las
# cajas en al menos uno de los dos días (mín. gfsc_britain: 2 y 7).
REGION_TABLE="
wds_pyralps  -2.5,41.5,17.5,48.5
wds_iberia   -10,35,-2.5,48.5
wds_medit    -2.5,35,17.5,41.5
wds_balkans  17.5,34,30,48.5
wds_turkey   30,34,45,43
wds_central  -2.5,48.5,30,56
wds_britain  -12,48.5,-2.5,62.5
wds_nordic   -2.5,56,32,72
wds_iceland  -25,62.5,-12,67
"

ALL_REGIONS=$(awk 'NF {print $1}' <<<"$REGION_TABLE")
REGIONS="${REGIONS:-$ALL_REGIONS}"

bbox_of() { awk -v r="$1" '$1 == r {print $2}' <<<"$REGION_TABLE"; }

OK_LIST=""; WARN_LIST=""; FAIL_LIST=""
T0=$SECONDS
for region in $REGIONS; do
  bbox=$(bbox_of "$region")
  if [ -z "$bbox" ]; then
    echo "!! región desconocida: $region (no está en REGION_TABLE)" >&2
    FAIL_LIST="$FAIL_LIST $region(desconocida)"
    continue
  fi
  echo
  echo "==== [$region] bbox=$bbox  $(date -u +%FT%TZ) ===="
  t=$SECONDS
  PRODUCT=wds DATASET="$region" BBOX="$bbox" ./gfsc_daily.sh
  rc=$?
  dt=$((SECONDS - t))
  case $rc in
    0) OK_LIST="$OK_LIST $region(${dt}s)" ;;
    3) WARN_LIST="$WARN_LIST $region(sin-producto)" ;;
    *) FAIL_LIST="$FAIL_LIST $region(rc=$rc,${dt}s)"
       echo "!! [$region] falló con código $rc; sigo con la siguiente" >&2 ;;
  esac
done

echo
echo "== Resumen WDS Europa: $(( (SECONDS - T0) / 60 )) min $(( (SECONDS - T0) % 60 )) s =="
echo "   ok:    ${OK_LIST:-"(ninguna)"}"
echo "   aviso: ${WARN_LIST:-"(ninguno)"}"
echo "   fallo: ${FAIL_LIST:-"(ninguno)"}"
[ -z "$FAIL_LIST" ]
