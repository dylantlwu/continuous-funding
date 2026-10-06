#!/usr/bin/env bash
# Mutation check: each entry below breaks one protection on purpose, and the Forge suite must then fail.
# A mutation the suite does not catch is reported as ESCAPED and the script exits non-zero. Sources are
# restored after every run, even on error. Takes a few minutes (a full rebuild per mutation: --force,
# because a stale build cache once made mutations look escaped).
#
#   bash script/mutation-check.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

python3 - <<'EOF'
import pathlib, subprocess, sys

E, F = "src/PerpEngine.sol", "src/ConsensusFeed.sol"
MUTATIONS = [
    (E, "        if (_abs(size) > maxSize) revert AboveMaxSize(_abs(size), maxSize);\n", "",
     "per-account size cap removed"),
    (E, "        _requireVaultCapacity(price);\n", "",
     "vault capacity check removed (opens oversell the vault)"),
    (E, "Usdc kept = _isMarginShortfall(reason) ? _rejectionFee(o, price, conf) : Usdc.wrap(0);",
     "Usdc kept = Usdc.wrap(0);", "margin-shortfall rejection refunds the fee (free conditional order)"),
    (E, "                if (reason.length == 0) revert SettlementOutOfGas();\n", "",
     "out-of-gas settlement treated as a rejection (trader can refuse a fill)"),
    (E, "        if (conf * WAD > price * maxOpenConfRate) revert ConfidenceTooWide(price, conf);",
     "        if (feed.isStale(feedMarket)) revert FeedStale();\n"
     "        if (conf * WAD > price * maxOpenConfRate) revert ConfidenceTooWide(price, conf);",
     "the fill re-checks the feed (refund by settling while stale)"),
    (E, "        if (publishTime < minTime || publishTime > maxTime) {",
     "        if (false) {", "fills accept a print outside the pinned window"),
    (E, "        if (block.timestamp > publishTime && block.timestamp - publishTime > maxPriceAge) {",
     "        if (false) {", "liquidations accept an old price"),
    (E, "        maintenance = Units.requiredDown(", "        maintenance = Units.required(",
     "liquidation threshold rounded up (a healthy account at the boundary is liquidated)"),
    (F, "        int256 applied = _clamp(median, -cMax, cMax);", "        int256 applied = median;",
     "c no longer capped at +-cMax"),
    (F, "        uint64 since = f.initialized ? f.lastPostTime : deployedAt;", "        uint64 since = f.lastPostTime;",
     "first post not bounded from deployment (c can jump on the first post)"),
    (F, "        int256 step = maxSlewPerSec * int256(uint256(block.timestamp - since));",
     "        int256 step = maxSlewPerSec * 60;", "per-post step cap instead of time (v1: c falls behind after a quiet spell)"),
]

escaped = 0
for path, old, new, what in MUTATIONS:
    p = pathlib.Path(path)
    src = p.read_text()
    if src.count(old) != 1:
        sys.exit(f"{path}: mutation target not found exactly once: {old.strip()[:70]}")
    p.write_text(src.replace(old, new))
    try:
        r = subprocess.run(["forge", "test", "--force"], capture_output=True, text=True)
    finally:
        p.write_text(src)
    caught = r.returncode != 0 and "[FAIL" in r.stdout  # a compile error is not a catch
    failed = sorted({l.split("] ")[1].split("(")[0] for l in r.stdout.splitlines() if l.startswith("[FAIL") and "] " in l})
    print(f"{'caught ' if caught else 'ESCAPED'}  {what}" + (f"  <- {', '.join(failed[:3])}" if caught else ""), flush=True)
    escaped += not caught
print(f"\n{len(MUTATIONS) - escaped} of {len(MUTATIONS)} mutations caught")
sys.exit(1 if escaped else 0)
EOF
