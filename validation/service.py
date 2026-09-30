"""One process on Railway: the recorder loop (background thread) + a read-only dashboard over HTTP.

    PORT=8080 python3 -m validation.service
Endpoints: /  (dashboard)   /api/markets   /api/state?base=BTC&policy=median   /healthz
Read-only: it serves public market data and our own computations; nothing here can move funds.
"""
import json
import os
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import live_engine, recorder

BASES = [b for b in os.environ.get("DASH_BASES", "BTC,ETH,SOL,TSLA,NVDA").split(",") if b]
POLICIES = ["median", "midrange", "anchor_binance"]
STATIC = os.path.join(os.path.dirname(__file__), "static", "dashboard.html")


def recorder_loop(every):
    db, last, st = recorder.open_db(), {}, {}
    while True:
        t = time.time()
        try:
            results, changed = recorder.one_round(db, last, st)
            print(time.strftime("%Y-%m-%d %H:%M:%S"), "changed=%d" % changed,
                  " ".join(f"{v}:{'ok' if e is None else 'ERR'}({lat}ms)" for v, r, e, lat in results), flush=True)
        except Exception:                      # never let the recorder thread die silently
            traceback.print_exc()
        time.sleep(max(0.0, every - (time.time() - t)))


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("cache-control", "no-store")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        try:
            if u.path == "/":
                with open(STATIC, "rb") as f:
                    return self._send(200, f.read(), "text/html; charset=utf-8")
            if u.path == "/healthz":
                return self._send(200, "ok", "text/plain")
            if u.path == "/api/markets":
                return self._send(200, json.dumps({"bases": BASES, "policies": POLICIES}), "application/json")
            if u.path == "/api/state":
                base, pol = q.get("base", BASES[0]), q.get("policy", "median")
                if base not in BASES or pol not in POLICIES:
                    return self._send(400, json.dumps({"error": "unknown base or policy"}), "application/json")
                return self._send(200, json.dumps(live_engine.state(base, pol)), "application/json")
            return self._send(404, "not found", "text/plain")
        except Exception as e:                  # fail loud to the client, keep serving
            traceback.print_exc()
            return self._send(500, json.dumps({"error": str(e)[:300]}), "application/json")

    def log_message(self, *a):
        pass


def main():
    if os.environ.get("RECORDER", "1") == "1":
        threading.Thread(target=recorder_loop, args=(int(os.environ.get("RECORD_EVERY", "60")),), daemon=True).start()
    port = int(os.environ.get("PORT", "8080"))
    print(f"dashboard on :{port} bases={BASES}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
