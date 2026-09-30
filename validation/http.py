"""Tiny JSON-over-HTTP helper with retries and an on-disk cache for immutable history pages.

Standard library only, so anyone can run the validation engine with a stock Python 3.9+.
urllib honours HTTP(S)_PROXY from the environment.
"""
import hashlib
import json
import os
import time
import urllib.request

CACHE_DIR = os.path.join(os.path.dirname(__file__), "data", "http_cache")


def get_json(url, body=None, cache=False, retries=4, timeout=30):
    """GET (or POST when body is given) and decode JSON. Raises after `retries` failures: never returns partial data."""
    key = hashlib.sha256((url + json.dumps(body, sort_keys=True)).encode()).hexdigest()
    path = os.path.join(CACHE_DIR, key + ".json")
    if cache and os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    last_err = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(
                url,
                data=json.dumps(body).encode() if body is not None else None,
                headers={"content-type": "application/json", "user-agent": "continuous-funding-validation/0.1"},
            )
            with urllib.request.urlopen(req, timeout=timeout) as r:
                data = json.loads(r.read())
            if cache:
                os.makedirs(CACHE_DIR, exist_ok=True)
                with open(path, "w") as f:
                    json.dump(data, f)
            return data
        except Exception as e:  # network errors are retried, then re-raised loudly
            last_err = e
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"request failed after {retries} attempts: {url} :: {last_err}")
