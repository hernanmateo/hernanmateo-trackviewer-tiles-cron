#!/usr/bin/env bash
# Motor común de las capas diarias de nieve HR-WSI (Copernicus, 60 m):
# descarga los productos de una fecha y una caja → un PMTiles en R2.
# PRODUCT elige la capa (el resto de la cadena es idéntico):
#   PRODUCT=gfsc (defecto)  "Daily cumulative Gap-filled Fractional Snow
#                           Cover": fracción de nieve 0-100 %.
#   PRODUCT=wds             "Wet/Dry Snow" v2: clasificación categórica
#                           húmeda/seca/sin-nieve (banda SSC, ver
#                           README-wds.md). Solo hay producto en las teselas
#                           con pasada de Sentinel-1 ese día, así que la
#                           cobertura diaria es parcial (franjas de órbita).
#
#   DATE=2026-09-16 ./gfsc_daily.sh          # fecha concreta
#   ./gfsc_daily.sh                          # por defecto: ayer UTC
#   PRODUCT=wds DATASET=wds_pyralps ./gfsc_daily.sh
#   DRY_RUN=1 DRY_SRC=test.tif ./gfsc_daily.sh   # valida la cadena GDAL→PMTiles
#                                                # sin CDSE y sin subir a R2
#
# Cadena: OData (búsqueda pública) → descarga por S3 de CDSE de SOLO el
# GeoTIFF de la banda (rclone) → limpieza de códigos → warp a EPSG:3857
# (mosaico, las teselas vienen en zonas UTM) → MBTiles → PMTiles → R2 + json
# de metadatos con la fecha.
#
# CÓDIGOS DE LA BANDA GF de GFSC (verificados 2026-09-17 en los metadatos STAC
# de la colección CDSE clms_wsi_gap-filled-fractional-snow-cover_europe_utm_60m_daily_v1,
# item_assets.GF, coherentes con el PUM de HR-S&I Snow de land.copernicus.eu):
#     0-100  fracción de nieve (%)
#     205    nube o sombra de nube (el gap-filling no siempre lo rellena todo)
#     210    agua interior
#     255    nodata
# Mapeo aplicado: 0-100 se conserva; 205, 210, 255 (y cualquier otro valor
# fuera de rango) → 255 = nodata. Byte, nodata 255, como slope_val.
# (Los códigos de la banda SSC de WDS están en el bloque PRODUCT de abajo y
# en README-wds.md.)
#
# RESAMPLING: NEAREST y no AVERAGE, a propósito. Medido aquí el 2026-09-17
# con un ráster sintético (valor 80 contra nodata 255 en borde diagonal):
# gdaladdo -r average sobre MBTiles promedia el canal rojo IGNORANDO el
# alpha, y en los overviews aparecían valores visibles 124/146/157 (mezcla
# de 80 con el 255 de nodata) con alpha=255. Con datos reales serían halos
# de "nieve fantasma" en todos los bordes de nubes/agua/región. NEAREST
# submuestrea sin inventar valores; para una capa que se mira como mancha
# de nieve la pérdida a zooms bajos es irrelevante.
#
# ZOOM NATIVO: warpeamos a la resolución EXACTA de z11 (76.437 m/px en 3857;
# a 42-48° de latitud son ~51-57 m de terreno, justo por encima de los 60 m
# del producto). Con -tr exacto el driver MBTiles (estrategia AUTO) cae en
# z11 determinísticamente; ZOOM_LEVEL_STRATEGY=UPPER aquí NO sirve: probado,
# con la resolución exacta redondea a z12 y cuadruplica tiles sin información
# nueva. Tras el translate se comprueba que el zoom nativo salió z11.
#
# SUBIDA ATÓMICA: un PUT de S3/R2 es atómico por objeto (rclone copyto de un
# archivo hace un solo PUT/multipart commit: los lectores ven el objeto viejo
# hasta que el nuevo está completo — nunca un archivo a medias). El Worker ya
# maneja el reemplazo (EtagMismatch → reintento). El json de metadatos se
# sube DESPUÉS del pmtiles y hace de marca de commit: si el json dice fecha
# X, el pmtiles de fecha X ya está servido.
#
# Códigos de salida: 0 = ok; 3 = producto de esa fecha aún no publicado en
# CDSE (reintentar más tarde; no se ha subido nada); otro = error.
set -euo pipefail
cd "$(dirname "$0")"

# Credenciales en local: si existe tiles/.env se carga automáticamente.
# `.env` está en .gitignore, así que las claves nunca entran en el repo. En CI
# no existe ese fichero y las variables llegan de los secretos del runner.
# Las variables que ya vengan del entorno mandan sobre el fichero.
if [ -f .env ]; then
  _prev_env=$(export -p)
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
  eval "$_prev_env"
  unset _prev_env
fi

# ------------------------------------------------------------- producto
# Lo que cambia entre capas HR-WSI: colección CDSE, prefijo de nombre para el
# catálogo, sufijo del GeoTIFF de la banda dentro del producto, expresión de
# limpieza de códigos y (opcional) lista de valores legales que la
# verificación posterior exige en los tiles generados.
PRODUCT="${PRODUCT:-gfsc}"
case "$PRODUCT" in
  gfsc)
    COLLECTION="clms_wsi_gap-filled-fractional-snow-cover_europe_utm_60m_daily_v1"
    NAME_PREFIX="CLMS_WSI_GFSC_060m"
    BAND_SUFFIX="GF"
    # 0-100 se conserva; 205 (nube), 210 (agua), 255 y cualquier otro → 255.
    CLEAN_CALC="(A<=100)*A + (A>100)*255"
    # Sin verificación de valores: es un dato casi continuo (0-100) ya
    # validado en producción; la verificación se pensó para las capas
    # categóricas, donde un valor inventado es una clase que no existe.
    LEGAL_VALUES=""
    DEFAULT_DATASET="gfsc_pyralps"
    ;;
  wds)
    COLLECTION="clms_wsi_wet-dry-snow_europe_utm_60m_daily_v2"
    NAME_PREFIX="CLMS_WSI_WDS_060m"
    BAND_SUFFIX="SSC"
    # CÓDIGOS DE LA BANDA SSC (verificados 2026-09-18 en item_assets.SSC de
    # la colección CDSE, classification:classes; ver README-wds.md):
    #   110 nieve húmeda   115 nieve seca   120 sin nieve o nieve parcheada
    #   200 sombra/layover radar  205 nube  210 agua  220 bosque  230 urbano
    #   255 nodata
    # Mapeo: 110/115/120 se conservan; todas las máscaras y cualquier valor
    # imprevisto → 255 = nodata. Dato CATEGÓRICO: cualquier promediado
    # inventaría clases (ver bloque RESAMPLING de abajo), de ahí la
    # verificación estricta de LEGAL_VALUES tras generar.
    CLEAN_CALC="(A==110)*110 + (A==115)*115 + (A==120)*120 + ((A!=110)&(A!=115)&(A!=120))*255"
    LEGAL_VALUES="110,115,120,255"
    DEFAULT_DATASET="wds_pyralps"
    ;;
  *)
    echo "PRODUCT desconocido: $PRODUCT (esperaba gfsc o wds)" >&2
    exit 1
    ;;
esac
TAG=$(printf '%s' "$PRODUCT" | tr '[:lower:]' '[:upper:]')

DATASET="${DATASET:-$DEFAULT_DATASET}"
# bounds de la región pyr_alps de la app ([-2,42,17,48]) con medio grado de
# margen para que la capa no corte justo en el borde del mapa.
BBOX="${BBOX:-"-2.5,41.5,17.5,48.5"}"
MINZOOM="${MINZOOM:-6}"
DRY_RUN="${DRY_RUN:-0}"
DRY_SRC="${DRY_SRC:-}"

# Ayer UTC por defecto (los productos del día D se publican durante D+1).
# date de BSD (macOS) y GNU (Linux) difieren en la sintaxis de "ayer".
if [ -z "${DATE:-}" ]; then
  DATE=$(date -u -v-1d +%F 2>/dev/null || date -u -d yesterday +%F)
fi

# Resolución de z11 en Web Mercator: 2*pi*6378137 / 256 / 2^11. Vale para
# GFSC y WDS por igual: ambos son 60 m nativos (a 37-71°N son ~25-61 m de
# terreno por píxel de z11, siempre a la altura del producto o por encima).
RES=76.43702828517625

W="work_${PRODUCT}_$DATASET"
rm -rf "$W"; mkdir -p "$W/raw" "$W/clean"
PM="$W/$DATASET.pmtiles"
MB="$W/$DATASET.mbtiles"
META="$W/$DATASET.json"

# ---------------------------------------------------------------- descarga
N_PRODUCTS=0
if [ "$DRY_RUN" = "1" ] && [ -n "$DRY_SRC" ]; then
  echo ">> [$TAG $DATE] DRY_RUN: usando ráster(es) local(es): $DRY_SRC"
  i=0
  for f in $DRY_SRC; do cp "$f" "$W/raw/dry_$((i+=1)).tif"; done
  N_PRODUCTS=$i
else
  # La descarga va por el endpoint S3 de eodata con las claves S3 de CDSE
  # (se generan en https://eodata-s3keysmanager.dataspace.copernicus.eu).
  # Es la vía más simple de automatizar: la búsqueda OData no necesita auth,
  # y por S3 bajamos SOLO el GeoTIFF de la banda de cada tesela (66 KB-2 MB)
  # en vez del zip del producto vía OAuth+OData (que exige refrescar token).
  : "${CDSE_S3_ACCESS_KEY:?falta CDSE_S3_ACCESS_KEY (claves S3 de CDSE)}"
  : "${CDSE_S3_SECRET_KEY:?falta CDSE_S3_SECRET_KEY (claves S3 de CDSE)}"
  # Remote rclone "cdse" definido al vuelo por variables de entorno: no se
  # toca la config del usuario ni pasan secretos por argv.
  export RCLONE_CONFIG_CDSE_TYPE=s3
  export RCLONE_CONFIG_CDSE_PROVIDER=Other
  export RCLONE_CONFIG_CDSE_ENDPOINT=https://eodata.dataspace.copernicus.eu
  export RCLONE_CONFIG_CDSE_ACCESS_KEY_ID="$CDSE_S3_ACCESS_KEY"
  export RCLONE_CONFIG_CDSE_SECRET_ACCESS_KEY="$CDSE_S3_SECRET_KEY"

  LIST="$W/products.tsv"
  set +e
  python3 gfsc_query.py --date "$DATE" --bbox "$BBOX" --prefix "$NAME_PREFIX" > "$LIST"
  RC=$?
  set -e
  if [ $RC -eq 3 ]; then
    # Para GFSC significa "aún no publicado" (siempre acaba llegando); para
    # WDS puede ser definitivo: si Sentinel-1 no pasó por la caja ese día,
    # ese día no habrá producto. En ambos casos: no se sube nada y el
    # archivo del día anterior sigue servido (su meta.json dice su fecha).
    echo "$TAG $DATE: sin productos en CDSE para esa fecha/caja. No se sube nada."
    rm -rf "$W"
    exit 3
  elif [ $RC -ne 0 ]; then
    echo "$TAG $DATE: error consultando el catálogo OData" >&2
    exit 1
  fi
  N_PRODUCTS=$(wc -l < "$LIST" | tr -d ' ')

  echo ">> [$TAG $DATE] descargando $N_PRODUCTS ${BAND_SUFFIX}.tif de CDSE"
  if [ "$DRY_RUN" = "1" ]; then
    echo ">> DRY_RUN sin DRY_SRC: me paro antes de descargar. Pasa DRY_SRC=<tif> para validar la cadena GDAL."
    rm -rf "$W"
    exit 0
  fi
  while IFS=$'\t' read -r NAME S3PATH; do
    # S3Path = /eodata/CLMS/.../<NAME>; la banda está en
    # <NAME>/<NAME>_${BAND_SUFFIX}.tif (verificado por OData Nodes para
    # GFSC el 2026-09-17 y para WDS el 2026-09-18).
    rclone copyto "cdse:${S3PATH#/}/${NAME}_${BAND_SUFFIX}.tif" \
      "$W/raw/${NAME}_${BAND_SUFFIX}.tif"
  done < "$LIST"
fi

# ---------------------------------------------------------------- limpieza
# ANTES del mosaico, tesela a tesela y en su UTM nativo: las teselas MGRS
# vecinas se solapan y gdalwarp resuelve el solape con "el último válido
# gana". Si una máscara (nube, bosque, sombra radar…) llegara viva al warp,
# pisaría el dato válido de la tesela vecina; convertida ya en nodata 255,
# warp la salta y siempre gana el dato bueno. En WDS esto cubre además el
# caso de DOS productos del mismo día para la misma tesela (pasada
# ascendente y descendente de S1): se mosaican y el dato válido prevalece.
echo ">> [$TAG $DATE] limpieza de códigos (máscaras→255) en $N_PRODUCTS teselas"
for f in "$W"/raw/*.tif; do
  out="$W/clean/$(basename "$f")"
  # --hideNoData: que la expresión vea también los 255 de origen como valores
  # normales (si no, gdal_calc los enmascara y el where no los tocaría).
  gdal_calc.py -A "$f" --outfile="$out" \
    --calc="$CLEAN_CALC" \
    --NoDataValue=255 --type=Byte --hideNoData --quiet \
    --co COMPRESS=DEFLATE --co TILED=YES
done

# ---------------------------------------------------------------- mosaico 3857
# Un solo gdalwarp con todas las teselas: reproyecta cada una desde su zona
# UTM y mosaica. -r near: a esta escala (z11 ≈ 25-61 m de terreno vs 60 m
# del producto) apenas hay remuestreo real y near no mezcla valores.
read -r TE < <(python3 -c "
import math
w,s,e,n = ($BBOX)
R = 6378137.0
m = lambda lon: math.radians(lon)*R
p = lambda lat: R*math.log(math.tan(math.pi/4 + math.radians(lat)/2))
print(m(w), p(s), m(e), p(n))")
MOSAIC="$W/${DATASET}_3857.tif"
echo ">> [$TAG $DATE] warp+mosaico a EPSG:3857 (res z11)"
# shellcheck disable=SC2086
gdalwarp -q -t_srs EPSG:3857 -tr $RES $RES -te $TE \
  -r near -srcnodata 255 -dstnodata 255 \
  -multi -wo NUM_THREADS=ALL_CPUS \
  -co COMPRESS=DEFLATE -co TILED=YES \
  "$W"/clean/*.tif "$MOSAIC"

# ---------------------------------------------------------------- PMTiles
echo ">> [$TAG $DATE] MBTiles (NEAREST, ver cabecera) + overviews hasta z$MINZOOM"
gdal_translate -q -of MBTILES "$MOSAIC" "$MB" \
  -co TILE_FORMAT=PNG -co RESAMPLING=NEAREST

MAXZ=$(python3 -c "
import sqlite3
c = sqlite3.connect('$MB')
print(dict(c.execute('select name,value from metadata').fetchall())['maxzoom'])")
if [ "$DRY_RUN" != "1" ] && [ "$MAXZ" != "11" ]; then
  # Red de seguridad del contrato de zoom (ver cabecera): si el driver no ha
  # caído en z11 es que alguien tocó RES o el driver cambió de criterio.
  echo "$TAG: zoom nativo inesperado z$MAXZ (esperaba z11); revisa RES/driver" >&2
  exit 1
fi
LEVELS=""; n=1
for _ in $(seq 1 $((MAXZ - MINZOOM))); do n=$((n*2)); LEVELS="$LEVELS $n"; done
[ -n "$LEVELS" ] && gdaladdo -q -r nearest "$MB" $LEVELS

# Verificación de valores legales (solo capas categóricas, ver bloque
# PRODUCT): se decodifican tiles de TODOS los zooms del MBTiles y se exige
# que los píxeles visibles sean exactamente clases del mapeo. Detectaría un
# promediado colado en cualquier punto de la cadena (el bug de los halos que
# ya mordió aquí, ver bloque RESAMPLING).
if [ -n "$LEGAL_VALUES" ]; then
  echo ">> [$TAG $DATE] verificando valores legales {$LEGAL_VALUES} en los tiles"
  python3 check_tile_values.py "$MB" "$LEGAL_VALUES"
fi

pmtiles convert "$MB" "$PM"
pmtiles show "$PM" | grep -iE "min zoom|max zoom|tile contents count" || true

# Metadatos para la app: fecha del dato ("nieve a <fecha>"), instante de
# generación (detectar datos rancios) y cobertura.
python3 - "$META" <<EOF
import json, sys, datetime
json.dump({
    "dataset": "$DATASET",
    "date": "$DATE",
    "generated": datetime.datetime.now(datetime.timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
    "coverage": {
        "bbox": [$BBOX],
        "minzoom": $MINZOOM,
        "maxzoom": int("$MAXZ"),
        "products": int("$N_PRODUCTS"),
    },
    "source": "$COLLECTION",
    "attribution": "© Copernicus Land Monitoring Service / EEA",
}, open(sys.argv[1], "w"), indent=1)
EOF

# ---------------------------------------------------------------- subida
# UPLOAD=0 descarga y procesa de verdad pero NO sube: sirve para inspeccionar el
# resultado de una fecha cualquiera (p. ej. un día de invierno) sin publicar en
# producción un dato que no es el de hoy. DRY_RUN=1 es otra cosa: ni descarga.
if [ "$DRY_RUN" = "1" ] || [ "${UPLOAD:-1}" = "0" ]; then
  OUT_DIR="${DRY_OUT:-.}"
  cp "$PM" "$OUT_DIR/$DATASET.dry.pmtiles"
  cp "$META" "$OUT_DIR/$DATASET.dry.json"
  echo ">> sin subida. Resultado en $OUT_DIR/$DATASET.dry.{pmtiles,json}"
else
  echo ">> [$TAG $DATE] subida a R2 (pmtiles primero, json como marca de commit)"
  # Cache-Control corto: el objeto se reemplaza a diario. --s3-no-check-bucket:
  # el token de R2 no puede crear buckets (mismo motivo que make_pmtiles.sh).
  rclone copyto --s3-no-check-bucket \
    --header-upload "Cache-Control: public, max-age=21600" \
    "$PM" "r2:trackviewer-tiles/pmtiles/$DATASET.pmtiles"
  rclone copyto --s3-no-check-bucket \
    --header-upload "Cache-Control: public, max-age=300" \
    "$META" "r2:trackviewer-tiles/pmtiles/$DATASET.json"
fi

ls -lh "$PM" | awk '{print "   tamaño:", $5}'
rm -rf "$W"
echo "$TAG $DATASET $DATE DONE"
