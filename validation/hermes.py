"""Pyth Hermes client for the backend.

Hermes requires an API key since 2026-08-26 (https://docs.pyth.network/price-feeds/core/upgrade/preparing).
The key (PYTH_API_KEY) is sent only to the official host, over HTTPS, with redirects refused, so the header can
never be forwarded to another host. It is never logged or returned: callers get prices and signed updates.

    latest(feed_id)   newest print, for bots (liquidation) and the price shown in the front-end
    at(feed_id, t)    the FIRST print at or after unix second t, which is what order settlement requires
"""
import json
import os
import threading
import time
import urllib.error
import urllib.request

HOST = os.environ.get("HERMES_URL", "https://pyth.dourolabs.app/hermes")


class HermesError(RuntimeError):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise HermesError(f"Hermes answered with a redirect ({code}); refused so the API key is not forwarded")


_opener = urllib.request.build_opener(_NoRedirect())
_cache_lock = threading.Lock()
_latest = {}  # feed_id -> (fetched_at, result)
_pinned = {}  # (feed_id, t) -> result; a past print never changes


def _key():
    k = os.environ.get("PYTH_API_KEY")
    if not k:
        raise HermesError("PYTH_API_KEY is not set")
    return k


def _get(path, timeout=15):
    if not HOST.startswith("https://") and not HOST.startswith("http://127.0.0.1"):
        raise HermesError("Hermes host must be HTTPS")
    req = urllib.request.Request(HOST + path, headers={"Authorization": "Bearer " + _key(),
                                                       "user-agent": "continuous-funding-backend/0.1"})
    try:
        with _opener.open(req, timeout=timeout) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise HermesError(f"Hermes HTTP {e.code} for {path.split('?')[0]}") from None


def _parse(doc):
    p = doc["parsed"][0]["price"]
    meta = doc["parsed"][0].get("metadata") or {}
    return {
        "price": int(p["price"]), "conf": int(p["conf"]), "expo": int(p["expo"]),
        "publish_time": int(p["publish_time"]), "prev_publish_time": meta.get("prev_publish_time"),
        "update": "0x" + doc["binary"]["data"][0],
    }


def latest(feed_id, max_cache_s=1.0):
    with _cache_lock:
        hit = _latest.get(feed_id)
        if hit and time.time() - hit[0] < max_cache_s:
            return hit[1]
    res = _parse(_get(f"/v2/updates/price/latest?ids[]={feed_id}&encoding=hex&parsed=true"))
    with _cache_lock:
        _latest[feed_id] = (time.time(), res)
    return res


def at(feed_id, t):
    """First print with publish_time >= t. Raises if Hermes has nothing at or after t yet."""
    key = (feed_id, int(t))
    with _cache_lock:
        if key in _pinned:
            return _pinned[key]
    res = _parse(_get(f"/v2/updates/price/{int(t)}?ids[]={feed_id}&encoding=hex&parsed=true"))
    if res["publish_time"] < int(t):
        raise HermesError(f"Hermes returned a print at {res['publish_time']}, before the requested {int(t)}")
    with _cache_lock:
        _pinned[key] = res
    return res
