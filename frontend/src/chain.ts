// Chain access: free reads through the public RPC (batched into one Multicall3 call per refresh) and writes
// through the user's wallet. Monad charges the gas LIMIT, so every write sets its limit from a fresh estimate
// plus 15% instead of letting the wallet pad it (https://docs.monad.xyz/developer-essentials/gas-pricing).
import {
  BaseError,
  ContractFunctionRevertedError,
  UserRejectedRequestError,
  createPublicClient,
  createWalletClient,
  custom,
  http,
  type Abi,
  type Address,
  type EIP1193Provider,
  type Hex,
  type TransactionReceipt,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { monadTestnet } from "viem/chains";
import { consensusFeedAbi, perpEngineAbi, priceSourceAbi, testUsdcAbi } from "./abi";
import type { ChainConfig } from "./api";

export const EXPLORER = "https://testnet.monadvision.com"; // Sourcify-verified sources show here (docs.monad.xyz)
export const chain = monadTestnet;
// VITE_RPC lets a local rehearsal point the app at an anvil fork of Monad testnet; production uses the default.
const RPC = (import.meta.env.VITE_RPC as string | undefined) || undefined;
export const client = createPublicClient({ chain, transport: http(RPC), batch: { multicall: true } });

// Development only: a burner key for clicking through the flow on a local fork without a browser wallet.
// `import.meta.env.DEV` is false in production builds, so Vite removes this branch from the shipped app.
const BURNER = import.meta.env.DEV ? (import.meta.env.VITE_BURNER_KEY as Hex | undefined) : undefined;
const burner = BURNER ? privateKeyToAccount(BURNER) : null;

declare global {
  interface Window {
    ethereum?: EIP1193Provider;
  }
}

export async function connect(): Promise<Address> {
  if (burner) return burner.address;
  if (!window.ethereum) throw new Error("No browser wallet found. Install MetaMask or another EVM wallet.");
  const [account] = await window.ethereum.request({ method: "eth_requestAccounts" });
  await ensureMonad();
  return account as Address;
}

export async function ensureMonad() {
  if (burner) return;
  const eth = window.ethereum!;
  const hexId = `0x${chain.id.toString(16)}` as Hex;
  if ((await eth.request({ method: "eth_chainId" })) === hexId) return;
  try {
    await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hexId }] });
  } catch (e) {
    if ((e as { code?: number }).code !== 4902) throw e;
    await eth.request({
      method: "wallet_addEthereumChain",
      params: [{ chainId: hexId, chainName: chain.name, nativeCurrency: chain.nativeCurrency,
                 rpcUrls: [...chain.rpcUrls.default.http], blockExplorerUrls: [EXPLORER] }],
    });
  }
}

const wallet = () =>
  burner ? createWalletClient({ account: burner, chain, transport: http(RPC) })
         : createWalletClient({ chain, transport: custom(window.ethereum!) });

/** Estimate (a revert surfaces here, before the wallet opens), set the limit to +15%, send, wait. */
export async function write(
  account: Address,
  address: Address,
  abi: Abi,
  functionName: string,
  args: readonly unknown[],
  value = 0n,
): Promise<TransactionReceipt> {
  await ensureMonad();
  const req = { account, address, abi, functionName, args, value, chain } as const;
  const gas = await client.estimateContractGas(req as never);
  const hash = await wallet().writeContract({ ...req, gas: (gas * 115n) / 100n } as never);
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`Transaction reverted: ${hash}`);
  return receipt;
}

const FRIENDLY: Record<string, string> = {
  FeedStale: "The consensus rate is being refreshed on-chain. Try again in a few seconds.",
  OpensArePaused: "New positions are paused by the operator. Closing still works.",
  PositionExists: "You already have a position. Close it first.",
  OrderPending: "You already have an order waiting to fill.",
  BelowMinSize: "The minimum size is 0.001 BTC.",
  VaultCapacityExceeded: "The vault cannot take more on this side right now: it must stay solvent through a 25% move.",
  InsufficientMargin: "Not enough margin at the fill price.",
  MarginBelowFee: "The margin does not cover the fee.",
  ConfidenceTooWide: "The oracle is unusually uncertain right now. Try again shortly.",
  NoPosition: "There is no position to close.",
  NoOrder: "This order was already settled.",
  OrderExpired: "This order expired unfilled; its margin can be returned.",
  ERC20InsufficientBalance: "Not enough test USDC. Use the faucet first.",
  OverFaucetMax: "The faucet gives at most 100,000 test USDC per call.",
};

export function explain(e: unknown): string {
  if (e instanceof BaseError) {
    if (e.walk((x) => x instanceof UserRejectedRequestError)) return "You declined in your wallet.";
    const rev = e.walk((x) => x instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
    const name = rev?.data?.errorName;
    if (name) return FRIENDLY[name] ?? `The contract refused: ${name}.`;
    if (/insufficient funds/i.test(e.message)) return "Not enough MON for gas. Get testnet MON from the faucet.";
    return e.shortMessage;
  }
  return e instanceof Error ? e.message : String(e);
}

export const abis = { perpEngineAbi, consensusFeedAbi, priceSourceAbi, testUsdcAbi };

export type Market = {
  rate: readonly [bigint, bigint, bigint]; // c, p, c + p (per second, 1e18)
  vaultCash: bigint;
  longOI: bigint;
  shortOI: bigint;
  stale: boolean;
  lastPostTime: bigint;
  block: bigint;
};

export type Mine = {
  position: readonly [bigint, bigint, bigint, bigint]; // size, deposit, entryIndex, entryPrice
  order: readonly [bigint, bigint, bigint, boolean]; // size, margin, commitTime, isClose
  value: readonly [bigint, bigint] | null; // pnl, funding owed (contract rounding), at the latest Pyth price
  liquidationPrice: bigint;
  usdc: bigint;
  allowance: bigint;
  mon: bigint;
};

/** Everything the page shows, in one Multicall3 round trip. */
export async function readAll(cfg: ChainConfig, account?: Address, priceWad?: bigint) {
  const e = { address: cfg.engine, abi: perpEngineAbi } as const;
  const f = { address: cfg.feed, abi: consensusFeedAbi } as const;
  const [block, rate, vaultCash, longOI, shortOI, stale, lastPostTime] = await Promise.all([
    client.getBlockNumber(),
    client.readContract({ ...e, functionName: "currentRate" }),
    client.readContract({ ...e, functionName: "vaultCash" }),
    client.readContract({ ...e, functionName: "longOI" }),
    client.readContract({ ...e, functionName: "shortOI" }),
    client.readContract({ ...f, functionName: "isStale", args: [0] }),
    client.readContract({ ...f, functionName: "lastPostTime", args: [0] }),
  ]);
  const market: Market = { rate, vaultCash, longOI, shortOI, stale, lastPostTime: BigInt(lastPostTime), block };
  if (!account) return { market, mine: null };
  const u = { address: cfg.usdc, abi: testUsdcAbi } as const;
  const [position, order, liquidationPrice, usdc, allowance, mon, value] = await Promise.all([
    client.readContract({ ...e, functionName: "positions", args: [account] }),
    client.readContract({ ...e, functionName: "orders", args: [account] }),
    client.readContract({ ...e, functionName: "liquidationPrice", args: [account] }),
    client.readContract({ ...u, functionName: "balanceOf", args: [account] }),
    client.readContract({ ...u, functionName: "allowance", args: [account, cfg.engine] }),
    client.getBalance({ address: account }),
    priceWad ? client.readContract({ ...e, functionName: "positionValue", args: [account, priceWad] }) : null,
  ]);
  const mine: Mine = {
    position: position as Mine["position"],
    order: [order[0], order[1], BigInt(order[2]), order[3]],
    value: value as Mine["value"],
    liquidationPrice,
    usdc,
    allowance,
    mon,
  };
  return { market, mine };
}

export async function oracleFee(cfg: ChainConfig, update: Hex): Promise<bigint> {
  return client.readContract({ address: cfg.priceSource, abi: priceSourceAbi, functionName: "updateFee", args: [[update]] });
}
