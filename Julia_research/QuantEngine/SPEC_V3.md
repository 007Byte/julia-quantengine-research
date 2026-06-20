# QuantEngine v3.0 — Technical Specification

**Date:** March 17, 2026
**Language:** Julia 1.12
**Codebase:** 13,441 lines source | 3,440 lines tests | 110 source files | 1,338 tests | 0 failures

---

## 1. What QuantEngine Is

QuantEngine is a fully autonomous quantitative trading system that monitors stocks, crypto, and prediction markets using a 33-model mathematical ensemble with 14 engineered features. It detects probability mispricings, sizes positions using cost-adjusted Kelly criterion, executes trades across three exchanges, manages risk through 12 defense-in-depth layers, and reports results — all without human intervention.

**Three asset classes, three exchanges:**

| Asset Class | Data Source | Execution | Real-Time Feed |
|------------|------------|-----------|----------------|
| Stocks | Yahoo Finance | Alpaca (REST API v2) | Polygon.io WebSocket |
| Crypto | Yahoo Finance | Future exchange adapter | Binance WebSocket |
| Prediction Markets | Polymarket API | Polymarket CLOB | X/Twitter Stream |

**Three operating modes:**
- **24/7 live pipeline** — event-driven monitoring with automated trading
- **On-demand analysis** — full 33-model report with PDF + 9 chart dashboards
- **Walk-forward backtest** — historical validation for stocks, crypto, and prediction markets

---

## 2. Architecture

### 2.1 Complete Data Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│                          DATA SOURCES                                │
│  Yahoo Finance · Polymarket API · Binance WS · Polygon.io WS        │
│  X/Twitter Stream · FRED Economic API · Kalshi API · Polling Data    │
└───────────────────────────┬──────────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────────┐
│                       EVENT BUS (Channel)                            │
│  WebSocket callbacks + X sentiment + polling fallback → events       │
│  Bounded buffer (100) · Sub-second delivery · Drop-on-overflow       │
└───────────────────────────┬──────────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────────┐
│                      DATA PIPELINE                                   │
│  validate_ticker() → fetch → sanitize → compute_features()           │
│  14-feature matrix:                                                  │
│    Returns(5) · Vol · VolChg · RSI · Momentum                        │
│    FracDiff(2) · Spread · OrderImbalance · TradeVelocity              │
└───────────────────────────┬──────────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────────┐
│                    33-MODEL ENSEMBLE                                 │
│                                                                      │
│  Phase 1A: 19 fast models (Threads.@threads, <5 sec total)           │
│  Phase 1B: 7 heavy NN models (worker processes, JLD2 weight-cached)  │
│  Phase 2:  8 dependent models (require Phase 1 results)              │
│                                                                      │
│  + Polymarket Quant Layer:                                           │
│    Bayesian blend · Calibration · Fee-aware EV · Binary Kelly         │
│    Logit edge · Fee-zone filter · Historical calibration table        │
│                                                                      │
│  Each model wrapped in RALPH (Review·Analyze·Log·Print·Halt)         │
└───────────────────────────┬──────────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────────┐
│             COMPOSITE SIGNAL + LEARNED WEIGHTS                       │
│  CPCV accuracy preferred · Optional LBFGS-optimized ensemble weights │
│  → direction + score + p_true + confidence                           │
└───────────────────────────┬──────────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────────┐
│                  DUAL DECISION LAYER                                 │
│                                                                      │
│  Aggressive: ¾ Kelly · market orders · short holds · wide TP/SL      │
│  Conservative: ¼ Kelly · limit orders · long holds · tight TP/SL     │
│  Kelly is regime-aware: volatile=50%, trending=120%, mean-rev=70%    │
│  Kelly is cost-adjusted: slippage + fees deducted from returns       │
│                                                                      │
│  Orchestrator: 10 rules → blend / select / skip                      │
└───────────────────────────┬──────────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────────┐
│                EXECUTION + RISK + PERSISTENCE                        │
│                                                                      │
│  Exchanges: PaperExchange · AlpacaExchange · PolymarketExchange      │
│  Risk: 12-layer defense-in-depth · Dynamic EV threshold              │
│  Audit: JSONL + SQLite + JLD2 weight cache                           │
│  Alerts: Telegram Bot API · Structured JSON logging                  │
│  Monitoring: /health (JSON) · /metrics (Prometheus)                  │
│  A/B Testing: Dual ensemble comparison with auto-promotion           │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.2 Directory Structure

```
QuantEngine/                          13,441 LOC · 110 files · 1,338 tests
├── Project.toml                      15 dependencies (all pure Julia)
├── Dockerfile                        Multi-stage build, Julia 1.12
├── docker-compose.yml                Pipeline + backup sidecar
├── deploy/quantengine.service        systemd (security-hardened)
├── SECURITY.md                       Threat model + 12 defense layers
├── bin/                              7 CLI entry points
│   ├── run_pipeline.jl               24/7 automated trading
│   ├── run_analysis.jl               Full 33-model analysis + PDF
│   ├── run_backtest.jl               Walk-forward backtest
│   ├── run_scanner.jl                Multi-ticker scan + portfolio
│   ├── run_tuning.jl                 Bayesian hyperparameter search
│   ├── run_live.jl                   Live monitoring
│   └── run_single_model.jl           Debug individual model
├── src/                              110 source files
│   ├── core/                         Types, constants, config, RALPH, logger
│   ├── security/                     Encrypted vault (SHA-256 PBKDF2)
│   ├── data/                         Ingestion, 14 features, feeds, signals
│   ├── nn/                           LSTM/GRU/MLP primitives + weight cache
│   ├── models/                       33 models + polymarket quant + studies
│   ├── reporting/                    Composite, charts, PDF, ensemble optimizer
│   ├── orchestrator/                 Model dispatch + strategy engine
│   ├── execution/                    Paper, Alpaca, Polymarket exchanges + audit
│   ├── risk/                         Circuit breakers, positions, portfolio
│   ├── pipeline/                     Types, config, triggers, steps, loop, event bus
│   ├── decision/                     Aggressive + conservative strategies
│   ├── instruments/                  Stock, crypto, polymarket instruments
│   ├── scanner/                      Multi-ticker scanner
│   ├── tuning/                       Bayesian optimization + A/B testing
│   ├── storage/                      SQLite database + queries
│   ├── monitoring/                   Health server + Telegram alerts
│   └── backtest/                     Walk-forward + Polymarket backtest
└── test/                             30 test files, 1,338 tests
```

---

## 3. The 33-Model Ensemble

### Core Models (1-30)

| # | Model | Category | Phase |
|---|-------|----------|-------|
| 1 | LSTM | Deep Learning (cached) | 1B |
| 2 | GRU | Deep Learning (cached) | 1B |
| 3 | Helformer | Transformer+LSTM+HW (cached) | 1B |
| 4 | LSTM-GARCH | Hybrid | 2 |
| 5 | Random Forest | ML (CPCV accuracy) | 1A |
| 6 | LightGBM | ML (CPCV accuracy) | 1A |
| 7 | XGBoost | ML (CPCV accuracy) | 1A |
| 8 | Conv-LSTM | Deep Learning (cached) | 1B |
| 9 | BiLSTM | Deep Learning (cached) | 1B |
| 10 | SGD | ML online learner | 1A |
| 11 | TFT | Temporal Fusion Transformer (cached) | 1B |
| 12 | Ensemble Stack | Model stacking | 2 |
| 13 | MLP | Multi-layer perceptron (cached) | 1B |
| 14 | GARCH/EGARCH | Volatility (reparameterized) | 1A |
| 15 | RL (DQN) | Reinforcement learning | 1A |
| 16 | LMSR | Prediction market pricing | 1A |
| 17 | Kelly Criterion | Position sizing (regime+cost aware) | 1A |
| 18 | EV Gap | Mispricing (dynamic threshold) | 2 |
| 19 | KL-Divergence | Info theory | 2 |
| 20 | Bregman Projection | Info theory | 2 |
| 21 | Bayesian Update | 4 evidence sources + tweets | 2 |
| 22 | Logistic Regression | Continuation/reversal | 1A |
| 23 | AR(1) | Regime detection | 1A |
| 24 | Black-Scholes | Options + 5 Greeks | 1A |
| 25 | Crank-Nicolson FD | American options | 1A |
| 26 | Term Structure | Nelson-Siegel + Vasicek | 1A |
| 27 | Martingale Detection | Random walk test | 2 |
| 28 | Meta-Labeling | Bet/no-bet (Lopez de Prado) | 2 |
| 29 | FracDiff Signal | Memory-preserving differentiation | 1A |
| 30 | Triple-Barrier | Regime classification | 1A |

### Prediction Market Models (31-33)

| # | Model | What It Does |
|---|-------|-------------|
| 31 | Kalman Filter | Smooths noisy probabilities, detects information shocks |
| 32 | Time Decay | Models volatility compression as event approaches expiry |
| 33 | Cross-Market Arb | Detects price discrepancies across Polymarket/Kalshi |

### Polymarket Professional Quant Layer

| Component | Function | Edge It Creates |
|-----------|----------|----------------|
| Bayesian Blend | `bayesian_blend(model, market; k_model, k_market)` | Liquidity-weighted model↔market fusion in logit space |
| Calibration | `calibrate_probability(raw_p, category_bias)` | Favorite-longshot bias correction |
| Fee Schedule | `_polymarket_fee(price)` | Accurate fee curve (peaks ~1.5% at 50¢, ~0% at tails) |
| Fee Zone Filter | `fee_zone_quality(price)` | Filters out the 45-55¢ fee death zone |
| Fair Probability | `estimate_fair_probability(inputs)` | Full pipeline: blend → calibrate → clip |
| Fee-Aware EV | `buy_ev()`, `sell_ev()` | Net EV after bid/ask spread + platform fees |
| Logit Edge | `logit_edge(fair, market)` | Symmetric edge scaling (proper near 0 and 1) |
| Binary Kelly | `binary_kelly(fair_prob, all_in_cost)` | `f* = (p - c) / (1 - c)` for $1/$0 contracts |
| Calibration Table | `CalibrationTable`, `derive_bias()` | Historical predicted-vs-actual tracking by bucket |
| Signal Generator | `generate_poly_signal(quote, inputs)` | Complete: estimate → EV → edge → Kelly → action |
| Instant Screener | `is_overpriced/underpriced_for_buyer()` | One-line: `p̂ > ask + fee + threshold` |

**The decision rule:**
```
Trade only if: p̂ - market > fees + slippage + risk buffer
```

---

## 4. The 14-Feature Matrix

| # | Feature | Type | Source |
|---|---------|------|--------|
| 1-5 | Return lags | Price | returns[t] through returns[t-4] |
| 6 | Vol(20) | Volatility | 20-day rolling std of returns |
| 7 | VolChg | Volume | (V[t+1] - V[t]) / V[t] |
| 8 | RSI(14) | Momentum | Relative Strength Index |
| 9 | Mom(10) | Momentum | 10-day return sum |
| 10-11 | FracDiff | Memory | Fractional differentiation (Lopez de Prado) |
| **12** | **Spread(HL)** | **Microstructure** | **(High - Low) / Price — bid-ask proxy** |
| **13** | **OrderImbalance** | **Microstructure** | **Volume-weighted price momentum (5-bar)** |
| **14** | **TradeVelocity** | **Microstructure** | **Volume acceleration (3-bar vs prior 3-bar)** |

Features 12-14 are the strongest short-term predictors for crypto and Polymarket. They feed directly into Logistic (m22), AR(1) (m23), and the full ensemble.

---

## 5. What Is Fully Automated

| Capability | How |
|-----------|-----|
| Market monitoring | 24/7 event-driven loop (WebSocket + polling fallback) |
| Trigger detection | Volume spikes, price jumps, orderbook imbalance, sentiment spikes |
| Signal generation | 33 models run per trigger, composite signal computed |
| Trade decision | Aggressive vs conservative, 10 orchestrator rules |
| Position sizing | Regime-aware, cost-adjusted Kelly criterion |
| Order execution | PaperExchange / AlpacaExchange / PolymarketExchange |
| Risk management | 12 defense layers, dynamic EV threshold |
| Position monitoring | Stop-loss, take-profit, time-based exits |
| Data persistence | Every trade, snapshot, model result → SQLite |
| Session resume | Loads bankroll + history from DB on restart |
| Weight caching | NN models skip training on cache hit (12 min → <1 sec) |
| Fast model threading | 19 fast models run in parallel via `Threads.@threads` |
| Audit trail | Immutable JSONL with rotation (50MB limit) |
| Alerting | Telegram for trades, circuit breakers, errors |
| Health monitoring | `/health` (JSON) + `/metrics` (Prometheus) |
| A/B testing | Dual ensemble configs tracked simultaneously |
| Calibration | Historical predicted-vs-actual bias tracking |

---

## 6. Performance Architecture

| Component | Impact |
|-----------|--------|
| **Weight Cache (JLD2)** | NN training: 12 min → <1 sec on cache hit |
| **Threaded Fast Models** | 19 models in parallel: ~4-8x speedup |
| **Event Bus (Channel)** | Sub-second reaction vs 5-second polling |
| **Incremental Retraining** | Warm-start from cached θ instead of random init |
| **Dynamic EV Threshold** | Higher vol → higher required edge (prevents noise trading) |
| **Cost-Adjusted Kelly** | Slippage + fees deducted before sizing |

---

## 7. Security Architecture (12 Defense Layers)

| # | Layer | What It Prevents |
|---|-------|-----------------|
| 1 | Input Validation | Ticker injection, URL manipulation |
| 2 | Data Sanitizer | NaN/Inf/negative prices |
| 3 | RALPH Wrapper | Model failures crashing system |
| 4 | Hard Pipeline Gates | Trading on uncalibrated/negative-EV signals |
| 5 | Circuit Breakers | Daily loss, drawdown, position limits |
| 6 | Execution Mode Guard | Accidental real-money trading (PAPER/LIVE) |
| 7 | Rate Limiter | API bans |
| 8 | Audit Logger | Untracked decisions (rotating JSONL, 50MB) |
| 9 | File Permissions | Unauthorized access (0o700/0o600) |
| 10 | Encrypted Vault | Key exposure (SHA-256 PBKDF2, 50K rounds) |
| 11 | Structured Logging | Undetected errors (JSON) |
| 12 | Telegram Alerts | Missed critical events |

---

## 8. Prediction Market Trading Stack

### Three Repeatable Edges (Implemented)

**1. Tail Miscalibration**
- `CalibrationTable` tracks predicted vs actual frequency per 10% bucket
- `derive_bias()` auto-corrects favorite-longshot bias in logit space
- Contracts at 5-20¢ are often overpriced, contracts at 80-95¢ can be cheap

**2. Fee-Aware Filtering**
- `fee_zone_quality()` scores 0 (50¢ = worst) to 1 (tails = best)
- `buy_ev()` / `sell_ev()` subtract exact Polymarket fee curve + slippage
- `break_even_buy/sell()` gives minimum probability to justify trade
- The 45-55¢ zone has 1.5% fees — many "good-looking" trades are actually bad

**3. Spread/Latency Harvesting**
- `PolyQuote` uses bid/ask (not midpoint)
- Binary Kelly uses all-in cost (ask + fee) not just ask
- Logit edge normalizes properly near 0 and 1
- Kalman filter (m31) smooths noisy prices to detect true probability shifts

### Complete Polymarket Flow

```
1. Fetch market data → PolyQuote(slug, bid, ask)
2. Build model inputs → PolyModelInputs(base_prob, market_mid, liquidity, recency, bias)
3. Estimate fair probability → estimate_fair_probability(inputs)
   a. Bayesian blend (model vs market, liquidity-weighted)
   b. Calibrate (longshot/favorite bias correction)
4. Compute net EV → buy_ev(fair, ask, fee) or sell_ev(fair, bid, fee)
5. Check threshold → EV > min_edge + fee_zone penalty
6. Size with binary Kelly → f* = (p - cost) / (1 - cost) × kelly_fraction
7. Execute → PolymarketExchange.place_order()
8. Record → CalibrationTable for future bias learning
```

---

## 9. What Can Be Improved

### High Impact (Next Sprint)

| Improvement | Current State | What It Would Do |
|------------|--------------|-----------------|
| **GPU acceleration** | CPU-only LBFGS | Flux.jl + CUDA → 100x NN training |
| **FinBERT sentiment** | Keyword + negation + bigrams | Contextual language model for sarcasm/nuance |
| **Live order-book integration** | Microstructure features from OHLCV | Direct Binance/Polymarket L2 depth data as features |
| **Options execution routing** | BS + FD pricing models exist | IBKR/Tastytrade adapter for vol-arb and defined-risk |
| **Polymarket historical OHLCV** | Synthetic or CSV only | Direct API when Polymarket provides it |

### Medium Impact

| Improvement | What It Would Do |
|------------|-----------------|
| Web dashboard (Genie.jl) | Real-time positions, equity curve, model signals |
| Multi-channel alerts | Slack/Discord alongside Telegram |
| Config hot-reload | Change parameters without restart |
| Cross-asset correlation features | BTC-SPY correlation, VIX regime as features |
| Market-making layer | Quote around p_true on liquid Polymarket contracts |

### Architecture Refinements

| Improvement | What It Would Do |
|------------|-----------------|
| Formal `ModelOutput` type | Standardized struct for all 33 models |
| Plugin `@register_model` macro | Self-registering models, zero edits to add m34+ |
| Nested config hierarchy | `TriggerConfig`, `RiskConfig` instead of flat 18-field struct |
| Typed results container | Replace `Dict{String, Any}` with `StructArray` |

---

## 10. Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `QE_EXECUTION_MODE` | `PAPER` | Must be explicit `LIVE` for real money |
| `QE_INITIAL_BANKROLL` | `2000` | Starting capital ($) |
| `QE_MAX_POSITION_PCT` | `0.10` | Max 10% per position |
| `QE_MAX_DAILY_LOSS_PCT` | `0.05` | Halt after 5% daily loss |
| `QE_MAX_DRAWDOWN_PCT` | `0.15` | Halt after 15% drawdown |
| `QE_MAX_CONCURRENT_POS` | `5` | Max open positions |
| `QE_POLL_INTERVAL_MS` | `5000` | Polling interval (ms) |
| `QE_FORCE_CONSERVATIVE` | `false` | Conservative-only mode |
| `QE_EV_GAP_MIN` | `0.05` | Minimum EV (dynamic with vol) |
| `QE_KELLY_MIN_FRAC` | `0.25` | Kelly lower bound |
| `QE_KELLY_MAX_FRAC` | `0.50` | Kelly upper bound |
| `QE_ALPACA_API_KEY` | — | Alpaca stock trading |
| `QE_ALPACA_SECRET_KEY` | — | Alpaca secret |
| `QE_POLYMARKET_API_KEY` | — | Polymarket CLOB key |
| `QE_POLYMARKET_SECRET` | — | Polymarket CLOB secret |
| `QE_POLYGON_API_KEY` | — | Polygon.io WebSocket |
| `QE_X_BEARER_TOKEN` | — | X/Twitter stream |
| `QE_FRED_API_KEY` | — | FRED economic data |
| `QE_TELEGRAM_BOT_TOKEN` | — | Telegram alerts |
| `QE_TELEGRAM_CHAT_ID` | — | Telegram chat |
| `QE_VAULT_TYPE` | `env` | `env` or `encrypted` |
| `QE_VAULT_MASTER_KEY` | — | Encrypted vault key |

---

## 11. Test Coverage

**1,338 tests across 29 test suites:**

| Suite | Coverage |
|-------|----------|
| Input Validation | Ticker injection, ExecutionMode |
| Data Sanitizer | Price/volume/returns/OHLCV/Polymarket |
| Feature Engineering | 14-feature matrix, sequences |
| Composite Signal | Accuracy weighting, learned weights |
| Kelly Criterion | Fractions, regime awareness, cost adjustment |
| GARCH/EGARCH | Persistence < 1.0, forecast, volume correlation |
| Circuit Breakers | Preflight, cooling, stop-loss, take-profit |
| Position Tracker | Open/close, PnL, thread safety |
| Rate Limiter | Per-second, per-minute limits |
| Audit Logger | JSON Lines, rotation, safe values |
| FracDiff | Weights, ADF, find_min_d |
| CPCV | Combinations, purged splits, evaluate |
| RALPH | Success/failure/retry/NaN |
| Backtest Engine | Folds, metrics, equity curve |
| Database | CRUD, resume, model leaderboard |
| Alpaca Exchange | URL selection, type hierarchy, keys |
| WebSocket Feeds | State lifecycle, Binance messages, thread safety |
| Vault | Roundtrip, wrong key, migration, permissions |
| X Stream | Sentiment, negation, bigrams, buffer |
| Scanner & Portfolio | Config, allocation, diversification |
| Tuning | Search spaces, Bayesian opt, save/load |
| Monitoring | Health JSON, Prometheus metrics |
| Weight Cache | Store/retrieve, JLD2 roundtrip, staleness |
| Event Bus | Emit/take, timeout, overflow, concurrent |
| Ensemble Optimizer | Weight learning, prediction matrix |
| Alerts | Config, level filtering, rate limiting |
| Prediction Markets | Kalman, time decay, arb, exchange, signals, backtest |
| Profit Boosters | Microstructure features, regime Kelly, dynamic EV, A/B testing |
| Polymarket Quant | Logit math, fees, blend, calibration, binary Kelly, signals |

---

## 12. Dependencies

All pure Julia. No Python. No GPU required.

| Package | Purpose |
|---------|---------|
| HTTP | REST APIs, WebSocket, health server |
| JSON | Data parsing, audit logs, vault |
| SQLite | Trade persistence, session resume |
| JLD2 | Weight cache serialization |
| Optim | LBFGS (NN training, ensemble weights, GARCH) |
| Plots | Chart generation (9 dashboards) |
| Luxor | PDF report generation |
| StatsBase | Advanced statistics |
| SpecialFunctions | erf for Black-Scholes |
| Distributed | Multi-process NN parallelism |
| Statistics | Basic statistics |
| LinearAlgebra | Matrix operations |
| Dates | Timestamps |
| Printf | Formatted output |
| Random | Monte Carlo, sampling |

---

## 13. Deployment

```bash
# Docker
docker compose up -d
curl localhost:8080/health

# systemd
sudo systemctl enable --now quantengine
journalctl -u quantengine -f

# Local
julia --project=. -t auto bin/run_pipeline.jl BTC-USD,AAPL
julia --project=. bin/run_analysis.jl AAPL
julia --project=. bin/run_backtest.jl AAPL --fast
julia --project=. bin/run_scanner.jl watchlist.txt --portfolio --capital 50000
julia --project=. bin/run_tuning.jl 7 AAPL --evals 50
```

---

*Generated March 17, 2026 — QuantEngine v3.0 (33 Models · 14 Features · 3 Exchanges · 1,338 Tests)*
