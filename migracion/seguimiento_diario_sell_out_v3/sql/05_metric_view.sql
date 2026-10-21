-- =====================================================================
-- 05 · Metric view con parámetros: base única de todas las gráficas
-- =====================================================================
-- Reemplaza la mv_sell_out de 03 (sin parámetros). Los parámetros del tablero
-- de Tableau entran aquí y se pasan desde cada dataset del tablero:
--   SELECT ..., MEASURE(Venta) FROM workspace.demo_sell_out.mv_sell_out(moneda => :moneda, ...) GROUP BY ...
--
--   moneda    'MXP' | 'USD' | 'Local'                       [Moneda]
--   tipo_tc   'Día' | 'Cierre de mes' | 'Fecha exacta'      [Tipo de Divisa]
--   fecha_tc  fecha para 'Fecha exacta'                     [Fecha Especifica]
--   dias_n, dias_m  ventanas de días hacia atrás            [Dias Atras N] [Dias Atras M]
--   a_ini, a_fin, b_ini, b_fin  periodos del comparativo    [Fecha inicio/fin A y B]
--
-- Todas las medidas de periodo son sumas con FILTER: se pueden volver a sumar
-- en las gráficas sin cambiar el resultado. Margen, precio promedio y conteos
-- distintos se dejan para consultas directas (Genie); en el tablero se calculan
-- a partir de las sumas.
-- Requiere un warehouse con Databricks Runtime 18.2 o superior.
-- =====================================================================

DROP VIEW IF EXISTS workspace.demo_sell_out.vw_sell_out_mxp;

CREATE OR REPLACE VIEW workspace.demo_sell_out.mv_sell_out
WITH METRICS
LANGUAGE YAML
COMMENT 'Sell Out (fuente "Sell Out." de Tableau) con moneda, tipo de cambio y periodos como parámetros'
AS $$
version: 1.1
source: SELECT * FROM workspace.demo_sell_out.fn_sell_out(moneda, tipo_tc, fecha_tc)

parameters:
  - name: moneda
    data_type: string
    default: "'MXP'"
  - name: tipo_tc
    data_type: string
    default: "'Día'"
  - name: fecha_tc
    data_type: date
    default: "'2025-10-19'"
  - name: dias_n
    data_type: int
    default: 56
  - name: dias_m
    data_type: int
    default: 14
  - name: a_ini
    data_type: date
    default: "'2026-10-14'"
  - name: a_fin
    data_type: date
    default: "'2026-10-20'"
  - name: b_ini
    data_type: date
    default: "'2026-10-07'"
  - name: b_fin
    data_type: date
    default: "'2026-10-13'"

dimensions:
  - name: Fecha
    expr: fecha_transaccion
  - name: Mes
    expr: date_trunc('MONTH', fecha_transaccion)
  - name: Dia de la semana
    expr: dia_semana
  - name: Pais
    expr: pais_descripcion
  - name: Tipo de tienda
    expr: tipo_tienda
  - name: Zona
    expr: zona_tablero
  - name: Escala
    expr: escala
  - name: CatWeb1
    expr: catweb1_tablero
  - name: Macrotipo
    expr: macrotipo
  - name: Grupo
    expr: grupo
  - name: Tienda
    expr: tienda
  - name: Tienda igual
    expr: tienda_igual
  - name: Familia
    expr: familia_tablero
  - name: Subfamilia
    expr: subfamilia
  - name: SKU
    expr: sku
  - name: SKU descripcion
    expr: sku_descripcion_tablero
  - name: Estatus SKU
    expr: estatus_sku_tablero

measures:
  # ---- básicas ----
  - name: Venta
    expr: SUM(venta)
  - name: Cantidad
    expr: SUM(cantidad)
  - name: Utilidad
    expr: SUM(utilidad)
  - name: Costo
    expr: SUM(costo)
  - name: Descuento
    expr: SUM(descuento)
  - name: Margen
    expr: try_divide(SUM(utilidad), SUM(venta))
  - name: Precio promedio
    expr: try_divide(SUM(venta), SUM(cantidad))
  - name: Tiendas activas
    expr: COUNT(DISTINCT tienda)
  - name: Dias con venta
    expr: COUNT(DISTINCT fecha_transaccion)
  # ---- periodos relativos a hoy (Resumen diario) ----
  - name: Venta ayer
    expr: SUM(venta) FILTER (WHERE fecha_transaccion = date_sub(current_date(), 1))
  - name: Cantidad ayer
    expr: SUM(cantidad) FILTER (WHERE fecha_transaccion = date_sub(current_date(), 1))
  - name: Venta 7 dias
    expr: SUM(venta) FILTER (WHERE fecha_transaccion >= date_sub(current_date(), 7))
  - name: Cantidad 7 dias
    expr: SUM(cantidad) FILTER (WHERE fecha_transaccion >= date_sub(current_date(), 7))
  - name: Venta 30 dias
    expr: SUM(venta) FILTER (WHERE fecha_transaccion >= date_sub(current_date(), 30))
  - name: Cantidad 30 dias
    expr: SUM(cantidad) FILTER (WHERE fecha_transaccion >= date_sub(current_date(), 30))
  - name: Utilidad 30 dias
    expr: SUM(utilidad) FILTER (WHERE fecha_transaccion >= date_sub(current_date(), 30))
  - name: Venta mes en curso
    expr: SUM(venta) FILTER (WHERE fecha_transaccion >= date_trunc('MONTH', current_date()))
  - name: Cantidad mes en curso
    expr: SUM(cantidad) FILTER (WHERE fecha_transaccion >= date_trunc('MONTH', current_date()))
  # ---- ventanas N y M (Concentrado) ----
  - name: Venta ultimos N
    expr: SUM(venta) FILTER (WHERE fecha_transaccion >= date_sub(current_date(), dias_n))
  - name: Venta ultimos M
    expr: SUM(venta) FILTER (WHERE fecha_transaccion >= date_sub(current_date(), dias_m))
  - name: Cantidad ultimos N
    expr: SUM(cantidad) FILTER (WHERE fecha_transaccion >= date_sub(current_date(), dias_n))
  - name: Cantidad ultimos M
    expr: SUM(cantidad) FILTER (WHERE fecha_transaccion >= date_sub(current_date(), dias_m))
  - name: Dias con venta N
    expr: COUNT(DISTINCT fecha_transaccion) FILTER (WHERE fecha_transaccion >= date_sub(current_date(), dias_n))
  - name: Dias con venta M
    expr: COUNT(DISTINCT fecha_transaccion) FILTER (WHERE fecha_transaccion >= date_sub(current_date(), dias_m))
  # ---- periodos A y B (Comparativo) ----
  - name: Venta A
    expr: SUM(venta) FILTER (WHERE fecha_transaccion BETWEEN a_ini AND a_fin)
  - name: Venta B
    expr: SUM(venta) FILTER (WHERE fecha_transaccion BETWEEN b_ini AND b_fin)
  - name: Cantidad A
    expr: SUM(cantidad) FILTER (WHERE fecha_transaccion BETWEEN a_ini AND a_fin)
  - name: Cantidad B
    expr: SUM(cantidad) FILTER (WHERE fecha_transaccion BETWEEN b_ini AND b_fin)
  - name: Utilidad A
    expr: SUM(utilidad) FILTER (WHERE fecha_transaccion BETWEEN a_ini AND a_fin)
  - name: Utilidad B
    expr: SUM(utilidad) FILTER (WHERE fecha_transaccion BETWEEN b_ini AND b_fin)
  - name: Costo A
    expr: SUM(costo) FILTER (WHERE fecha_transaccion BETWEEN a_ini AND a_fin)
  - name: Costo B
    expr: SUM(costo) FILTER (WHERE fecha_transaccion BETWEEN b_ini AND b_fin)
  - name: Descuento A
    expr: SUM(descuento) FILTER (WHERE fecha_transaccion BETWEEN a_ini AND a_fin)
  - name: Descuento B
    expr: SUM(descuento) FILTER (WHERE fecha_transaccion BETWEEN b_ini AND b_fin)
$$;

-- Prueba: por omisión (MXP, día) y en USD con cierre de mes
SELECT `Tipo de tienda`, MEASURE(Venta) AS venta_mxp, MEASURE(`Venta ultimos M`) AS venta_m, MEASURE(`Venta A`) AS venta_a
FROM workspace.demo_sell_out.mv_sell_out()
WHERE Pais = 'México'
GROUP BY ALL ORDER BY venta_mxp DESC
LIMIT 10;

SELECT Pais, MEASURE(Venta) AS venta_usd, MEASURE(`Venta ultimos M`) AS venta_m_usd
FROM workspace.demo_sell_out.mv_sell_out(moneda => 'USD', tipo_tc => 'Cierre de mes', dias_m => 7)
GROUP BY ALL ORDER BY venta_usd DESC
LIMIT 10;
