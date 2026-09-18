#!/usr/bin/env bash
# Cuadrícula GFSC de toda Europa (EEA38+UK): recorre las cajas llamando a
# gfsc_daily.sh una por una y resume al final.
#
#   ./gfsc_europe.sh                                    # todas las cajas, ayer UTC
#   DATE=2026-09-16 ./gfsc_europe.sh                    # fecha concreta
#   REGIONS="gfsc_iberia gfsc_nordic" ./gfsc_europe.sh  # relanzar solo algunas
#
# El resto de variables de gfsc_daily.sh (UPLOAD=0, DRY_RUN, MINZOOM…) pasan
# tal cual por el entorno.
#
# Secuencial a propósito: cada lote de gfsc_daily.sh borra su directorio de
# trabajo al acabar, así el pico de disco es el de UNA caja y no el de todas.
# Una caja que falla NO aborta el resto: se registra y se sigue. El código 3
# de gfsc_daily.sh (producto de esa fecha aún no publicado en CDSE) cuenta
# como aviso, no como fallo: reintentar más tarde.
#
# Código de salida: 0 = todas ok (avisos incluidos); 1 = alguna caja falló.
set -uo pipefail
cd "$(dirname "$0")"

# ---------------------------------------------------------------- cuadrícula
# ÚNICA fuente de verdad de las cajas: dataset y bbox "w,s,e,n" (EPSG:4326).
# Regla DURA: las cajas comparten BORDE pero jamás ÁREA — la app pinta todas
# las fuentes del encuadre a la vez y dos rásteres semitransparentes
# solapados alteran el color. gfsc_pyralps ya estaba en producción antes que
# el resto; la cuadrícula lo rodea casando bordes con él.
# Cobertura: EEA38+UK (Iberia, Mediterráneo con las islas, Balcanes+Grecia,
# Turquía+Chipre, Europa central hasta los Cárpatos, Islas Británicas con
# las Feroe, Escandinavia+Finlandia hasta 72°N, Islandia). Fuera: Rusia,
# Cáucaso (no son EEA38) y Svalbard (>72°N).
# Dimensionado 2026-09-17 con los productos CDSE del día 16: la caja mayor
# (gfsc_nordic) son 219 productos; el tope cómodo por lote ronda los 400.
REGION_TABLE="
gfsc_pyralps  -2.5,41.5,17.5,48.5
gfsc_iberia   -10,35,-2.5,48.5
gfsc_medit    -2.5,35,17.5,41.5
gfsc_balkans  17.5,34,30,48.5
gfsc_turkey   30,34,45,43
gfsc_central  -2.5,48.5,30,56
gfsc_britain  -12,48.5,-2.5,62.5
gfsc_nordic   -2.5,56,32,72
gfsc_iceland  -25,62.5,-12,67
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
  DATASET="$region" BBOX="$bbox" ./gfsc_daily.sh
  rc=$?
  dt=$((SECONDS - t))
  case $rc in
    0) OK_LIST="$OK_LIST $region(${dt}s)" ;;
    3) WARN_LIST="$WARN_LIST $region(sin-producto-aún)" ;;
    *) FAIL_LIST="$FAIL_LIST $region(rc=$rc,${dt}s)"
       echo "!! [$region] falló con código $rc; sigo con la siguiente" >&2 ;;
  esac
done

echo
echo "== Resumen GFSC Europa: $(( (SECONDS - T0) / 60 )) min $(( (SECONDS - T0) % 60 )) s =="
echo "   ok:    ${OK_LIST:-"(ninguna)"}"
echo "   aviso: ${WARN_LIST:-"(ninguno)"}"
echo "   fallo: ${FAIL_LIST:-"(ninguno)"}"
[ -z "$FAIL_LIST" ]
