// Continuous Funding v3 events -> activity totals, trades, the market's funding record and every feed post.
import { indexer } from "envio";
import type { Stats, Trader } from "envio";

const WAD = 10n ** 18n;
const abs = (x: bigint) => (x < 0n ? -x : x);
const id = (e: { chainId: number; block: { number: number }; logIndex: number }) =>
  `${e.chainId}_${e.block.number}_${e.logIndex}`;

async function stats(context: any): Promise<Stats> {
  return (
    (await context.Stats.get("global")) ?? {
      id: "global", traders: 0, fills: 0, closes: 0, liquidations: 0, rejections: 0,
      volumeUsd: 0n, feesUsdc: 0n, vaultSeeded: 0n, vaultWithdrawn: 0n,
    }
  );
}

async function trader(context: any, account: string): Promise<{ t: Trader; isNew: boolean }> {
  const key = account.toLowerCase();
  const t = await context.Trader.get(key);
  return t ? { t, isNew: false } : { t: { id: key, fills: 0, closes: 0, liquidations: 0 }, isNew: true };
}

function trade(event: any, kind: string, size: bigint, price: bigint) {
  return {
    id: id(event), kind, account: event.params.account.toLowerCase(), size, price,
    block: event.block.number, time: event.block.timestamp, txHash: event.transaction.hash,
  };
}

indexer.onEvent({ contract: "PerpEngine", event: "Opened" }, async ({ event, context }) => {
  const s = await stats(context);
  const { t, isNew } = await trader(context, event.params.account);
  const { size, price, fee } = event.params;
  context.Trader.set({ ...t, fills: t.fills + 1 });
  context.Trade.set(trade(event, "open", size, price));
  context.Stats.set({
    ...s, fills: s.fills + 1, traders: s.traders + (isNew || t.fills === 0 ? 1 : 0),
    volumeUsd: s.volumeUsd + (abs(size) * price) / WAD, feesUsdc: s.feesUsdc + fee,
  });
});

indexer.onEvent({ contract: "PerpEngine", event: "Closed" }, async ({ event, context }) => {
  const s = await stats(context);
  const { t } = await trader(context, event.params.account);
  const { size, price, fee } = event.params;
  context.Trader.set({ ...t, closes: t.closes + 1 });
  context.Trade.set(trade(event, "close", size, price));
  context.Stats.set({ ...s, closes: s.closes + 1, volumeUsd: s.volumeUsd + (abs(size) * price) / WAD, feesUsdc: s.feesUsdc + fee });
});

indexer.onEvent({ contract: "PerpEngine", event: "Liquidated" }, async ({ event, context }) => {
  const s = await stats(context);
  const { t } = await trader(context, event.params.account);
  const { size, price } = event.params;
  context.Trader.set({ ...t, liquidations: t.liquidations + 1 });
  context.Trade.set(trade(event, "liquidation", size, price));
  context.Stats.set({ ...s, liquidations: s.liquidations + 1, volumeUsd: s.volumeUsd + (abs(size) * price) / WAD });
});

indexer.onEvent({ contract: "PerpEngine", event: "OrderRejected" }, async ({ event, context }) => {
  const s = await stats(context);
  context.Stats.set({ ...s, rejections: s.rejections + 1, feesUsdc: s.feesUsdc + event.params.feeKept });
});

indexer.onEvent({ contract: "PerpEngine", event: "VaultSeeded" }, async ({ event, context }) => {
  const s = await stats(context);
  context.Stats.set({ ...s, vaultSeeded: s.vaultSeeded + event.params.amount });
});

indexer.onEvent({ contract: "PerpEngine", event: "VaultWithdrawn" }, async ({ event, context }) => {
  const s = await stats(context);
  context.Stats.set({ ...s, vaultWithdrawn: s.vaultWithdrawn + event.params.amount });
});

indexer.onEvent({ contract: "PerpEngine", event: "MarketUpdated" }, async ({ event, context }) => {
  const { time, premium, fundingIndex, price, consensusRate } = event.params;
  context.MarketPoint.set({ id: id(event), time, premium, fundingIndex, price, consensusRate, block: event.block.number });
});

indexer.onEvent({ contract: "ConsensusFeed", event: "Posted" }, async ({ event, context }) => {
  const { median, applied, observedAt, venueRates } = event.params;
  context.FeedPost.set({
    id: id(event), median, applied, observedAt, venueRates: [...venueRates],
    block: event.block.number, txHash: event.transaction.hash,
  });
});
