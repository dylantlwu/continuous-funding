# Validation engine

Question it answers: **if someone trades against our funding rate and hedges on Binance, OKX, Bybit or Hyperliquid, how much funding can they extract?** Lower is better.

```bash
python3 -m unittest discover -s validation/tests -t .        # intent tests, no network
python3 -m validation.run --bases BTC,ETH,SOL --days 30         # live public data, Python 3.9+, stdlib only
python3 -m validation.run --bases NVDA:binance --start 2026-09-01 --end 2026-09-30
```

- Data: public settled-funding history from each venue; Binance's 1-minute premium index to rebuild its live prediction (checked against actual settlements in every report).
- Our charge: a progressive true-up tracker (`tracker.py`), under several policies: anchor to one venue, median, midrange.
- Score (`arb.py`): per settlement period and persistent (hold one side for the whole window), gross of fees and price basis.
- Every report prints the theoretical floor: half the spread between the highest- and lowest-paying venue. No single charge path can beat it.
