# trackviewer-tiles-cron

Generación diaria de las capas de nieve de TrackViewer: descarga los productos
de Copernicus del día, los convierte a PMTiles y los sube a Cloudflare R2, desde
donde los sirve el Worker de `tiles.pimes.ai`.

Este repositorio existe **solo** para que GitHub Actions ejecute ese cron. El
resto del backend (Firebase, el Worker de tiles, el pipeline de DEM) vive en
`trackviewer_server` en Bitbucket. Ver **Sincronización** más abajo.

## Qué publica

| Capa | Producto | Resolución | Datasets en R2 |
|---|---|---|---|
| Cobertura de nieve | CLMS Gap-filled Fractional Snow Cover (Sentinel-2 + relleno) | 60 m | `gfsc_<región>` |
| Nieve húmeda / seca | CLMS Wet/Dry Snow (Sentinel-1) | 60 m | `wds_<región>` |

Nueve cajas que cubren Europa (EEA38 + Reino Unido) y que **comparten borde pero
nunca área**: si dos se solaparan, la app pintaría dos rásteres semitransparentes
encima y alteraría el color. Los límites de las cajas `wds_` se derivan de las
`gfsc_` precisamente para que no puedan divergir.

```
pyralps  -2.5,41.5,17.5,48.5   Pirineos y Alpes
iberia   -10,35,-2.5,48.5      Península Ibérica
medit    -2.5,35,17.5,41.5     Baleares, Córcega, Cerdeña, Italia
balkans  17.5,34,30,48.5       Balcanes, Grecia, Cárpatos sur
turkey   30,34,45,43           Tauro, Pónticas, Ararat
central  -2.5,48.5,30,56       Alemania, Chequia, Polonia, Tatras
britain  -12,48.5,-2.5,62.5    Islas Británicas e Irlanda
nordic   -2.5,56,32,72         Escandinavia
iceland  -25,62.5,-12,67       Islandia
```

## Puesta en marcha

1. **Cuenta CDSE** gratuita en <https://dataspace.copernicus.eu> y claves S3 en
   <https://eodata-s3keysmanager.dataspace.copernicus.eu>. Son claves de solo
   lectura del archivo de datos, distintas de la contraseña de la cuenta.
2. **Secrets del repositorio** (Settings → Secrets and variables → Actions):

   | Secret | Qué es |
   |---|---|
   | `CDSE_S3_ACCESS_KEY` | clave S3 de eodata |
   | `CDSE_S3_SECRET_KEY` | secreto S3 de eodata |
   | `R2_ACCESS_KEY_ID` | token de R2 con escritura en el bucket `trackviewer-tiles` |
   | `R2_SECRET_ACCESS_KEY` | secreto del token de R2 |
   | `R2_ENDPOINT` | `https://<account_id>.r2.cloudflarestorage.com` |

3. Listo. Los crones se lanzan solos; para probar, Actions → el workflow →
   *Run workflow* (admite fecha y lista de cajas concretas).

## Ejecución local

Los mismos scripts corren en cualquier máquina con GDAL, rclone y `pmtiles`.
Las credenciales se leen de `tiles/.env` (ignorado por git):

```sh
CDSE_S3_ACCESS_KEY=...
CDSE_S3_SECRET_KEY=...
```

```sh
./tiles/gfsc_europe.sh                                  # todas las cajas, ayer UTC
DATE=2026-03-15 REGIONS="gfsc_pyralps" ./tiles/gfsc_europe.sh
UPLOAD=0 ./tiles/gfsc_daily.sh                          # procesa sin publicar
```

`UPLOAD=0` es la forma de mirar un día del pasado sin publicar en producción un
dato que no es el de hoy.

## Cosas que conviene saber antes de tocar nada

- **La cobertura diaria de WDS es parcial por diseño.** Sentinel-1 cubre por
  franjas de órbita, así que cada día hay cajas sin producto: salen con aviso
  (código 3), no con error, y conservan en R2 su último día con datos.
- **Dato categórico ⇒ NEAREST en toda la cadena.** Promediar inventaría clases
  que no existen. Ya mordió a este pipeline: el driver MBTiles promedia el canal
  de valor ignorando el alfa y generaba halos de "nieve fantasma" en los bordes
  de las nubes. `check_tile_values.py` verifica que en los tiles publicados solo
  aparecen los valores legales.
- **El nodata es 255 y debe quedar siempre transparente**, tanto en el ráster
  como en la paleta del cliente.
- **Los huecos significan "sin información", nunca "sin nieve".** En la app eso
  se dice explícitamente en la leyenda; es una capa de seguridad en montaña.
- **Minutos de Actions**: la pasada completa ronda los 53 minutos (cobertura) y
  17 (húmeda). A diario suma cerca del límite mensual del plan gratuito, así que
  conviene mirar la factura los primeros meses.

El detalle de códigos de píxel, cobertura y limitaciones de cada producto está en
`tiles/README-gfsc.md` y `tiles/README-wds.md`.

## Sincronización

Los scripts de `tiles/` son copia de los de `trackviewer_server/tiles/`
(Bitbucket), donde se desarrollan. **Esta copia es la que ejecuta el cron**: si
tocas el original, tráelo aquí, y al revés. No hay automatismo que lo haga.
