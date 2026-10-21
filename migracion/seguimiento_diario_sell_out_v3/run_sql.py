"""Ejecuta un archivo .sql en un SQL warehouse de Databricks, sentencia por sentencia, con la CLI.

Uso:
    python3 run_sql.py sql/01_fuentes_sinteticas.sql [--warehouse ID] [--profile DEFAULT]

- Separa sentencias por ';' al final de línea (los ';' dentro de comentarios o textos no cuentan).
- Un SELECT/WITH suelto debe terminar en LIMIT: así ninguna consulta exploratoria gasta de más.
- Imprime hasta 20 filas de cada consulta que devuelve resultados.
"""
import argparse
import json
import re
import subprocess
import sys

DEFAULT_WAREHOUSE = "fa978ee381d35616"


def split_statements(sql):
    sql = re.sub(r"--[^\n]*", "", sql)
    parts, buf, quote = [], [], None
    for ch in sql:
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = None
        elif ch in ("'", "`"):
            quote = ch
            buf.append(ch)
        elif ch == ";":
            parts.append("".join(buf).strip())
            buf = []
        else:
            buf.append(ch)
    parts.append("".join(buf).strip())
    return [p for p in parts if p]


def run(statement, warehouse, profile):
    body = json.dumps({"warehouse_id": warehouse, "wait_timeout": "50s", "statement": statement,
                       "on_wait_timeout": "CONTINUE"})
    cmd = ["databricks", "api", "post", "/api/2.0/sql/statements", "--json", body, "-p", profile]
    r = json.loads(subprocess.run(cmd, capture_output=True, text=True, check=True).stdout)
    while r["status"]["state"] in ("PENDING", "RUNNING"):
        cmd = ["databricks", "api", "get", f"/api/2.0/sql/statements/{r['statement_id']}", "-p", profile]
        r = json.loads(subprocess.run(cmd, capture_output=True, text=True, check=True).stdout)
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("archivo")
    ap.add_argument("--warehouse", default=DEFAULT_WAREHOUSE)
    ap.add_argument("--profile", default="DEFAULT")
    a = ap.parse_args()

    for i, st in enumerate(split_statements(open(a.archivo, encoding="utf-8").read()), 1):
        if re.match(r"(SELECT|WITH)\b", st, re.I) and not re.search(r"\bLIMIT\s+\d+\s*$", st, re.I):
            sys.exit(f"[{i}] SELECT sin LIMIT al final; se detiene:\n{st[:300]}")
        head = " ".join(st.split())[:90]
        r = run(st, a.warehouse, a.profile)
        state = r["status"]["state"]
        print(f"[{i}] {state:9} {head}")
        if state != "SUCCEEDED":
            print(json.dumps(r["status"], ensure_ascii=False, indent=1))
            sys.exit(1)
        rows = (r.get("result") or {}).get("data_array")
        if rows and r.get("manifest", {}).get("schema", {}).get("columns"):
            cols = [c["name"] for c in r["manifest"]["schema"]["columns"]]
            print("     " + " | ".join(cols))
            for row in rows[:20]:
                print("     " + " | ".join("" if x is None else str(x) for x in row))


if __name__ == "__main__":
    main()
