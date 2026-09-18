# Capa diaria de nieve húmeda/seca WDS (Europa EEA38+UK)

Pipeline diario que convierte el producto **Copernicus HR-WSI "Wet/Dry Snow"
v2 (WDS, 60 m, Sentinel-1 + Sentinel-2)** en un PMTiles + un json de
metadatos por caja (`pmtiles/wds_<caja>.{pmtiles,json}`) en R2, servidos por
el Worker en `https://tiles.pimes.ai/wds_<caja>/{z}/{x}/{y}.png` y
`…/meta.json`. Comparte el motor con la capa GFSC: `gfsc_daily.sh` con
`PRODUCT=wds` (ver README-gfsc.md para todo lo común: vía de acceso CDSE,
credenciales, subida atómica, NEAREST…).

- Scripts: `wds_europe.sh` (recorre la cuadrícula, tolera fallos por caja) →
  `gfsc_daily.sh PRODUCT=wds` (una caja) + `gfsc_query.py --prefix
  CLMS_WSI_WDS_060m` (catálogo) + `check_tile_values.py` (verificación de
  clases, ver abajo).
- Regiones: las MISMAS 9 cajas de GFSC con prefijo `wds_` (bordes calcados =
  sin solapes; en el Worker `WDS_REGIONS` se deriva de `GFSC_REGIONS` para
  que no puedan divergir).
- Zoom: nativo z11 (60 m), overviews hasta z6 — idéntico a GFSC.

## Elección del producto: WDS y no SWS

Colección CDSE: `clms_wsi_wet-dry-snow_europe_utm_60m_daily_v2`
(teselas UTM de 110×110 km, zonas 25-38; NRT, ~12 h tras la adquisición).

Se evaluó también SWS (`clms_wsi_sar-wet-snow_europe_utm_60m_daily_v2`) y se
descartó por dos motivos, verificados el 2026-09-18 en los metadatos STAC de
CDSE y en la FAQ de CLMS ("What are the differences between WDS and SWS?"):

1. **SWS es binario**: su clase 125 es "dry snow or patchy snow or no snow"
   — no distingue nieve seca de suelo sin nieve, que es justo lo que una
   capa "húmeda/seca" quiere enseñar. WDS sí separa 110/115/120.
2. **SWS solo existe en regiones de montaña seleccionadas** (su clase 240 es
   literalmente `no_mountain`); WDS es pan-europeo (EEA38+UK, montaña y
   llanura), confirmado además contando productos por caja en OData: el
   2026-09-16/17 TODAS las cajas tenían productos en al menos uno de los dos
   días (de ahí que la cuadrícula conserve las 9 cajas de GFSC).

## Códigos de la banda SSC y mapeo

El GeoTIFF de la banda dentro del producto es `<NAME>_SSC.tif`
("Snow State Classification"; verificado listando un producto real por OData
Nodes: MTD.xml, QKL.png, SSC-QA.tif, SSC.tif, legend/). Clases verificadas
el 2026-09-18 en `item_assets.SSC.classification:classes` de la colección
CDSE (`data_type: uint8`, `nodata: 255`):

| SSC | Significado | En nuestro ráster |
|-----|-------------|-------------------|
| 110 | nieve húmeda (S1 detecta agua líquida donde FSCTOCagg ≥ 60 %) | se conserva |
| 115 | nieve seca (FSCTOCagg ≥ 60 % sin detección de agua) | se conserva |
| 120 | sin nieve o nieve parcheada (FSCTOCagg < 60 %) | se conserva |
| 200 | sombra radar, layover o foreshortening | 255 (nodata) |
| 205 | nube o sombra de nube | 255 (nodata) |
| 210 | agua | 255 (nodata) |
| 220 | bosque | 255 (nodata) |
| 230 | zonas urbanas | 255 (nodata) |
| 255 | sin datos | 255 (nodata) |

El 120 se conserva a propósito: distingue "observado y sin nieve" de "no
observado" (nodata), que en un dato con tantas máscaras es información.
Salida: Byte, nodata 255, EPSG:3857 — mismo contrato que slope_val/GFSC (el
cliente pinta el 255 transparente).

**Dato CATEGÓRICO ⇒ NEAREST en warp y overviews**, con más motivo aún que en
GFSC: un promedio de 110 y 120 daría 115 — "nieve seca" inventada entre
nieve húmeda y suelo desnudo. Tras generar cada MBTiles,
`check_tile_values.py` decodifica tiles de TODOS los zooms y falla si
aparece un solo píxel visible fuera de {110, 115, 120, 255} (el script
documenta la semántica exacta: el driver rellena con 0 bajo alpha=0 la parte
de tile fuera del ráster, y eso no cuenta porque nunca se pinta).

## Cobertura temporal: no hay dato nuevo todos los días en todas partes

WDS solo tiene producto en las teselas con **pasada de Sentinel-1 ese día**
(y necesita además un FSC óptico reciente de Sentinel-2 como máscara de
nieve). La franja orbital cambia a diario: contando por OData,
el 2026-09-16 → 2026-09-17 las cajas dieron 44→10 (pyralps), 54→0 (medit),
40→0 (turkey), 10→52 (nordic)… Consecuencias asumidas:

- El código 3 del motor ("sin productos para esa fecha/caja") aquí puede ser
  **definitivo**, no solo "aún no publicado": si S1 no pasó, ese día no
  habrá producto. La caja se queda sirviendo el último día con datos y su
  `meta.json` dice de qué fecha es.
- Dentro de una caja actualizada, la cobertura del día son las franjas de
  órbita: lo demás es nodata (transparente). Es la naturaleza del producto,
  no un fallo del pipeline.
- Si una tesela tiene dos pasadas el mismo día (ascendente y descendente),
  se mosaican y el dato válido prevalece sobre las máscaras (la limpieza
  convierte las máscaras en nodata ANTES del warp, igual que en GFSC).

## Limitación conocida: el radar se degrada justo en terreno escarpado

La detección de nieve húmeda viene del SAR de Sentinel-1, y en terreno
abrupto la geometría de adquisición produce **layover, foreshortening y
sombra radar**: laderas enteras quedan enmascaradas (clase 200 → nodata) o,
peor, mal iluminadas cerca del umbral de la máscara. Es decir: la capa
pierde fiabilidad exactamente donde más se consulta — cuencas encajonadas,
caras norte empinadas, valles estrechos de alta montaña. A eso se suman las
máscaras de bosque (220) y las nubes del FSC óptico (205). Interpretar los
huecos como "sin información", nunca como "sin nieve"; para extensión de
nieve está la capa GFSC, que es óptica y gap-filled.

## Uso

```bash
# Producción (sube a R2): toda la cuadrícula, producto de ayer UTC
./wds_europe.sh
DATE=2026-09-17 ./wds_europe.sh                 # fecha concreta
REGIONS="wds_pyralps" ./wds_europe.sh           # solo algunas cajas

# Una caja suelta, sin subir, para inspección:
PRODUCT=wds DATASET=wds_pyralps DATE=2026-09-17 UPLOAD=0 ./gfsc_daily.sh

# Solo catálogo (público, sin credenciales):
python3 gfsc_query.py --date 2026-09-17 --bbox="-2.5,41.5,17.5,48.5" \
  --prefix CLMS_WSI_WDS_060m

# Verificar clases de un MBTiles ya generado:
python3 check_tile_values.py wds_pyralps.mbtiles 110,115,120,255
```

## Atribución

La misma que GFSC, obligatoria en la app:
**"© Copernicus Land Monitoring Service / EEA"** (va también en el
`meta.json`). Datos: producto HR-WSI WDS del Copernicus Land Monitoring
Service, financiado por la Unión Europea.
