#!/usr/bin/env bash
# Local rehearsal on an anvil fork of Monad testnet (the real Pyth contract is there):
# deploy, post the consensus feed, open and close with real Pyth updates from Hermes, and show that a
# healthy position cannot be liquidated and an old price is rejected. Spends no testnet funds.
#
#   bash script/rehearse-fork.sh
#
# Needs .env: PRIVATE_KEY (read by forge only), DEPLOYER, MONAD_TESTNET_RPC, PYTH_API_KEY.
# Trades are sent as the deployer through anvil's impersonation, so no key is ever on a command line.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${PYTH_API_KEY:?set PYTH_API_KEY in .env}"
export PATH="$HOME/.foundry/bin:$PATH"

PORT=${PORT:-8546}
RPC=http://127.0.0.1:$PORT
BTC=0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
OUT=deployments/local-fork.json

anvil --fork-url "$MONAD_TESTNET_RPC" --port "$PORT" --silent &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true' EXIT
for _ in $(seq 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.5; done

step() { printf '\n== %s\n' "$*"; }
usd() { python3 -c "print(f'{int(\"$1\".split()[0]) / 10**$2:,.${3:-2}f}')"; }
apr() { python3 -c "print(f'{int(\"$1\".split()[0]) * 365 * 86400 / 1e16:.3f}% APR')"; }

# Signed Pyth updates for BTC/USD. The key goes to curl on stdin; redirects are refused so the header
# is never forwarded to another host. `hermes` = latest print (bots); `hermes_at T` = first print at or after T.
hermes_get() {
  printf 'Authorization: Bearer %s' "$PYTH_API_KEY" |
    curl -sS --fail --max-redirs 0 --max-time 15 -H @- "https://pyth.dourolabs.app/hermes/v2/updates/price/$1?ids[]=$BTC&encoding=hex" |
    python3 -c 'import json,sys; print("[0x" + json.load(sys.stdin)["binary"]["data"][0] + "]")'
}
hermes() { hermes_get latest; }
hermes_at() {
  while [ "$(date +%s)" -lt $(($1 + 3)) ]; do sleep 0.5; done # local clock runs ~1 s behind; let Hermes have it
  hermes_get "$1"
}
fill_time() { echo $(($(cast call "$ENGINE" 'orders(address)(int256,uint256,uint64,bool)' "$ME" --rpc-url "$RPC" | sed -n 3p | awk '{print $1}') + 2)); }

ME=$DEPLOYER
send() { # prints status and gas used
  cast send --unlocked --from "$ME" --rpc-url "$RPC" --json "$@" |
    python3 -c 'import json,sys; r=json.load(sys.stdin); print("status", int(r["status"],16), "gasUsed", int(r["gasUsed"],16))'
}
expect_revert() { # $1 = error signature, rest = cast call args
  local sig=$1; shift
  local sel; sel=$(cast sig "$sig")
  local out; out=$(cast call --from "$ME" --rpc-url "$RPC" "$@" 2>&1 || true)
  if grep -qE "${sel#0x}|${sig%%(*}" <<<"$out"; then echo "reverted with $sig, as expected"; else echo "UNEXPECTED: $out"; exit 1; fi
}

step "deploy (forge reads PRIVATE_KEY from .env)"
# Any key works, including a new one with no testnet MON: the fork funds it locally.
cast rpc anvil_setBalance "$DEPLOYER" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
DEPLOY_OUT=$OUT forge script script/Deploy.s.sol --rpc-url "$RPC" --broadcast >/tmp/cf-rehearse-deploy.log 2>&1 ||
  { tail -30 /tmp/cf-rehearse-deploy.log; exit 1; }
grep -E "PerpEngine|ConsensusFeed|PythPriceSource|TestUSDC|vault cash" /tmp/cf-rehearse-deploy.log | sed 's/^ *//'
addr() { python3 -c "import json; print(json.load(open('$OUT'))['$1'])"; }
ENGINE=$(addr perpEngine); FEED=$(addr consensusFeed); USDC=$(addr testUsdc)
cast rpc anvil_impersonateAccount "$ME" --rpc-url "$RPC" >/dev/null

step "relayer posts five venue rates (3,4,5,6,7% APR); the contract takes the median"
VENUES=$(python3 -c "print('[' + ','.join(str(p * 10**16 // (365*86400)) for p in (3,4,5,6,7)) + ']')")
NOW=$(cast block latest -f timestamp --rpc-url "$RPC")
send "$FEED" "post(uint8,uint64,int256[5])" 0 $((NOW - 1)) "$VENUES"
echo "c = $(apr "$(cast call "$FEED" 'rate(uint8)(int256)' 0 --rpc-url "$RPC")")"

step "trader commits a 0.1 BTC long (no price); a keeper settles at the first Pyth print 2 s later"
send "$USDC" "mint(address,uint256)" "$ME" 20000000000 >/dev/null
send "$USDC" "approve(address,uint256)" "$ENGINE" 20000000000 >/dev/null
BAL0=$(cast call "$USDC" 'balanceOf(address)(uint256)' "$ME" --rpc-url "$RPC" | awk '{print $1}')
printf 'commitOpen: '; send "$ENGINE" "commitOpen(int256,uint256)" 100000000000000000 1000000000
AT=$(fill_time); echo "fills at the first print at or after $AT"
FIRST=$(hermes_at "$AT")
printf 'a later print (not the first after the fill time): '
expect_revert "PriceFeedNotFoundWithinRange()" "$ENGINE" "settle(address,bytes[])" "$ME" "$(hermes_at $((AT + 1)))" --value 1
printf 'settle with the first print: '; send "$ENGINE" "settle(address,bytes[])" "$ME" "$FIRST" --value 1
POS=$(cast call "$ENGINE" 'positions(address)(int256,uint256,int256,uint256)' "$ME" --rpc-url "$RPC")
echo "entry price (price + conf) = $(usd "$(sed -n 4p <<<"$POS")" 18)  deposit = $(usd "$(sed -n 2p <<<"$POS")" 6) USDC"
echo "liquidation price         = $(usd "$(cast call "$ENGINE" 'liquidationPrice(address)(uint256)' "$ME" --rpc-url "$RPC")" 18)"
RATE=$(cast call "$ENGINE" 'currentRate()(int256,int256,int256)' --rpc-url "$RPC")
echo "rate: c = $(apr "$(sed -n 1p <<<"$RATE")"), p = $(apr "$(sed -n 2p <<<"$RATE")"), c + p = $(apr "$(sed -n 3p <<<"$RATE")")"

step "a healthy position cannot be liquidated (latest price, bot path)"
expect_revert "NotLiquidatable(int256,uint256)" "$ENGINE" "liquidate(address,bytes[])" "$ME" "$(hermes)" --value 1

step "close: commit, then settle at the first print 2 s later"
printf 'commitClose: '; send "$ENGINE" "commitClose()"
AT=$(fill_time)
printf 'settle:      '; send "$ENGINE" "settle(address,bytes[])" "$ME" "$(hermes_at "$AT")" --value 1
BAL1=$(cast call "$USDC" 'balanceOf(address)(uint256)' "$ME" --rpc-url "$RPC" | awk '{print $1}')
echo "round trip cost = $(usd "$((BAL0 - BAL1))" 6) USDC (fees + conf spread + price move + funding)"
echo "vault cash      = $(usd "$(cast call "$ENGINE" 'vaultCash()(uint256)' --rpc-url "$RPC")" 6) USDC"
echo "open interest   = $(cast call "$ENGINE" 'longOI()(uint256)' --rpc-url "$RPC" | awk '{print $1}') long, $(cast call "$ENGINE" 'shortOI()(uint256)' --rpc-url "$RPC" | awk '{print $1}') short"
step "rehearsal passed"
