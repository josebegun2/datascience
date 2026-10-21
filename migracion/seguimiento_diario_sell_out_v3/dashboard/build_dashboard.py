"""Genera el tablero AI/BI (Lakeview) "Seguimiento Diario Sell Out V3" y lo publica con la CLI.

Uso:
    python3 build_dashboard.py                 # solo escribe dashboard.lvdash.json
    python3 build_dashboard.py --crear         # crea el tablero en el workspace
    python3 build_dashboard.py --actualizar ID # reemplaza el contenido de un tablero existente

Migración "nativa": tablas, gráficas, filtros y parámetros de Databricks. No se copian colores,
logo ni formato de Tableau.

Parámetros de Tableau -> parámetros del tablero (todos en la página de filtros globales):
    Moneda / Tipo de Divisa / Fecha Especifica   -> moneda, tipo_tc, fecha_tc
    Venta o cantidad                             -> medida
    Agrupacion Diario                            -> agrupacion
    Dias Atras N / Dias Atras M                  -> dias_n, dias_m
    Dimension comparativo / Medida Comparativo   -> dimension, medida_comp
    Fecha inicio/fin A y B                       -> a_ini, a_fin, b_ini, b_fin
    Filtro "Pais descripcion = México"           -> pais (con opción 'Todos')
"""
import argparse
import json
import os
import subprocess

AQUI = os.path.dirname(os.path.abspath(__file__))
WAREHOUSE = "fa978ee381d35616"
FN = "workspace.demo_sell_out.fn_sell_out(:moneda, :tipo_tc, :fecha_tc)"

# ---------------------------------------------------------------------------
# Parámetros (keyword, tipo, valor por omisión)
# ---------------------------------------------------------------------------
PARAMS = {
    "moneda": ("STRING", "MXP"),
    "tipo_tc": ("STRING", "Día"),
    "fecha_tc": ("DATE", "2025-10-19"),
    "pais": ("STRING", "México"),
    "medida": ("STRING", "venta"),
    "agrupacion": ("STRING", "Tipo de tienda"),
    "dias_n": ("INTEGER", "56"),
    "dias_m": ("INTEGER", "14"),
    "dimension": ("STRING", "SKU"),
    "medida_comp": ("STRING", "Venta"),
    "a_ini": ("DATE", "2026-10-14"),
    "a_fin": ("DATE", "2026-10-20"),
    "b_ini": ("DATE", "2026-10-07"),
    "b_fin": ("DATE", "2026-10-13"),
}

OPCIONES = {
    "moneda": ["MXP", "USD", "Local"],
    "tipo_tc": ["Día", "Cierre de mes", "Fecha exacta"],
    "pais": None,  # sale de los datos
    "medida": ["venta", "cantidad"],
    "agrupacion": ["Tipo de tienda", "Zona", "Escala", "Catweb1"],
    "dias_n": ["28", "56", "90"],
    "dias_m": ["7", "14", "28"],
    "dimension": ["Macrotipo", "Grupo", "Tienda", "Familia", "Subfamilia", "SKU"],
    "medida_comp": ["Venta", "Cantidad", "Utilidad", "Margen", "Costo", "Descuento"],
}

FILTRO_PAIS = "(:pais = 'Todos' OR pais_descripcion = :pais)"


def param_def(k):
    tipo, valor = PARAMS[k]
    return {"displayName": k, "keyword": k, "dataType": tipo,
            "defaultSelection": {"values": {"dataType": tipo, "values": [{"value": valor}]}}}


def dataset(nombre, titulo, sql, params):
    return {"name": nombre, "displayName": titulo,
            "queryLines": [l + "\n" for l in sql.strip().splitlines()],
            "parameters": [param_def(p) for p in params]}


# ---------------------------------------------------------------------------
# Datasets
# ---------------------------------------------------------------------------
DS = []

# Resumen diario: detalle a nivel día, con columnas por periodo (ayer, 7, 30, mes, N días)
DS.append(dataset("ds_detalle", "Detalle diario", f"""
SELECT *,
       CASE WHEN fecha = date_sub(current_date(), 1) THEN valor END AS valor_ayer,
       CASE WHEN fecha >= date_sub(current_date(), 7) THEN valor END AS valor_7d,
       CASE WHEN fecha >= date_sub(current_date(), 7) THEN fecha END AS dia_7d,
       CASE WHEN fecha >= date_sub(current_date(), 30) THEN valor END AS valor_30d,
       CASE WHEN fecha >= date_sub(current_date(), 30) THEN fecha END AS dia_30d,
       CASE WHEN fecha >= date_trunc('MONTH', current_date()) THEN valor END AS valor_mes,
       fecha >= date_sub(current_date(), :dias_n) AS en_ultimos_n
FROM (
  SELECT fecha_transaccion AS fecha, date_trunc('MONTH', fecha_transaccion) AS mes, dia_semana,
         pais_descripcion, tipo_tienda, zona_tablero AS zona, escala, catweb1_tablero AS catweb1,
         familia_tablero AS familia, estatus_sku_tablero AS estatus_sku, tienda, tienda_igual,
         CASE :agrupacion WHEN 'Zona' THEN zona_tablero WHEN 'Escala' THEN escala
                          WHEN 'Catweb1' THEN catweb1_tablero ELSE tipo_tienda END AS agrupacion,
         venta, cantidad, utilidad, descuento,
         CASE WHEN :medida = 'cantidad' THEN cantidad ELSE venta END AS valor
  FROM {FN}
  WHERE {FILTRO_PAIS}
    AND fecha_transaccion >= add_months(date_trunc('MONTH', current_date()), -13)
)
""", ["moneda", "tipo_tc", "fecha_tc", "pais", "medida", "agrupacion", "dias_n"]))

# Venta acumulada del mes contra el mes anterior y el mismo mes del año pasado
DS.append(dataset("ds_acumulado", "Venta acumulada", f"""
SELECT dia, serie, sum(sum(valor)) OVER (PARTITION BY serie ORDER BY dia) AS acumulado
FROM (
  SELECT day(fecha_transaccion) AS dia,
         CASE WHEN fecha_transaccion >= date_trunc('MONTH', current_date()) THEN 'Mes actual'
              WHEN fecha_transaccion >= add_months(date_trunc('MONTH', current_date()), -1) THEN 'Mes anterior'
              WHEN fecha_transaccion >= add_months(date_trunc('MONTH', current_date()), -12)
               AND fecha_transaccion <  add_months(date_trunc('MONTH', current_date()), -11) THEN 'Mismo mes año anterior'
         END AS serie,
         CASE WHEN :medida = 'cantidad' THEN cantidad ELSE venta END AS valor
  FROM {FN}
  WHERE {FILTRO_PAIS}
)
WHERE serie IS NOT NULL
GROUP BY dia, serie
""", ["moneda", "tipo_tc", "fecha_tc", "pais", "medida"]))

# Concentrado: ranking de SKUs, últimos M días contra últimos N días
DS.append(dataset("ds_concentrado", "Concentrado por SKU", f"""
WITH f AS (
  SELECT sku, sku_descripcion_tablero, familia_tablero, tipo_tienda, fecha_transaccion AS fecha, venta, cantidad
  FROM {FN}
  WHERE {FILTRO_PAIS} AND fecha_transaccion >= date_sub(current_date(), :dias_n)
),
d AS (
  SELECT count(DISTINCT CASE WHEN fecha >= date_sub(current_date(), :dias_m) THEN fecha END) AS dias_m,
         count(DISTINCT fecha) AS dias_n
  FROM f
),
s AS (
  SELECT sku, max(sku_descripcion_tablero) AS descripcion, max(familia_tablero) AS familia,
         sum(CASE WHEN fecha >= date_sub(current_date(), :dias_m) THEN venta END) AS venta_m, sum(venta) AS venta_n,
         sum(CASE WHEN fecha >= date_sub(current_date(), :dias_m) THEN cantidad END) AS piezas_m, sum(cantidad) AS piezas_n
  FROM f GROUP BY sku
),
r AS (
  SELECT s.*,
         30 * venta_m / d.dias_m AS venta_mens_m, 30 * venta_n / d.dias_n AS venta_mens_n,
         30 * piezas_m / d.dias_m AS piezas_mens_m, 30 * piezas_n / d.dias_n AS piezas_mens_n,
         row_number() OVER (ORDER BY coalesce(venta_m, 0) DESC) AS rank_m,
         row_number() OVER (ORDER BY coalesce(venta_n, 0) DESC) AS rank_n
  FROM s CROSS JOIN d
)
SELECT *,
       try_divide(venta_mens_m, venta_mens_n) - 1 AS dif_pct_venta_mens,
       venta_mens_m - venta_mens_n AS dif_venta_mens,
       try_divide(piezas_mens_m, piezas_mens_n) - 1 AS dif_pct_piezas_mens,
       rank_m - rank_n AS avance,
       CASE WHEN rank_m = rank_n THEN 'Sin variación' WHEN rank_m > rank_n THEN 'Bajó' ELSE 'Subió' END AS etiqueta_ranking,
       CASE WHEN rank_m <= 100 THEN 'Top 100' WHEN rank_m <= 200 THEN 'Top 101-200'
            WHEN rank_m <= 300 THEN 'Top 201-300' ELSE '300 +' END AS segmento
FROM r
""", ["moneda", "tipo_tc", "fecha_tc", "pais", "dias_n", "dias_m"]))

# Top 10 crecimiento y decremento (venta mensualizada M vs N)
DS.append(dataset("ds_top_variacion", "Top 10 crecimiento y decremento", f"""
WITH f AS (
  SELECT sku, fecha_transaccion AS fecha, venta
  FROM {FN}
  WHERE {FILTRO_PAIS} AND fecha_transaccion >= date_sub(current_date(), :dias_n)
),
d AS (
  SELECT count(DISTINCT CASE WHEN fecha >= date_sub(current_date(), :dias_m) THEN fecha END) AS dias_m,
         count(DISTINCT fecha) AS dias_n FROM f
),
v AS (
  SELECT sku,
         30 * sum(CASE WHEN fecha >= date_sub(current_date(), :dias_m) THEN venta ELSE 0 END) / max(d.dias_m)
       - 30 * sum(venta) / max(d.dias_n) AS dif_venta_mens
  FROM f CROSS JOIN d GROUP BY sku
)
SELECT sku, dif_venta_mens, 'Crecimiento' AS tipo FROM (SELECT * FROM v ORDER BY dif_venta_mens DESC LIMIT 10)
UNION ALL
SELECT sku, dif_venta_mens, 'Decremento' AS tipo FROM (SELECT * FROM v ORDER BY dif_venta_mens ASC LIMIT 10)
""", ["moneda", "tipo_tc", "fecha_tc", "pais", "dias_n", "dias_m"]))

# Comparativo: periodo A contra periodo B por la dimensión elegida
DS.append(dataset("ds_comparativo", "Comparativo A vs B", f"""
WITH f AS (
  SELECT CASE :dimension WHEN 'Macrotipo' THEN macrotipo WHEN 'Grupo' THEN grupo WHEN 'Tienda' THEN tienda
                         WHEN 'Familia' THEN familia_tablero WHEN 'Subfamilia' THEN subfamilia
                         ELSE concat(sku, ' ', coalesce(sku_descripcion_tablero, '')) END AS miembro,
         fecha_transaccion BETWEEN :a_ini AND :a_fin AS en_a,
         fecha_transaccion BETWEEN :b_ini AND :b_fin AS en_b,
         venta, cantidad, utilidad, costo, descuento
  FROM {FN}
  WHERE {FILTRO_PAIS}
    AND (fecha_transaccion BETWEEN :a_ini AND :a_fin OR fecha_transaccion BETWEEN :b_ini AND :b_fin)
),
g AS (
  SELECT miembro,
         sum(CASE WHEN en_a THEN venta END) AS venta_a, sum(CASE WHEN en_b THEN venta END) AS venta_b,
         sum(CASE WHEN en_a THEN cantidad END) AS cantidad_a, sum(CASE WHEN en_b THEN cantidad END) AS cantidad_b,
         sum(CASE WHEN en_a THEN utilidad END) AS utilidad_a, sum(CASE WHEN en_b THEN utilidad END) AS utilidad_b,
         sum(CASE WHEN en_a THEN costo END) AS costo_a, sum(CASE WHEN en_b THEN costo END) AS costo_b,
         sum(CASE WHEN en_a THEN descuento END) AS descuento_a, sum(CASE WHEN en_b THEN descuento END) AS descuento_b
  FROM f GROUP BY miembro
),
m AS (
  SELECT miembro, venta_a, venta_b, utilidad_a, utilidad_b,
         CASE :medida_comp WHEN 'Cantidad' THEN cantidad_a WHEN 'Utilidad' THEN utilidad_a
                           WHEN 'Margen' THEN 100 * try_divide(utilidad_a, venta_a) WHEN 'Costo' THEN costo_a
                           WHEN 'Descuento' THEN descuento_a ELSE venta_a END AS valor_a,
         CASE :medida_comp WHEN 'Cantidad' THEN cantidad_b WHEN 'Utilidad' THEN utilidad_b
                           WHEN 'Margen' THEN 100 * try_divide(utilidad_b, venta_b) WHEN 'Costo' THEN costo_b
                           WHEN 'Descuento' THEN descuento_b ELSE venta_b END AS valor_b
  FROM g
)
SELECT miembro, valor_a, valor_b,
       valor_a - valor_b AS variacion,
       try_divide(valor_a - valor_b, valor_b) AS pct_variacion,
       rank_a, rank_b, rank_b - rank_a AS posiciones_subio,
       CASE WHEN :medida_comp <> 'Margen' THEN try_divide(valor_a, sum(valor_a) OVER ()) END AS pct_del_total_a,
       CASE WHEN :medida_comp <> 'Margen'
            THEN try_divide(sum(valor_a) OVER (ORDER BY rank_a ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
                            sum(valor_a) OVER ()) END AS pct_acumulado_a,
       venta_a, venta_b, utilidad_a, utilidad_b
FROM (
  SELECT *, row_number() OVER (ORDER BY coalesce(valor_a, 0) DESC) AS rank_a,
            row_number() OVER (ORDER BY coalesce(valor_b, 0) DESC) AS rank_b
  FROM m
)
""", ["moneda", "tipo_tc", "fecha_tc", "pais", "dimension", "medida_comp", "a_ini", "a_fin", "b_ini", "b_fin"]))

# Opciones de los parámetros (listas cortas; país sale de los datos)
for k, vals in OPCIONES.items():
    if vals is None:
        sql = ("SELECT 'Todos' AS opcion UNION ALL "
               "SELECT DISTINCT pais_descripcion FROM workspace.demo_sell_out.gold_sell_out")
    else:
        sql = "SELECT * FROM VALUES " + ", ".join(f"('{v}')" for v in vals) + " AS t(opcion)"
    DS.append(dataset(f"opt_{k}", f"Opciones {k}", sql, []))

PARAMS_POR_DS = {d["name"]: [p["keyword"] for p in d["parameters"]] for d in DS}

# ---------------------------------------------------------------------------
# Widgets
# ---------------------------------------------------------------------------
def campo(nombre, expr=None):
    return {"name": nombre, "expression": expr or f"`{nombre}`"}


def query(ds, campos, desagregado=False, nombre="main_query"):
    return {"name": nombre, "query": {"datasetName": ds, "fields": campos, "disaggregated": desagregado}}


def contador(nombre, titulo, ds, expr):
    return {"name": nombre,
            "queries": [query(ds, [campo("valor", expr)])],
            "spec": {"version": 2, "widgetType": "counter",
                     "encodings": {"value": {"fieldName": "valor", "displayName": titulo}},
                     "frame": {"showTitle": True, "title": titulo}}}


def grafica(nombre, titulo, tipo, ds, x, y, color=None, x_tipo="temporal", y_titulo=None, x_titulo=None):
    """x, y, color: (nombre_campo, expresion)."""
    campos = [campo(*x), campo(*y)] + ([campo(*color)] if color else [])
    enc = {"x": {"fieldName": x[0], "scale": {"type": x_tipo}, "displayName": x_titulo or x[0]},
           "y": {"fieldName": y[0], "scale": {"type": "quantitative"}, "displayName": y_titulo or y[0]}}
    if color:
        enc["color"] = {"fieldName": color[0], "scale": {"type": "categorical"}, "displayName": color[0]}
    return {"name": nombre, "queries": [query(ds, campos)],
            "spec": {"version": 3, "widgetType": tipo, "encodings": enc,
                     "frame": {"showTitle": True, "title": titulo}}}


def barra_h(nombre, titulo, ds, categoria, valor, color=None):
    """Barras horizontales: categoría en y, valor en x."""
    campos = [campo(*categoria), campo(*valor)] + ([campo(*color)] if color else [])
    enc = {"x": {"fieldName": valor[0], "scale": {"type": "quantitative"}, "displayName": valor[0]},
           "y": {"fieldName": categoria[0], "scale": {"type": "categorical",
                 "sort": {"by": "x-reversed"}}, "displayName": categoria[0]}}
    if color:
        enc["color"] = {"fieldName": color[0], "scale": {"type": "categorical"}, "displayName": color[0]}
    return {"name": nombre, "queries": [query(ds, campos)],
            "spec": {"version": 3, "widgetType": "bar", "encodings": enc,
                     "frame": {"showTitle": True, "title": titulo}}}


def tabla(nombre, titulo, ds, columnas, desagregado=True):
    """columnas: lista de (nombre, expresion | None, titulo, tipo 'string'|'number'|'date', formato)."""
    campos, cols = [], []
    for i, (n, expr, tit, tipo, fmt) in enumerate(columnas):
        campos.append(campo(n, expr))
        c = {"fieldName": n, "displayName": tit, "title": tit, "type": {"number": "float", "date": "date"}.get(tipo, "string"),
             "displayAs": {"number": "number", "date": "datetime"}.get(tipo, "string"),
             "visible": True, "order": i, "alignContent": "right" if tipo == "number" else "left",
             "allowSearch": tipo == "string", "booleanValues": ["false", "true"], "imageUrlTemplate": "{{ @ }}",
             "imageTitleTemplate": "{{ @ }}", "imageWidth": "", "imageHeight": "", "linkUrlTemplate": "{{ @ }}",
             "linkTextTemplate": "{{ @ }}", "linkTitleTemplate": "{{ @ }}", "linkOpenInNewTab": True,
             "allowHTML": False, "highlightLinks": False, "useMonospaceFont": False, "preserveWhitespace": False}
        if fmt:
            c["numberFormat"] = fmt
        if tipo == "date":
            c["dateTimeFormat"] = "YYYY-MM-DD"
        cols.append(c)
    return {"name": nombre, "queries": [query(ds, campos, desagregado)],
            "spec": {"version": 1, "widgetType": "table", "encodings": {"columns": cols},
                     "invisibleColumns": [], "allowHTMLByDefault": False, "itemsPerPage": 25,
                     "paginationSize": "default", "condensed": True, "withRowNumber": False,
                     "frame": {"showTitle": True, "title": titulo}}}


def filtro_parametro(nombre, titulo, keyword, tipo_widget="filter-single-select"):
    """Filtro que fija un parámetro en todos los datasets que lo usan; opciones desde opt_<keyword>."""
    queries, fields = [], []
    if keyword in OPCIONES:
        qn = f"opt_{keyword}_q"
        queries.append(query(f"opt_{keyword}", [campo("opcion")], nombre=qn))
        fields.append({"fieldName": "opcion", "displayName": titulo, "queryName": qn})
    for ds, ps in PARAMS_POR_DS.items():
        if keyword in ps:
            qn = f"param_{ds}_{keyword}"
            queries.append({"name": qn, "query": {"datasetName": ds,
                            "parameters": [{"name": keyword, "keyword": keyword}], "disaggregated": False}})
            fields.append({"parameterName": keyword, "queryName": qn})
    return {"name": nombre, "queries": queries,
            "spec": {"version": 2, "widgetType": tipo_widget, "encodings": {"fields": fields},
                     "frame": {"showTitle": True, "title": titulo}}}


def filtro_campo(nombre, titulo, ds, columna):
    qn = f"{ds}_{columna}"
    return {"name": nombre, "queries": [query(ds, [campo(columna)], nombre=qn)],
            "spec": {"version": 2, "widgetType": "filter-multi-select",
                     "encodings": {"fields": [{"fieldName": columna, "displayName": titulo, "queryName": qn}]},
                     "frame": {"showTitle": True, "title": titulo}}}


def pos(w, x, y, ancho, alto):
    return {"widget": w, "position": {"x": x, "y": y, "width": ancho, "height": alto}}


MONEY = {"type": "number-currency", "currencyCode": "MXN", "abbreviation": "compact",
         "decimalPlaces": {"type": "max", "places": 1}}
PCT = {"type": "number-percent", "decimalPlaces": {"type": "max", "places": 1}}
NUM = {"type": "number-plain", "abbreviation": "compact", "decimalPlaces": {"type": "max", "places": 1}}

# --- Página 1: Resumen diario ---
p1 = [
    pos(contador("k_ayer", "Ayer", "ds_detalle", "SUM(`valor_ayer`)"), 0, 0, 1, 2),
    pos(contador("k_7d", "Promedio diario últimos 7 días", "ds_detalle",
                 "SUM(`valor_7d`) / COUNT(DISTINCT `dia_7d`)"), 1, 0, 1, 2),
    pos(contador("k_30d", "Promedio diario últimos 30 días", "ds_detalle",
                 "SUM(`valor_30d`) / COUNT(DISTINCT `dia_30d`)"), 2, 0, 1, 2),
    pos(contador("k_mes", "Mes en curso", "ds_detalle", "SUM(`valor_mes`)"), 3, 0, 1, 2),
    pos(contador("k_tiendas", "Tiendas activas (30 días)", "ds_detalle",
                 "COUNT(DISTINCT CASE WHEN `dia_30d` IS NOT NULL THEN `tienda` END)"), 4, 0, 1, 2),
    pos(contador("k_margen", "Margen (30 días)", "ds_detalle",
                 "SUM(CASE WHEN `dia_30d` IS NOT NULL THEN `utilidad` END) / SUM(CASE WHEN `dia_30d` IS NOT NULL THEN `venta` END)"),
        5, 0, 1, 2),
    pos(grafica("g_diaria", "Venta diaria (últimos N días) por agrupación", "line", "ds_detalle",
                ("fecha", "CASE WHEN `en_ultimos_n` THEN `fecha` END"), ("valor", "SUM(`valor`)"),
                ("agrupacion", "`agrupacion`"), x_titulo="Fecha", y_titulo="Venta o cantidad"), 0, 2, 4, 6),
    pos(barra_h("g_participacion", "Participación por agrupación (30 días)", "ds_detalle",
                ("agrupacion", "`agrupacion`"), ("valor_30d", "SUM(`valor_30d`)")), 4, 2, 2, 6),
    pos(grafica("g_acumulada", "Venta acumulada del mes", "line", "ds_acumulado",
                ("dia", "`dia`"), ("acumulado", "SUM(`acumulado`)"), ("serie", "`serie`"),
                x_tipo="quantitative", x_titulo="Día del mes", y_titulo="Acumulado"), 0, 8, 3, 6),
    pos(barra_h("g_tiendas", "Distribución de tiendas activas (30 días)", "ds_detalle",
                ("tipo_tienda", "`tipo_tienda`"),
                ("tiendas", "COUNT(DISTINCT CASE WHEN `dia_30d` IS NOT NULL THEN `tienda` END)")), 3, 8, 3, 6),
    pos(grafica("g_historico", "Histórico mensual", "bar", "ds_detalle",
                ("mes", "`mes`"), ("valor", "SUM(`valor`)"), x_titulo="Mes", y_titulo="Venta o cantidad"), 0, 14, 3, 6),
    pos(grafica("g_precio", "Histórico de precio promedio", "line", "ds_detalle",
                ("mes", "`mes`"), ("precio_promedio", "SUM(`venta`) / SUM(`cantidad`)"),
                x_titulo="Mes", y_titulo="Precio promedio"), 3, 14, 3, 6),
    pos(tabla("t_detalle", "Detalle diario por agrupación", "ds_detalle", [
        ("agrupacion", "`agrupacion`", "Agrupación", "string", None),
        ("ayer", "SUM(`valor_ayer`)", "Ayer", "number", NUM),
        ("prom_7d", "SUM(`valor_7d`) / COUNT(DISTINCT `dia_7d`)", "Prom. diario 7 días", "number", NUM),
        ("prom_30d", "SUM(`valor_30d`) / COUNT(DISTINCT `dia_30d`)", "Prom. diario 30 días", "number", NUM),
        ("mes", "SUM(`valor_mes`)", "Mes en curso", "number", NUM),
        ("tiendas", "COUNT(DISTINCT CASE WHEN `dia_30d` IS NOT NULL THEN `tienda` END)", "Tiendas activas", "number", None),
    ], desagregado=False), 0, 20, 6, 6),
    pos(filtro_campo("f_tipo_tienda", "Tipo de tienda", "ds_detalle", "tipo_tienda"), 0, 26, 2, 2),
    pos(filtro_campo("f_zona", "Zona", "ds_detalle", "zona"), 2, 26, 2, 2),
    pos(filtro_campo("f_familia", "Familia", "ds_detalle", "familia"), 4, 26, 2, 2),
]

# --- Página 2: Concentrado ---
p2 = [
    pos(barra_h("g_top", "Top 10 crecimiento y decremento (venta mensualizada M vs N)", "ds_top_variacion",
                ("sku", "`sku`"), ("dif_venta_mens", "SUM(`dif_venta_mens`)"), ("tipo", "`tipo`")), 0, 0, 6, 7),
    pos(filtro_campo("f_segmento", "Segmento de ranking", "ds_concentrado", "segmento"), 0, 7, 2, 2),
    pos(filtro_campo("f_etiqueta", "Movimiento en el ranking", "ds_concentrado", "etiqueta_ranking"), 2, 7, 2, 2),
    pos(filtro_campo("f_familia_c", "Familia", "ds_concentrado", "familia"), 4, 7, 2, 2),
    pos(tabla("t_concentrado", "Ranking de SKUs: últimos M días contra últimos N días", "ds_concentrado", [
        ("rank_m", None, "Rank M", "number", None),
        ("rank_n", None, "Rank N", "number", None),
        ("etiqueta_ranking", None, "Movimiento", "string", None),
        ("sku", None, "SKU", "string", None),
        ("descripcion", None, "Descripción", "string", None),
        ("familia", None, "Familia", "string", None),
        ("venta_m", None, "Venta últimos M", "number", MONEY),
        ("venta_n", None, "Venta últimos N", "number", MONEY),
        ("venta_mens_m", None, "Venta mensualizada M", "number", MONEY),
        ("venta_mens_n", None, "Venta mensualizada N", "number", MONEY),
        ("dif_pct_venta_mens", None, "Dif. % venta mens.", "number", PCT),
        ("piezas_mens_m", None, "Piezas mens. M", "number", NUM),
        ("piezas_mens_n", None, "Piezas mens. N", "number", NUM),
        ("dif_pct_piezas_mens", None, "Dif. % piezas mens.", "number", PCT),
    ]), 0, 9, 6, 12),
]

# --- Página 3: Comparativo ---
p3 = [
    pos(contador("k_a", "Periodo A", "ds_comparativo", "SUM(`valor_a`)"), 0, 0, 1, 2),
    pos(contador("k_b", "Periodo B", "ds_comparativo", "SUM(`valor_b`)"), 1, 0, 1, 2),
    pos(contador("k_var", "Variación % A vs B", "ds_comparativo",
                 "(SUM(`valor_a`) - SUM(`valor_b`)) / SUM(`valor_b`)"), 2, 0, 1, 2),
    pos(contador("k_margen_a", "Margen A", "ds_comparativo", "SUM(`utilidad_a`) / SUM(`venta_a`)"), 3, 0, 1, 2),
    pos(contador("k_margen_b", "Margen B", "ds_comparativo", "SUM(`utilidad_b`) / SUM(`venta_b`)"), 4, 0, 1, 2),
    pos(barra_h("g_comparativo", "Variación A - B por miembro", "ds_comparativo",
                ("miembro", "`miembro`"), ("variacion", "SUM(`variacion`)")), 0, 2, 3, 8),
    pos(grafica("g_pareto", "% acumulado del periodo A (Pareto)", "line", "ds_comparativo",
                ("rank_a", "`rank_a`"), ("pct_acumulado_a", "MAX(`pct_acumulado_a`)"),
                x_tipo="quantitative", x_titulo="Posición en el ranking A", y_titulo="% acumulado"), 3, 2, 3, 8),
    pos(tabla("t_comparativo", "Tabla de detalle A vs B", "ds_comparativo", [
        ("rank_a", None, "Rank A", "number", None),
        ("rank_b", None, "Rank B", "number", None),
        ("posiciones_subio", None, "Posiciones que subió", "number", None),
        ("miembro", None, "Miembro", "string", None),
        ("valor_a", None, "A", "number", NUM),
        ("valor_b", None, "B", "number", NUM),
        ("variacion", None, "A - B", "number", NUM),
        ("pct_variacion", None, "% var.", "number", PCT),
        ("pct_del_total_a", None, "% del total A", "number", PCT),
        ("pct_acumulado_a", None, "% acumulado A", "number", PCT),
    ]), 0, 10, 6, 12),
]

# --- Filtros globales (aplican a todas las páginas) ---
globales = [
    pos(filtro_parametro("fp_pais", "País", "pais"), 0, 0, 1, 1),
    pos(filtro_parametro("fp_moneda", "Moneda", "moneda"), 0, 1, 1, 1),
    pos(filtro_parametro("fp_tipo_tc", "Tipo de cambio", "tipo_tc"), 0, 2, 1, 1),
    pos(filtro_parametro("fp_fecha_tc", "Fecha del tipo de cambio (si es fecha exacta)", "fecha_tc",
                         "filter-date-picker"), 0, 3, 1, 1),
    pos(filtro_parametro("fp_medida", "Venta o cantidad", "medida"), 0, 4, 1, 1),
    pos(filtro_parametro("fp_agrupacion", "Agrupación", "agrupacion"), 0, 5, 1, 1),
    pos(filtro_parametro("fp_dias_n", "Días atrás N", "dias_n"), 0, 6, 1, 1),
    pos(filtro_parametro("fp_dias_m", "Días atrás M", "dias_m"), 0, 7, 1, 1),
    pos(filtro_parametro("fp_dimension", "Dimensión comparativo", "dimension"), 0, 8, 1, 1),
    pos(filtro_parametro("fp_medida_comp", "Medida comparativo", "medida_comp"), 0, 9, 1, 1),
    pos(filtro_parametro("fp_a_ini", "Inicio periodo A", "a_ini", "filter-date-picker"), 0, 10, 1, 1),
    pos(filtro_parametro("fp_a_fin", "Fin periodo A", "a_fin", "filter-date-picker"), 0, 11, 1, 1),
    pos(filtro_parametro("fp_b_ini", "Inicio periodo B", "b_ini", "filter-date-picker"), 0, 12, 1, 1),
    pos(filtro_parametro("fp_b_fin", "Fin periodo B", "b_fin", "filter-date-picker"), 0, 13, 1, 1),
]

DASHBOARD = {
    "datasets": DS,
    "pages": [
        {"name": "resumen_diario", "displayName": "Resumen diario", "pageType": "PAGE_TYPE_CANVAS", "layout": p1},
        {"name": "concentrado", "displayName": "Concentrado", "pageType": "PAGE_TYPE_CANVAS", "layout": p2},
        {"name": "comparativo", "displayName": "Comparativo", "pageType": "PAGE_TYPE_CANVAS", "layout": p3},
        {"name": "filtros", "displayName": "Filtros", "pageType": "PAGE_TYPE_GLOBAL_FILTERS", "layout": globales},
    ],
}


def cli(*args):
    r = subprocess.run(["databricks", *args, "-o", "json"], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(r.stderr)
    return json.loads(r.stdout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--crear", action="store_true")
    ap.add_argument("--actualizar", metavar="DASHBOARD_ID")
    a = ap.parse_args()

    ruta = os.path.join(AQUI, "dashboard.lvdash.json")
    with open(ruta, "w", encoding="utf-8") as f:
        json.dump(DASHBOARD, f, ensure_ascii=False, indent=1)
    print(f"Escrito {ruta}: {len(DS)} datasets, {sum(len(p['layout']) for p in DASHBOARD['pages'])} widgets")

    cuerpo = {"display_name": "Seguimiento Diario Sell Out V3 (demo migración)",
              "warehouse_id": WAREHOUSE, "serialized_dashboard": json.dumps(DASHBOARD, ensure_ascii=False)}
    if a.crear:
        yo = cli("current-user", "me")["userName"]
        cuerpo["parent_path"] = f"/Users/{yo}"
        r = cli("lakeview", "create", "--json", json.dumps(cuerpo, ensure_ascii=False))
        print("Creado:", r["dashboard_id"], r.get("path"))
    elif a.actualizar:
        r = cli("lakeview", "update", a.actualizar, "--json", json.dumps(cuerpo, ensure_ascii=False))
        print("Actualizado:", r["dashboard_id"])


if __name__ == "__main__":
    main()
