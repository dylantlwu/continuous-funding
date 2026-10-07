"""Keeper: settles orders, keeps c posted while positions are open, liquidates, records the market
(docs/design.md §3, §5.4, §7).

It settles every order as soon as the first Pyth print at or after its fill time exists (owner, 2026-10-05:
one wallet confirmation per trade; anyone else may settle first, at the same pinned price). It cancels orders
past their deadline so the margin goes back. While there is open interest or a pending order it asks the
relayer to post c once the venues' median has moved 0.25% a year from c on chain, and at least hourly. It liquidates only positions that a free eth_call simulation says are
liquidatable, so it never pays for a transaction that would revert. Every 5 minutes it samples c, p, open
interest and vault cash with free reads, for the market history chart.

Progress (last scanned block, known accounts) is kept in the recorder's SQLite so a restart resumes instead of
rescanning: Monad's public RPC serves at most 100 blocks per eth_getLogs.
"""
import os
import time
import traceback

from eth_abi import decode

from . import hermes
from .chain import RpcError, selector, topic

T_ORDER = topic("OrderCommitted(address,int256,uint256,bool,uint64)")
T_OPENED = topic("Opened(address,int256,uint256,uint256,uint256)")
NOT_LIQUIDATABLE = selector("NotLiquidatable(int256,uint256)").hex()
# Blocks per eth_getLogs: Monad's public RPC serves 100, Alchemy's Monad endpoint 1,000 (measured 2026-10-06).
PAGE = int(os.environ.get("KEEPER_LOG_PAGE", "100"))
# Owner, 2026-10-05: post c on a 0.25%-a-year move or hourly, not on a 2-minute timer. Replayed on 24 h of minute
# medians: about 117 posts a day instead of 720 (1.1 MON instead of 6.7 at 0.0092 MON a post), and the worst gap
# between c and the median falls from 1.34% to 0.25% a year, since a jump is posted at the next check.
YEAR_S = 31_536_000
POST_MOVE_WAD = round(0.0025 * 10**18 / YEAR_S)
POST_HEARTBEAT_S = 3600


def _account(log):
    return "0x" + log["topics"][1][-40:]


class Keeper:
    def __init__(self, chain, engine, db, post_if_needed, start_block, grace_s=0, log=None,
                 heartbeat_s=POST_HEARTBEAT_S, move_wad=POST_MOVE_WAD, sample_every_s=300, post_when_empty=False):
        self.chain, self.engine, self.db, self.post_if_needed = chain, engine, db, post_if_needed
        self.log = log or (lambda *a: print(*a, flush=True))  # unbuffered: a keeper action must show at once
        self.grace_s = grace_s
        c = chain.call
        self.feed = c(engine, "feed()", out=["address"])[0]
        self.source = c(engine, "priceSource()", out=["address"])[0]
        self.feed_id = "0x" + c(self.source, "feedId()", out=["bytes32"])[0].hex()
        self.settle_delay = c(engine, "settleDelay()", out=["uint64"])[0]
        self.order_ttl = c(engine, "orderTtl()", out=["uint64"])[0]
        db.execute("CREATE TABLE IF NOT EXISTS keeper_cursor(engine TEXT PRIMARY KEY, block INTEGER)")
        db.execute("CREATE TABLE IF NOT EXISTS keeper_accounts(engine TEXT, account TEXT, PRIMARY KEY(engine, account))")
        row = db.execute("SELECT block FROM keeper_cursor WHERE engine=?", (engine,)).fetchone()
        self.cursor = row[0] if row else start_block - 1
        self.pending = {}  # account -> fill time (commitTime + settleDelay)
        self._last_liq = 0.0
        self.heartbeat_s, self.move_wad, self.sample_every_s = heartbeat_s, move_wad, sample_every_s
        self.post_when_empty = post_when_empty  # other perps read c: keep it fresh even when this book is empty
        self._last_post_check = 0.0
        self._last_sample = 0.0
        db.execute("CREATE TABLE IF NOT EXISTS market_samples(engine TEXT, ts INTEGER, block INTEGER, c TEXT, p TEXT, "
                   "long_oi TEXT, short_oi TEXT, vault_cash TEXT, funding_index TEXT, PRIMARY KEY(engine, ts))")

    # ------------------------------------------------------------ discovery

    def scan(self):
        head = self.chain.block()[0]
        while self.cursor < head:
            a, b = self.cursor + 1, min(self.cursor + PAGE, head)
            for lg in self.chain.logs(self.engine, [T_ORDER, T_OPENED], a, b):  # either event, one call per page
                if lg["topics"][0] == T_ORDER:
                    *_, settle_at = decode(["int256", "uint256", "bool", "uint64"], bytes.fromhex(lg["data"][2:]))
                    self.pending[_account(lg)] = settle_at
                else:
                    self.db.execute("INSERT OR IGNORE INTO keeper_accounts VALUES (?,?)", (self.engine, _account(lg)))
            self.cursor = b
            self.db.execute("INSERT OR REPLACE INTO keeper_cursor VALUES (?,?)", (self.engine, b))
            self.db.commit()

    # ------------------------------------------------------------ settlement fallback

    def _fee(self, update):
        return self.chain.call(self.source, "updateFee(bytes[])", ["bytes[]"], [[bytes.fromhex(update[2:])]],
                               ["uint256"])[0]

    def settle_due(self, now_ts):
        acted = []
        for acct, at in list(self.pending.items()):
            if now_ts < at + self.grace_s:
                continue
            _, _, commit_time, is_close = self.chain.call(
                self.engine, "orders(address)", ["address"], [acct], ["int256", "uint256", "uint64", "bool"])
            if commit_time == 0:  # the trader settled it, or it was cancelled, or liquidation removed it
                del self.pending[acct]
                continue
            if commit_time + self.settle_delay != at:  # a newer order replaced the one we saw
                self.pending[acct] = commit_time + self.settle_delay
                continue
            if now_ts > at + self.order_ttl:  # nobody can settle it any more: return the margin
                tx, _ = self.chain.send(self.engine, "cancelExpired(address)", ["address"], [acct])
                self.log(f"keeper: cancelled expired order of {acct} tx {tx}")
                del self.pending[acct]
                acted.append(("cancel", acct, tx))
                continue
            try:
                upd = hermes.at(self.feed_id, at)
            except hermes.HermesError:
                continue  # the print for the fill time is not published yet: try again next second
            args = (["address", "bytes[]"], [acct, [bytes.fromhex(upd["update"][2:])]])
            fee = self._fee(upd["update"])
            try:  # free simulation first: never pay for a settlement that would revert
                self.chain.call(self.engine, "settle(address,bytes[])", *args, value=fee, sender=self.chain.address)
            except RpcError as e:
                self.log(f"keeper: settle simulation for {acct} reverted, will retry: {e}")
                continue
            tx, _ = self.chain.send(self.engine, "settle(address,bytes[])", *args, value=fee)
            self.log(f"keeper: settled {'close' if is_close else 'open'} of {acct} at print {upd['publish_time']} tx {tx}")
            del self.pending[acct]
            acted.append(("settle", acct, tx))
        return acted

    # ------------------------------------------------------------ liquidation

    def check_liquidations(self, near=0.02):
        """Simulate liquidation only for positions within `near` of their liquidation price; send only if the
        simulation succeeds. Liquidations use the latest price and must land within 3 s of its publish time."""
        accounts = [r[0] for r in self.db.execute("SELECT account FROM keeper_accounts WHERE engine=?", (self.engine,))]
        if not accounts:
            return []
        upd = hermes.latest(self.feed_id)
        price = upd["price"] * 10 ** (18 + upd["expo"]) if 18 + upd["expo"] >= 0 else upd["price"] // 10 ** -(18 + upd["expo"])
        acted = []
        for acct in accounts:
            size = self.chain.call(self.engine, "positions(address)", ["address"], [acct],
                                   ["int256", "uint256", "int256", "uint256"])[0]
            if size == 0:
                continue
            liq = self.chain.call(self.engine, "liquidationPrice(address)", ["address"], [acct], ["uint256"])[0]
            if liq == 0 or abs(price - liq) > near * liq:
                continue
            args = (["address", "bytes[]"], [acct, [bytes.fromhex(upd["update"][2:])]])
            fee = self._fee(upd["update"])
            try:
                self.chain.call(self.engine, "liquidate(address,bytes[])", *args, value=fee, sender=self.chain.address)
            except RpcError as e:
                # Healthy is the normal answer. Anything else (a price that aged past 3 s, bad data) means a
                # position near liquidation that the keeper cannot liquidate: say so, never skip silently.
                if NOT_LIQUIDATABLE not in str(e):
                    self.log(f"keeper: cannot liquidate {acct} (price published {upd['publish_time']}): {e}")
                continue
            tx, _ = self.chain.send(self.engine, "liquidate(address,bytes[])", *args, value=fee)
            self.log(f"keeper: liquidated {acct} tx {tx}")
            acted.append(("liquidate", acct, tx))
        return acted

    # ------------------------------------------------------------ loop

    # ------------------------------------------------------------ c while positions are open; market samples

    def _open_interest(self, block="latest"):
        c = self.chain.call
        return (c(self.engine, "longOI()", out=["uint256"], block=block)[0],
                c(self.engine, "shortOI()", out=["uint256"], block=block)[0])

    def keep_c_fresh(self):
        """While anything accrues or waits to fill, post c once the median is `move_wad` away from it or c is
        `heartbeat_s` old. When the book is empty nothing here accrues, so it posts only if `post_when_empty` is set
        (other perps read the feed; every post is charged at its gas limit). Checked every 30 s; the recorder reads
        the venues every minute."""
        if time.time() - self._last_post_check < 30:
            return None
        self._last_post_check = time.time()
        long_oi, short_oi = self._open_interest()
        if long_oi + short_oi == 0 and not self.pending and not self.post_when_empty:
            return None
        return self.post_if_needed(min_age_s=self.heartbeat_s - 5, move_wad=self.move_wad)

    def sample(self, now_ts, block):
        if time.time() - self._last_sample < self.sample_every_s:
            return
        self._last_sample = time.time()
        at = hex(block)  # every value read at the block the sample is labelled with, so anyone can re-read it
        c, p, _ = self.chain.call(self.engine, "currentRate()", out=["int256", "int256", "int256"], block=at)
        long_oi, short_oi = self._open_interest(at)
        vault = self.chain.call(self.engine, "vaultCash()", out=["uint256"], block=at)[0]
        index = self.chain.call(self.engine, "fundingIndexNow()", out=["int256"], block=at)[0]
        self.db.execute("INSERT OR REPLACE INTO market_samples VALUES (?,?,?,?,?,?,?,?,?)",
                        (self.engine, now_ts, block, str(c), str(p), str(long_oi), str(short_oi), str(vault), str(index)))
        self.db.commit()

    def step(self):
        self.scan()
        block, now_ts, _ = self.chain.block()
        acted = self.settle_due(now_ts)
        posted = self.keep_c_fresh()
        if posted and posted.get("posted"):
            why = "hourly" if posted.get("gap_wad") is None else f"median moved {posted['gap_wad'] * YEAR_S / 1e16:+.3f}%/yr"
            self.log(f"keeper: posted c (positions open, {why}) tx {posted['tx']}")
        if time.time() - self._last_liq >= 5:
            self._last_liq = time.time()
            acted += self.check_liquidations()
        self.sample(now_ts, block)
        return acted

    def latency_probe(self, rounds=5):
        """Free (no transaction): how long the latest-price liquidation path takes from this host. A liquidation
        needs one Hermes fetch, one simulation and about five RPC calls to send, then inclusion, all within 3 s
        of the print's publish time. Logged so the 3-second window can be judged from the real server."""
        hermes_s, rpc_s, ages = [], [], []
        for _ in range(rounds):
            t = time.time()
            upd = hermes.latest(self.feed_id, max_cache_s=0)
            hermes_s.append(time.time() - t)
            t = time.time()
            _, block_ts, _ = self.chain.block()
            rpc_s.append(time.time() - t)
            ages.append(block_ts - upd["publish_time"])
            time.sleep(0.5)
        med = lambda xs: sorted(xs)[len(xs) // 2]
        budget = med(hermes_s) + 7 * med(rpc_s)
        self.log(f"keeper: latency probe: hermes {med(hermes_s):.2f}s, rpc {med(rpc_s):.2f}s per call, "
                 f"latest-price path before inclusion ~{budget:.2f}s, block time minus print time {med(ages)}s")
        return budget

    def run(self, every=1.0):
        self.log(f"keeper: engine {self.engine} as {self.chain.address}, from block {self.cursor + 1}")
        try:
            self.latency_probe()
        except Exception:
            traceback.print_exc()
        while True:
            t = time.time()
            try:
                self.step()
            except Exception:  # never let the keeper die silently; the next step retries
                traceback.print_exc()
            time.sleep(max(0.0, every - (time.time() - t)))
