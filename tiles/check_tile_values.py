#!/usr/bin/env python3
"""Verifica que un MBTiles categórico solo contiene los valores legales.

Uso:  check_tile_values.py <fichero.mbtiles> <v1,v2,...>

Contrato de estas capas (el mismo que slope_val y el GFSC de producción,
verificado 2026-09-18 decodificando tiles reales de gfsc_pyralps en R2): el
valor del píxel viaja en la banda 1 y el NODATA va como VALOR 255, no como
alpha — es el cliente quien pinta el 255 transparente. El driver MBTiles de
GDAL escribe cada tile como Gray, Gray+Alpha, RGB o RGBA según le convenga
(en RGB(A) el valor se replica en los tres canales), así que aquí se
comprueba, en TODOS los niveles de zoom (overviews incluidos):

  1. Todo píxel VISIBLE de la banda de valor pertenece a la lista legal (el
     255 de nodata debe venir incluido en la lista). Visible = cualquier
     píxel de un tile sin canal alpha, o con alpha > 0 si lo hay: el driver
     rellena con 0 bajo alpha=0 la parte del tile que cae fuera de la
     extensión del ráster (medido aquí: en wds_pyralps 2026-09-17 los ~18 M
     de ceros estaban TODOS bajo alpha=0), y ese relleno nunca se pinta.
  2. En tiles RGB(A), los tres canales de color son idénticos (el valor no
     se ha desdoblado por canal).
  3. Si hay canal alpha, es binario (0 o 255).

Cualquier promediado colado en la cadena (warp, translate u overviews)
inventa valores intermedios que no son ninguna clase — el bug de los halos
documentado en README-gfsc.md — y aquí haría saltar el error.

Muestreo: todos los tiles en zooms bajos y hasta MAX_PER_ZOOM aleatorios
(semilla fija) en los altos; suficiente para pillar un promediado, que
contamina todos los bordes dato/nodata, sin decodificar decenas de miles
de PNG.

Códigos de salida: 0 = todo legal; 1 = valores ilegales o error.
"""
import random
import sqlite3
import sys

from osgeo import gdal

gdal.UseExceptions()

MAX_PER_ZOOM = 400


def tile_check(blob, idx):
    """Decodifica un PNG de tile → (valores banda 1, alphas, canales_iguales)."""
    path = f"/vsimem/tile_{idx}.png"
    gdal.FileFromMemBuffer(path, blob)
    try:
        ds = gdal.Open(path)
        arr = ds.ReadAsArray()  # (bandas, h, w), o (h, w) si es monobanda
        nbands = ds.RasterCount
        has_alpha = (
            nbands in (2, 4)
            and ds.GetRasterBand(nbands).GetColorInterpretation() == gdal.GCI_AlphaBand
        )
        if arr.ndim == 2:
            return set(arr.ravel().tolist()), set(), True
        values = arr[0]
        if has_alpha:
            alpha = arr[nbands - 1]
            alphas = set(alpha.ravel().tolist())
            # Solo los píxeles visibles: bajo alpha=0 el driver deja relleno
            # (0) que el cliente nunca pinta.
            seen = set(values[alpha > 0].ravel().tolist())
        else:
            alphas = set()
            seen = set(values.ravel().tolist())
        # En RGB(A) el mismo valor debe estar replicado en los tres canales.
        equal = nbands < 3 or (
            bool((arr[0] == arr[1]).all()) and bool((arr[1] == arr[2]).all())
        )
        return seen, alphas, equal
    finally:
        gdal.Unlink(path)


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 1
    mbtiles, legal_arg = sys.argv[1], sys.argv[2]
    legal = {int(v) for v in legal_arg.split(",")}

    con = sqlite3.connect(mbtiles)
    zooms = [z for (z,) in con.execute(
        "select distinct zoom_level from tiles order by zoom_level")]
    rng = random.Random(0)  # semilla fija: la validación es reproducible
    bad = False
    for z in zooms:
        rows = con.execute(
            "select tile_data from tiles where zoom_level=?", (z,)).fetchall()
        sample = rows if len(rows) <= MAX_PER_ZOOM else rng.sample(rows, MAX_PER_ZOOM)
        seen, alphas, unequal = set(), set(), 0
        for i, (blob,) in enumerate(sample):
            vals, alph, equal = tile_check(bytes(blob), i)
            seen |= vals
            alphas |= alph
            unequal += 0 if equal else 1
        illegal = sorted(seen - legal)
        bad_alpha = sorted(alphas - {0, 255})
        status = "OK"
        if illegal:
            status = f"ILEGAL {illegal[:12]}"
            bad = True
        if bad_alpha:
            status += f" ALPHA-NO-BINARIO {bad_alpha[:8]}"
            bad = True
        if unequal:
            status += f" CANALES-RGB-DESIGUALES en {unequal} tiles"
            bad = True
        print(f"   z{z:2d}: {len(sample)}/{len(rows)} tiles, "
              f"valores {sorted(seen)} -> {status}")
    con.close()
    if bad:
        print("check_tile_values: valores fuera del mapeo — hay un "
              "promediado colado en la cadena", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
