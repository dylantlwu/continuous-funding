#!/usr/bin/env bash
# The backend (validation/service.py: recorder + keeper + API) against an anvil fork of Monad testnet and the
# real deployed engine. A trader commits and walks away; the keeper must settle after its grace period.
# Spends no testnet funds.   bash script/rehearse-backend-fork.sh
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
export PATH="$HOME/.foundry/bin:$PATH"
FORK=http://127.0.0.1:8548
API=http://127.0.0.1:8790
ENGINE=$(python3 -c "import json; print(json.load(open('deployments/monad-testnet.json'))['perpEngine'])")
TRADER=0x000000000000000000000000000000000000bEEF
LOGF=/tmp/cf-backend.log

anvil --fork-url "$MONAD_TESTNET_RPC" --port 8548 --block-time 1 --silent & ANVIL=$!  # blocks keep coming, as on Monad
trap 'kill $ANVIL ${SVC:-} 2>/dev/null || true' EXIT
for _ in $(seq 60); do cast chain-id --rpc-url $FORK >/dev/null 2>&1 && break; sleep 0.5; done
HEAD=$(cast block-number --rpc-url $FORK)

rm -f /tmp/cf-backend.sqlite*
MONAD_RPC=$FORK PERP_ENGINE=$ENGINE ENGINE_START_BLOCK=$HEAD RECORDER_DB=/tmp/cf-backend.sqlite RECORD_EVERY=20 \
  PORT=8790 validation/.venv/bin/python -m validation.service >"$LOGF" 2>&1 & SVC=$!
j() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

echo "== waiting for the recorder's first round"
for _ in $(seq 90); do
  M=$(curl -s $API/api/consensus | j "d.get('median_per_second_wad')" 2>/dev/null || true)
  [ -n "$M" ] && [ "$M" != "None" ] && break; sleep 1
done
curl -s $API/api/consensus | j "'median c = %.3f%% APR from %d venues' % (d['median_per_second_wad']*365*86400/1e16, sum(r is not None for r in d['rates_per_second_wad']))"
curl -s $API/api/chain/config | j "'engine %s, settleDelay %d s, orderTtl %d s, signer is relayer: %s' % (d['engine'], d['settleDelay'], d['orderTtl'], d['signer'].lower()==d['relayer'].lower())"
curl -s $API/api/pyth/latest | j "'pyth latest %.2f at %d (update %d bytes, key not in response: %s)' % (d['price']*10**d['expo'], d['publish_time'], len(d['update'])//2, 'Bearer' not in json.dumps(d))"

echo "== wake: posts because the feed is old"
curl -s -X POST $API/api/wake | j "'posted %s, gas charged %s' % (d['posted'], d.get('gas_charged'))"

echo "== trader commits a 0.05 BTC long and walks away (does not settle)"
cast rpc anvil_setBalance $TRADER 0xDE0B6B3A7640000 --rpc-url $FORK >/dev/null
cast rpc anvil_impersonateAccount $TRADER --rpc-url $FORK >/dev/null
USDC=$(curl -s $API/api/chain/config | j "d['usdc']")
S() { cast send --unlocked --from $TRADER --rpc-url $FORK "$@" >/dev/null; }
S $USDC "mint(address,uint256)" $TRADER 2000000000
S $USDC "approve(address,uint256)" $ENGINE 2000000000
S $ENGINE "commitOpen(int256,uint256)" 50000000000000000 1000000000
for _ in $(seq 40); do
  SIZE=$(cast call $ENGINE 'positions(address)(int256,uint256,int256,uint256)' $TRADER --rpc-url $FORK | head -1 | awk '{print $1}')
  [ "$SIZE" != "0" ] && break; sleep 1
done
echo "position size after the keeper's grace period: $SIZE"
[ "$SIZE" = "50000000000000000" ] || { echo "KEEPER DID NOT SETTLE"; tail -20 "$LOGF"; exit 1; }

echo "== trader commits a close and walks away"
S $ENGINE "commitClose()"
for _ in $(seq 40); do
  SIZE=$(cast call $ENGINE 'positions(address)(int256,uint256,int256,uint256)' $TRADER --rpc-url $FORK | head -1 | awk '{print $1}')
  [ "$SIZE" = "0" ] && break; sleep 1
done
echo "position size: $SIZE"
[ "$SIZE" = "0" ] || { echo "KEEPER DID NOT SETTLE THE CLOSE"; tail -20 "$LOGF"; exit 1; }

echo "== wake again: no post while the feed is recent; a repeat within 30 s from the same client is refused"
curl -s -X POST $API/api/wake | j "'posted %s (feed age %s s)' % (d['posted'], d.get('age_s'))"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST $API/api/wake); echo "repeat: HTTP $CODE"
[ "$CODE" = "429" ] || { echo "WAKE RATE LIMIT NOT ENFORCED"; exit 1; }

echo "== keeper log"
grep -E "keeper:" "$LOGF" | sed 's/tx 0x[0-9a-f]*/tx …/' | head
echo "== backend rehearsal passed"
