#!/usr/bin/env bash
# T4: the type system, not discipline, keeps deposited margin, required margin, USD and USDC apart.
# Control.sol must compile; each MUST-FAIL file must fail with the specific type error.
# Uses solc directly (the version pinned in foundry.toml), because `forge build <file>` still builds the project.
set -uo pipefail
cd "$(dirname "$0")/.."
VER=$(sed -n 's/^solc_version *= *"\(.*\)".*/\1/p' foundry.toml)
SOLC="${SOLC:-}"
for c in "$HOME/.svm/$VER/solc-$VER" "$HOME/Library/Application Support/svm/$VER/solc-$VER"; do
  [ -z "$SOLC" ] && [ -x "$c" ] && SOLC="$c"
done
[ -z "$SOLC" ] && { echo "solc $VER not found; run 'forge build' once or set SOLC"; exit 2; }
compile() { "$SOLC" --base-path . "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/" --bin "$1" >/tmp/cf.log 2>&1; }
fail=0
if compile compile_fail/Control.sol; then echo "PASS control compiles"; else echo "FAIL control did not compile:"; tail -5 /tmp/cf.log; fail=1; fi
check() { # file expected-error-substring
  if compile "$1"; then echo "FAIL $1 compiled but must not"; fail=1
  elif grep -q "$2" /tmp/cf.log; then echo "PASS $1 rejected: $(grep -m1 "^Error" /tmp/cf.log)"
  else echo "FAIL $1 failed for another reason:"; grep -m3 -i error /tmp/cf.log; fail=1; fi
}
check compile_fail/MixMargins.sol "type MarginDynamic is not implicitly convertible to expected type (type of first return variable) MarginStatic"
check compile_fail/MixUnits.sol "type UsdWad is not implicitly convertible to expected type (type of first return variable) Usdc"
exit $fail
