# Capa diaria de nieve GFSC (Europa EEA38+UK)

Pipeline diario que convierte el producto **Copernicus HR-WSI "Daily
cumulative Gap-filled Fractional Snow Cover" (GFSC, 60 m)** en un PMTiles +
un json de metadatos por caja (`pmtiles/<dataset>.{pmtiles,json}`) en R2,
servidos por el Worker en `https://tiles.pimes.ai/<dataset>/{z}/{x}/{y}.png`
y `https://tiles.pimes.ai/<dataset>/meta.json`.

- Regiones: cuadrícula de 9 cajas que cubre EEA38+UK sin solapes (la app
  pinta todas las fuentes del encuadre a la vez y dos rásteres
  semitransparentes solapados alterarían el color). La tabla vive en UN solo
  sitio: `REGION_TABLE` de `gfsc_europe.sh` (calcada en `GFSC_REGIONS` del
  Worker). `gfsc_pyralps` (`-2.5,41.5,17.5,48.5`) fue la caja original y las
  demás la rodean casando bordes. Fuera: Rusia, Cáucaso y Svalbard.
- Zoom: nativo z11 (60 m del producto ≈ 51-57 m de terreno a esas latitudes),
  overviews hasta z6. El cliente sobrezoomea a partir de z11.
- Scripts: `gfsc_europe.sh` (recorre la cuadrícula, tolera fallos por caja) →
  `gfsc_daily.sh` (una caja: descarga→limpieza→warp→PMTiles→R2) +
  `gfsc_query.py` (catálogo).
- Automatización: `.github/workflows/gfsc-daily.yml` (cron 07:20 UTC +
  reintento 12:20 UTC).

## Vía de acceso a los datos (elegida y por qué)

Colección CDSE: `clms_wsi_gap-filled-fractional-snow-cover_europe_utm_60m_daily_v1`
(teselas UTM 100×100 km, zonas 30-33 en nuestra región, ~148 productos/día).

1. **Búsqueda: OData** (`catalogue.dataspace.copernicus.eu/odata/v1`), pública,
   sin credenciales. El STAC nuevo (`stac.dataspace.copernicus.eu/v1`) tiene la
   colección registrada pero **sin items** a 2026-09-17 (search e items
   devuelven 0), así que no sirve todavía; si algún día se puebla, migrar es
   trivial.
2. **Descarga: S3 de eodata** (`https://eodata.dataspace.copernicus.eu`,
   bucket `eodata`) con las claves S3 de CDSE, vía rclone (remote `cdse`
   definido al vuelo por variables de entorno). Ventajas frente a
   OData+OAuth: no hay token que refrescar, y se baja **solo** el
   `*_GF.tif` de cada tesela (66 KB–2 MB) en vez del zip completo del
   producto (~167 MB/día la región entera en verano).

Estructura en S3:
`/eodata/CLMS/bio-geophysical/snow_cover_extent/<colección>/YYYY/MM/DD/<NAME>/<NAME>_GF.tif`
con `NAME = CLMS_WSI_GFSC_060m_T31TCH_20260916P7D_COMB_V102`.

## Códigos de la banda GF y mapeo

Verificados en los metadatos STAC de la colección CDSE (`item_assets.GF`:
`data_type: uint8`, `nodata: 255`, `classification:classes`) y coherentes con
el PUM de HR-S&I Snow (land.copernicus.eu) y los evalscripts oficiales de
Sentinel Hub:

| GF | Significado | En nuestro ráster |
|----|-------------|-------------------|
| 0–100 | fracción de nieve (%) | se conserva |
| 205 | nube o sombra de nube | 255 (nodata) |
| 210 | agua interior | 255 (nodata) |
| 255 | sin datos | 255 (nodata) |

Salida: Byte, nodata 255, EPSG:3857 — mismo contrato que `slope_val`. La
limpieza se hace **antes** del mosaico (las teselas MGRS vecinas se solapan y
en gdalwarp "el último válido gana": una nube convertida ya en nodata no pisa
la nieve válida de la tesela de al lado).

Remuestreo **NEAREST** (base y overviews): medido en este repo (2026-09-17),
`gdaladdo -r average` sobre MBTiles promedia el canal de valor ignorando el
alpha y en los bordes de nodata inventa valores visibles (80 contra 255 daba
124/146/157 con alpha=255) → halos de nieve fantasma alrededor de nubes/agua.
Con NEAREST no se puede contaminar.

## Credenciales

1. **Cuenta CDSE** (gratuita): https://dataspace.copernicus.eu → Register.
2. **Claves S3 de eodata**: entrar en
   https://eodata-s3keysmanager.dataspace.copernicus.eu con la cuenta CDSE y
   generar un par access key / secret key. Son las variables
   `CDSE_S3_ACCESS_KEY` / `CDSE_S3_SECRET_KEY`. (La búsqueda en el catálogo
   OData no necesita nada.)
3. **R2**: el token de siempre del bucket `trackviewer-tiles` (el remote
   `r2:` local ya vale).

## Secrets de GitHub Actions

| Secret | Contenido |
|--------|-----------|
| `CDSE_S3_ACCESS_KEY` | access key de eodata (paso 2 de arriba) |
| `CDSE_S3_SECRET_KEY` | secret key de eodata |
| `R2_ACCESS_KEY_ID` | access key del token de API de R2 |
| `R2_SECRET_ACCESS_KEY` | secret del token de API de R2 |
| `R2_ENDPOINT` | `https://<account_id>.r2.cloudflarestorage.com` |

## Uso

```bash
# Producción (sube a R2): producto de ayer UTC
CDSE_S3_ACCESS_KEY=... CDSE_S3_SECRET_KEY=... ./gfsc_daily.sh
DATE=2026-02-03 ./gfsc_daily.sh          # fecha concreta

# Probar en local SIN credenciales y SIN subir nada:
#   valida la cadena limpieza→warp→MBTiles→PMTiles con un GeoTIFF cualquiera
DRY_RUN=1 DRY_SRC=/ruta/a/un.tif DRY_OUT=/tmp ./gfsc_daily.sh
#   → /tmp/gfsc_pyralps.dry.pmtiles + .dry.json

# Solo consultar el catálogo (público):
python3 gfsc_query.py --date 2026-09-16 --bbox="-2.5,41.5,17.5,48.5"
```

Salida con código **3** = producto de esa fecha aún no publicado en CDSE (el
workflow lo trata como "reintentar", no como fallo).

## Reemplazo atómico en R2

Un PUT de S3/R2 es atómico por objeto: `rclone copyto` nunca deja un archivo
a medias visible. Orden de subida: primero el `.pmtiles`, después el `.json`
(marca de commit: si el json dice fecha X, el pmtiles de X ya está servido).
El Worker absorbe el cambio de etag a mitad de lectura con su reintento de
`EtagMismatch`; el edge expira solo (Cache-Control de 6 h para este dataset).

## Atribución

Obligatoria en la app al mostrar la capa:
**"© Copernicus Land Monitoring Service / EEA"** (también va en el
`meta.json`). Datos: producto HR-WSI GFSC del Copernicus Land Monitoring
Service, financiado por la Unión Europea.
