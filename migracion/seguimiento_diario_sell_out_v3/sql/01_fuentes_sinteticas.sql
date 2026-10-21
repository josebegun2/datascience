-- =====================================================================
-- 01 · Fuentes sintéticas con la misma estructura que las de Tableau
-- =====================================================================
-- Replica las 6 fuentes que leen los flujos de Prep del tablero
-- "Seguimiento Diario Sell Out V3", con sus mismos nombres de columna:
--   src_bipos            <- BiPos2021..2026 (Fuentes)            41 col.
--   src_venta_total      <- Venta Total (Reingenieria Venta Total) 53 col.
--   src_dim_frq_so       <- DimFrq_SO (Fuentes)                  31 col.
--   src_dim_tcurr        <- DIM_TCURR (Fuentes)                  18 col.
--   src_tce_sku_pais     <- TCE_SKU_PAIS (Fuentes de Datos)      15 col.
--   src_dim_mat_radsku   <- DIM_MAT_RADSKU (BI Pruebas)           8 col.
--
-- Tiendas y SKUs salen de workspace.planning (nombres, familias y costos
-- reales); la venta es inventada pero con forma realista. Todo es
-- determinista: se usa un hash en vez de rand() para que cada corrida dé
-- los mismos números.
--
-- Tamaño: 35 tiendas x 150 SKUs x ~415 días -> ~100 mil filas en BiPos.
-- Casos difíciles incluidos a propósito:
--   * 3 tiendas que abren en marzo 2026 (no son tienda igual)
--   * 2 tiendas que cambiaron de cliente SAP en mayo 2026 (sucesoras)
--   * filas de escala 12/13 dentro de BiPos (S0 las quita, SO_1 no)
--   * SKUs de servicio (FLETE, ENVIOLIBRE, SERVICIO) que se excluyen
--   * SKUs con ceros a la izquierda y un SKU real que empieza con "00"
--   * 6 días sin tipo de cambio
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS workspace.demo_sell_out
COMMENT 'Demo de migración del tablero Seguimiento Diario Sell Out V3 (datos sintéticos)';

-- ---------------------------------------------------------------------
-- Referencias tomadas de planning (una sola lectura de gold_base)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE workspace.demo_sell_out.ref_tiendas AS
WITH g AS (
  SELECT regexp_replace(sap, '^0+', '') AS sap,
         max(tienda) AS tienda, max(estado) AS estado, max(store_type) AS store_type,
         max(nullif(trim(franquiciatario), '')) AS franquiciatario, max(cedis) AS cedis,
         sum(adu) AS adu
  FROM workspace.planning.gold_base
  WHERE sap RLIKE '^[0-9]+$' AND adu > 0
  GROUP BY 1
),
p AS (
  SELECT regexp_replace(stock_location, '^0+', '') AS sap, max(pais) AS pais
  FROM workspace.planning.dim_tienda GROUP BY 1
),
t AS (
  SELECT g.*, CASE p.pais WHEN 'COLOMBIA' THEN 'CO' WHEN 'COSTA RICA' THEN 'CR'
                          WHEN 'GUATEMALA' THEN 'GT' WHEN 'HONDURAS' THEN 'HN'
                          WHEN 'EL SALVADOR' THEN 'SV' WHEN 'ECUADOR' THEN 'EC'
                          WHEN 'DOMINICANA' THEN 'DO' WHEN 'PERU' THEN 'PE'
                          ELSE 'MX' END AS pais
  FROM g LEFT JOIN p USING (sap)
),
r AS (
  SELECT *,
         CASE WHEN pais <> 'MX' THEN 'LATAM'
              WHEN sap LIKE '9000%' THEN 'PV'
              WHEN sap LIKE '580%' THEN 'SHOP'
              WHEN sap LIKE '500%' THEN 'PRO' END AS grupo_muestra,
         row_number() OVER (PARTITION BY CASE WHEN pais <> 'MX' THEN pais
                                              WHEN sap LIKE '9000%' THEN 'PV'
                                              WHEN sap LIKE '580%' THEN 'SHOP'
                                              WHEN sap LIKE '500%' THEN 'PRO' END
                            ORDER BY adu DESC) AS rn
  FROM t
)
SELECT row_number() OVER (ORDER BY adu DESC) AS id_tienda, sap, tienda, estado, store_type,
       coalesce(franquiciatario, 'GRUPO STEREN') AS franquiciatario, cedis, pais, grupo_muestra, adu
FROM r
WHERE (grupo_muestra = 'PRO' AND rn <= 18) OR (grupo_muestra = 'SHOP' AND rn <= 8)
   OR (grupo_muestra = 'PV' AND rn <= 3) OR (grupo_muestra = 'LATAM' AND rn <= 1 AND pais IN ('CO','CR','GT','HN','SV','EC'));

CREATE OR REPLACE TABLE workspace.demo_sell_out.ref_skus AS
WITH s AS (
  SELECT material AS sku_sap, max(descripcion) AS descripcion, max(familia) AS familia,
         max(subfamilia) AS subfamilia, avg(nullif(costo_unitario, 0)) AS costo, sum(adu) AS adu
  FROM workspace.planning.gold_base
  WHERE adu > 0 AND familia IS NOT NULL
  GROUP BY 1
),
top AS (SELECT * FROM s WHERE costo IS NOT NULL ORDER BY adu DESC LIMIT 149),
cero AS (SELECT * FROM s WHERE costo IS NOT NULL AND sku_sap LIKE '00%' AND sku_sap NOT IN (SELECT sku_sap FROM top) ORDER BY adu DESC LIMIT 1)
SELECT row_number() OVER (ORDER BY adu DESC) AS id_sku, sku_sap, descripcion, familia, subfamilia,
       round(costo, 2) AS costo, adu,
       -- popularidad 0..1 por rango, para la probabilidad de venta diaria
       0.15 + percent_rank() OVER (ORDER BY adu) * 0.85 AS popularidad
FROM (SELECT * FROM top UNION ALL SELECT * FROM cero);

-- ---------------------------------------------------------------------
-- Tiendas con atributos (lo que en Tableau viene de ZDM_FRQ)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE workspace.demo_sell_out.ref_tiendas_attr AS
WITH t AS (
  SELECT *,
         row_number() OVER (PARTITION BY grupo_muestra ORDER BY id_tienda DESC) AS rn_ultimas,
         row_number() OVER (PARTITION BY grupo_muestra ORDER BY id_tienda) AS rn_primeras
  FROM workspace.demo_sell_out.ref_tiendas
)
SELECT id_tienda, sap, tienda, estado, store_type, franquiciatario, cedis, pais, grupo_muestra,
       lpad(cast(800 + id_tienda AS string), 5, '0') AS mandante,
       CASE pais WHEN 'MX' THEN 'MXP' WHEN 'CO' THEN 'COP' WHEN 'CR' THEN 'CRC' WHEN 'GT' THEN 'GTQ'
                 WHEN 'HN' THEN 'HNL' ELSE 'USD' END AS moneda,
       CASE pais WHEN 'MX' THEN 'México' WHEN 'CO' THEN 'Colombia' WHEN 'CR' THEN 'Costa Rica'
                 WHEN 'GT' THEN 'Guatemala' WHEN 'HN' THEN 'Honduras' WHEN 'SV' THEN 'El Salvador'
                 ELSE 'Ecuador' END AS pais_desc,
       -- unidades de moneda local por 1 peso, para convertir precios
       CASE pais WHEN 'MX' THEN 1.0 WHEN 'CO' THEN 215.0 WHEN 'CR' THEN 27.5 WHEN 'GT' THEN 0.42
                 WHEN 'HN' THEN 1.40 ELSE 0.054 END AS local_por_mxp,
       CASE WHEN pais <> 'MX' THEN pais
            ELSE element_at(array('CENTRO','NORTE','BAJIO','SURESTE'), cast(abs(xxhash64(sap)) % 4 AS int) + 1) END AS zona,
       CASE grupo_muestra WHEN 'SHOP' THEN 'SHOP' WHEN 'PV' THEN 'PUNTO DE VENTA' ELSE 'PROFESIONAL' END AS macrotipo,
       CASE WHEN grupo_muestra = 'PRO' AND id_tienda % 7 = 0 THEN '100x100'
            WHEN grupo_muestra = 'SHOP' THEN 'SHOP' WHEN grupo_muestra = 'PV' THEN 'PUNTO DE VENTA'
            ELSE 'PROFESIONAL' END AS subtipo,
       CASE WHEN franquiciatario = 'GRUPO STEREN' THEN ''
            ELSE concat('0000950', lpad(cast(dense_rank() OVER (ORDER BY franquiciatario) AS string), 3, '0')) END AS num_franq,
       -- 3 tiendas abren en marzo 2026 (las de menor venta de PRO y SHOP)
       CASE WHEN (grupo_muestra = 'PRO' AND rn_ultimas <= 2) OR (grupo_muestra = 'SHOP' AND rn_ultimas = 1)
            THEN DATE'2026-03-01' ELSE DATE'2025-09-01' END AS fecha_apertura,
       -- 2 tiendas cambiaron de cliente SAP en mayo 2026 (la de mayor venta de PRO y SHOP)
       CASE WHEN grupo_muestra IN ('PRO', 'SHOP') AND rn_primeras = 1
            THEN concat(substr(sap, 1, 3), '9', substr(sap, 5)) END AS sap_anterior,
       -- zona que tenía la tienda antes del cambio de cliente SAP
       CASE WHEN element_at(array('CENTRO','NORTE','BAJIO','SURESTE'), cast(abs(xxhash64(sap)) % 4 AS int) + 1) = 'SURESTE'
            THEN 'CENTRO' ELSE 'SURESTE' END AS zona_anterior,
       round(19.0 + (abs(xxhash64(sap, 'lat')) % 900) / 100.0, 6) AS lat,
       round(-99.0 - (abs(xxhash64(sap, 'lon')) % 800) / 100.0, 6) AS lon
FROM t;

-- ---------------------------------------------------------------------
-- src_dim_frq_so: un registro por mandante; las tiendas con cambio de
-- cliente SAP tienen el registro viejo INACTIVA con su sucesor
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE workspace.demo_sell_out.src_dim_frq_so
TBLPROPERTIES ('delta.columnMapping.mode' = 'name') AS
WITH base AS (
  SELECT pais, pais_desc, mandante, sap, tienda, 'ACTIVA' AS estatus, num_franq, franquiciatario,
         estado, zona, lat, lon, macrotipo, subtipo, cedis, sap AS sap_suc, mandante AS mandante_suc, zona AS zona_suc
  FROM workspace.demo_sell_out.ref_tiendas_attr
  UNION ALL
  SELECT pais, pais_desc, lpad(cast(900 + id_tienda AS string), 5, '0'), sap_anterior, tienda, 'INACTIVA',
         num_franq, franquiciatario, estado, zona_anterior, lat, lon, macrotipo, subtipo, cedis, sap, mandante, zona
  FROM workspace.demo_sell_out.ref_tiendas_attr WHERE sap_anterior IS NOT NULL
)
SELECT pais AS `FR Pais`, pais_desc AS `FR Pais descripcion`, mandante AS `FR_Mandante`,
       sap AS `FR Cliente sap`, tienda AS `FR Tienda`, estatus AS `ESTATUS`,
       num_franq AS `FR Numero de franquiciatario`, franquiciatario AS `FR Grupo`,
       estado AS `FR Estado`, estado AS `FR Estado descripcion`, zona AS `FR Zona`,
       lat AS `FR Latitud`, lon AS `FR Longitud`, macrotipo AS `FR Macrotipo`, subtipo AS `FR Subtipo`,
       concat('MM', lpad(cast(abs(xxhash64(cedis)) % 20 AS string), 2, '0')) AS `FR Cedis`, cedis AS `FR Cedis descripcion`,
       mandante_suc AS `Segundo Mandante`, sap_suc AS `Segundo Cliente sap`, tienda AS `Segundo Nombre de Tienda`,
       num_franq AS `Segundo Numero de franquiciatario`, franquiciatario AS `Segundo Grupo`,
       estado AS `Segundo Estado`, estado AS `Segundo Estado descripcion`,
       -- el registro INACTIVA tiene la zona vieja y el sucesor la actual: así se ve el IFNULL invertido
       zona_suc AS `Segundo Zona`,
       lat AS `Segundo Latitud`, lon AS `Segundo Longitud`, macrotipo AS `Segundo Macrotipo`, subtipo AS `Segundo Subtipo`,
       concat('MM', lpad(cast(abs(xxhash64(cedis)) % 20 AS string), 2, '0')) AS `Segundo Cedis`, cedis AS `Segundo Cedis descripcion`
FROM base;

-- ---------------------------------------------------------------------
-- src_dim_tcurr: tipo de cambio diario; faltan 6 días a propósito
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE workspace.demo_sell_out.src_dim_tcurr
TBLPROPERTIES ('delta.columnMapping.mode' = 'name') AS
WITH d AS (
  SELECT explode(sequence(DATE'2025-09-01', DATE'2026-10-20')) AS f
),
r AS (
  SELECT f, 18.6 + 0.6 * sin(datediff(f, DATE'2025-09-01') / 40.0) + (abs(xxhash64(f)) % 100 - 50) / 500.0 AS usdmxp
  FROM d
  WHERE f NOT IN (DATE'2025-12-25', DATE'2026-01-01', DATE'2026-04-03', DATE'2026-07-19', DATE'2026-09-16', DATE'2026-10-11')
)
SELECT f AS `Fecha TC`,
       round(usdmxp / 4150, 5) AS `TC COPMXP`, round(usdmxp / 512, 5) AS `TC CRCMXP`, round(usdmxp, 5) AS `TC USDMXP`,
       round(usdmxp / 7.2, 5) AS `TC CNYNMXP`, round(1 / 4150.0, 5) AS `TC COPUSD`, round(1 / 512.0, 5) AS `TC CRCUSD`,
       round(1 / usdmxp, 5) AS `TC MXPUSD`, 4150.0 AS `TC USDCOP`, round(1 / 7.2, 5) AS `TC CNYNUSD`,
       round(usdmxp / 26.1, 5) AS `TC HNLMXP`, round(1 / 26.1, 5) AS `TC HNLUSD`,
       round(usdmxp / 60.5, 5) AS `TC DOPMXP`, round(1 / 60.5, 5) AS `TC DOPUSD`,
       round(1 / 3.75, 5) AS `TC PENUSD`, round(usdmxp / 3.75, 5) AS `TC PENMXP`,
       round(usdmxp / 7.75, 5) AS `TC GTMMXP`, round(1 / 7.75, 5) AS `TC GTMUSD`
FROM r;

-- ---------------------------------------------------------------------
-- src_dim_mat_radsku: atributos de SKU (solo México, con ceros a la izq.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE workspace.demo_sell_out.src_dim_mat_radsku
TBLPROPERTIES ('delta.columnMapping.mode' = 'name') AS
SELECT 'México' AS DM_Pais,
       CASE WHEN sku_sap RLIKE '^[0-9]+$' THEN lpad(sku_sap, 18, '0') ELSE sku_sap END AS DM_SKU,
       descripcion AS `DM_SKU_descripción`, familia AS DM_Familia,
       element_at(array('Linea','Linea','Linea','Linea','Nuevo','Descontinuado por Compras','Por Rematar','Descontinuado'),
                  cast(abs(xxhash64(sku_sap, 'est')) % 8 AS int) + 1) AS DM_Estatus,
       element_at(array('Audio y Video','Cómputo','Energía','Herramientas','Hogar Inteligente','Electrónica'),
                  cast(abs(xxhash64(familia)) % 6 AS int) + 1) AS DM_CatWeb1,
       subfamilia AS DM_Subfamilia, concat('Subfamilia ', subfamilia) AS DM_Descripcion_subfamilia
FROM workspace.demo_sell_out.ref_skus;

-- ---------------------------------------------------------------------
-- src_tce_sku_pais: temporalidad y tendencia por SKU y país
-- (el SKU viene sin limpiar, como en la fuente real)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE workspace.demo_sell_out.src_tce_sku_pais
TBLPROPERTIES ('delta.columnMapping.mode' = 'name') AS
SELECT DATE'2026-10-01' AS `Fecha de corte`, s.sku_sap AS SKU,
       element_at(array('Audio y Video','Cómputo','Energía','Herramientas','Hogar Inteligente','Electrónica'),
                  cast(abs(xxhash64(s.familia)) % 6 AS int) + 1) AS `Categoria Web`,
       cast(s.id_sku AS string) AS Ranking, p.pais AS `Codigo pais`, p.pais_desc AS Pais,
       round(0.7 + (abs(xxhash64(s.sku_sap, p.pais, 't')) % 60) / 100.0, 2) AS `Indice de temporalidad`,
       element_at(array('Baja','Media','Alta'), cast(abs(xxhash64(s.sku_sap, p.pais, 'nt')) % 3 AS int) + 1) AS `Nivel de temporalidad`,
       element_at(array('Nov-Dic','Mar-Abr','Jul-Ago','Sin pico'), cast(abs(xxhash64(s.sku_sap, 'mp')) % 4 AS int) + 1) AS `Meses pico`,
       element_at(array('Baja','Media','Alta'), cast(abs(xxhash64(s.sku_sap, p.pais, 'ct')) % 3 AS int) + 1) AS `Confianza de la temporalidad`,
       'v3' AS `Version de la temporalidad`,
       round(-0.3 + (abs(xxhash64(s.sku_sap, p.pais, 'i')) % 60) / 100.0, 2) AS `Indice de tendencia`,
       element_at(array('A la baja','Estable','Al alza'), cast(abs(xxhash64(s.sku_sap, p.pais, 'n')) % 3 AS int) + 1) AS `Nivel de tendencia`,
       element_at(array('Baja','Media','Alta'), cast(abs(xxhash64(s.sku_sap, p.pais, 'c')) % 3 AS int) + 1) AS `Confianza de la tendencia`,
       'v2' AS `Version de la tendencia`
FROM workspace.demo_sell_out.ref_skus s
CROSS JOIN (SELECT DISTINCT pais, pais_desc FROM workspace.demo_sell_out.ref_tiendas_attr) p;

-- ---------------------------------------------------------------------
-- src_bipos: venta diaria por tienda x SKU x escala (BiPos2021..2026)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE workspace.demo_sell_out.src_bipos
TBLPROPERTIES ('delta.columnMapping.mode' = 'name') AS
WITH d AS (
  SELECT explode(sequence(DATE'2025-09-01', DATE'2026-10-20')) AS fecha
),
c AS (
  SELECT t.*, s.id_sku, s.sku_sap, s.descripcion, s.familia, s.subfamilia, s.costo, s.popularidad, d.fecha,
         (abs(xxhash64(t.sap, s.sku_sap, d.fecha)) % 1000000) / 1000000.0 AS u,
         (abs(xxhash64(t.sap, s.sku_sap, d.fecha, 'q')) % 1000) / 1000.0 AS u2
  FROM workspace.demo_sell_out.ref_tiendas_attr t CROSS JOIN workspace.demo_sell_out.ref_skus s CROSS JOIN d
  WHERE d.fecha >= t.fecha_apertura
),
v AS (
  SELECT *,
         -- probabilidad de venta: popularidad del SKU x tamaño de tienda x día de la semana
         popularidad * 0.09
           * CASE grupo_muestra WHEN 'PV' THEN 1.6 WHEN 'PRO' THEN 1.0 WHEN 'SHOP' THEN 0.6 ELSE 0.7 END
           * CASE dayofweek(fecha) WHEN 1 THEN 0.7 WHEN 7 THEN 1.3 ELSE 1.0 END
           * CASE WHEN month(fecha) IN (11, 12) THEN 1.35 ELSE 1.0 END AS p
  FROM c
),
filas AS (
  SELECT *,
         CASE WHEN familia = 'RESISTENCIAS' THEN 10 ELSE 1 END * (1 + cast(u2 * 3 AS int)) AS cantidad,
         CASE WHEN u2 < 0.70 THEN '01 Publico' WHEN u2 < 0.84 THEN '02 Mayoreo' WHEN u2 < 0.92 THEN '03 Distribuidor'
              WHEN u2 < 0.975 THEN '04 Especial' WHEN u2 < 0.99 THEN '12 Venta en linea' ELSE '13 Marketplace' END AS escala,
         costo * (1.7 + (abs(xxhash64(sku_sap, 'margen')) % 50) / 100.0) AS precio_mxp
  FROM v WHERE u < p
),
servicios AS (
  -- SKUs de servicio que el flujo excluye (fletes, envíos, servicios)
  SELECT t.*, 0 AS id_sku, x.sku AS sku_sap, x.sku AS descripcion, 'SERVICIOS' AS familia, 'SERV' AS subfamilia,
         0.0 AS costo, 0.0 AS popularidad, d.fecha, 0.0 AS u, 0.5 AS u2, 0.0 AS p, 1 AS cantidad, '01 Publico' AS escala,
         x.importe AS precio_mxp
  FROM workspace.demo_sell_out.ref_tiendas_attr t CROSS JOIN d
  CROSS JOIN (SELECT * FROM VALUES ('FLETE', 150.0), ('ENVIOLIBRE', -80.0), ('SERVICIO', 200.0) AS x(sku, importe)) x
  WHERE d.fecha >= t.fecha_apertura AND abs(xxhash64(t.sap, x.sku, d.fecha)) % 100 < 2
),
todo AS (SELECT * FROM filas UNION ALL SELECT * FROM servicios),
m AS (
  SELECT *,
         -- la tienda sucesora vendía con el cliente SAP anterior antes de mayo 2026
         CASE WHEN sap_anterior IS NOT NULL AND fecha < DATE'2026-05-01' THEN sap_anterior ELSE sap END AS sap_venta,
         CASE WHEN sap_anterior IS NOT NULL AND fecha < DATE'2026-05-01' THEN lpad(cast(900 + id_tienda AS string), 5, '0') ELSE mandante END AS mandante_venta,
         round(cantidad * precio_mxp * local_por_mxp, 2) AS subtotal,
         CASE escala WHEN '02 Mayoreo' THEN 0.05 WHEN '03 Distribuidor' THEN 0.10 WHEN '04 Especial' THEN 0.08 ELSE 0.0 END AS pct_desc_pos,
         CASE WHEN u2 > 0.95 THEN 0.02 ELSE 0.0 END AS pct_desc_cab
  FROM todo
)
SELECT pais AS Pais, pais_desc AS `Pais descripcion`, estado AS Estado, estado AS `Estado descripcion`,
       CASE WHEN sap_anterior IS NOT NULL AND fecha < DATE'2026-05-01' THEN zona_anterior ELSE zona END AS Zona, lat AS Latitud, lon AS Longitud, macrotipo AS Macrotipo, subtipo AS Subtipo,
       concat('MM', lpad(cast(abs(xxhash64(cedis)) % 20 AS string), 2, '0')) AS Cedis, cedis AS `Cedis descripcion`,
       mandante_venta AS Mandante, sap_venta AS `Cliente sap`, tienda AS Tienda,
       num_franq AS `Numero de franquiciatario`, franquiciatario AS Grupo,
       fecha AS `Fecha transaccion`, moneda AS Moneda, escala AS Escala,
       CASE WHEN num_franq <> '' AND u2 > 0.98 THEN 'X' ELSE '' END AS `Venta interfranquicia`,
       -- 20% de las filas trae el SKU con ceros a la izquierda, como en BiPos
       CASE WHEN u > 0.8 * p THEN concat('00', sku_sap) ELSE sku_sap END AS SKU,
       descripcion AS `SKU descripcion`, 'LINEA' AS `Estatus SKU`, subfamilia AS Subfamilia,
       concat('Subfamilia ', subfamilia) AS `Descripcion subfamilia`, familia AS Familia,
       greatest(1, cast(cantidad / (1 + u2 * 2) AS int)) AS `Total de facturas`, 1 AS `Total de skus`,
       cantidad AS Cantidad,
       round((subtotal * (1 - pct_desc_pos - pct_desc_cab)) * CASE WHEN pais = 'MX' THEN 1.16 ELSE 1.12 END, 2) AS `Total con IVA`,
       round((subtotal * (1 - pct_desc_pos - pct_desc_cab)) * CASE WHEN pais = 'MX' THEN 0.16 ELSE 0.12 END, 2) AS IVA,
       subtotal AS Subtotal,
       round(subtotal * pct_desc_pos, 2) AS `Descuento posicion`,
       round(subtotal * pct_desc_cab, 2) AS `Descuento cabecera`,
       round(subtotal * (1 - pct_desc_pos - pct_desc_cab), 2) AS `Subtotal neto`,
       round(cantidad * costo * local_por_mxp, 2) AS `Costo promedio`,
       round(subtotal * (1 - pct_desc_pos - pct_desc_cab) - cantidad * costo * local_por_mxp, 2) AS `Utilidad promedio`,
       round(try_divide(subtotal * (1 - pct_desc_pos - pct_desc_cab) - cantidad * costo * local_por_mxp,
                        subtotal * (1 - pct_desc_pos - pct_desc_cab)), 4) AS `Margen promedio`,
       round(cantidad * costo * local_por_mxp * 1.06, 2) AS `Costo reposicion`,
       round(subtotal * (1 - pct_desc_pos - pct_desc_cab) - cantidad * costo * local_por_mxp * 1.06, 2) AS `Utilidad reposicion`,
       round(try_divide(subtotal * (1 - pct_desc_pos - pct_desc_cab) - cantidad * costo * local_por_mxp * 1.06,
                        subtotal * (1 - pct_desc_pos - pct_desc_cab)), 4) AS `Margen reposicion`
FROM m;

-- ---------------------------------------------------------------------
-- src_venta_total: venta de todos los canales; SO_3 solo usa 12 y 13
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE workspace.demo_sell_out.src_venta_total
TBLPROPERTIES ('delta.columnMapping.mode' = 'name') AS
WITH d AS (SELECT explode(sequence(DATE'2025-09-01', DATE'2026-10-20')) AS fecha),
canales AS (
  SELECT * FROM VALUES
    ('12 Ventas en Línea', 'VEL001', 'STEREN TIENDA EN LINEA', 'México', 'MX', 0.30),
    ('13 Ventas Marketplace', 'MKP001', 'MARKETPLACE MERCADO LIBRE', 'México', 'MX', 0.25),
    ('13 Ventas Marketplace', 'MKP002', 'MARKETPLACE AMAZON', 'Mexico', 'MX', 0.20),
    ('10 Mayoreo', 'MAY001', 'CLIENTE MAYOREO', 'México', 'MX', 0.10),
    ('12 Ventas en Línea', 'VEL101', 'STEREN EN LINEA CR', 'Costa R.', 'CR', 0.08)
  AS c(canal, cliente, nombre, sociedad, pais, prob)
),
f AS (
  SELECT c.*, s.*, d.fecha,
         (abs(xxhash64(c.cliente, s.sku_sap, d.fecha)) % 1000000) / 1000000.0 AS u,
         1 + abs(xxhash64(c.cliente, s.sku_sap, d.fecha, 'q')) % 4 AS cantidad
  FROM canales c CROSS JOIN workspace.demo_sell_out.ref_skus s CROSS JOIN d
),
g AS (
  SELECT *, round(cantidad * costo * (1.7 + (abs(xxhash64(sku_sap, 'margen')) % 50) / 100.0)
                  * CASE pais WHEN 'CR' THEN 27.5 ELSE 1 END, 2) AS venta_ml,
            round(cantidad * costo * CASE pais WHEN 'CR' THEN 27.5 ELSE 1 END, 2) AS costo_ml
  FROM f WHERE u < prob * popularidad
)
SELECT round(costo_ml / 18.6, 2) AS `Costo de Adquisición  USD UDMC`, sociedad AS Sociedad,
       round(costo_ml, 2) AS `Costo de Adquisición MXP UDMC `, round(venta_ml / 18.6, 2) AS `Venta USD UDMC`,
       round(venta_ml, 2) AS `Venta MXP UDMC`, fecha AS Fecha,
       CASE WHEN sku_sap RLIKE '^[0-9]+$' THEN lpad(sku_sap, 18, '0') ELSE sku_sap END AS SKU,
       'ZFAC' AS Clase, 'Comercio' AS Giro, CASE pais WHEN 'CR' THEN 'CRC' ELSE 'MXN' END AS Moneda,
       cast(cantidad AS double) AS Cantidad, descripcion AS `SKU descripcion`, familia AS Familia,
       element_at(array('LINEA','LINEA','NUEVO','DESCONTINUADO','POR REMATAR'), cast(abs(xxhash64(sku_sap, 'vt')) % 5 AS int) + 1) AS `Estatus SKU`,
       element_at(array('Audio y Video','Cómputo','Energía','Herramientas','Hogar Inteligente','Electrónica'),
                  cast(abs(xxhash64(familia)) % 6 AS int) + 1) AS `Categoria Web`,
       subfamilia AS Subfamilia, concat('Subfamilia ', subfamilia) AS `Descripcion subfamilia`,
       '1000' AS `Organizacion de Venta`, 'OV01' AS `Oficina de Venta`, 'CEDIS CENTRAL' AS `Centro Descripcion`,
       canal AS `Canal Descripcion`, cliente AS `# Cliente SAP`, nombre AS `Cliente SAP Nombre`,
       concat(cliente, ' ', nombre) AS `Cliente Sap`, 'E01' AS `Id Ejecutivo`, 'G01' AS IdGiro,
       venta_ml AS `Venta ML`, costo_ml AS `Costo de adquisicion ML`,
       round(venta_ml / CASE pais WHEN 'CR' THEN 27.5 ELSE 1 END, 2) AS `Venta MXP`,
       round(costo_ml / CASE pais WHEN 'CR' THEN 27.5 ELSE 1 END, 2) AS `Costo de adquisicion MXP`,
       round(venta_ml / CASE pais WHEN 'CR' THEN 512 ELSE 18.6 END, 2) AS `Venta USD`,
       round(costo_ml / CASE pais WHEN 'CR' THEN 512 ELSE 18.6 END, 2) AS `Costo de adquisicion USD`,
       CAST(NULL AS double) AS `Tipo de cambio COPMXP`, CAST(NULL AS double) AS `Tipo de cambio CRCMXP`,
       CAST(NULL AS double) AS `Tipo de cambio USDMXP`, CAST(NULL AS double) AS `Tipo de cambio CNYNMXP`,
       CAST(NULL AS double) AS `Tipo de cambio COPUSD`, CAST(NULL AS double) AS `Tipo de cambio CRCUSD`,
       CAST(NULL AS double) AS `Tipo de cambio MXPUSD`, CAST(NULL AS double) AS `Tipo de cambio USDCOP`,
       CAST(NULL AS double) AS `Tipo de cambio CNYNUSD`, CAST(NULL AS double) AS `Tipo de cambio HNLMXP`,
       CAST(NULL AS double) AS `Tipo de cambio HNLUSD`, CAST(NULL AS double) AS `Tipo de cambio DOPMXP`,
       CAST(NULL AS double) AS `Tipo de cambio DOPUSD`, CAST(NULL AS double) AS `Tipo de cambio PENUSD`,
       CAST(NULL AS double) AS `Tipo de cambio PENMXP`, CAST(NULL AS double) AS `Tipo de cambio GTMMXP`,
       CAST(NULL AS double) AS `Tipo de cambio GTMUSD`,
       pais AS DM_Pais, sociedad AS Pais,
       -- en la fuente real esta columna se renombra a "Total de facturas" en SO_3
       CASE WHEN abs(xxhash64(cliente, sku_sap, fecha, 'pol')) % 10 = 0 THEN -1 ELSE 1 END AS POLARIDAD,
       1 AS `Total Skus`
FROM g;

-- ---------------------------------------------------------------------
-- Conteos de control
-- ---------------------------------------------------------------------
SELECT 'src_bipos' AS tabla, count(*) AS filas FROM workspace.demo_sell_out.src_bipos
UNION ALL SELECT 'src_venta_total', count(*) FROM workspace.demo_sell_out.src_venta_total
UNION ALL SELECT 'src_dim_frq_so', count(*) FROM workspace.demo_sell_out.src_dim_frq_so
UNION ALL SELECT 'src_dim_tcurr', count(*) FROM workspace.demo_sell_out.src_dim_tcurr
UNION ALL SELECT 'src_dim_mat_radsku', count(*) FROM workspace.demo_sell_out.src_dim_mat_radsku
UNION ALL SELECT 'src_tce_sku_pais', count(*) FROM workspace.demo_sell_out.src_tce_sku_pais
UNION ALL SELECT 'ref_tiendas', count(*) FROM workspace.demo_sell_out.ref_tiendas
LIMIT 10;
