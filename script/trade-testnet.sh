#!/usr/bin/env bash
# One real round trip on Monad testnet against deployments/monad-testnet.json: the relayer posts venue
# rates, the deployer commits a 0.1 BTC long, settles it at the first Pyth print 2 s later, then closes
# the same way. Prints receipts' gas (Monad charges the gas limit). Spends testnet MON.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${PYTH_API_KEY:?set PYTH_API_KEY in .env}"
export PATH="$HOME/.foundry/bin:$PATH"
RPC=$MONAD_TESTNET_RPC
BTC=0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
D=deployments/monad-testnet.json
addr() { python3 -c "import json; print(json.load(open('$D'))['$1'])"; }
ENGINE=$(addr perpEngine); USDC=$(addr testUsdc); ME=$DEPLOYER

ops() { # runs one Ops function and prints status and gas of each transaction it sent
  forge script script/Ops.s.sol --rpc-url "$RPC" --broadcast --slow --sig "$@" >/tmp/cf-ops.log 2>&1 ||
    { tail -25 /tmp/cf-ops.log; exit 1; }
  python3 - <<'PY'
import json, glob, os
f = max(glob.glob('broadcast/Ops.s.sol/10143/*-latest.json'), key=os.path.getmtime)
d = json.load(open(f))
for tx, r in zip(d['transactions'], d['receipts']):
    print(f"   {tx.get('function') or 'create'}: status {int(r['status'],16)}, gas limit charged {int(r['gasUsed'],16):,}, tx {r['transactionHash']}")
PY
}
hermes_get() {
  printf 'Authorization: Bearer %s' "$PYTH_API_KEY" |
    curl -sS --fail --max-redirs 0 --max-time 15 -H @- "https://pyth.dourolabs.app/hermes/v2/updates/price/$1?ids[]=$BTC&encoding=hex" |
    python3 -c 'import json,sys; print("0x" + json.load(sys.stdin)["binary"]["data"][0])'
}
hermes_at() { while [ "$(date +%s)" -lt $(($1 + 3)) ]; do sleep 0.5; done; hermes_get "$1"; }
fill_time() { echo $(($(cast call "$ENGINE" 'orders(address)(int256,uint256,uint64,bool)' "$ME" --rpc-url "$RPC" | sed -n 3p | awk '{print $1}') + 2)); }
usd() { python3 -c "print(f'{int(\"$1\".split()[0]) / 10**$2:,.${3:-2}f}')"; }

echo "== relayer posts five venue rates (3,4,5,6,7% APR)"
ops "post(int256[5])" "$(python3 -c "print('[' + ','.join(str(p * 10**16 // (365*86400)) for p in (3,4,5,6,7)) + ']')")"

echo "== commit a 0.1 BTC long (margin 1,000 tUSDC)"
ops "commitOpen(int256,uint256)" 100000000000000000 1000000000
# start balance = what is left after the commit plus the 1,000 margin now in escrow
BAL0=$(( $(cast call "$USDC" 'balanceOf(address)(uint256)' "$ME" --rpc-url "$RPC" | awk '{print $1}') + 1000000000 ))
AT=$(fill_time); echo "   fills at the first Pyth print at or after $AT"
echo "== settle"
ops "settle(address,bytes)" "$ME" "$(hermes_at "$AT")"
POS=$(cast call "$ENGINE" 'positions(address)(int256,uint256,int256,uint256)' "$ME" --rpc-url "$RPC")
echo "   entry price $(usd "$(sed -n 4p <<<"$POS")" 18), deposit $(usd "$(sed -n 2p <<<"$POS")" 6) tUSDC, liquidation price $(usd "$(cast call "$ENGINE" 'liquidationPrice(address)(uint256)' "$ME" --rpc-url "$RPC")" 18)"

echo "== commit close, then settle"
ops "commitClose()"
AT=$(fill_time)
ops "settle(address,bytes)" "$ME" "$(hermes_at "$AT")"
BAL1=$(cast call "$USDC" 'balanceOf(address)(uint256)' "$ME" --rpc-url "$RPC" | awk '{print $1}')
echo "   round trip: trader $(python3 -c "print(f'{($BAL1 - $BAL0)/1e6:+,.2f}')") tUSDC"
echo "   vault cash $(usd "$(cast call "$ENGINE" 'vaultCash()(uint256)' --rpc-url "$RPC")" 6) tUSDC, open interest $(cast call "$ENGINE" 'longOI()(uint256)' --rpc-url "$RPC" | awk '{print $1}')/$(cast call "$ENGINE" 'shortOI()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
echo "   MON left: $(cast balance "$ME" --ether --rpc-url "$RPC")"
