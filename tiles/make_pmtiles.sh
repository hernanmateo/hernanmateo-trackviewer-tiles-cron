#!/usr/bin/env bash
# Empaqueta un ráster de capa (Byte, nodata 255, EPSG:3857) como UN archivo
# .pmtiles y lo sube a R2. Sustituye a gdal2tiles + rclone de un directorio
# de millones de PNG: pasamos de ~1 operación de escritura POR TILE (lo que
# disparó la factura: 4,50 $/millón) a una decena por capa entera.
#
#   ./make_pmtiles.sh <raster.tif> <dataset> <average|nearest> [minzoom]
#
# Camino: GTiff -> MBTiles (pirámide interna, zoom nativo por resolución)
#         -> gdaladdo (zooms inferiores) -> pmtiles convert -> R2.
# Validado 2026-09-11 contra los tiles ya servidos: PNG de 1 banda idéntico
# en formato, direccionamiento XYZ correcto (pmtiles convert ya voltea el
# eje Y de MBTiles) y valores dentro del ruido de remuestreo (93 % a ±1°).
#
# NOTA sobre el zoom máximo: el driver elige el zoom cuya resolución casa con
# el dato (z14 para 10 m, z12 para 30 m). NO forzamos más: el z15 que venía
# generando gdal2tiles era una interpolación sin información nueva que
# multiplicaba por 4 el número de tiles. El cliente hace ese sobrezoom solo.
set -euo pipefail
cd "$(dirname "$0")"
SRC="${1:?raster de entrada}"
DATASET="${2:?nombre del dataset (p.ej. slope_val_alps)}"
RESAMPLE="${3:-average}"
MINZOOM="${4:-6}"

W="work_pmtiles_$DATASET"
rm -rf "$W"; mkdir -p "$W"
MB="$W/$DATASET.mbtiles"
PM="$W/$DATASET.pmtiles"

echo ">> [$DATASET] MBTiles (zoom nativo)"
# RESAMPLING debe seguir al tipo de dato TAMBIÉN en el nivel base, no solo en
# los overviews: el driver interpola por defecto y en las capas de CLASE
# (aspect, sun) eso inventa sectores — de un ráster con solo los valores 20 y
# 200 salían 22, 24, 26... y en el mapa se veía moteado de colores imposibles.
R_BASE=$( [ "$RESAMPLE" = "nearest" ] && echo NEAREST || echo AVERAGE )
gdal_translate -q -of MBTILES "$SRC" "$MB" -co TILE_FORMAT=PNG -co RESAMPLING=$R_BASE

# Zoom nativo elegido por el driver → cuántos overviews hacen falta para
# bajar hasta MINZOOM (cada overview = un zoom menos).
MAXZ=$(python3 -c "
import sqlite3,sys
c=sqlite3.connect('$MB')
m=dict(c.execute('select name,value from metadata').fetchall())
print(m.get('maxzoom','14'))")
LEVELS=""
n=1
for _ in $(seq 1 $((MAXZ - MINZOOM))); do n=$((n*2)); LEVELS="$LEVELS $n"; done
echo ">> [$DATASET] zoom nativo z$MAXZ → overviews hasta z$MINZOOM ($LEVELS)"
[ -n "$LEVELS" ] && gdaladdo -q -r "$RESAMPLE" "$MB" $LEVELS

echo ">> [$DATASET] convertir a PMTiles"
pmtiles convert "$MB" "$PM"
pmtiles show "$PM" | grep -iE "min zoom|max zoom|tile contents count"

echo ">> [$DATASET] subida a R2 (un solo objeto)"
# --s3-no-check-bucket: el token de R2 no puede crear buckets y rclone, al
# subir un fichero suelto, intenta asegurarse de que existe (403 CreateBucket).
rclone copyto --s3-no-check-bucket \
  --header-upload "Cache-Control: public, max-age=86400" \
  "$PM" "r2:trackviewer-tiles/pmtiles/$DATASET.pmtiles"
ls -lh "$PM" | awk '{print "   tamaño:", $5}'
rm -rf "$W"
echo "PMTILES $DATASET DONE"
