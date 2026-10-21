# Migración de prueba: "Seguimiento Diario Sell Out V3" (Tableau → Databricks)

Prueba de qué tan bien se puede migrar un tablero de Tableau a Databricks con un agente (Claude, por CLI), para estimar el esfuerzo de migrar los ~100 tableros de Steren.

- **Datos:** sintéticos, con la misma estructura que las fuentes reales. Tiendas, SKUs, familias y costos salen de `workspace.planning`; la venta es inventada y determinista. Hay 35 tiendas, 149 SKUs y 14 meses de venta: unas 130 mil filas.
- **Tablero:** nativo de Databricks (AI/BI). Tiene tablas, gráficas, filtros y parámetros; no se copiaron colores, logo ni formato.
- **Todo vive en** `workspace.demo_sell_out`.

## Qué había en Tableau

```
BiPos2021..2026 ─┐
                 ├─ S0 (reemplaza) ─┐
BiPos2026 ── SO_1 (agrega ayer) ────┴─ "Sell Out Integración Anual"
                                              │
DIM_MAT_RADSKU, DimFrq_SO, DIM_TCURR,         │
TCE_SKU_PAIS ──────────────────────── SO_2 (reemplaza) ─┐
Venta Total (canales 12 y 13) ─────── SO_3 (agrega) ────┴─ "Sell Out." ── Libro (3 tableros, 102 campos calculados, 26 parámetros)
```

## Qué quedó en Databricks

| Paso | Objeto | Archivo |
|---|---|---|
| Fuentes sintéticas, mismos nombres de columna que Tableau | `src_bipos`, `src_venta_total`, `src_dim_frq_so`, `src_dim_tcurr`, `src_tce_sku_pais`, `src_dim_mat_radsku` | `sql/01_fuentes_sinteticas.sql` |
| S0 + SO_1 | vista `silver_sell_out_integracion` | `sql/02_sell_out.sql` |
| Tipo de cambio diario sin huecos | vista `silver_tipo_cambio` | `sql/02_sell_out.sql` |
| SO_2 + SO_3 (la fuente "Sell Out.") | tabla `gold_sell_out`, que se reconstruye completa | `sql/02_sell_out.sql` |
| Campos calculados de fila, moneda y tipo de cambio | función `fn_sell_out(moneda, tipo_tc, fecha_tc)` | `sql/03_capa_tablero.sql` |
| Medidas para Genie y otros tableros | metric view `mv_sell_out` | `sql/03_capa_tablero.sql` |
| Tablero | "Seguimiento Diario Sell Out V3 (demo migración)" | `dashboard/build_dashboard.py` |
| Validaciones | 9 pruebas | `sql/04_validaciones.sql` |
| Mapa de los 102 campos calculados | — | `mapeo_campos_calculados.csv` |

### Cómo correrlo

Necesitas el CLI de Databricks con sesión iniciada (`databricks auth login --host https://dbc-69717c3d-b783.cloud.databricks.com`).

```bash
python3 run_sql.py sql/01_fuentes_sinteticas.sql
python3 run_sql.py sql/02_sell_out.sql
python3 run_sql.py sql/03_capa_tablero.sql
python3 run_sql.py sql/04_validaciones.sql
python3 dashboard/build_dashboard.py --crear        # o --actualizar <id>
```

`run_sql.py` se niega a correr un SELECT que no termine en `LIMIT`, para cuidar el consumo de la cuenta.

## Cambios contra la lógica de Tableau

Estos cambios son a propósito; cada uno está marcado con `[CAMBIO]` en el SQL.

| # | En Tableau | En Databricks | Impacto medido con los datos sintéticos |
|---|---|---|---|
| 1 | S0 quita las escalas 12 y 13, pero SO_1 (la carga diaria) no las quita, y SO_3 vuelve a agregar esos canales desde Venta Total | Se quitan en todos los días | 4% de la venta POS se habría contado dos veces en los días cargados por SO_1 |
| 2 | Zona homologada con `IFNULL([Zona],[Segundo Zona])`: al revés que los otros 12 campos | `coalesce(segundo, original)` | 3,128 filas de tiendas sucesoras caían en la zona vieja |
| 3 | Días sin tipo de cambio quedan en nulo | Se toma el último tipo de cambio disponible (`tc_imputado = true`) | 6 días y 206 filas de LATAM sin convertir |
| 4 | SO_1 y SO_3 **agregan** filas: el resultado depende del orden y de no repetir corridas | Una tabla que se reconstruye completa | Correrla dos veces da el mismo resultado (0 duplicados) |

**Se dejó igual a propósito y queda anotado:**
- Atributos de SKU de México para todos los países.
- "Total de facturas" de Venta Total viene de la columna `POLARIDAD`.
- Nombres de 3 tiendas escritos en el código.
- Remapeo de 33 clientes SAP en `Cliente SAP - Tienda`.
- El cliente SAP de una tienda sucesora conserva su número viejo, igual que en SO_2.

## Validaciones (todas pasan)

| Prueba | Resultado |
|---|---|
| Venta POS de `gold_sell_out` contra BiPos con los filtros de S0 | Cuadra exacto (100,250 filas) |
| Canales 12 y 13 contra Venta Total | Cuadra exacto |
| Duplicados por tienda, día, SKU y escala | 0 |
| Tiendas abiertas en marzo 2026 | "Tienda igual" = No |
| Tiendas sucesoras | Quedan con un nombre y una zona |
| Conversión de COP a MXP de un día | Igual al cálculo a mano |

## El tablero migrado

Tiene 3 páginas más una de filtros globales, 14 datasets y 43 widgets.

| Página en Tableau | En Databricks |
|---|---|
| **Resumen diario** (11 hojas) | Indicadores de ayer, promedios de 7 y 30 días, mes en curso, tiendas activas y margen; venta diaria por agrupación; participación; venta acumulada del mes contra el mes anterior y el mismo mes del año pasado; distribución de tiendas; histórico mensual y de precio promedio; tabla de detalle; filtros de tipo de tienda, zona y familia |
| **Concentrado** (7 hojas) | Top 10 de crecimiento y decremento; ranking de SKUs de los últimos M días contra los últimos N; filtros de segmento, movimiento y familia |
| **Comparativo** (7 hojas) | Totales A y B, variación %, margen A y B; variación por miembro; Pareto; tabla A contra B con rankings, % del total y % acumulado |
| Parámetros (26) | 14 parámetros en la página de filtros globales: país, moneda, tipo de cambio, fecha del tipo de cambio, venta o cantidad, agrupación, días N y M, dimensión, medida y fechas de los periodos A y B |

### Campos calculados (102)

El detalle de cada uno está en `mapeo_campos_calculados.csv`.

| Estado | Cuántos | Dónde quedaron |
|---|---|---|
| Migrados | 70 | 23 de fila en `fn_sell_out` o en el filtro de silver; 47 agregados o de ventana en el SQL de los datasets o en el widget |
| No aplica | 26 | Tooltips, etiquetas, prefijos y marcadores que AI/BI resuelve con su formato nativo |
| No migrados | 6 | Un *set* de Tableau ("Otros"), 3 cálculos LOD `EXCLUDE`, un `WINDOW_AVG` y el modo de fecha por día de la semana |

## Evaluación para escalar a 100 tableros

**Lo que sí se automatiza bien con un agente:**
- **Leer el .twb y los flujos .tfl:** son XML y JSON. Con dos scripts chicos se saca la cadena completa: fuentes, SQL, pasos de Prep, campos calculados, parámetros y qué hoja usa qué. Funciona igual para cualquier libro.
- **Traducir el SQL y los pasos de Prep a Databricks SQL.** Los errores que salieron se detectaron al correr y se corrigieron en minutos:
  - un `JOIN … USING` que reordenaba columnas;
  - una subconsulta con agregado que no se puede correlacionar;
  - nombres de columna con espacios, que requieren activar el column mapping de Delta.
- **Clasificar los campos calculados:** cuáles son de fila, cuáles agregados y cuáles solo de presentación. En este libro, uno de cada cuatro era solo de presentación y no hace falta migrarlo.
- **Encontrar errores de la lógica original.** Al leer los flujos aparecieron 4 que nadie había reportado; para producción esto vale más que la migración misma.

**Lo que requiere criterio humano:**
- **Decidir si los errores se corrigen o se replican.** Corregirlos cambia los números contra Tableau y hay que explicarlo a cada área.
- **Las funciones de Tableau sin equivalente directo en AI/BI:** sets, LOD en el widget, cálculos de tabla anidados y seguridad por usuario (`ISMEMBEROF` / `USERNAME()`). Se resuelven en SQL o con filtros de fila de Unity Catalog, pero cada caso se decide.
- **Revisar visualmente el tablero.** El agente genera el JSON del tablero, pero no ve cómo se renderiza; alguien debe abrirlo y ajustar el acomodo.

**Patrón reutilizable para los demás libros:**
1. Bronze: fuentes con los nombres de HANA y Tableau (column mapping activado).
2. Silver y gold: un SQL por flujo de Prep, siempre reconstruible, nunca "append".
3. Una función por fuente publicada con los campos de fila y los parámetros de moneda.
4. Datasets del tablero con los agregados; widgets nativos.
5. Validaciones de cuadre contra la fuente y de duplicados.
6. Un CSV de mapeo de campos calculados como evidencia de cobertura.

**Antes de pasar a producción:**
- **La fuente real:** extraer HANA hacia Databricks (ver "Cómo llegar a Databricks" en *Steren · Conocimiento*).
- **Seguridad:** el filtro de datos sensibles y el acceso por país, con filtros de fila y máscaras de columna de Unity Catalog. En la demo se usa `is_member('admins')`.
- **Calendario:** un Job de Databricks que corra 02 y 03 cada día, en lugar de los 4 flujos de Prep.
