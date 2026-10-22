"""Aplica el tema base de Steren (tema_steren.json) a uno o varios tableros AI/BI con la CLI.

Uso:
    python3 aplicar_tema.py DASHBOARD_ID [DASHBOARD_ID ...] [--publicar] [--profile DEFAULT]

Solo cambia uiSettings.theme del borrador: datasets, páginas y widgets quedan igual.
Con --publicar, publica cada tablero después de aplicar el tema.

El tema del workspace (el que heredan los tableros nuevos) no tiene API: se captura una vez
en Settings > Appearance > AI/BI > Theme con los valores de README.md.
"""
import argparse
import json
import os
import subprocess

TEMA = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "tema_steren.json"), encoding="utf-8"))


def cli(perfil, *args):
    r = subprocess.run(["databricks", *args, "-p", perfil, "-o", "json"], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(r.stderr)
    return json.loads(r.stdout) if r.stdout.strip() else {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tableros", nargs="+", metavar="DASHBOARD_ID")
    ap.add_argument("--publicar", action="store_true")
    ap.add_argument("--profile", default="DEFAULT")
    a = ap.parse_args()

    for did in a.tableros:
        d = cli(a.profile, "lakeview", "get", did)
        contenido = json.loads(d["serialized_dashboard"])
        contenido.setdefault("uiSettings", {})["theme"] = TEMA
        cli(a.profile, "lakeview", "update", did, "--json",
            json.dumps({"display_name": d["display_name"], "etag": d["etag"],
                        "serialized_dashboard": json.dumps(contenido, ensure_ascii=False)}, ensure_ascii=False))
        print(f"Tema aplicado: {d['display_name']} ({did})")
        if a.publicar:
            cli(a.profile, "lakeview", "publish", did, "--json",
                json.dumps({"embed_credentials": True, "warehouse_id": d["warehouse_id"]}))
            print(f"Publicado: {did}")


if __name__ == "__main__":
    main()
