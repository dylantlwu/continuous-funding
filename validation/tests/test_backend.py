"""Intent tests for the backend (relayer, keeper, Hermes client). No network: chain and Hermes are fakes.

    python3 -m unittest validation.tests.test_backend      (needs validation/requirements.txt)
"""
import http.server
import os
import urllib.error
import sqlite3
import threading
import unittest

from validation import hermes, keeper, relayer
from validation.chain import RpcError

WAD = 10**18


def recorder_db(polls, snaps):
    db = sqlite3.connect(":memory:")
    db.execute("CREATE TABLE polls(ts_ms INTEGER, venue TEXT, ok INTEGER, rows INTEGER, latency_ms INTEGER, error TEXT)")
    db.execute("CREATE TABLE snapshots(ts_ms INTEGER, venue TEXT, base TEXT, symbol TEXT, rate REAL, next_ms INTEGER, interval_h REAL)")
    db.executemany("INSERT INTO polls VALUES (?,?,1,1,10,NULL)", polls)
    db.executemany("INSERT INTO snapshots VALUES (?,?,'BTC',?,?,0,?)", snaps)
    return db


ALL_FRESH = [(1_000_000, v) for v, _ in relayer.VENUES]
SNAPS = [(900_000, "binance", "BTCUSDT", 0.0001, 8), (900_000, "okx", "BTC-USDT-SWAP", 0.0001, 8),
         (900_000, "bybit", "BTCUSDT", 0.0001, 8), (900_000, "hyperliquid", "BTC", 0.0000125, 1),
         (900_000, "bitget", "BTCUSDT", 0.0001, 8)]


class FakeChain:
    """Answers eth_call by signature from a dict; records sends. `reverts` makes simulations of a signature fail."""

    def __init__(self, answers, ts=1_000, reverts=()):
        self.answers, self.ts, self.reverts, self.sent, self.simulated = answers, ts, set(reverts), [], []
        self.address = "0x" + "11" * 20

    def call(self, to, signature, types=(), args=(), out=(), value=0, sender=None, block="latest"):
        if signature in self.reverts:
            raise RpcError(f"{signature}: execution reverted")
        if signature in ("settle(address,bytes[])", "liquidate(address,bytes[])"):
            self.simulated.append((signature, args[0]))
            return "0x"
        a = self.answers[signature]
        return a(args) if callable(a) else a

    def block(self, tag="latest"):
        return 100, self.ts, 100 * 10**9

    def logs(self, *a):
        return []

    def send(self, to, signature, types=(), args=(), value=0, gas_factor=1.3, wait=60):
        self.sent.append((signature, list(args), value, gas_factor))
        return "0xtx", {"gasUsed": "0x1"}


class VenueRates(unittest.TestCase):
    # Without this, venues on different settlement intervals would be compared per interval: Binance's 0.01% per
    # 8 h would look 8x Hyperliquid's 0.00125% per 1 h, though both are the same 10.95% APR. That is the very
    # mistake the project's earlier public research is about.
    def test_same_apr_on_different_intervals_gives_the_same_per_second_rate(self):
        self.assertEqual(relayer.per_second_wad(0.0001, 8), relayer.per_second_wad(0.0000125, 1))
        self.assertEqual(relayer.per_second_wad(0.0001, 8), round(0.0001 / 28_800 * WAD))

    # Without this, a venue whose API stopped answering would keep voting with its last value forever.
    def test_stale_or_incomplete_venues_are_reported_missing(self):
        polls = [(1_000_000, "binance"), (1_000_000, "okx"), (1_000_000, "bybit"), (700_000, "hyperliquid")]
        snaps = SNAPS[:3] + [SNAPS[3], (900_000, "bitget", "BTCUSDT", 0.0001, None)]
        rates, observed, detail = relayer.venue_rates(recorder_db(polls, snaps), now_ms=1_050_000)
        self.assertEqual(rates[3], relayer.MISSING)  # hyperliquid: last good poll 350 s ago
        self.assertEqual(rates[4], relayer.MISSING)  # bitget: never polled successfully here, and no interval
        self.assertEqual(rates[:3], [relayer.per_second_wad(0.0001, 8)] * 3)
        self.assertEqual(observed, 1_000_000)
        self.assertIn("missing", detail["hyperliquid"])


class RecorderQuery(unittest.TestCase):
    # Without this, reading the latest rate would scan the recorder's whole history (millions of rows on the
    # server: 2.8 s per venue measured) and every wake, i.e. every first open, would make the trader wait.
    def test_latest_rate_lookup_uses_the_recorder_index(self):
        import tempfile
        from validation import recorder
        with tempfile.TemporaryDirectory() as d:
            db = recorder.open_db(os.path.join(d, "live.sqlite"))
            relayer.venue_rates(db, now_ms=0)  # must run against the real schema
            plan = db.execute("EXPLAIN QUERY PLAN SELECT rate, interval_h FROM snapshots WHERE venue=? AND base='BTC' "
                              "AND symbol=? ORDER BY ts_ms DESC LIMIT 1", ("binance", "BTCUSDT")).fetchall()
            self.assertIn("USING INDEX snap_vb", plan[-1][-1])
            import inspect
            self.assertIn("base='BTC'", inspect.getsource(relayer.venue_rates), "the query the relayer runs")


class Wake(unittest.TestCase):
    def chain(self, last_post, ts=10_000):
        return FakeChain({"lastPostTime(uint8)": (last_post,)}, ts=ts)

    # Without this, every wake call would pay for a post: a page reload loop could drain the relayer's MON.
    def test_no_post_when_the_feed_is_recent(self):
        c = self.chain(last_post=10_000 - 100)
        res = relayer.post_if_needed(c, "feed", recorder_db(ALL_FRESH, SNAPS), now_ms=10_000_000)
        self.assertFalse(res["posted"])
        self.assertEqual(c.sent, [])

    # Without this, the post could claim an observation newer than the block (the feed would revert InFuture),
    # or use a loose gas limit that Monad would charge in full.
    def test_posts_venues_in_contract_order_with_a_tight_gas_limit(self):
        c = self.chain(last_post=995 - 200, ts=995)  # block clock behind the recorder's
        res = relayer.post_if_needed(c, "feed", recorder_db(ALL_FRESH, SNAPS), now_ms=1_050_000)
        self.assertTrue(res["posted"])
        sig, args, _, factor = c.sent[0]
        self.assertEqual(sig, "post(uint8,uint64,int256[5])")
        self.assertEqual(args[1], 995, "observedAt never later than the block")
        self.assertEqual(args[2], [relayer.per_second_wad(0.0001, 8)] * 5)
        self.assertEqual(factor, 1.05)

    # Without this, a recorder outage would post a two-venue "consensus" (the contract would refuse it, but the
    # relayer must not even try, and must say why).
    def test_refuses_to_post_with_fewer_than_three_fresh_venues(self):
        c = self.chain(last_post=0)
        with self.assertRaises(RuntimeError):
            relayer.post_if_needed(c, "feed", recorder_db(ALL_FRESH[:2], SNAPS), now_ms=1_050_000)
        self.assertEqual(c.sent, [])


class DeviationTrigger(unittest.TestCase):
    """The keeper's policy while positions are open: post when the median moves, or hourly (owner, 2026-10-05)."""
    MEDIAN = relayer.per_second_wad(0.0001, 8)  # every venue in SNAPS: 10.95% a year
    MOVE = keeper.POST_MOVE_WAD                 # 0.25% a year

    def post(self, on_chain, c_max=10**18, last_post=10_000 - 600, ts=10_000):
        c = FakeChain({"lastPostTime(uint8)": (last_post,), "rate(uint8)": (on_chain,), "cMax()": (c_max,)}, ts=ts)
        res = relayer.post_if_needed(c, "feed", recorder_db([(9_990_000, v) for v, _ in relayer.VENUES], SNAPS),
                                     now_ms=10_000_000, min_age_s=3595, move_wad=self.MOVE)
        return res, c.sent

    # Without this, every 30-second check would post: back to a timer, at 6.65 MON a day or worse.
    def test_a_small_move_inside_the_hour_does_not_post(self):
        res, sent = self.post(on_chain=self.MEDIAN - self.MOVE + 1)
        self.assertFalse(res["posted"])
        self.assertEqual(sent, [])

    # Without this, a jump in the venues would wait up to an hour to reach c (a 60-minute move has been 3.6% a
    # year), and open positions would accrue at the old rate meanwhile.
    def test_a_move_of_the_threshold_posts_before_the_hour(self):
        res, sent = self.post(on_chain=self.MEDIAN - self.MOVE)
        self.assertTrue(res["posted"])
        self.assertEqual(res["gap_wad"], self.MOVE)
        self.assertEqual(sent[0][0], "post(uint8,uint64,int256[5])")

    # Without this, a quiet market would leave c unposted for good, and nothing on chain would show the relayer
    # is still alive.
    def test_posts_after_an_hour_even_without_a_move(self):
        res, sent = self.post(on_chain=self.MEDIAN, last_post=10_000 - 3595)
        self.assertTrue(res["posted"])
        self.assertIsNone(res["gap_wad"], "posted for age, not for a move")

    # Without this, venues beyond the ±cMax cap would keep the gap open for good (the feed holds c at the cap),
    # and the relayer would post on every check until its MON ran out.
    def test_a_median_beyond_the_cap_does_not_post_again_and_again(self):
        cap = relayer.per_second_wad(0.0001, 8) // 2  # cap below the median, c already at the cap
        res, sent = self.post(on_chain=cap, c_max=cap)
        self.assertFalse(res["posted"])
        self.assertEqual(res["gap_wad"], 0)
        self.assertEqual(sent, [])


class HermesKey(unittest.TestCase):
    # Without this, a redirect from the Hermes host would make urllib resend the Authorization header (our Pyth
    # API key) to whatever host the redirect names.
    def test_redirects_are_refused_and_the_key_never_reaches_another_host(self):
        stolen = []

        class Thief(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                stolen.append(self.headers.get("Authorization"))
                self.send_response(200)
                self.end_headers()

            def log_message(self, *a):
                pass

        thief = http.server.HTTPServer(("127.0.0.1", 0), Thief)

        class Redirect(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(302)
                self.send_header("location", f"http://127.0.0.1:{thief.server_port}/steal")
                self.end_headers()

            def log_message(self, *a):
                pass

        hermes_srv = http.server.HTTPServer(("127.0.0.1", 0), Redirect)
        for s in (thief, hermes_srv):
            threading.Thread(target=s.serve_forever, daemon=True).start()
        old_host, old_key = hermes.HOST, os.environ.get("PYTH_API_KEY")
        hermes.HOST, os.environ["PYTH_API_KEY"] = f"http://127.0.0.1:{hermes_srv.server_port}", "secret-test-key"
        try:
            with self.assertRaises(hermes.HermesError):
                hermes._get("/v2/updates/price/latest")
        finally:
            hermes.HOST = old_host
            if old_key is None:
                del os.environ["PYTH_API_KEY"]
            else:
                os.environ["PYTH_API_KEY"] = old_key
            thief.shutdown()
            hermes_srv.shutdown()
        self.assertEqual(stolen, [])


class PublicDomain(unittest.TestCase):
    # Without this, putting the API on a public domain would also publish the research dashboard, which the
    # owner decided to keep private.
    def test_public_mode_serves_only_chain_endpoints_and_health(self):
        import urllib.request
        from validation import service
        service.PUBLIC_API_ONLY, old = True, service.PUBLIC_API_ONLY
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), service.Handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{srv.server_port}"

        def code(path):
            try:
                return urllib.request.urlopen(base + path, timeout=5).status
            except urllib.error.HTTPError as e:
                return e.code
        import http.client as hc
        import tempfile

        def raw(path):  # http.client sends the path as is (urllib would normalise "..")
            c = hc.HTTPConnection("127.0.0.1", srv.server_port, timeout=5)
            c.request("GET", path)
            r = c.getresponse()
            body = r.read()
            c.close()
            return r.status, body
        root = tempfile.mkdtemp()
        app = os.path.join(root, "app")
        os.makedirs(os.path.join(app, "assets"))
        with open(os.path.join(app, "index.html"), "w") as f:
            f.write("<html>app</html>")
        with open(os.path.join(root, "secret.txt"), "w") as f:  # a real file just outside the app folder
            f.write("PRIVATE_KEY=do-not-serve")
        old_dir, service.APP_DIR = service.APP_DIR, app
        try:
            self.assertEqual(code("/healthz"), 200)
            for private in ("/api/markets", "/api/state?base=BTC"):
                self.assertEqual(code(private), 404, private)
            self.assertEqual(raw("/"), (200, b"<html>app</html>"), "the front-end, not the research dashboard")
            # Without this, a crafted path could read the service's own files (including any secrets on disk).
            for evil in ("/../secret.txt", "/assets/../../secret.txt", "/%2e%2e/secret.txt", "/..%2fsecret.txt"):
                status, body = raw(evil)
                self.assertEqual(status, 404, evil)
                self.assertNotIn(b"do-not-serve", body, evil)
        finally:
            service.APP_DIR = old_dir
            service.PUBLIC_API_ONLY = old
            srv.shutdown()


class KeeperSettlement(unittest.TestCase):
    def make(self, order, ts, stale=False, reverts=()):
        answers = {"feed()": ("0xfeed",), "priceSource()": ("0xsrc",), "feedId()": (b"\x01" * 32,),
                   "settleDelay()": (2,), "orderTtl()": (60,), "orders(address)": order,
                   "isStale(uint8)": (stale,), "updateFee(bytes[])": (1,)}
        c = FakeChain(answers, ts=ts, reverts=reverts)
        posts = []
        k = keeper.Keeper(c, "0xengine", sqlite3.connect(":memory:"),
                          lambda min_age_s, move_wad=None: posts.append(min_age_s if move_wad is None else (min_age_s, move_wad)),
                          start_block=1, log=lambda *a: None)
        k.pending["0xabc"] = 1_002  # committed at 1_000, fills at the first print at or after 1_002
        self.pinned = []
        hermes.at = lambda feed_id, t: self.pinned.append(t) or {"update": "0x01", "publish_time": t}
        return k, c, posts

    def tearDown(self):
        import importlib
        importlib.reload(hermes)

    # Without this, the keeper would try to settle before the fill time, when no valid print can exist yet.
    def test_does_not_settle_before_the_fill_time(self):
        k, c, _ = self.make((0, 0, 1_000, False), ts=1_001)
        self.assertEqual(k.settle_due(1_001), [])
        self.assertEqual(c.sent, [])

    # Without this, the second or so between the fill time and Pyth publishing its print would crash the
    # keeper's step instead of simply retrying, and the trader (who now confirms only once) would wait.
    def test_retries_quietly_until_the_print_exists(self):
        k, c, _ = self.make((10**18, 10**9, 1_000, False), ts=1_002)
        def not_yet(feed_id, t):
            raise hermes.HermesError("Hermes HTTP 404")
        hermes.at = not_yet
        self.assertEqual(k.settle_due(1_002), [])
        self.assertIn("0xabc", k.pending)
        self.assertEqual(c.sent, [])

    # Without this, a settled order would be retried forever.
    def test_drops_orders_the_trader_already_settled(self):
        k, c, _ = self.make((0, 0, 0, False), ts=1_020)
        k.settle_due(1_020)
        self.assertEqual(c.sent, [])
        self.assertNotIn("0xabc", k.pending)

    # Without this, the keeper could settle with the wrong print (any print but the first after the fill time
    # is refused on chain) or pay for a settlement that reverts.
    def test_settles_due_orders_with_the_pinned_print_after_a_free_simulation(self):
        k, c, posts = self.make((10**18, 10**9, 1_000, False), ts=1_020)
        k.settle_due(1_020)
        self.assertEqual(self.pinned, [1_002], "Hermes asked for the first print at or after commit + 2 s")
        self.assertEqual(c.simulated, [("settle(address,bytes[])", "0xabc")])
        self.assertEqual(c.sent[0][0], "settle(address,bytes[])")
        self.assertEqual(posts, [], "a fresh feed needs no post")

    # Without this, a keeper outage of more than 5 minutes would make every pending open get rejected (refunded)
    # at settlement because the feed went stale meanwhile.
    def test_posts_first_if_the_feed_went_stale_before_settling_an_open(self):
        k, c, posts = self.make((10**18, 10**9, 1_000, False), ts=1_020, stale=True)
        k.settle_due(1_020)
        self.assertEqual(posts, [0])
        self.assertEqual(c.sent[0][0], "settle(address,bytes[])")

    # Without this, a settlement that would revert (bad data, insolvency) would cost gas on every retry.
    def test_does_not_send_when_the_simulation_reverts(self):
        k, c, _ = self.make((10**18, 10**9, 1_000, False), ts=1_020, reverts={"settle(address,bytes[])"})
        k.settle_due(1_020)
        self.assertEqual(c.sent, [])
        self.assertIn("0xabc", k.pending, "kept for a retry")

    # Without this, c would go unposted while positions accrue at it (the review's top finding), or be posted
    # with nobody exposed, spending the relayer's gas for nothing.
    def test_posts_c_only_while_something_accrues_or_waits(self):
        k, c, posts = self.make((0, 0, 0, False), ts=1_100)
        k.pending.clear()
        c.answers.update({"longOI()": (0,), "shortOI()": (0,)})
        k.keep_c_fresh()
        self.assertEqual(posts, [], "empty book: no post")
        k._last_post_check = 0
        c.answers["shortOI()"] = (5 * 10**17,)
        k.keep_c_fresh()
        self.assertEqual(posts, [(3595, keeper.POST_MOVE_WAD)],
                         "positions open: post on a 0.25%-a-year move, or when c is about an hour old")

    # Without this, an order nobody settled in time would keep the trader's margin in escrow forever.
    def test_cancels_expired_orders_so_the_margin_goes_back(self):
        k, c, _ = self.make((10**18, 10**9, 1_000, False), ts=1_063)
        k.settle_due(1_063)
        self.assertEqual(c.sent[0][0], "cancelExpired(address)")


if __name__ == "__main__":
    unittest.main()
