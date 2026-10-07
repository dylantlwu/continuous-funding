"""One process on Railway: the recorder loop, the keeper (optional), and HTTP for the dashboard and front-end.

    PORT=8080 python3 -m validation.service
Research (read-only): /  (dashboard)   /api/markets   /api/state?base=BTC&policy=median   /healthz
Chain (needs PERP_ENGINE, MONAD_RPC; signing needs PRIVATE_KEY = the feed's relayer; Pyth needs PYTH_API_KEY):
  GET  /api/chain/config      addresses and parameters, all read from the engine on chain
  GET  /api/consensus         the five venue rates and their median, computed off-chain (free)
  GET  /api/consensus/history?hours=24   per-minute median, for the chart of settlement cadences
  GET  /api/market/history?hours=24      c, p, open interest and vault cash sampled by the keeper every 5 minutes
  GET  /api/pyth/latest       newest signed Pyth update (the key stays on this server)
  GET  /api/pyth/at?t=UNIX    first signed Pyth print at or after t, which settling an order requires
  POST /api/wake              before an open: post the venue rates if c would go stale within 5 minutes
The only endpoint that spends gas is /api/wake, and it posts at most once per (staleAfter - 5 min) whoever calls it.
PUBLIC_API_ONLY=1 (set on the public domain): only the chain endpoints, /healthz and the front-end (built into
static/app/, served at /) answer; the research dashboard and its data stay private (owner, 2026-10-05).
"""
import json
import os
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import hermes, keeper, live_engine, recorder, relayer

CHAIN = None  # set in main() when PERP_ENGINE is configured
PUBLIC_API_ONLY = os.environ.get("PUBLIC_API_ONLY") == "1"
CHAIN_CFG = {}
_wake_seen = {}  # ip -> last wake time

BASES = [b for b in os.environ.get("DASH_BASES", "BTC,ETH,SOL,TSLA,NVDA").split(",") if b]
POLICIES = ["median", "midrange", "anchor_binance"]
STATIC = os.path.join(os.path.dirname(__file__), "static", "dashboard.html")
APP_DIR = os.path.join(os.path.dirname(__file__), "static", "app")
TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml",
         ".woff2": "font/woff2", ".woff": "font/woff", ".png": "image/png", ".ico": "image/x-icon", ".json": "application/json"}


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

    def _json(self, code, obj):
        return self._send(code, json.dumps(obj), "application/json")

    def end_headers(self):
        origin = os.environ.get("CORS_ORIGIN")
        if origin:
            self.send_header("access-control-allow-origin", origin)
            self.send_header("access-control-allow-headers", "content-type")
        super().end_headers()

    def do_OPTIONS(self):
        self._send(204, b"", "text/plain")

    def do_POST(self):
        u = urlparse(self.path)
        try:
            if u.path == "/api/wake" and CHAIN:
                ip = self.headers.get("x-forwarded-for", self.client_address[0]).split(",")[0].strip()
                if time.time() - _wake_seen.get(ip, 0) < 30:
                    return self._json(429, {"error": "one wake per 30 s"})
                _wake_seen[ip] = time.time()
                db = recorder.open_db()
                try:
                    res = relayer.post_if_needed(CHAIN, CHAIN_CFG["feed"], db, int(time.time() * 1000),
                                                 min_age_s=CHAIN_CFG["staleAfter"] - 300)
                finally:
                    db.close()
                return self._json(200, res)
            return self._send(404, "not found", "text/plain")
        except Exception as e:  # fail loud to the client, keep serving
            traceback.print_exc()
            return self._json(500, {"error": str(e)[:300]})

    def _chain_get(self, path, q):
        """Returns True if it answered the request."""
        if path == "/api/chain/config":
            self._json(200, CHAIN_CFG)
            return True
        if path == "/api/consensus":
            db = recorder.open_db()
            try:
                rates, observed_ms, detail = relayer.venue_rates(db, int(time.time() * 1000))
            finally:
                db.close()
            try:  # the contract's own median (free eth_call): one implementation of the rule, not two
                median = CHAIN.call(CHAIN_CFG["feed"], "medianOf(int256[5])", ["int256[5]"], [rates], ["int256"])[0]
            except Exception:  # fewer than three venues: the contract refuses, and so do we
                median = None
            self._json(200, {"venues": detail, "rates_per_second_wad": [None if r == relayer.MISSING else r for r in rates],
                             "median_per_second_wad": median, "observed_ms": observed_ms})
            return True
        if path == "/api/consensus/history":
            hours = min(48, max(1, int(q.get("hours", "24"))))
            db = recorder.open_db()
            try:
                pts = relayer.consensus_history(db, int(time.time() * 1000), hours=hours)
            finally:
                db.close()
            self._json(200, {"step_s": 60, "points": [[t, r] for t, r in pts]})
            return True
        if path == "/api/market/history":
            hours = min(24 * 14, max(1, int(q.get("hours", "24"))))
            db = recorder.open_db()
            try:
                db.execute("CREATE TABLE IF NOT EXISTS market_samples(engine TEXT, ts INTEGER, block INTEGER, c TEXT, "
                           "p TEXT, long_oi TEXT, short_oi TEXT, vault_cash TEXT, funding_index TEXT, PRIMARY KEY(engine, ts))")
                rows = db.execute("SELECT ts, block, c, p, long_oi, short_oi, vault_cash, funding_index FROM market_samples "
                                  "WHERE engine=? AND ts>=? ORDER BY ts", (CHAIN_CFG["engine"], int(time.time()) - hours * 3600)).fetchall()
            finally:
                db.close()
            keys = ["ts", "block", "c", "p", "longOI", "shortOI", "vaultCash", "fundingIndex"]
            self._json(200, {"engine": CHAIN_CFG["engine"], "samples": [dict(zip(keys, r)) for r in rows]})
            return True
        if path == "/api/pyth/latest":
            self._json(200, hermes.latest(CHAIN_CFG["feedId"]))
            return True
        if path == "/api/pyth/at":
            t = int(q.get("t", "0"))
            if not time.time() - 600 <= t <= time.time() + 5:
                self._json(400, {"error": "t must be within the last 10 minutes"})
            else:
                self._json(200, hermes.at(CHAIN_CFG["feedId"], t))
            return True
        return False

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        try:
            if CHAIN and u.path.startswith("/api/") and self._chain_get(u.path, q):
                return None
            if PUBLIC_API_ONLY and u.path != "/healthz":
                return self._app(u.path)
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

    def _app(self, path):
        """The built front-end. Only files under static/app/ (no traversal); hashed assets are cached."""
        rel = "index.html" if path in ("/", "/index.html") else path.lstrip("/")
        full = os.path.realpath(os.path.join(APP_DIR, rel))
        if not full.startswith(os.path.realpath(APP_DIR) + os.sep) or not os.path.isfile(full):
            return self._send(404, "not found", "text/plain")
        with open(full, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("content-type", TYPES.get(os.path.splitext(full)[1], "application/octet-stream"))
        self.send_header("cache-control", "public, max-age=31536000, immutable" if rel.startswith("assets/") else "no-store")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def chain_setup():
    """Connect to the engine named by PERP_ENGINE and read everything else from chain."""
    global CHAIN, CHAIN_CFG
    from .chain import Chain
    CHAIN = Chain(os.environ["MONAD_RPC"], os.environ.get("PRIVATE_KEY"))
    e = os.environ["PERP_ENGINE"]
    c = CHAIN.call
    source = c(e, "priceSource()", out=["address"])[0]
    CHAIN_CFG = {"chainId": CHAIN.chain_id, "engine": e, "feed": c(e, "feed()", out=["address"])[0],
                 "priceSource": source, "usdc": c(e, "usdc()", out=["address"])[0],
                 "feedId": "0x" + c(source, "feedId()", out=["bytes32"])[0].hex(),
                 "settleDelay": c(e, "settleDelay()", out=["uint64"])[0], "orderTtl": c(e, "orderTtl()", out=["uint64"])[0],
                 "relayer": c(c(e, "feed()", out=["address"])[0], "relayer()", out=["address"])[0],
                 "staleAfter": c(c(e, "feed()", out=["address"])[0], "staleAfter()", out=["uint64"])[0],
                 # 1e18-scaled, as the contract stores them: the page derives max leverage and liquidation prices
                 "initialMarginRate": str(c(e, "initialMarginRate()", out=["uint256"])[0]),
                 "maintenanceMarginRate": str(c(e, "maintenanceMarginRate()", out=["uint256"])[0]),
                 "signer": CHAIN.address}
    if CHAIN.address and CHAIN.address.lower() != CHAIN_CFG["relayer"].lower():
        raise SystemExit(f"PRIVATE_KEY is {CHAIN.address}, but the feed's relayer is {CHAIN_CFG['relayer']}")


def keeper_loop():
    db = recorder.open_db()
    k = keeper.Keeper(CHAIN, CHAIN_CFG["engine"], db,
                      lambda min_age_s, move_wad=None: relayer.post_if_needed(CHAIN, CHAIN_CFG["feed"], db,
                                                                              int(time.time() * 1000), min_age_s, move_wad),
                      start_block=int(os.environ.get("ENGINE_START_BLOCK", "0")),
                      grace_s=int(os.environ.get("KEEPER_GRACE_S", "0")),
                      heartbeat_s=int(os.environ.get("KEEPER_HEARTBEAT_S", keeper.POST_HEARTBEAT_S)),
                      sample_every_s=int(os.environ.get("KEEPER_SAMPLE_S", "300")),
                      post_when_empty=os.environ.get("KEEPER_POST_WHEN_EMPTY") == "1")
    k.run()


def main():
    if os.environ.get("RECORDER", "1") == "1":
        threading.Thread(target=recorder_loop, args=(int(os.environ.get("RECORD_EVERY", "60")),), daemon=True).start()
    if os.environ.get("PERP_ENGINE"):
        chain_setup()
        print(f"chain: engine {CHAIN_CFG['engine']} chain {CHAIN_CFG['chainId']} signer {CHAIN_CFG['signer']}", flush=True)
        if os.environ.get("KEEPER", "1") == "1" and CHAIN.address:
            threading.Thread(target=keeper_loop, daemon=True).start()
    port = int(os.environ.get("PORT", "8080"))
    print(f"dashboard on :{port} bases={BASES}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
