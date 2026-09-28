#!/usr/bin/env bash
# Reads BTC/USD and ETH/USD from the oracles available on Monad testnet and prints
# price, decimals, publish time and age in seconds. Read-only: no key, no gas.
#
# Sources (checked 2026-09-28):
#   Supra push storage  0xf0e852BC3F940447862D6b67e5B9807E64B433F6  https://docs.monad.xyz/tooling-and-infra/oracles
#   Supra pair ids      BTC_USD=18, ETH_USD=19                     https://docs.supra.com/oracles/data-feeds/data-feeds-index
#   Pyth (pull)         0x2880aB155794e7179c9eE2e38200202908C17B43  https://docs.monad.xyz/tooling-and-infra/oracles
#   Pyth feed ids       from https://hermes.pyth.network/v2/price_feeds
set -euo pipefail
RPC="${MONAD_TESTNET_RPC:-https://testnet-rpc.monad.xyz}"
SUPRA=0xf0e852BC3F940447862D6b67e5B9807E64B433F6
PYTH=0x2880aB155794e7179c9eE2e38200202908C17B43
PYTH_BTC=0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
PYTH_ETH=0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace

# Public testnet RPCs time out intermittently; retry each call up to 4 times, 20 s each.
c() { local i; for i in 1 2 3 4; do cast "$@" --rpc-timeout 20 2>/dev/null && return 0; echo "  (rpc retry $i: cast $1)" >&2; sleep 2; done; echo "RPC failed 4 times: cast $*" >&2; return 1; }

now=$(c block latest --field timestamp --rpc-url "$RPC")
echo "chain_id=$(c chain-id --rpc-url "$RPC") block_time=$now ($(date -u -r "$now" 2>/dev/null || date -u -d "@$now"))"

supra() { # $1 name $2 pair id; Supra timestamps are milliseconds
  local r; r=$(c call "$SUPRA" 'getSvalue(uint256)((bytes32,uint256,uint256,uint256))' "$2" --rpc-url "$RPC" | tr -d '()')
  local dec ts px; dec=$(awk -F', ' '{print $2}' <<<"$r"); ts=$(awk -F', ' '{print $3}' <<<"$r" | awk '{print $1}'); px=$(awk -F', ' '{print $4}' <<<"$r" | awk '{print $1}')
  python3 -c "print(f'supra  $1  price={$px/10**$dec:.2f}  raw=$px  decimals=$dec  publish_ms=$ts  age_s={$now-$ts//1000}')"
}
pyth() { # $1 name $2 feed id; getPriceUnsafe never reverts on staleness, so the age is printed explicitly
  local r; r=$(c call "$PYTH" 'getPriceUnsafe(bytes32)((int64,uint64,int32,uint256))' "$2" --rpc-url "$RPC" | tr -d '()')
  local px expo ts; px=$(awk -F', ' '{print $1}' <<<"$r" | awk '{print $1}'); expo=$(awk -F', ' '{print $3}' <<<"$r"); ts=$(awk -F', ' '{print $4}' <<<"$r" | awk '{print $1}')
  python3 -c "print(f'pyth   $1  price={$px*10**($expo):.2f}  raw=$px  expo=$expo  publish_s=$ts  age_s={$now-$ts}')"
}
supra BTC/USD 18; supra ETH/USD 19
pyth BTC/USD "$PYTH_BTC"; pyth ETH/USD "$PYTH_ETH"
