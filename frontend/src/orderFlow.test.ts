import { encodeAbiParameters, encodeErrorResult, encodeEventTopics, type Hex } from "viem";
import { describe, expect, it } from "vitest";
import { perpEngineAbi } from "./abi";
import { outcomeFromLogs } from "./orderFlow";

const ME = "0x00000000000000000000000000000000000000aa";
const OTHER = "0x00000000000000000000000000000000000000bb";
const tx = ("0x" + "11".repeat(32)) as Hex;

function log(eventName: "Opened" | "Closed" | "OrderRejected", account: string, types: { type: string }[], values: unknown[]) {
  const topics = encodeEventTopics({ abi: perpEngineAbi, eventName, args: { account } as never });
  return { topics: topics as [Hex, ...Hex[]], data: encodeAbiParameters(types as never, values as never), transactionHash: tx };
}
const rejected = (who: string, error: "OpensArePaused" | "InsufficientMargin", feeKept: bigint) => {
  const reason = error === "InsufficientMargin"
    ? encodeErrorResult({ abi: perpEngineAbi, errorName: error, args: [10_000_000_000n, 10_100_000_000n] })
    : encodeErrorResult({ abi: perpEngineAbi, errorName: error });
  return log("OrderRejected", who, [{ type: "bytes" }, { type: "uint256" }], [reason, feeKept]);
};

describe("what the user is told after settlement", () => {
  // Without this, an open rejected at the fill price would be reported as "Filled": the user would believe
  // they hold a position that does not exist.
  it("reports a rejection the trader could not cause as a full refund", () => {
    const out = outcomeFromLogs([rejected(ME, "OpensArePaused", 0n)], ME);
    expect(out?.ok).toBe(false);
    expect(out?.text).toContain("OpensArePaused");
    expect(out?.text).toContain("refunded in full");
  });

  // Without this, a margin-shortfall rejection would claim a full refund while the vault kept the open fee.
  it("reports the fee kept on a margin shortfall", () => {
    const out = outcomeFromLogs([rejected(ME, "InsufficientMargin", 50_500_000n)], ME);
    expect(out?.text).toBe(
      "Rejected at the fill price (InsufficientMargin): the $50.50 open fee was kept and the rest of your margin refunded.",
    );
  });

  // Without this, when the keeper settles, the page (which scans the blocks since the commit) could report
  // someone else's fill or rejection as yours.
  it("ignores other accounts' events", () => {
    const theirs = log("Opened", OTHER, [{ type: "int256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }],
      [10n ** 17n, 90_000n * 10n ** 18n, 1n, 1n]);
    const mine = log("Opened", ME, [{ type: "int256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }],
      [10n ** 17n, 86_104_950_000_000_000_000_000n, 869_770_000n, 2_150_000n]);
    expect(outcomeFromLogs([theirs], ME)).toBeNull();
    expect(outcomeFromLogs([theirs, mine], ME)?.text).toBe("Filled at $86,104.95.");
  });

  it("reports the cash returned on a close", () => {
    const l = log("Closed", ME, [{ type: "int256" }, { type: "uint256" }, { type: "int256" }, { type: "int256" }, { type: "uint256" }, { type: "uint256" }],
      [10n ** 17n, 86_000_000_000_000_000_000_000n, 0n, 0n, 2_150_000n, 866_500_000n]);
    expect(outcomeFromLogs([l], ME)?.text).toBe("Closed at $86,000.00; $866.50 returned to your wallet.");
  });
});
