#!/usr/bin/env python3
"""Consulta el catálogo OData de CDSE por productos HR-WSI de una fecha y bbox.

Por defecto busca GFSC; con --prefix vale para cualquier producto CLMS con
nombre por prefijo (p. ej. CLMS_WSI_WDS_060m para la capa de nieve
húmeda/seca; verificado 2026-09-18 que OData sí lista los WDS del día).

Elegimos OData (https://catalogue.dataspace.copernicus.eu/odata/v1) y no el
STAC nuevo (stac.dataspace.copernicus.eu) porque, verificado el 2026-09-17,
la colección clms_wsi_gap-filled-fractional-snow-cover_europe_utm_60m_daily_v1
existe en STAC pero /search y /items devuelven 0 items (aún no indexados);
OData sí lista los productos del día anterior. La BÚSQUEDA es pública (sin
credenciales); solo la descarga necesita las claves S3 de CDSE.

Salida: una línea TSV por producto  NAME<TAB>S3PATH  donde S3PATH es la ruta
/eodata/... del directorio del producto (el GF vive en S3PATH/NAME_GF.tif).

Códigos de salida: 0 = productos encontrados; 3 = ninguno para esa fecha
(aún no publicados); 1 = error.
"""
import argparse
import json
import sys
import urllib.parse
import urllib.request

ODATA = "https://catalogue.dataspace.copernicus.eu/odata/v1/Products"
# Prefijo de nombre del producto GFSC 60 m (v1.0.2 a fecha de hoy; no fijamos
# la versión en el filtro para sobrevivir a reprocesados V103+).
DEFAULT_PREFIX = "CLMS_WSI_GFSC_060m"


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "trackviewer-gfsc/1.0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--date", required=True, help="YYYY-MM-DD (día del producto)")
    ap.add_argument("--bbox", required=True, help="w,s,e,n en grados (EPSG:4326)")
    ap.add_argument("--prefix", default=DEFAULT_PREFIX,
                    help="prefijo del nombre de producto CLMS (def.: GFSC 60 m)")
    args = ap.parse_args()

    w, s, e, n = (float(v) for v in args.bbox.split(","))
    poly = f"POLYGON(({w} {s},{e} {s},{e} {n},{w} {n},{w} {s}))"
    filt = (
        f"Collection/Name eq 'CLMS' and contains(Name,'{args.prefix}') "
        f"and ContentDate/Start ge {args.date}T00:00:00.000Z "
        f"and ContentDate/Start lt {args.date}T23:59:59.999Z "
        f"and OData.CSC.Intersects(area=geography'SRID=4326;{poly}')"
    )
    url = ODATA + "?" + urllib.parse.urlencode(
        {"$filter": filt, "$top": "200", "$select": "Name,S3Path"}
    )

    products = []
    while url:
        try:
            data = fetch(url)
        except Exception as exc:  # red o servidor caído: error real, no "sin datos"
            print(f"gfsc_query: error consultando OData: {exc}", file=sys.stderr)
            return 1
        products.extend(data.get("value", []))
        url = data.get("@odata.nextLink")

    if not products:
        print(f"gfsc_query: 0 productos {args.prefix} para {args.date} "
              f"en bbox {args.bbox}", file=sys.stderr)
        return 3

    for p in products:
        print(f"{p['Name']}\t{p['S3Path']}")
    print(f"gfsc_query: {len(products)} productos para {args.date}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
