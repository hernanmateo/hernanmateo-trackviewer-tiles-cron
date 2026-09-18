# Puesta en marcha en GitHub — paso a paso

Guía para dejar corriendo el cron diario de las capas de nieve.
Estado: **pendiente de hacer** (actualiza las casillas según avances).

- [ ] 1. Decidir visibilidad del repositorio
- [ ] 2. Subir el código
- [ ] 3. Configurar los cinco secrets
- [ ] 4. Prueba manual corta
- [ ] 5. Dejar rodar

Repositorio: <https://github.com/hernanmateo/hernanmateo-trackviewer-tiles-cron>

---

## 1. Ponlo público (recomendado)

**Settings → General → Danger Zone → Change visibility.**

El motivo es económico y concreto: en repos privados hay **2.000 minutos de
Actions al mes** y las dos pasadas diarias rondan los **2.100** (unos 53 min de
cobertura + 17 de nieve húmeda), así que habría que pagar unos euros al mes. En
repos **públicos los minutos son ilimitados y gratis**.

Aquí no hay nada que ocultar: el repositorio solo contiene scripts y
documentación. Las credenciales nunca viven en el código — van en los secrets de
GitHub, que siguen siendo privados aunque el repo sea público. Y los tiles que
genera ya se sirven públicamente desde `tiles.pimes.ai`.

Si se prefiere privado, funciona igual; solo hay que vigilar la factura.

## 2. Sube el código

```sh
cd /Users/hernan/Projects/trackviewer/trackviewer-tiles-cron
git push -u origin main
```

Si pide usuario y contraseña: GitHub ya no acepta la contraseña de la cuenta.
Hace falta un token en **Settings de la cuenta → Developer settings → Personal
access tokens → Fine-grained tokens**, con permiso de escritura sobre este
repositorio, y se pega donde pide la contraseña.

## 3. Configura los cinco secrets

En el repo: **Settings → Secrets and variables → Actions → New repository
secret**. Uno por uno, con estos nombres exactos:

| Nombre | De dónde sale |
|---|---|
| `CDSE_S3_ACCESS_KEY` | `trackviewer-server/tiles/.env` |
| `CDSE_S3_SECRET_KEY` | ídem |
| `R2_ACCESS_KEY_ID` | `~/.config/rclone/rclone.conf`, sección `[r2]` |
| `R2_SECRET_ACCESS_KEY` | ídem |
| `R2_ENDPOINT` | ídem, campo `endpoint` (`https://<account_id>.r2.cloudflarestorage.com`) |

Abrir esos ficheros con el editor y copiar los valores directamente al
navegador. **Nunca pegarlos en un chat.**

## 4. Haz una prueba corta antes de fiarte

No esperes al cron. **Actions → gfsc-daily → Run workflow**, rellenando:

- **date**: una fecha con producto, p. ej. `2026-09-17`
- **regions**: `gfsc_pyralps`

Limitarlo a una sola caja hace que tarde unos **3 minutos** en vez de cincuenta,
y sirve igual para comprobar que los secrets funcionan, que GDAL se instala y
que la subida a R2 entra. Al terminar, el propio job muestra un resumen con las
cajas que entraron.

Comprobación de que llegó de verdad:

```sh
rclone cat r2:trackviewer-tiles/pmtiles/gfsc_pyralps.json
curl -s -o /dev/null -w "%{http_code}\n" https://tiles.pimes.ai/gfsc_pyralps/11/1063/729.png
```

## 5. Déjalo rodar

A partir de ahí no hay que tocar nada:

| Workflow | Horario (UTC) | Reintento |
|---|---|---|
| `gfsc-daily` (cobertura) | 07:20 | 12:20 |
| `wds-daily` (húmeda/seca) | 09:40 | 14:40 |

El reintento existe porque Copernicus a veces publica tarde; cuando eso pasa el
script sale con aviso (código 3) sin subir nada, y la segunda pasada lo recoge.

**Dos avisos para más adelante:**

- Si el repositorio pasa **60 días sin ningún commit**, GitHub desactiva solo
  los workflows programados y manda un correo. Basta reactivarlos o hacer
  cualquier cambio.
- Si un día una capa no se actualiza, mirar la pestaña **Actions**: el resumen
  del job dice qué caja falló y por qué. Que en `wds-daily` falten cajas es
  **normal** — Sentinel-1 cubre por franjas de órbita y no pasa por todas partes
  el mismo día; esas cajas conservan su último día con datos.

---

## Optimización pendiente (opcional)

La caja `gfsc_central` tarda ~21 minutos frente a los 5-6 de sus vecinas. Si esa
desproporción tiene arreglo, el total diario baja bastante — relevante solo si
el repositorio se queda privado.
