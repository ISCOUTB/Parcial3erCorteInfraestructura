#!/usr/bin/env python3
"""
App de demostración para escalamiento y alta disponibilidad.
Solo usa la librería estándar de Python (no necesita Internet para instalar nada).

Endpoints:
  /            Página HTML con el nombre, zona y color de la instancia que respondió
  /api/info    Lo mismo en JSON
  /work?ms=N   Consume CPU durante ~N ms (carga sintética para disparar el autoscaling)
  /health      200 si la instancia está sana; 503 si existe el archivo /var/run/app-unhealthy
"""
import hashlib
import json
import os
import socket
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("APP_PORT", "80"))
FLAG_UNHEALTHY = "/var/run/app-unhealthy"
HOST = socket.gethostname()
START = time.time()
COLORES = ["#0939D7", "#E4572E", "#17BEBB", "#76B041", "#FFC914", "#8E44AD", "#D7263D", "#2E86AB"]
COLOR = COLORES[int(hashlib.md5(HOST.encode()).hexdigest(), 16) % len(COLORES)]


def metadata():
    """Lee zona y nombre de la VM desde el servicio de metadatos de Azure (IMDS)."""
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
    """Trabajo CPU-bound real (hashes encadenados) durante ~ms milisegundos."""
    fin = time.perf_counter() + ms / 1000.0
    h = HOST.encode()
    vueltas = 0
    while time.perf_counter() < fin:
        h = hashlib.sha256(h).digest()
        vueltas += 1
    return vueltas


HTML = """<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Demo Escalamiento</title>
<meta http-equiv="refresh" content="3">
<style>body{{margin:0;font-family:Segoe UI,Arial,sans-serif;background:{color};color:#fff;
display:flex;align-items:center;justify-content:center;height:100vh}}
.c{{background:rgba(0,0,0,.25);padding:40px 60px;border-radius:16px;text-align:center}}
h1{{margin:0 0 8px;font-size:42px}}p{{margin:6px 0;font-size:20px}}</style></head>
<body><div class="c"><h1>{host}</h1><p>Zona de disponibilidad: <b>{zona}</b></p>
<p>Tamaño: {tamano} &middot; Uptime: {uptime_s}s</p>
<p style="opacity:.8">La página se recarga cada 3 s: observe cómo cambia la instancia</p></div></body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "DemoHA/1.0"

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
        if url.path == "/work":
            qs = parse_qs(url.query)
            ms = max(1, min(int(qs.get("ms", ["100"])[0]), 2000))
            t0 = time.perf_counter()
            vueltas = quemar_cpu(ms)
            return self._send(200, json.dumps(info({"ms_pedidos": ms, "ms_reales": round((time.perf_counter() - t0) * 1000, 1), "hashes": vueltas})))
        if url.path == "/":
            return self._send(200, HTML.format(color=COLOR, **info()), "text/html")
        return self._send(404, json.dumps({"error": "no encontrado"}))

    def log_message(self, fmt, *args):  # silencia el log por petición
        pass


if __name__ == "__main__":
    ThreadingHTTPServer.daemon_threads = True
    print(f"Escuchando en :{PORT} como {HOST}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
