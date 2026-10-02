# continuous-funding

An oracle-priced perpetual on Monad whose funding protects the vault that takes the other side:
rate = a bounded cross-venue consensus `c` + a premium `p` driven by the market's own long/short
imbalance (|p| ≤ 5% APR). Re-evaluated on every call that touches the market, accrued per second.
Design: [docs/design.md](docs/design.md).

> Status: work in progress for the Monad Metropolis hackathon (Track 01 · Onchain Finance & Trading). Testnet only. Not audited.

## AI Disclosure

This repository is built with AI coding tools (Claude Code). A full account of what the AI did and what the author did will be kept in this section as the project progresses.

## License

MIT, see [LICENSE](LICENSE).
