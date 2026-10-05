import { encodeAbiParameters, encodeErrorResult, encodeEventTopics, type Hex } from "viem";
import { describe, expect, it } from "vitest";
import { perpEngineAbi } from "./abi";
import { outcomeFromReceipt } from "./orderFlow";

const ACCOUNT = "0x00000000000000000000000000000000000000aa";
const tx = "0x" + "11".repeat(32) as Hex;

function log(eventName: "Opened" | "Closed" | "OrderRejected", types: { type: string }[], values: unknown[]) {
  const topics = encodeEventTopics({ abi: perpEngineAbi, eventName, args: { account: ACCOUNT } as never });
  return { topics: topics as [Hex, ...Hex[]], data: encodeAbiParameters(types as never, values as never) };
}

describe("what the user is told after settlement", () => {
  // Without this, an open rejected at the fill price (margin, vault capacity, a pause) would be reported as
  // "Filled": the user would believe they hold a position that does not exist, with their margin refunded.
  it("reports a rejection with the contract's reason", () => {
    const reason = encodeErrorResult({ abi: perpEngineAbi, errorName: "OpensArePaused" });
    const out = outcomeFromReceipt({ transactionHash: tx, logs: [log("OrderRejected", [{ type: "bytes" }], [reason])] as never });
    expect(out?.ok).toBe(false);
    expect(out?.text).toContain("OpensArePaused");
    expect(out?.text).toContain("refunded");
  });

  // Without this, the fill price shown could be something other than what the contract recorded.
  it("reports the fill price from the Opened event", () => {
    const l = log("Opened", [{ type: "int256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }],
      [10n ** 17n, 86_104_950_000_000_000_000_000n, 869_770_000n, 2_150_000n]);
    expect(outcomeFromReceipt({ transactionHash: tx, logs: [l] as never })?.text).toBe("Filled at $86,104.95.");
  });

  it("reports the cash returned on a close", () => {
    const l = log("Closed", [{ type: "int256" }, { type: "uint256" }, { type: "int256" }, { type: "int256" }, { type: "uint256" }, { type: "uint256" }],
      [10n ** 17n, 86_000_000_000_000_000_000_000n, 0n, 0n, 2_150_000n, 866_500_000n]);
    expect(outcomeFromReceipt({ transactionHash: tx, logs: [l] as never })?.text).toBe("Closed at $86,000.00; $866.50 returned to your wallet.");
  });
});
