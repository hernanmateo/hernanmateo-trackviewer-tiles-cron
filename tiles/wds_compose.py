#!/usr/bin/env python3
"""Composición temporal de la capa WDS: funde el mosaico del día con el
estado compuesto anterior en vez de reemplazarlo.

Uso:
  wds_compose.py --new mosaico.tif [--prev estado.tif] --date YYYY-MM-DD \
                 --max-age-days 7 --out estado_nuevo.tif

Por qué existe: Sentinel-1 cubre por franjas de órbita, así que el mosaico de
un día cualquiera solo tiene dato en parte de la caja. Regenerar el PMTiles
desde cero cada día hacía PARPADEAR la capa (medido el 2026-09-19: el archivo
del 17 tenía datos sobre los Alpes y el del 18 los dejó en nodata pese a
tener 71 productos — estaban en otra franja). La regla de composición, píxel
a píxel:

  - donde el mosaico NUEVO tiene dato (110/115/120) → manda el nuevo, edad 0;
  - donde el nuevo es 255 (sin observación) → se CONSERVA el valor anterior,
    envejecido delta días (delta = fecha nueva - fecha del estado previo),
    salvo que su edad supere --max-age-days, en cuyo caso CADUCA (255);
  - sin estado previo (primera pasada, caja nueva) → el estado es el mosaico
    del día con edad 0, es decir, el comportamiento de siempre.

Cada píxel del compuesto es una copia LITERAL del nuevo o del previo: aquí no
se promedia nada (dato categórico; ver el bloque RESAMPLING de gfsc_daily.sh).

Formato del estado (GeoTIFF, misma malla exacta que el mosaico — mismo -te y
-tr de gfsc_daily.sh, por eso la composición es un simple alineado 1:1):
  banda 1  valor SSC {110, 115, 120}, nodata 255
  banda 2  edad del dato en DÍAS respecto a COMPOSITE_DATE (0 = observado en
           esa fecha), nodata 255; con la caducidad en días nunca se acerca
           al tope del Byte
  metadatos: COMPOSITE_DATE (fecha de la pasada), MAX_AGE_DAYS, OLDEST_DATE

Se eligió llevar la edad por píxel (y no una sola fecha global) porque el
compuesto mezcla por construcción píxeles de pasadas distintas: con fecha
única no se puede caducar lo viejo sin tirar también lo recién observado. Es
la solución más simple que cumple: un único fichero de estado autocontenido
(la fecha va en sus metadatos), sin catálogo de mosaicos históricos en R2.

El estado previo se IGNORA (con aviso en stderr, nunca en silencio) si su
malla no coincide con la del mosaico nuevo o si su fecha es posterior a
--date (relanzar una fecha antigua no debe pisar dato más nuevo); la pasada
se comporta entonces como una primera pasada. Relanzar la MISMA fecha
(delta 0, p. ej. el reintento del cron) es idempotente.

Salida: stdout, un JSON con los recuentos por clase de previo/nuevo/compuesto
y los totales de conservados/caducados más oldest_date (la fecha del píxel
más viejo aún presente, para el meta.json); stderr, un resumen humano.
Código de salida: 0 = ok; otro = error (el estado no se ha escrito entero).
"""
import argparse
import datetime
import json
import sys

import numpy as np
from osgeo import gdal

gdal.UseExceptions()

NODATA = 255
CLASSES = (110, 115, 120)
ROWS_PER_BLOCK = 1024  # franjas de ancho completo: ~30 MB por array en pyralps


def warn(msg):
    print(f"wds_compose: AVISO: {msg}", file=sys.stderr)


def class_counts(arr):
    """Recuento por clase legal + total de píxeles con dato."""
    counts = {str(c): int(np.count_nonzero(arr == c)) for c in CLASSES}
    counts["valid"] = int(np.count_nonzero(arr != NODATA))
    return counts


def add_counts(acc, new):
    for k, v in new.items():
        acc[k] = acc.get(k, 0) + v


def open_prev(path, ref_ds, date):
    """Abre el estado previo y devuelve (dataset, delta_días) o (None, 0) si
    no sirve — malla distinta, sin fecha o fecha posterior a la pasada."""
    ds = gdal.Open(path)
    if (ds.RasterXSize != ref_ds.RasterXSize
            or ds.RasterYSize != ref_ds.RasterYSize
            or not np.allclose(ds.GetGeoTransform(), ref_ds.GetGeoTransform(),
                               atol=1e-6)):
        warn("la malla del estado previo no coincide con la del mosaico "
             "(¿cambió BBOX o RES?); se ignora y la pasada arranca de cero")
        return None, 0
    if ds.RasterCount != 2:
        warn(f"estado previo con {ds.RasterCount} bandas (esperaba 2); se ignora")
        return None, 0
    prev_date_str = ds.GetMetadataItem("COMPOSITE_DATE")
    if not prev_date_str:
        warn("estado previo sin metadato COMPOSITE_DATE; se ignora")
        return None, 0
    prev_date = datetime.date.fromisoformat(prev_date_str)
    delta = (date - prev_date).days
    if delta < 0:
        warn(f"el estado previo es de {prev_date} y la pasada de {date} "
             "(fecha anterior): no se pisa dato más nuevo con más viejo; "
             "se ignora el estado")
        return None, 0
    return ds, delta


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--new", required=True, help="mosaico del día (Byte, nodata 255)")
    ap.add_argument("--prev", help="estado compuesto anterior (opcional)")
    ap.add_argument("--date", required=True, help="fecha de la pasada YYYY-MM-DD")
    ap.add_argument("--max-age-days", type=int, required=True,
                    help="edad máxima en días de un píxel arrastrado")
    ap.add_argument("--out", required=True, help="estado compuesto de salida")
    args = ap.parse_args()

    date = datetime.date.fromisoformat(args.date)
    max_age = args.max_age_days
    if not 0 <= max_age <= 200:
        # Muy por debajo del tope del Byte (255 = nodata de la banda de edad).
        ap.error(f"--max-age-days fuera de rango razonable: {max_age}")

    new_ds = gdal.Open(args.new)
    prev_ds, delta = (None, 0)
    prev_date_str = None
    if args.prev:
        prev_ds, delta = open_prev(args.prev, new_ds, date)
        if prev_ds is not None:
            prev_date_str = prev_ds.GetMetadataItem("COMPOSITE_DATE")

    xs, ys = new_ds.RasterXSize, new_ds.RasterYSize
    drv = gdal.GetDriverByName("GTiff")
    out_ds = drv.Create(args.out, xs, ys, 2, gdal.GDT_Byte,
                        options=["COMPRESS=DEFLATE", "TILED=YES",
                                 "BIGTIFF=IF_SAFER"])
    out_ds.SetGeoTransform(new_ds.GetGeoTransform())
    out_ds.SetProjection(new_ds.GetProjection())
    b_val, b_age = out_ds.GetRasterBand(1), out_ds.GetRasterBand(2)
    b_val.SetNoDataValue(NODATA)
    b_age.SetNoDataValue(NODATA)
    b_val.SetDescription("SSC")
    b_age.SetDescription("age_days")

    stats = {"prev": {}, "new": {}, "composite": {}, "kept_by_class": {}}
    kept = expired = 0
    oldest_age = 0

    for y in range(0, ys, ROWS_PER_BLOCK):
        rows = min(ROWS_PER_BLOCK, ys - y)
        new = new_ds.GetRasterBand(1).ReadAsArray(0, y, xs, rows)
        add_counts(stats["new"], class_counts(new))

        out_val = new.copy()
        out_age = np.where(new != NODATA, 0, NODATA).astype(np.uint8)

        if prev_ds is not None:
            prev_val = prev_ds.GetRasterBand(1).ReadAsArray(0, y, xs, rows)
            prev_age = prev_ds.GetRasterBand(2).ReadAsArray(0, y, xs, rows)
            add_counts(stats["prev"], class_counts(prev_val))
            # int16 para que 255+delta no dé la vuelta en el Byte.
            aged = prev_age.astype(np.int16) + delta
            hole = (new == NODATA) & (prev_val != NODATA) & (prev_age != NODATA)
            keep = hole & (aged <= max_age)
            out_val[keep] = prev_val[keep]
            out_age[keep] = aged[keep].astype(np.uint8)
            kept += int(np.count_nonzero(keep))
            expired += int(np.count_nonzero(hole & ~keep))
            if np.any(keep):
                add_counts(stats["kept_by_class"], class_counts(prev_val[keep]))
                oldest_age = max(oldest_age, int(aged[keep].max()))

        add_counts(stats["composite"], class_counts(out_val))
        b_val.WriteArray(out_val, 0, y)
        b_age.WriteArray(out_age, 0, y)

    oldest_date = (date - datetime.timedelta(days=oldest_age)).isoformat()
    out_ds.SetMetadata({
        "COMPOSITE_DATE": args.date,
        "MAX_AGE_DAYS": str(max_age),
        "OLDEST_DATE": oldest_date,
    })
    out_ds.FlushCache()
    out_ds = None

    result = {
        "date": args.date,
        "prev_date": prev_date_str,
        "delta_days": delta if prev_ds is not None else None,
        "max_age_days": max_age,
        "oldest_age_days": oldest_age,
        "oldest_date": oldest_date,
        "kept_px": kept,
        "expired_px": expired,
        **stats,
    }
    print(f"wds_compose: nuevo={result['new'].get('valid', 0)} px, "
          f"previo={result['prev'].get('valid', 0)} px, "
          f"conservados={kept}, caducados={expired}, "
          f"compuesto={result['composite'].get('valid', 0)} px, "
          f"dato más viejo={oldest_date} ({oldest_age} d)", file=sys.stderr)
    json.dump(result, sys.stdout)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
