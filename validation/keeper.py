"""Keeper: the fallback that settles orders nobody else settled, and liquidates (docs/design.md §3, §7).

Traders settle their own orders about 2 s after committing; the keeper settles any order still pending
`grace_s` seconds after its fill time, at the same pinned price anyone would have to use. It cancels orders
past their deadline so the margin goes back. It liquidates only positions that a free eth_call simulation
says are liquidatable, so it never pays for a transaction that would revert.

Progress (last scanned block, known accounts) is kept in the recorder's SQLite so a restart resumes instead of
rescanning: Monad's public RPC serves at most 100 blocks per eth_getLogs.
"""
import time
import traceback

from eth_abi import decode

from . import hermes
from .chain import RpcError, selector, topic

T_ORDER = topic("OrderCommitted(address,int256,uint256,bool,uint64)")
T_OPENED = topic("Opened(address,int256,uint256,uint256,uint256)")
NOT_LIQUIDATABLE = selector("NotLiquidatable(int256,uint256)").hex()
PAGE = 100


def _account(log):
    return "0x" + log["topics"][1][-40:]


class Keeper:
    def __init__(self, chain, engine, db, post_if_needed, start_block, grace_s=10, log=None):
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
            if not is_close and self.chain.call(self.feed, "isStale(uint8)", ["uint8"], [0], ["bool"])[0]:
                self.post_if_needed(min_age_s=0)  # an open is rejected at settlement if the feed went stale
            upd = hermes.at(self.feed_id, at)
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

    def step(self):
        self.scan()
        _, now_ts, _ = self.chain.block()
        acted = self.settle_due(now_ts)
        if time.time() - self._last_liq >= 5:
            self._last_liq = time.time()
            acted += self.check_liquidations()
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
