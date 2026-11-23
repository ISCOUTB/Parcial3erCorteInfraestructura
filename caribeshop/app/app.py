#!/usr/bin/env python3
"""
App de CaribeShop para escalamiento, alta disponibilidad y seguridad.
Solo usa la libreria estandar de Python.

Endpoints:
  /            Pagina HTML con el nombre, zona y color de la instancia
  /api/info    Lo mismo en JSON
  /work?ms=N   Consume CPU durante ~N ms (carga sintetica para autoscaling)
  /health      200 si la instancia esta sana; 503 si existe /var/run/app-unhealthy
  /secret      Lee un secreto desde Key Vault con la identidad administrada
               del VMSS y muestra solo una huella (longitud + SHA-256 truncado)
"""
import hashlib
import json
import os
import socket
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("APP_PORT", "80"))
FLAG_UNHEALTHY = "/var/run/app-unhealthy"
HOST = socket.gethostname()
START = time.time()
KEY_VAULT_NAME = os.environ.get("KEY_VAULT_NAME", "")
SECRET_NAME = os.environ.get("SECRET_NAME", "app-db-password")
COLORES = ["#0939D7", "#E4572E", "#17BEBB", "#76B041", "#FFC914", "#8E44AD", "#D7263D", "#2E86AB"]
COLOR = COLORES[int(hashlib.md5(HOST.encode()).hexdigest(), 16) % len(COLORES)]


def metadata():
    try:
        req = urllib.request.Request(
            "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01",
            headers={"Metadata": "true"},
        )
        with urllib.request.urlopen(req, timeout=2) as r:
            d = json.load(r)
            return {"zona": d.get("zone") or "sin-zona", "vm": d.get("name"), "tamano": d.get("vmSize")}
    except Exception:
        return {"zona": "local", "vm": HOST, "tamano": "n/a"}


META = metadata()


def info(extra=None):
    d = {"host": HOST, **META, "uptime_s": int(time.time() - START), "pid": os.getpid()}
    if extra:
        d.update(extra)
    return d


def quemar_cpu(ms):
    fin = time.perf_counter() + ms / 1000.0
    h = HOST.encode()
    vueltas = 0
    while time.perf_counter() < fin:
        h = hashlib.sha256(h).digest()
        vueltas += 1
    return vueltas


def obtener_token(resource):
    url = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=" + urllib.parse.quote(resource, safe="")
    req = urllib.request.Request(url, headers={"Metadata": "true"})
    with urllib.request.urlopen(req, timeout=2) as r:
        return json.load(r)["access_token"]


def leer_secreto():
    if not KEY_VAULT_NAME or not SECRET_NAME:
        return {"status": "not_configured", "error": "KEY_VAULT_NAME/SECRET_NAME no definidos"}
    try:
        token = obtener_token("https://vault.azure.net")
        url = f"https://{KEY_VAULT_NAME}.vault.azure.net/secrets/{SECRET_NAME}?api-version=7.4"
        req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
        with urllib.request.urlopen(req, timeout=5) as r:
            data = json.load(r)
            value = data.get("value", "")
            return {
                "status": "ok",
                "vault": KEY_VAULT_NAME,
                "secret": SECRET_NAME,
                "length": len(value),
                "sha256_truncado": hashlib.sha256(value.encode()).hexdigest()[:12],
            }
    except Exception as e:
        return {"status": "error", "error": str(e)}


HTML = """<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>CaribeShop</title>
<meta http-equiv="refresh" content="3">
<style>body{{margin:0;font-family:Segoe UI,Arial,sans-serif;background:{color};color:#fff;
display:flex;align-items:center;justify-content:center;height:100vh}}
.c{{background:rgba(0,0,0,.25);padding:40px 60px;border-radius:16px;text-align:center}}
h1{{margin:0 0 8px;font-size:42px}}p{{margin:6px 0;font-size:20px}}</style></head>
<body><div class="c"><h1>{host}</h1><p>Zona de disponibilidad: <b>{zona}</b></p>
<p>Tamano: {tamano} &middot; Uptime: {uptime_s}s</p>
<p style="opacity:.8">La pagina se recarga cada 3 s: observe como cambia la instancia</p></div></body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "CaribeShop/1.0"

    def _send(self, code, body, ctype="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Served-By", HOST)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/health":
            if os.path.exists(FLAG_UNHEALTHY):
                return self._send(503, json.dumps({"status": "unhealthy", "host": HOST}))
            return self._send(200, json.dumps({"status": "ok", "host": HOST}))
        if url.path == "/api/info":
            return self._send(200, json.dumps(info()))
        if url.path == "/secret" or url.path == "/api/secret":
            return self._send(200, json.dumps(leer_secreto()))
        if url.path == "/work":
            qs = parse_qs(url.query)
            ms = max(1, min(int(qs.get("ms", ["100"])[0]), 2000))
            t0 = time.perf_counter()
            vueltas = quemar_cpu(ms)
            return self._send(200, json.dumps(info({"ms_pedidos": ms, "ms_reales": round((time.perf_counter() - t0) * 1000, 1), "hashes": vueltas})))
        if url.path == "/":
            return self._send(200, HTML.format(color=COLOR, **info()), "text/html")
        return self._send(404, json.dumps({"error": "no encontrado"}))

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer.daemon_threads = True
    print(f"Escuchando en :{PORT} como {HOST}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()