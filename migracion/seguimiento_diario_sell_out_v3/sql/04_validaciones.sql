-- =====================================================================
-- 04 · Validaciones de la migración (todas con LIMIT, salida corta)
-- =====================================================================

-- 1. Cuadre: la venta POS de gold_sell_out = BiPos con los filtros de S0
WITH fuente AS (
  SELECT round(sum(`Subtotal neto`), 2) AS neto, count(*) AS filas
  FROM workspace.demo_sell_out.src_bipos
  WHERE `Fecha transaccion` <= date_sub(current_date(), 1)
    AND Escala NOT IN ('12 Venta en linea', '13 Marketplace')
    AND upper(trim(regexp_replace(SKU, '^0+', ''))) NOT IN ('BONIFSC','COMISION','ENVIOEXPRESS','ENVIOLIBRE',
        'ENVIONORMAL','FLETE','GASTOS ENVIO','REMBOLSO GTO LOCAL','REPARACION','SELLO STEREN CARD',
        'SERV PROM VENTAS','SERV PUBLIC','SERV PUBLICIDAD','SERVICIO','BALMUN-ACB','BALMUN-ANB','BALMUN-MAS','BALMUN-TRI')
),
destino AS (
  SELECT round(sum(subtotal_neto), 2) AS neto, count(*) AS filas
  FROM workspace.demo_sell_out.gold_sell_out WHERE origen = 'POS'
)
SELECT '1. Cuadre POS' AS prueba, f.neto AS fuente, d.neto AS destino, f.filas AS filas_fuente, d.filas AS filas_destino,
       CASE WHEN f.neto = d.neto AND f.filas = d.filas THEN 'OK' ELSE 'REVISAR' END AS resultado
FROM fuente f CROSS JOIN destino d
LIMIT 1;

-- 2. Cuadre: canales 12 y 13 = Venta Total de esos canales
SELECT '2. Cuadre canales 12/13' AS prueba,
       (SELECT round(sum(`Venta ML`), 2) FROM workspace.demo_sell_out.src_venta_total
         WHERE `Canal Descripcion` IN ('12 Ventas en Línea', '13 Ventas Marketplace')) AS fuente,
       (SELECT round(sum(subtotal_neto), 2) FROM workspace.demo_sell_out.gold_sell_out WHERE origen = 'VENTA_TOTAL') AS destino
LIMIT 1;

-- 3. Sin duplicados: una fila por tienda, día, SKU, escala y origen
SELECT '3. Duplicados' AS prueba, count(*) AS llaves_repetidas
FROM (
  SELECT cliente_sap, mandante, fecha_transaccion, sku, escala, origen, cliente_sap
  FROM workspace.demo_sell_out.gold_sell_out
  GROUP BY ALL HAVING count(*) > 1
)
LIMIT 1;

-- 4. Error de Tableau: escala 12/13 que SO_1 dejaba pasar (se sumaría dos veces
--    con los canales que agrega SO_3). Venta diaria promedio en riesgo, en pesos.
SELECT '4. Escala 12/13 en BiPos' AS prueba,
       round(sum(`Subtotal neto`) / count(DISTINCT `Fecha transaccion`), 2) AS neto_diario_en_riesgo_local,
       round(100 * sum(`Subtotal neto`) / (SELECT sum(`Subtotal neto`) FROM workspace.demo_sell_out.src_bipos), 2) AS pct_de_la_venta
FROM workspace.demo_sell_out.src_bipos
WHERE Escala IN ('12 Venta en linea', '13 Marketplace')
LIMIT 1;

-- 5. Error de Tableau: Zona con IFNULL invertido (filas que caen en otra zona)
SELECT '5. Zona invertida' AS prueba, count(*) AS filas_afectadas, round(sum(s.`Subtotal neto`), 2) AS neto_afectado
FROM workspace.demo_sell_out.silver_sell_out_integracion s
JOIN workspace.demo_sell_out.src_dim_frq_so f
  ON f.`FR Pais` = s.Pais AND f.`FR_Mandante` = s.Mandante AND f.`FR Cliente sap` = s.`Cliente sap`
WHERE coalesce(s.Zona, f.`Segundo Zona`) <> coalesce(f.`Segundo Zona`, s.Zona)
LIMIT 1;

-- 6. Error de Tableau: días sin tipo de cambio (venta de LATAM sin convertir)
SELECT '6. Días sin tipo de cambio' AS prueba, count(DISTINCT fecha_transaccion) AS dias,
       count(*) AS filas_latam, round(sum(subtotal_neto), 2) AS neto_local_sin_convertir
FROM workspace.demo_sell_out.gold_sell_out
WHERE tc_imputado AND pais_descripcion NOT IN ('México', 'Producto E.')
LIMIT 1;

-- 7. Tienda igual: tiendas nuevas (abiertas en marzo 2026) deben ser 'No'
SELECT '7. Tienda igual' AS prueba, tienda, min(fecha_transaccion) AS primera_venta, max(tienda_igual) AS tienda_igual
FROM workspace.demo_sell_out.gold_sell_out
WHERE origen = 'POS'
GROUP BY tienda
HAVING min(fecha_transaccion) > DATE'2025-09-01'
LIMIT 10;

-- 8. Sucesoras: el cliente SAP viejo debe quedar con el nombre y la zona de la tienda actual
SELECT '8. Sucesoras' AS prueba, tienda, count(DISTINCT cliente_sap) AS clientes_sap, count(DISTINCT zona) AS zonas,
       min(fecha_transaccion) AS desde
FROM workspace.demo_sell_out.gold_sell_out
WHERE tienda IN (SELECT tienda FROM workspace.demo_sell_out.ref_tiendas_attr WHERE sap_anterior IS NOT NULL)
GROUP BY tienda
LIMIT 5;

-- 9. Moneda: venta de un día de Colombia en MXP y USD contra cálculo a mano
SELECT '9. Conversión' AS prueba, f.fecha_transaccion, round(sum(f.subtotal_neto), 2) AS cop,
       round(sum(f.venta), 2) AS mxp_funcion, round(sum(f.subtotal_neto) * max(t.tc_copmxp), 2) AS mxp_a_mano
FROM workspace.demo_sell_out.fn_sell_out('MXP', 'Día', DATE'2025-10-19') f
JOIN workspace.demo_sell_out.silver_tipo_cambio t ON t.fecha = f.fecha_transaccion
WHERE f.pais_descripcion = 'Colombia' AND f.fecha_transaccion = DATE'2026-10-01'
GROUP BY ALL
LIMIT 1;
