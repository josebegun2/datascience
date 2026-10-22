# Tema base de Steren para tableros AI/BI (Databricks)

Tema único para todos los tableros de Steren en Databricks. Parte del preset **New York** de AI/BI (esquinas rectas, sin sombra, títulos de campo en mayúsculas, título a la izquierda) con la tipografía y los colores de steren.com.mx.

| Archivo | Para qué |
|---|---|
| `tema_steren.json` | El tema en el formato que AI/BI guarda en `uiSettings.theme` |
| `aplicar_tema.py` | Aplica el tema a uno o varios tableros por CLI y, si se pide, los publica |

## Cómo se usa

**1. Tema del workspace (una sola vez, requiere ser admin).** Así todos los tableros nuevos nacen con el tema. No tiene API: se captura en *Settings → Appearance → AI/BI → Theme → Add/Edit* con los valores de la tabla de abajo.

**2. Tableros que ya existen.** Los tableros existentes no toman solos el tema del workspace. Se les aplica con:

```bash
python3 tema_steren/aplicar_tema.py <dashboard_id> [<dashboard_id> ...] --publicar
```

Solo cambia el tema del borrador; datasets, páginas y widgets quedan igual. Usa el `etag` del tablero: si alguien lo editó mientras corría, falla en lugar de pisar sus cambios.

## Valores para el formulario del tema del workspace

### Interface

| Sección | Ajuste | Claro | Oscuro |
|---|---|---|---|
| Canvas | Background | `#F7F8F9` | `#121317` |
| Widget | Background | `#FFFFFF` | `#1B1D22` |
| Widget | Border | `#D5D2D2` | `#3B3E45` |
| Widget | Selection | `#008FD1` (azul Steren) | `#4DB8E8` |
| Widget | Corner radius / Padding / Margin / Shadow | 0 / 16 / 4 / 0 | igual |
| Widget | Title alignment | Left | igual |
| Visualization | Axis color | `#D5D2D2` | `#4F5052` |
| Visualization | Grid color | `#EBEDED` | `#2C2F36` |

### Fonts

En todas las categorías la familia es **Roboto**. Heebo, la fuente de steren.com.mx, es una extensión de Roboto: se ven prácticamente igual y Roboto sí viene en AI/BI.

| Categoría | Tamaño | Peso | Color claro | Color oscuro | Mayúsculas |
|---|---|---|---|---|---|
| Default | 13 | 400 | `#2F2F2F` | `#F7F5F2` | No |
| Title | 15 | 700 | `#2F2F2F` | `#F7F5F2` | No |
| Description | 13 | 400 | `#636363` | `#B4B6BA` | No |
| Field title | 12 | 500 | `#636363` | `#B4B6BA` | Sí |
| Field value | 12 | 400 | `#2F2F2F` | `#F7F5F2` | No |

### Color palette

**Categorical**, en este orden y siempre en este orden. Azul, naranja, dorado y verde salen del código de color por categoría del Catálogo Steren 2026, ajustados de luminosidad para pasar contraste en claro y oscuro:

| # | Color | Hex |
|---|---|---|
| 1 | Azul Steren (títulos Smart Home del catálogo) | `#008FD1` |
| 2 | Naranja (Computación y Móvil) | `#CF6F0E` |
| 3 | Turquesa | `#0E9A94` |
| 4 | Dorado (Energía e iluminación) | `#B28308` |
| 5 | Magenta | `#C34E97` |
| 6 | Café | `#A06024` |
| 7 | Morado | `#7B57C8` |
| 8 | Verde (TV y Video) | `#0E9A40` |

**Continuous gradient:** a partir del color 1 (azul Steren), en claro y en oscuro.

## Reglas de uso

- **Una sola serie va en azul Steren.** Las barras de una misma medida no se pintan de colores distintos.
- **El orden de la paleta no se cambia.** Está calculado para que los colores vecinos se distingan, también con daltonismo. Si una gráfica tiene más de 8 series, se agrupan en "Otros" o se divide la gráfica.
- **El rojo Steren `#E30C12` no está en la paleta a propósito.** Se reserva para alertas y valores negativos (en oscuro, `#FF5A5F`), siempre con texto o ícono, nunca solo el color.
- **Los textos van en gris oscuro o gris medio,** nunca del color de la serie.
- **Gráficas de pastel:** no se usan; mejor barras horizontales.

## Validación

Se validó con el método de la skill *dataviz*: OKLCH para la luminosidad y saturación, y daltonismo simulado (Machado 2009).

| Prueba | Claro (sobre `#FFFFFF`) | Oscuro (sobre `#1B1D22`) |
|---|---|---|
| Luminosidad y saturación de los 8 colores | Pasa | Pasa |
| Daltonismo: peor par de colores vecinos | ΔE 13.8 (mínimo 8) | ΔE 13.8 |
| Visión normal: peor par de colores vecinos | ΔE 18.3 (mínimo 15) | ΔE 18.3 |
| Contraste de cada color contra el fondo | Todos ≥ 3:1 | Todos ≥ 3:1 |

| Texto | Contraste |
|---|---|
| Texto `#2F2F2F` sobre blanco | 13.4:1 |
| Texto secundario `#636363` sobre blanco | 6.0:1 |
| Texto `#F7F5F2` sobre `#1B1D22` | 15.5:1 |
| Texto secundario `#B4B6BA` sobre `#1B1D22` | 8.3:1 |
| Selección `#0093D0` sobre blanco | 3.5:1 (mínimo 3:1 para controles) |
| Rojo de alerta `#E30C12` sobre blanco | 4.9:1 |

Lo que se ajustó de la primera versión: tenía dos grises y un azul claro como colores de serie. Los grises no sirven para identificar series, y el azul claro tenía contraste de 1.9:1 contra el fondo.
