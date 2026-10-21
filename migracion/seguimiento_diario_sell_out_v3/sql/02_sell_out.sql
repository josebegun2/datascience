-- =====================================================================
-- 02 · Cadena S0 -> SO_1 -> SO_2 -> SO_3 traducida a Databricks SQL
-- =====================================================================
-- En Tableau son 4 flujos de Prep que publican 2 extractos y dos de ellos
-- AGREGAN filas (SO_1 y SO_3). Aquí es una sola tabla que se reconstruye
-- completa en cada corrida: correrla dos veces da el mismo resultado.
--
--   S0 + SO_1  ->  silver_sell_out_integracion   (vista)
--   SO_2       ->  parte "POS" de gold_sell_out
--   SO_3       ->  parte "VENTA_TOTAL" (canales 12 y 13) de gold_sell_out
--
-- Cambios contra Tableau (marcados con [CAMBIO] abajo):
--   1. Escala 12/13 se excluye en TODOS los días. En Tableau S0 la excluye
--      pero SO_1 (carga diaria) no, y SO_3 vuelve a agregar esos canales:
--      los días cargados por SO_1 podían quedar duplicados.
--   2. Zona homologada: COALESCE(segundo, original) como los otros 12 campos.
--      En SO_2 estaba invertido: IFNULL([Zona],[Segundo Zona]).
--   3. Días sin tipo de cambio toman el último disponible (columna
--      tc_imputado = true). En Tableau quedaban en nulo y la venta
--      convertida de LATAM salía vacía ese día.
--   4. La tabla se reconstruye completa (no hay "append"), así el orden de
--      corrida ya no importa.
-- Lo que se dejó igual a propósito (para cuadrar con Tableau) y se anota:
--   * Atributos de SKU de México para todos los países (DIM_MAT_RADSKU
--     filtrado a México y unido solo por SKU).
--   * "Total de facturas" de Venta Total = columna POLARIDAD.
--   * Nombres de 3 tiendas escritos en el código (500220, 500972, 501028).
-- =====================================================================

-- ---------------------------------------------------------------------
-- S0 + SO_1: Sell Out Integración Anual
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workspace.demo_sell_out.silver_sell_out_integracion AS
SELECT b.* EXCEPT (SKU, `Numero de franquiciatario`, Grupo),
       regexp_replace(b.SKU, '^0+', '') AS SKU
FROM workspace.demo_sell_out.src_bipos b
WHERE b.`Fecha transaccion` <= date_sub(current_date(), 1)
  -- [CAMBIO 1] S0 excluye estas escalas; SO_1 no lo hacía
  AND b.Escala NOT IN ('12 Venta en linea', '13 Marketplace')
  -- "Filtro Skus Negativos" (mismo listado en S0, SO_1 y SO_3)
  AND upper(trim(regexp_replace(b.SKU, '^0+', ''))) NOT IN (
        'BONIFSC', 'COMISION', 'ENVIOEXPRESS', 'ENVIOLIBRE', 'ENVIONORMAL', 'FLETE',
        'GASTOS ENVIO', 'REMBOLSO GTO LOCAL', 'REPARACION', 'SELLO STEREN CARD',
        'SERV PROM VENTAS', 'SERV PUBLIC', 'SERV PUBLICIDAD', 'SERVICIO',
        'BALMUN-ACB', 'BALMUN-ANB', 'BALMUN-MAS', 'BALMUN-TRI');

-- ---------------------------------------------------------------------
-- Tipo de cambio diario, con el último disponible para días sin dato
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workspace.demo_sell_out.silver_tipo_cambio AS
WITH dias AS (
  SELECT explode(sequence((SELECT min(`Fecha TC`) FROM workspace.demo_sell_out.src_dim_tcurr), current_date())) AS fecha
),
j AS (
  SELECT d.fecha, t.*, t.`Fecha TC` IS NULL AS tc_imputado
  FROM dias d LEFT JOIN workspace.demo_sell_out.src_dim_tcurr t ON t.`Fecha TC` = d.fecha
)
SELECT fecha, tc_imputado,
       last_value(`TC COPMXP`, true) OVER w AS tc_copmxp, last_value(`TC CRCMXP`, true) OVER w AS tc_crcmxp,
       last_value(`TC USDMXP`, true) OVER w AS tc_usdmxp, last_value(`TC COPUSD`, true) OVER w AS tc_copusd,
       last_value(`TC CRCUSD`, true) OVER w AS tc_crcusd, last_value(`TC MXPUSD`, true) OVER w AS tc_mxpusd,
       last_value(`TC HNLMXP`, true) OVER w AS tc_hnlmxp, last_value(`TC HNLUSD`, true) OVER w AS tc_hnlusd,
       last_value(`TC DOPMXP`, true) OVER w AS tc_dopmxp, last_value(`TC DOPUSD`, true) OVER w AS tc_dopusd,
       last_value(`TC PENMXP`, true) OVER w AS tc_penmxp, last_value(`TC PENUSD`, true) OVER w AS tc_penusd,
       last_value(`TC GTMMXP`, true) OVER w AS tc_gtqmxp, last_value(`TC GTMUSD`, true) OVER w AS tc_gtqusd
FROM j
-- [CAMBIO 3] ventana hasta el día actual: rellena con el último tipo de cambio conocido
WINDOW w AS (ORDER BY fecha ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW);

-- ---------------------------------------------------------------------
-- SO_2 + SO_3 -> gold_sell_out (la fuente "Sell Out." del tablero)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE workspace.demo_sell_out.gold_sell_out
COMMENT 'Venta diaria por tienda y SKU (equivale a la fuente "Sell Out." de Tableau). Se reconstruye completa.'
AS
WITH
tiendas_nombre AS (   -- nombres escritos a mano en SO_2 y en DimFrq_SO
  SELECT * FROM VALUES ('500220', 'LOPEZ MATEOS GDL'), ('500972', 'PLAYA DEL CARMEN ARCUS'),
                       ('501028', 'PLAZA ORIENTE SLP') AS t(cliente_sap, tienda)
),
dim_mat AS (          -- DIM_MAT_RADSKU filtrado a México; SKU sin ceros a la izquierda
  SELECT regexp_replace(DM_SKU, '^0+', '') AS sku,
         `DM_SKU_descripción` AS sku_descripcion, DM_Familia AS familia, DM_Estatus AS estatus_sku,
         DM_CatWeb1 AS catweb1, DM_Subfamilia AS subfamilia, DM_Descripcion_subfamilia AS descripcion_subfamilia
  FROM workspace.demo_sell_out.src_dim_mat_radsku
  WHERE DM_Pais = 'México'
),
tce AS (
  SELECT SKU AS sku, `Codigo pais` AS pais,
         `Indice de temporalidad` AS indice_temporalidad, `Nivel de temporalidad` AS nivel_temporalidad,
         `Meses pico` AS meses_pico, `Confianza de la temporalidad` AS confianza_temporalidad,
         `Indice de tendencia` AS indice_tendencia, `Nivel de tendencia` AS nivel_tendencia,
         `Confianza de la tendencia` AS confianza_tendencia
  FROM workspace.demo_sell_out.src_tce_sku_pais
),
-- ---- SO_2: tiendas físicas (POS) ----
so AS (
  SELECT s.* EXCEPT (Tienda, `SKU descripcion`, `Estatus SKU`, Subfamilia, `Descripcion subfamilia`, Familia),
         coalesce(n.tienda, s.Tienda) AS Tienda
  FROM workspace.demo_sell_out.silver_sell_out_integracion s
  LEFT JOIN tiendas_nombre n ON n.cliente_sap = s.`Cliente sap`
),
pos AS (
  SELECT
    so.Pais AS pais, so.`Pais descripcion` AS pais_descripcion,
    coalesce(f.`Segundo Estado`, so.Estado) AS estado,
    coalesce(f.`Segundo Estado descripcion`, so.`Estado descripcion`) AS estado_descripcion,
    coalesce(f.`Segundo Zona`, so.Zona) AS zona,                       -- [CAMBIO 2]
    coalesce(f.`Segundo Latitud`, so.Latitud) AS latitud,
    coalesce(f.`Segundo Longitud`, so.Longitud) AS longitud,
    coalesce(f.`Segundo Macrotipo`, so.Macrotipo) AS macrotipo,
    coalesce(f.`Segundo Subtipo`, so.Subtipo) AS subtipo,
    coalesce(f.`Segundo Cedis`, so.Cedis) AS cedis,
    coalesce(f.`Segundo Cedis descripcion`, so.`Cedis descripcion`) AS cedis_descripcion,
    coalesce(f.`Segundo Mandante`, so.Mandante) AS mandante,
    coalesce(f.`FR Cliente sap`, so.`Cliente sap`) AS cliente_sap,
    coalesce(n.tienda, f.`Segundo Nombre de Tienda`, so.Tienda) AS tienda,
    coalesce(f.`Segundo Numero de franquiciatario`, f.`FR Numero de franquiciatario`) AS numero_franquiciatario,
    coalesce(f.`Segundo Grupo`, f.`FR Grupo`) AS grupo,
    f.ESTATUS AS estatus_tienda,
    so.`Fecha transaccion` AS fecha_transaccion, so.Moneda AS moneda, so.Escala AS escala,
    so.`Venta interfranquicia` AS venta_interfranquicia, so.SKU AS sku,
    m.sku_descripcion, m.estatus_sku, m.familia, m.subfamilia, m.descripcion_subfamilia, m.catweb1,
    so.`Total de facturas` AS total_facturas, so.`Total de skus` AS total_skus, so.Cantidad AS cantidad,
    so.`Total con IVA` AS total_con_iva, so.IVA AS iva, so.Subtotal AS subtotal,
    so.`Descuento posicion` AS descuento_posicion, so.`Descuento cabecera` AS descuento_cabecera,
    so.`Subtotal neto` AS subtotal_neto, so.`Costo promedio` AS costo_promedio,
    so.`Utilidad promedio` AS utilidad_promedio, so.`Margen promedio` AS margen_promedio,
    so.`Costo reposicion` AS costo_reposicion, so.`Utilidad reposicion` AS utilidad_reposicion,
    so.`Margen reposicion` AS margen_reposicion,
    'POS' AS origen
  FROM so
  LEFT JOIN dim_mat m ON m.sku = so.SKU
  LEFT JOIN workspace.demo_sell_out.src_dim_frq_so f
         ON f.`FR Pais` = so.Pais AND f.`FR_Mandante` = so.Mandante AND f.`FR Cliente sap` = so.`Cliente sap`
  LEFT JOIN tiendas_nombre n ON n.cliente_sap = coalesce(f.`FR Cliente sap`, so.`Cliente sap`)
),
-- Tienda igual: 12 meses cerrados, cada uno con al menos 20 días con venta
tienda_igual AS (
  SELECT tienda, CASE WHEN count(*) >= 12 THEN 'Si' ELSE 'No' END AS tienda_igual
  FROM (
    SELECT tienda, date_trunc('month', fecha_transaccion) AS mes
    FROM pos
    WHERE fecha_transaccion <  date_trunc('month', current_date())
      AND fecha_transaccion >= add_months(date_trunc('month', current_date()), -12)
    GROUP BY 1, 2
    HAVING count(DISTINCT fecha_transaccion) >= 20
  )
  GROUP BY tienda
),
-- ---- SO_3: canales 12 y 13 desde Venta Total ----
vt AS (
  SELECT
    `# Cliente SAP` AS cliente_sap, `Cliente SAP Nombre` AS tienda, Fecha AS fecha, Moneda AS moneda,
    regexp_replace(SKU, '^0+', '') AS sku, Sociedad AS sociedad,
    POLARIDAD AS total_facturas, `Total Skus` AS total_skus,
    `Canal Descripcion` AS canal, `Categoria Web` AS catweb1, `SKU descripcion` AS sku_descripcion,
    `Descripcion subfamilia` AS descripcion_subfamilia, `Estatus SKU` AS estatus_sku, Familia AS familia,
    Subfamilia AS subfamilia,
    sum(Cantidad) AS cantidad, sum(`Costo de adquisicion ML`) AS costo,
    sum(`Venta ML` - `Costo de adquisicion ML`) AS utilidad, sum(`Venta ML`) AS venta
  FROM workspace.demo_sell_out.src_venta_total
  WHERE `Canal Descripcion` IN ('12 Ventas en Línea', '13 Ventas Marketplace')
  GROUP BY ALL
),
ecom AS (
  SELECT
    CASE sociedad_h WHEN 'Colombia' THEN 'CO' WHEN 'Costa Rica' THEN 'CR' WHEN 'Ecuador' THEN 'EC'
                    WHEN 'Guatemala' THEN 'GT' WHEN 'Honduras' THEN 'HO' WHEN 'México' THEN 'MX'
                    WHEN 'Panamá' THEN 'PA' WHEN 'Producto E.' THEN 'PROEMP'
                    WHEN 'Republica Dominicana' THEN 'DO' WHEN 'Salvador' THEN 'SV' END AS pais,
    sociedad_h AS pais_descripcion,
    canal_h AS estado, canal_h AS estado_descripcion, canal_h AS zona,
    CASE WHEN sociedad_h IN ('México', 'Producto E.') THEN 19.460614 WHEN sociedad_h = 'Colombia' THEN 6.2475799 END AS latitud,
    CASE WHEN sociedad_h IN ('México', 'Producto E.') THEN -99.1763879 WHEN sociedad_h = 'Colombia' THEN -74.6042124 END AS longitud,
    canal_h AS macrotipo, canal_h AS subtipo, canal_h AS cedis, canal_h AS cedis_descripcion, canal_h AS mandante,
    cliente_sap, tienda, '' AS numero_franquiciatario, '' AS grupo, CAST(NULL AS string) AS estatus_tienda,
    fecha AS fecha_transaccion, CASE moneda WHEN 'MXN' THEN 'MXP' ELSE moneda END AS moneda, canal_h AS escala,
    '' AS venta_interfranquicia, sku, sku_descripcion,
    CASE estatus_sku WHEN 'NUEVO' THEN 'Nuevo' WHEN 'LINEA' THEN 'Linea'
                     WHEN 'DESCONTINUADO POR COMPRAS' THEN 'Descontinuado por Compras'
                     WHEN 'POR REMATAR' THEN 'Por Rematar' WHEN 'POR DEVOLVER' THEN 'Por Devolver'
                     WHEN 'DESCONTINUADO' THEN 'Descontinuado' ELSE 'Sin Estatus' END AS estatus_sku,
    familia, subfamilia, descripcion_subfamilia, catweb1,
    total_facturas, total_skus, cast(cantidad AS int) AS cantidad,
    0.0 AS total_con_iva, 0.0 AS iva, 0.0 AS subtotal, 0.0 AS descuento_posicion, 0.0 AS descuento_cabecera,
    venta AS subtotal_neto, costo AS costo_promedio, utilidad AS utilidad_promedio,
    try_divide(utilidad, venta) AS margen_promedio,
    0.0 AS costo_reposicion, 0.0 AS utilidad_reposicion, 0.0 AS margen_reposicion,
    'VENTA_TOTAL' AS origen
  FROM (
    SELECT *,
           CASE sociedad WHEN 'Costa R.' THEN 'Costa Rica' WHEN 'Mexico' THEN 'México' ELSE sociedad END AS sociedad_h,
           -- "Reasignar ... a 12 Venta en linea": el canal queda igual en Mandante, Zona, Escala, etc.
           CASE canal WHEN '12 Ventas en Línea' THEN '12 Venta en linea'
                      WHEN '13 Ventas Marketplace' THEN '13 Marketplace' ELSE canal END AS canal_h
    FROM vt
  )
  WHERE upper(trim(sku)) NOT IN (
        'BONIFSC', 'COMISION', 'ENVIOEXPRESS', 'ENVIOLIBRE', 'ENVIONORMAL', 'FLETE',
        'GASTOS ENVIO', 'REMBOLSO GTO LOCAL', 'REPARACION', 'SELLO STEREN CARD',
        'SERV PROM VENTAS', 'SERV PUBLIC', 'SERV PUBLICIDAD', 'SERVICIO',
        'BALMUN-ACB', 'BALMUN-ANB', 'BALMUN-MAS', 'BALMUN-TRI')
),
todo AS (
  SELECT pos.*, coalesce(ti.tienda_igual, 'No') AS tienda_igual
  FROM pos LEFT JOIN tienda_igual ti ON ti.tienda = pos.tienda
  UNION ALL
  SELECT ecom.*, 'No' AS tienda_igual FROM ecom
)
SELECT t.*, t.catweb1 AS catweb2,
       tc.tc_imputado, tc.tc_copmxp, tc.tc_crcmxp, tc.tc_usdmxp, tc.tc_copusd, tc.tc_crcusd, tc.tc_mxpusd,
       tc.tc_hnlmxp, tc.tc_hnlusd, tc.tc_dopmxp, tc.tc_dopusd, tc.tc_penmxp, tc.tc_penusd, tc.tc_gtqmxp, tc.tc_gtqusd,
       x.indice_temporalidad, x.nivel_temporalidad, x.meses_pico, x.confianza_temporalidad,
       x.indice_tendencia, x.nivel_tendencia, x.confianza_tendencia
FROM todo t
LEFT JOIN workspace.demo_sell_out.silver_tipo_cambio tc ON tc.fecha = t.fecha_transaccion
LEFT JOIN tce x ON x.pais = t.pais AND x.sku = t.sku;

-- ---------------------------------------------------------------------
-- Controles rápidos
-- ---------------------------------------------------------------------
SELECT origen, count(*) AS filas, count(DISTINCT tienda) AS tiendas, min(fecha_transaccion) AS desde,
       max(fecha_transaccion) AS hasta, round(sum(subtotal_neto)) AS neto_local,
       sum(CASE WHEN tienda_igual = 'Si' THEN 1 ELSE 0 END) AS filas_tienda_igual,
       sum(CASE WHEN tc_imputado THEN 1 ELSE 0 END) AS filas_tc_imputado
FROM workspace.demo_sell_out.gold_sell_out
GROUP BY origen
LIMIT 10;
