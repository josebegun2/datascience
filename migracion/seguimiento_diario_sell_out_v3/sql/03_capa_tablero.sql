-- =====================================================================
-- 03 · Capa del tablero: campos calculados de fila + conversión de moneda
-- =====================================================================
-- En Tableau el libro tiene 102 campos calculados. Se reparten así:
--   * Los de FILA (no agregan): aquí, en la función fn_sell_out.
--   * Los que dependen de PARÁMETROS de moneda y tipo de cambio: argumentos
--     de la función (moneda, tipo_tc, fecha_tc).
--   * Los AGREGADOS y de ventana (rank, % del total, acumulados, últimos
--     N/M días, A vs B): en el SQL de cada dataset del tablero.
--   * Medidas: metric view mv_sell_out con parámetros (sql/05_metric_view.sql),
--     que lee esta función y es la base de todos los datasets del tablero.
--
-- Parámetros de Tableau -> argumentos de la función:
--   [Moneda]          0 Local / 1 MXP / 2 USD        -> moneda  'Local'|'MXP'|'USD'
--   [Tipo de Divisa]  1 día / 2 cierre / 3 exacta    -> tipo_tc 'Día'|'Cierre de mes'|'Fecha exacta'
--   [Fecha Especifica]                              -> fecha_tc DATE
-- =====================================================================

CREATE OR REPLACE FUNCTION workspace.demo_sell_out.fn_sell_out(
  moneda   STRING DEFAULT 'MXP',
  tipo_tc  STRING DEFAULT 'Día',
  fecha_tc DATE   DEFAULT DATE'2025-10-19'
)
RETURNS TABLE
COMMENT 'Sell Out con los campos calculados de fila del tablero y la venta convertida a la moneda elegida'
RETURN
WITH
-- [Tc Ultimo Mes cerrado] usa el último día del mes anterior; [TcFecha Excacta] una fecha elegida
tc_cierre AS (
  SELECT struct(tc_copmxp, tc_crcmxp, tc_usdmxp, tc_hnlmxp, tc_gtqmxp, tc_penmxp, tc_dopmxp, tc_copusd, tc_crcusd, tc_mxpusd, tc_hnlusd, tc_gtqusd, tc_penusd, tc_dopusd) AS cierre
  FROM workspace.demo_sell_out.silver_tipo_cambio
  WHERE fecha = date_sub(date_trunc('month', current_date()), 1)
),
tc_exacta AS (
  SELECT struct(tc_copmxp, tc_crcmxp, tc_usdmxp, tc_hnlmxp, tc_gtqmxp, tc_penmxp, tc_dopmxp, tc_copusd, tc_crcusd, tc_mxpusd, tc_hnlusd, tc_gtqusd, tc_penusd, tc_dopusd) AS exacta
  FROM workspace.demo_sell_out.silver_tipo_cambio
  WHERE fecha = fn_sell_out.fecha_tc
),
-- [Cliente SAP - Tienda]: 33 clientes que se reportan con el número de su sucesor
remapeo AS (
  SELECT * FROM VALUES
    ('500796','500963'),('580516','500963'),('500783','500030'),('500174','500846'),('500200','500824'),
    ('500816','500836'),('500019','500977'),('500375','500778'),('500033','500740'),('500061','500731'),
    ('500610','500887'),('500065','500823'),('500457','500742'),('500062','500732'),('500970','500979'),
    ('500445','500848'),('580175','580428'),('500250','500822'),('500013','500741'),('500477','500736'),
    ('500014','500763'),('500637','500987'),('580026','580427'),('500425','500735'),('580019','580466'),
    ('580229','580550'),('500507','500777'),('500818','501006'),('500032','500776'),('500015','500886'),
    ('500626','500965'),('500195','500988'),('500806','500978'),('500395','500825')
  AS r(cliente_sap, cliente_sap_reporte)
),
base AS (
  SELECT g.*,
    -- tipo de cambio a usar según [Tipo de Divisa]
    CASE fn_sell_out.tipo_tc
      WHEN 'Cierre de mes' THEN c.cierre
      WHEN 'Fecha exacta'  THEN e.exacta
      ELSE struct(g.tc_copmxp, g.tc_crcmxp, g.tc_usdmxp, g.tc_hnlmxp, g.tc_gtqmxp, g.tc_penmxp, g.tc_dopmxp,
                  g.tc_copusd, g.tc_crcusd, g.tc_mxpusd, g.tc_hnlusd, g.tc_gtqusd, g.tc_penusd, g.tc_dopusd)
    END AS tc,
    -- [Filtro de datos sensibles]: costo y utilidad solo para el grupo autorizado
    CASE WHEN is_member('admins') OR current_user() IN ('june@steren.com.mx', 'manuel@steren.com.mx') THEN 1 ELSE 0 END AS ve_sensibles
  FROM workspace.demo_sell_out.gold_sell_out g
  LEFT JOIN tc_cierre c ON true
  LEFT JOIN tc_exacta e ON true
),
conv AS (
  SELECT base.* EXCEPT (tc),
    -- [Tipo de cambio (copia)] / [Tc Ultimo Mes cerrado] / [TcFecha Excacta]: según país y moneda destino
    CASE WHEN fn_sell_out.moneda = 'Local' THEN 1.0
         WHEN pais_descripcion IN ('México', 'Producto E.') THEN CASE WHEN fn_sell_out.moneda = 'MXP' THEN 1.0 ELSE tc.tc_mxpusd END
         WHEN pais_descripcion IN ('Ecuador', 'El Salvador', 'Panama', 'Panamá') THEN CASE WHEN fn_sell_out.moneda = 'MXP' THEN tc.tc_usdmxp ELSE 1.0 END
         WHEN pais_descripcion = 'Colombia' THEN CASE WHEN fn_sell_out.moneda = 'MXP' THEN tc.tc_copmxp ELSE tc.tc_copusd END
         WHEN pais_descripcion = 'Costa Rica' THEN CASE WHEN fn_sell_out.moneda = 'MXP' THEN tc.tc_crcmxp ELSE tc.tc_crcusd END
         WHEN pais_descripcion = 'Guatemala' THEN CASE WHEN fn_sell_out.moneda = 'MXP' THEN tc.tc_gtqmxp ELSE tc.tc_gtqusd END
         WHEN pais_descripcion = 'Honduras' THEN CASE WHEN fn_sell_out.moneda = 'MXP' THEN tc.tc_hnlmxp ELSE tc.tc_hnlusd END
         WHEN pais_descripcion IN ('Peru', 'Perú') THEN CASE WHEN fn_sell_out.moneda = 'MXP' THEN tc.tc_penmxp ELSE tc.tc_penusd END
         WHEN pais_descripcion = 'Rep.Dominicana' THEN CASE WHEN fn_sell_out.moneda = 'MXP' THEN tc.tc_dopmxp ELSE tc.tc_dopusd END
         ELSE 1.0 END AS tipo_cambio
  FROM base
)
SELECT
  b.* EXCEPT (tipo_cambio, ve_sensibles),
  b.tipo_cambio,
  b.subtotal_neto * b.tipo_cambio AS venta,                                               -- [Venta]
  b.costo_promedio * b.ve_sensibles * b.tipo_cambio AS costo,                             -- [ Costo]
  b.utilidad_promedio * b.ve_sensibles * b.tipo_cambio AS utilidad,                       -- [Utilidad]
  (b.descuento_cabecera + b.descuento_posicion) * b.tipo_cambio AS descuento,             -- [Descuento]
  -- [Tipo de tienda]
  initcap(CASE
    WHEN b.macrotipo IN ('12 Venta en linea', '13 Marketplace') THEN b.macrotipo
    WHEN b.macrotipo = '100x100' OR b.subtipo = '100x100' THEN '100 X 100'
    WHEN b.cliente_sap IN ('9000003','9000008','9000011','9000012','9000014','9000015','9000085',
                           '9000016','9000025','9000026','9000055') THEN 'Pv'
    WHEN left(b.cliente_sap, 3) = '580' THEN 'Shop'
    WHEN left(b.cliente_sap, 3) = '500' THEN 'Profesional'
    ELSE b.macrotipo END) AS tipo_tienda,
  -- [Zona ] (se compara en mayúsculas; en Tableau la comparación es exacta)
  CASE upper(b.zona) WHEN 'MEXICO' THEN '13 Marketplace' WHEN '13 MARKETPLACE' THEN '13 Marketplace'
                     WHEN '12 VENTA EN LINEA' THEN '12 Venta en Linea' WHEN 'CENTRO' THEN 'Centro'
                     WHEN 'NORTE' THEN 'Norte' WHEN 'BAJIO' THEN 'Bajio' WHEN 'SURESTE' THEN 'Sureste' END AS zona_tablero,
  -- [Familia ]
  concat(upper(left(b.familia, 1)), lower(substr(b.familia, 2))) AS familia_tablero,
  -- [CatWeb1.] [CatWeb2.]
  coalesce(b.catweb1, 'N/A') AS catweb1_tablero,
  coalesce(b.catweb2, 'N/A') AS catweb2_tablero,
  -- [Estatus SKU ]: el estatus "más avanzado" que haya tenido el SKU
  element_at(array('Sin Estatus','Nuevo','Linea','Descontinuado por Compras','Por Rematar','Por Devolver','Descontinuado'),
    max(CASE coalesce(b.estatus_sku, 'Sin Estatus') WHEN 'Sin Estatus' THEN 1 WHEN 'Nuevo' THEN 2 WHEN 'Linea' THEN 3
             WHEN 'Descontinuado por Compras' THEN 4 WHEN 'Por Rematar' THEN 5 WHEN 'Por Devolver' THEN 6
             WHEN 'Descontinuado' THEN 7 END) OVER (PARTITION BY b.sku)) AS estatus_sku_tablero,
  -- [SKU Descripción]: la descripción más reciente del SKU
  max_by(b.sku_descripcion, b.fecha_transaccion) OVER (PARTITION BY b.sku) AS sku_descripcion_tablero,
  -- [Dia de la Semana]
  element_at(array('Lunes','Martes','Miercoles','Jueves','Viernes','Sabado','Domingo'),
             weekday(b.fecha_transaccion) + 1) AS dia_semana,
  -- [Cliente SAP - Tienda]
  concat(coalesce(r.cliente_sap_reporte, b.cliente_sap), ' ', b.tienda) AS cliente_sap_tienda,
  -- [StarWars] [Amazon] [Filtro SKUs importes negativos]
  b.sku LIKE '%/SW%' AS es_starwars,
  b.sku LIKE '%ECHO%' AS es_amazon
FROM conv b
LEFT JOIN remapeo r ON r.cliente_sap = b.cliente_sap;

-- ---------------------------------------------------------------------
-- Prueba de la función (poca salida)
-- ---------------------------------------------------------------------
SELECT pais_descripcion, tipo_tienda, round(sum(venta)) AS venta_mxp, round(sum(utilidad)) AS utilidad,
       round(min(tipo_cambio), 5) AS tc_min, round(max(tipo_cambio), 5) AS tc_max
FROM workspace.demo_sell_out.fn_sell_out('MXP', 'Día', DATE'2025-10-19')
GROUP BY ALL ORDER BY venta_mxp DESC
LIMIT 15;
