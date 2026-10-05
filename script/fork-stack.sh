#!/usr/bin/env bash
# Local stack for clicking through the front-end without a wallet: an anvil fork of Monad testnet (one block
# per second, like a live chain) and the backend pointed at it. Then: npm --prefix frontend run dev:fork
# (port 5174; uses anvil's well-known account #0 as a burner). Ctrl-C stops both.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
export PATH="$HOME/.foundry/bin:$PATH"
ENGINE=$(python3 -c "import json; print(json.load(open('deployments/monad-testnet.json'))['perpEngine'])")
anvil --fork-url "$MONAD_TESTNET_RPC" --port 8548 --block-time 1 --silent & ANVIL=$!
trap 'kill $ANVIL ${SVC:-} 2>/dev/null || true' EXIT
for _ in $(seq 60); do cast chain-id --rpc-url http://127.0.0.1:8548 >/dev/null 2>&1 && break; sleep 0.5; done
HEAD=$(cast block-number --rpc-url http://127.0.0.1:8548)
rm -f /tmp/cf-fork.sqlite*
MONAD_RPC=http://127.0.0.1:8548 PERP_ENGINE=$ENGINE ENGINE_START_BLOCK=$HEAD RECORDER_DB=/tmp/cf-fork.sqlite \
  RECORD_EVERY=30 PORT=8790 PYTHONUNBUFFERED=1 validation/.venv/bin/python -m validation.service & SVC=$!
echo "fork on :8548 (head $HEAD), backend on :8790"
wait $SVC
