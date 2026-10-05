"""Minimal Monad JSON-RPC client: free reads (eth_call) and signed transactions.

Monad charges the gas LIMIT, not the gas used (https://docs.monad.xyz/developer-essentials/gas-pricing), and
reprices cold state access, so every limit here is the node's own estimate times a small factor chosen per
call, never a generous default. A transaction whose estimate reverts is never sent (fail loud before paying).
The signing key is passed in by the caller from the environment and is never logged or returned.
"""
import json
import threading
import time
import urllib.error
import urllib.request

from eth_abi import decode, encode
from eth_account import Account
from eth_utils import keccak, to_checksum_address


class RpcError(RuntimeError):
    pass


class TxFailed(RuntimeError):
    pass


def selector(signature):
    return keccak(text=signature)[:4]


def topic(event_signature):
    return "0x" + keccak(text=event_signature).hex()


def calldata(signature, types=(), args=()):
    return "0x" + (selector(signature) + encode(list(types), list(args))).hex()


class Chain:
    def __init__(self, rpc_url, private_key=None, timeout=20):
        self.rpc_url = rpc_url
        self.timeout = timeout
        self._acct = Account.from_key(private_key) if private_key else None
        self._send_lock = threading.Lock()  # one key, one nonce sequence
        self.chain_id = int(self.rpc("eth_chainId", []), 16)

    @property
    def address(self):
        return self._acct.address if self._acct else None

    def rpc(self, method, params, retries=3):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        last = None
        for attempt in range(retries):
            try:
                req = urllib.request.Request(self.rpc_url, data=body, headers={"content-type": "application/json"})
                with urllib.request.urlopen(req, timeout=self.timeout) as r:
                    out = json.loads(r.read())
                if "error" in out:  # an answer from the node (e.g. a revert): do not retry
                    raise RpcError(f"{method}: {out['error']}")
                return out["result"]
            except RpcError:
                raise
            except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
                last = e
                time.sleep(0.5 * (attempt + 1))
        raise RpcError(f"{method}: no answer after {retries} attempts: {last}")

    # ---------------------------------------------------------------- reads (free)

    def call(self, to, signature, types=(), args=(), out=(), value=0, sender=None, block="latest"):
        tx = {"to": to, "data": calldata(signature, types, args)}
        if value:
            tx["value"] = hex(value)
        if sender:
            tx["from"] = sender
        raw = self.rpc("eth_call", [tx, block])
        return decode(list(out), bytes.fromhex(raw[2:])) if out else raw

    def block(self, tag="latest"):
        b = self.rpc("eth_getBlockByNumber", [tag, False])
        return int(b["number"], 16), int(b["timestamp"], 16), int(b.get("baseFeePerGas", "0x0"), 16)

    def logs(self, address, topic0, from_block, to_block):
        """Monad's public RPC answers at most 100 blocks per eth_getLogs, so callers page in steps of 100."""
        return self.rpc("eth_getLogs", [{"address": address, "topics": [topic0],
                                         "fromBlock": hex(from_block), "toBlock": hex(to_block)}])

    # ---------------------------------------------------------------- writes (paid)

    def send(self, to, signature, types=(), args=(), value=0, gas_factor=1.3, wait=60):
        """Estimate (reverts surface here, before any cost), sign, send, wait for the receipt.
        Returns (tx_hash, receipt). Raises TxFailed if the transaction reverted on chain."""
        if not self._acct:
            raise RuntimeError("no signing key configured")
        data = calldata(signature, types, args)
        with self._send_lock:
            frm = self._acct.address
            est = int(self.rpc("eth_estimateGas", [{"from": frm, "to": to, "data": data, "value": hex(value)}]), 16)
            _, _, base = self.block()
            tip = int(self.rpc("eth_maxPriorityFeePerGas", []), 16)
            nonce = int(self.rpc("eth_getTransactionCount", [frm, "pending"]), 16)
            tx = {"type": 2, "chainId": self.chain_id, "nonce": nonce, "to": to_checksum_address(to), "value": value,
                  "data": data,
                  "gas": int(est * gas_factor) + 1, "maxFeePerGas": 2 * base + tip, "maxPriorityFeePerGas": tip}
            signed = self._acct.sign_transaction(tx)
            tx_hash = self.rpc("eth_sendRawTransaction", ["0x" + signed.raw_transaction.hex().removeprefix("0x")],
                               retries=1)
        deadline = time.time() + wait
        while time.time() < deadline:
            receipt = self.rpc("eth_getTransactionReceipt", [tx_hash])
            if receipt:
                if int(receipt["status"], 16) != 1:
                    raise TxFailed(f"{signature} reverted on chain: {tx_hash}")
                return tx_hash, receipt
            time.sleep(0.4)
        raise TxFailed(f"{signature} not mined within {wait}s: {tx_hash}")
