import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

type Addr = `0x${string}`;
const [A, B, K] = TestHelpers.Addresses.mockAddresses.slice(0, 3) as Addr[] as [Addr, Addr, Addr];
const BTC = 10n ** 18n;
const P = 100_000n * 10n ** 18n;

const opened = (account: Addr, size: bigint) => ({
  contract: "PerpEngine" as const, event: "Opened" as const,
  params: { account, size, price: P, deposit: 4_000_000_000n, fee: 50_000_000n },
});

describe("activity totals for the page's strip", () => {
  // Without this, a wallet that trades twice would be counted as two traders, inflating the traction figure.
  it("counts each wallet once, however many fills it has", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 10143: { simulate: [opened(A, BTC), opened(A, -BTC), opened(B, BTC / 2n)] } } });
    const s = await indexer.Stats.getOrThrow("global");
    t.expect(s.traders).toBe(2);
    t.expect(s.fills).toBe(3);
  });

  // Without this, shorts (negative size) would subtract from volume, and liquidations would be missing from it.
  it("adds |size| x price for opens, closes and liquidations, and counts liquidations", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        10143: {
          simulate: [
            opened(A, -BTC),
            { contract: "PerpEngine" as const, event: "Closed" as const,
              params: { account: A, size: -BTC, price: P, pnl: 0n, funding: 0n, fee: 50_000_000n, payout: 3_950_000_000n } },
            { contract: "PerpEngine" as const, event: "Liquidated" as const,
              params: { account: B, liquidator: K, size: BTC / 10n, price: P, conf: 0n, reward: 50_000_000n } },
          ],
        },
      },
    });
    const s = await indexer.Stats.getOrThrow("global");
    t.expect(s.volumeUsd).toBe(2n * 100_000n * 10n ** 18n + 10_000n * 10n ** 18n);
    t.expect(s.liquidations).toBe(1);
    t.expect(s.feesUsdc).toBe(100_000_000n);
  });

  // Without this, the strip's vault P&L (vault cash minus net seeding) would be computed against the wrong base.
  it("tracks what the owner seeded and withdrew", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        10143: {
          simulate: [
            { contract: "PerpEngine" as const, event: "VaultSeeded" as const, params: { amount: 1_000_000_000_000n } },
            { contract: "PerpEngine" as const, event: "VaultWithdrawn" as const, params: { amount: 200_000_000n } },
          ],
        },
      },
    });
    const s = await indexer.Stats.getOrThrow("global");
    t.expect(s.vaultSeeded - s.vaultWithdrawn).toBe(999_800_000_000n);
  });
});

describe("the feed's public record", () => {
  // Without this, a missing venue (int256 min) could be lost or reordered, and nobody could recheck a median.
  it("keeps all five venue rates in contract order, missing ones included", async (t) => {
    const indexer = createTestIndexer();
    const MISSING = -(2n ** 255n);
    const venueRates = [1n, 2n, MISSING, 4n, 5n] as const;
    await indexer.process({
      chains: { 10143: { simulate: [{ contract: "ConsensusFeed" as const, event: "Posted" as const,
        params: { market: 0n, median: 2n, applied: 2n, observedAt: 1_000n, venueRates } }] } },
    });
    const posts = await indexer.FeedPost.getAll();
    t.expect(posts.length).toBe(1);
    t.expect(posts[0]!.venueRates).toEqual([1n, 2n, MISSING, 4n, 5n]);
  });
});
