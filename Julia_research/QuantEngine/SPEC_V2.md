# QuantEngine v2.0 — Technical Specification

**Date:** March 17, 2026
**Language:** Julia 1.12
**Codebase:** 12,811 lines of source | 108 files | 1,229 tests passing | 0 failures

---

## 1. What QuantEngine Is

QuantEngine is a fully autonomous quantitative trading system that monitors stocks, crypto, and prediction markets using a 33-model mathematical ensemble. It detects opportunities, sizes positions, executes trades, manages risk, and reports results — all without human intervention.

**Three operating modes:**
- **24/7 live pipeline** — continuous monitoring with automated paper or real trading
- **On-demand analysis** — full 33-model report with PDF, charts, and trade plan
- **Walk-forward backtest** — historical validation with out-of-sample metrics

**Three asset classes:**
- **Stocks** — via Yahoo Finance (data) + Alpaca (execution) + Polygon.io (WebSocket)
- **Crypto** — via Yahoo Finance (data) + Binance (WebSocket) + future exchange integration
- **Prediction Markets** — via Polymarket (data + execution via CLOB API)

---

## 2. Architecture

### 2.1 System Data Flow

```
┌──────────────────────────────────────────────────────────────────┐
│                        DATA SOURCES                               │
│  Yahoo Finance · Polymarket API · Binance WS · Polygon.io WS     │
│  X/Twitter Stream · FRED Economic API · Kalshi API                │
└──────────────────────────┬───────────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────────┐
│                     EVENT BUS (Channel)                           │
│  WebSocket callbacks + X sentiment + polling fallback → events    │
│  Sub-second delivery · Bounded buffer (100) · Drop-on-overflow    │
└──────────────────────────┬───────────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────────┐
│                    DATA PIPELINE                                  │
│  validate_ticker() → fetch → sanitize → compute_features()       │
│  11-feature matrix: returns(5), vol, volume_change, RSI,          │
│  momentum, fracdiff(price), fracdiff(logprice)                    │
└──────────────────────────┬───────────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────────┐
│                  33-MODEL ENSEMBLE                                │
│                                                                   │
│  Phase 1A: 19 fast models (threaded, <5 sec total)                │
│    RF, LightGBM, XGBoost, SGD, GARCH, RL, LMSR, Kelly, EV Gap,   │
│    Logistic, AR(1), BS, FD, Term Structure, FracDiff, Triple-Bar, │
│    Kalman Filter, Time Decay, Cross-Market Arb                    │
│                                                                   │
│  Phase 1B: 7 heavy NN models (worker processes, weight-cached)    │
│    LSTM, GRU, Helformer, Conv-LSTM, BiLSTM, TFT, MLP              │
│    → JLD2 cache: second run = milliseconds instead of minutes     │
│                                                                   │
│  Phase 2: 8 dependent models (require Phase 1 results)            │
│    LSTM-GARCH, Ensemble Stack, EV Gap, KL-Div, Bregman,           │
│    Bayesian Update, Martingale, Meta-Labeling                     │
│                                                                   │
│  Each model wrapped in RALPH (Review·Analyze·Log·Print·Halt)      │
└──────────────────────────┬───────────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────────┐
│               COMPOSITE SIGNAL + LEARNED WEIGHTS                  │
│  Accuracy-based weighting (default) or LBFGS-optimized weights    │
│  → direction + score + p_true + confidence                        │
│  CPCV accuracy preferred over standard accuracy                   │
└──────────────────────────┬───────────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────────┐
│                DUAL DECISION LAYER                                │
│                                                                   │
│  Aggressive: ¾ Kelly · market orders · short holds · wide TP/SL   │
│  Conservative: ¼ Kelly · limit orders · long holds · tight TP/SL  │
│                                                                   │
│  Orchestrator: 10 rules → blend / select / skip                   │
│  Portfolio heat, daily loss, drawdown, regime, cooling period      │
└──────────────────────────┬───────────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────────┐
│               EXECUTION + RISK + PERSISTENCE                     │
│                                                                   │
│  Exchanges: PaperExchange · AlpacaExchange · PolymarketExchange   │
│  Risk: Circuit breakers · Position limits · Cooling periods       │
│  Audit: Append-only JSONL · SQLite database · JLD2 weight cache   │
│  Alerts: Telegram Bot API · Structured JSON logging               │
│  Monitoring: /health (JSON) · /metrics (Prometheus)               │
└──────────────────────────────────────────────────────────────────┘
```

### 2.2 Directory Structure

```
QuantEngine/                          12,811 LOC · 108 files · 1,229 tests
├── Project.toml                      15 dependencies (all pure Julia)
├── Dockerfile                        Multi-stage build
├── docker-compose.yml                Pipeline + backup sidecar
├── deploy/quantengine.service        systemd (security-hardened)
├── SECURITY.md                       Threat model + controls
├── SPEC_V2.md                        This document
├── bin/                              7 CLI entry points
│   ├── run_pipeline.jl               24/7 automated trading
│   ├── run_analysis.jl               Full 33-model analysis + PDF
│   ├── run_backtest.jl               Walk-forward backtest
│   ├── run_scanner.jl                Multi-ticker scan + portfolio
│   ├── run_tuning.jl                 Bayesian hyperparameter search
│   ├── run_live.jl                   Live monitoring
│   └── run_single_model.jl           Debug individual model
├── src/                              108 source files
│   ├── core/                         Types, constants, config, RALPH, logger
│   ├── security/                     Encrypted vault (SHA-256 PBKDF2)
│   ├── data/                         Ingestion, features, feeds, sanitization, external signals
│   ├── nn/                           LSTM, GRU, MLP, tree primitives, weight cache
│   ├── models/                       33 models (m01-m33) + 2 studies
│   ├── reporting/                    Composite, charts, PDF, trade plan, ensemble optimizer
│   ├── orchestrator/                 Model dispatch + strategy engine
│   ├── execution/                    Paper, Alpaca, Polymarket exchanges + audit
│   ├── risk/                         Circuit breakers, position tracking, portfolio optimizer
│   ├── pipeline/                     Types, config, triggers, steps, executor, loop, event bus
│   ├── decision/                     Aggressive + conservative strategies
│   ├── instruments/                  Stock, crypto, polymarket instruments
│   ├── scanner/                      Multi-ticker scanner
│   ├── tuning/                       Bayesian optimization + search spaces
│   ├── storage/                      SQLite database + queries
│   ├── monitoring/                   Health server + Telegram alerts
│   └── backtest/                     Walk-forward engine + Polymarket backtest
└── test/                             28 test files, 1,229 tests
```

---

## 3. The 33-Model Ensemble

| # | Model | Category | What It Computes |
|---|-------|----------|-----------------|
| 1 | LSTM | Deep Learning | Sequential price patterns (cached) |
| 2 | GRU | Deep Learning | Simplified sequential patterns (cached) |
| 3 | Helformer | Deep Learning | Transformer+LSTM+Holt-Winters hybrid (cached) |
| 4 | LSTM-GARCH | Hybrid | Sequence learning + volatility (Phase 2) |
| 5 | Random Forest | ML | 100-tree ensemble with CPCV accuracy |
| 6 | LightGBM | ML | Gradient boosting with CPCV accuracy |
| 7 | XGBoost | ML | Regularized boosting with CPCV accuracy |
| 8 | Conv-LSTM | Deep Learning | Spatial-temporal patterns (cached) |
| 9 | BiLSTM | Deep Learning | Bidirectional sequences (cached) |
| 10 | SGD | ML | Online learner for real-time adaptation |
| 11 | TFT | Deep Learning | Temporal Fusion Transformer (cached) |
| 12 | Ensemble Stack | ML | Stacks top models (Phase 2) |
| 13 | MLP | Deep Learning | Multi-layer perceptron (cached) |
| 14 | GARCH/EGARCH | Statistical | Volatility forecast (reparameterized, persistence < 1) |
| 15 | RL (DQN) | Reinforcement | Optimal buy/sell/hold policy |
| 16 | LMSR | Market Pricing | Prediction market pricing + slippage |
| 17 | Kelly Criterion | Position Sizing | Optimal bet size + Monte Carlo simulation |
| 18 | EV Gap | Expected Value | Probability mispricing detector (Phase 2) |
| 19 | KL-Divergence | Info Theory | Model vs market disagreement (Phase 2) |
| 20 | Bregman Projection | Info Theory | Optimal probability weights (Phase 2) |
| 21 | Bayesian Update | Probabilistic | Prior→posterior with 4 evidence sources (Phase 2) |
| 22 | Logistic Regression | Statistical | Continuation vs reversal detection |
| 23 | AR(1) | Statistical | Momentum vs mean-reversion regime |
| 24 | Black-Scholes | Derivatives | Options pricing + 5 Greeks |
| 25 | Crank-Nicolson FD | Derivatives | Numerical PDE for American options |
| 26 | Term Structure | Interest Rates | Nelson-Siegel yield curve + Vasicek |
| 27 | Martingale Detection | No-Arbitrage | Random walk test (Phase 2) |
| 28 | Meta-Labeling | Advanced ML | Bet/no-bet decision (Phase 2) |
| 29 | FracDiff Signal | Advanced ML | Fractional differentiation |
| 30 | Triple-Barrier | Advanced ML | Regime classification |
| 31 | **Kalman Filter** | Prediction Markets | Probability smoothing + shock detection |
| 32 | **Time Decay** | Prediction Markets | Volatility compression + convergence |
| 33 | **Cross-Market Arb** | Prediction Markets | Multi-platform spread detection |

---

## 4. What Is Fully Automated

### Runs Without Human Intervention

| Capability | How It Works |
|-----------|-------------|
| **Market monitoring** | 24/7 loop polls or receives WebSocket events for all watched assets |
| **Trigger detection** | Volume spikes, price jumps, orderbook imbalance, sentiment spikes auto-detected |
| **Signal generation** | 33 models run automatically per trigger, composite signal computed |
| **Trade decision** | Aggressive vs conservative strategies evaluated, orchestrator selects optimal blend |
| **Position sizing** | Kelly criterion + meta-labeling + GARCH volatility → dollar amount |
| **Order execution** | PaperExchange (simulated) or AlpacaExchange (real stocks) or PolymarketExchange (real prediction markets) |
| **Risk management** | Circuit breakers halt trading on daily loss, drawdown, or consecutive losses |
| **Position monitoring** | Stop-loss, take-profit, and time-based exits checked every iteration |
| **Data persistence** | Every trade, equity snapshot, and model result saved to SQLite |
| **Session resume** | On restart, loads last bankroll and trade history from database |
| **Weight caching** | NN models train once, cache weights to JLD2, skip training on subsequent runs |
| **Audit trail** | Every decision logged to immutable JSONL files with daily rotation |
| **Alerting** | Telegram notifications for trades, circuit breakers, and errors |
| **Health monitoring** | HTTP /health and /metrics endpoints for external monitoring |

### Runs On Demand

| Capability | Command |
|-----------|---------|
| Full 33-model analysis | `julia bin/run_analysis.jl AAPL` |
| Walk-forward backtest | `julia bin/run_backtest.jl BTC-USD --fast` |
| Multi-ticker scan | `julia bin/run_scanner.jl watchlist.txt --portfolio` |
| Hyperparameter tuning | `julia bin/run_tuning.jl 7 AAPL --evals 50` |
| Prediction market backtest | Via `run_polymarket_backtest()` API |

---

## 5. Performance Architecture

### 5.1 Weight Caching (JLD2)

| Metric | Without Cache | With Cache |
|--------|--------------|------------|
| LSTM training | ~3 min | <100 ms |
| GRU training | ~2 min | <100 ms |
| All 7 NN models | ~12 min | <1 sec |
| Total analysis | ~15 min | ~3 min (first) / ~1 min (cached) |

**How it works:** After LBFGS optimization, the trained parameter vector θ and architecture shapes are serialized to `~/.quantengine/weights/weight_cache.jld2`. On subsequent runs for the same ticker, weights are loaded directly — skipping the expensive optimization entirely.

**Cache invalidation:** Entries expire after 7 days or when the training data hash changes (new data fetched).

### 5.2 Threaded Fast Models

Fast models (19 of them) now run in parallel via `Threads.@threads`. On a 12-core Mac, this provides ~4-8x speedup for the fast model phase.

Thread safety is guaranteed by the existing `ReentrantLock` in `AnalysisContext` — each model's `ralph()` call acquires the lock to write results.

### 5.3 Event-Driven Pipeline

The `PipelineEventBus` uses a bounded `Channel{PipelineEvent}` for real-time event delivery:

- WebSocket price callbacks → check triggers → `emit_event!()` if triggered
- X/Twitter sentiment callbacks → emit `:sentiment_spike` on high sentiment
- Main loop calls `take_event!(timeout=poll_interval)` instead of `sleep()`
- Falls back to polling when no events arrive within the timeout

**Result:** Sub-second reaction to market events vs 5-second polling intervals.

---

## 6. Security Architecture

### Defense-in-Depth (12 Layers)

| Layer | Component | What It Prevents |
|-------|-----------|-----------------|
| 1 | Input Validation | Ticker injection, URL manipulation |
| 2 | Data Sanitizer | NaN/Inf/negative prices entering pipeline |
| 3 | RALPH Wrapper | Model failures crashing the system |
| 4 | Hard Pipeline Gates | Trading on uncalibrated or negative-EV signals |
| 5 | Circuit Breakers | Exceeding daily loss, drawdown, or position limits |
| 6 | Execution Mode Guard | Accidental real-money trading (PAPER/LIVE enum) |
| 7 | Rate Limiter | API bans from excessive requests |
| 8 | Audit Logger | Untracked decisions (rotating JSONL, 50MB limit) |
| 9 | File Permissions | Unauthorized access (0o700 dirs, 0o600 files) |
| 10 | Encrypted Vault | API key exposure (SHA-256 PBKDF2, 50K rounds) |
| 11 | Structured Logging | Undetected errors (JSON to stderr) |
| 12 | Telegram Alerts | Missed critical events (rate-limited, level-filtered) |

---

## 7. Prediction Market Capabilities

### Complete Polymarket Trading Stack

| Layer | Component | Status |
|-------|-----------|--------|
| **Data** | `fetch_polymarket_data(slug)` | Live via Gamma API |
| **Smoothing** | Kalman Filter (m31) | Extracts true probability from noise |
| **Pricing** | LMSR (m16) | Models market maker behavior |
| **Mispricing** | EV Gap (m18) | Detects probability mispricing |
| **Timing** | Time Decay (m32) | Optimal entry/exit based on expiry |
| **Arbitrage** | Cross-Market Arb (m33) | Multi-platform spread detection |
| **Sizing** | Kelly Criterion (m17) | Optimal bet fraction |
| **Evidence** | Bayesian Update (m21) | Integrates tweets + polls + FRED data |
| **Execution** | PolymarketExchange | Paper + live CLOB order placement |
| **Backtest** | Polymarket Backtest | Synthetic + CSV historical data |
| **External Data** | FRED + Polls | Economic indicators as model inputs |

### Cross-Market Arbitrage Flow

```
Polymarket (YES=$0.55) ──┐
                         ├── detect_arbitrage() → net_spread = $0.12
Kalshi     (YES=$0.68) ──┘                       → BUY Poly, SELL Kalshi
```

---

## 8. What Can Be Improved

### 8.1 High Impact

| Improvement | Current State | What It Would Do |
|------------|--------------|-----------------|
| **GPU acceleration** | CPU-only LBFGS via Optim.jl | Flux.jl/Lux.jl + CUDA → 100x NN training speed |
| **Order flow features** | 11 features (price-based only) | Add bid/ask spread, book depth, trade imbalance as features 12-14 |
| **FinBERT sentiment** | Keyword-based scorer (22 bull + 21 bear words) | Fine-tuned financial language model for sarcasm, context, complex sentiment |
| **Walk-forward retraining** | Models train once per analysis | Incremental weight updates with each new day's data |
| **Options execution** | Black-Scholes + Crank-Nicolson price models exist | No order routing to options exchanges — add IBKR or Tastytrade adapter |

### 8.2 Medium Impact

| Improvement | Current State | What It Would Do |
|------------|--------------|-----------------|
| **Web dashboard** | Console-only + Prometheus metrics | Real-time UI via Genie.jl: positions, equity curve, model signals |
| **Slack/Discord alerts** | Telegram only | Multi-channel alerting for team trading operations |
| **Config hot-reload** | Restart required to change PipelineConfig | Watch config file, reload on modification without pipeline restart |
| **Model A/B testing** | Single ensemble configuration | Run two configs simultaneously, compare live performance |
| **Cross-asset correlation** | Each asset analyzed in isolation | BTC-SPY correlation, sector rotation, VIX regime as features |
| **Historical Polymarket OHLCV** | Synthetic data or CSV only | Direct API for historical prices (Polymarket doesn't provide this yet) |

### 8.3 Architecture Refinements

| Improvement | Current State | What It Would Do |
|------------|--------------|-----------------|
| **Formal ModelOutput type** | Each model returns slightly different NamedTuple | Standardized struct all 33 models return, eliminating runtime type checks |
| **Plugin model architecture** | Adding a model requires editing 3 files | `@register_model` macro for self-registering models |
| **Nested config structs** | Flat PipelineConfig with 18 fields | `TriggerConfig`, `RiskConfig`, `KellyConfig` hierarchy |
| **Typed results dict** | `ctx.results::Dict{String, Any}` | `StructArray` or typed container eliminating `hasproperty` checks |
| **Separate data/analysis** | `prepare_context` fetches + computes features | Split into `fetch_data()` → `DataBundle` → `prepare_features()` for caching |

### 8.4 Testing & Reliability

| Improvement | Current State | What It Would Do |
|------------|--------------|-----------------|
| **Integration tests** | All tests use synthetic data | Nightly CI with real market data (validate format, not predictions) |
| **Property-based testing** | Manual test cases | `Supposition.jl` for random inputs + invariant checking |
| **Benchmark regression** | No performance tracking | Fail CI if critical function slows >20% |
| **Mutation testing** | Standard assertions only | Verify tests actually catch bugs by mutating source code |

---

## 9. Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `QE_EXECUTION_MODE` | `PAPER` | Must be explicit `LIVE` for real trading |
| `QE_INITIAL_BANKROLL` | `2000` | Starting capital ($) |
| `QE_MAX_POSITION_PCT` | `0.10` | Max 10% per position |
| `QE_MAX_DAILY_LOSS_PCT` | `0.05` | Halt after 5% daily loss |
| `QE_MAX_DRAWDOWN_PCT` | `0.15` | Halt after 15% drawdown |
| `QE_MAX_CONCURRENT_POS` | `5` | Max open positions |
| `QE_POLL_INTERVAL_MS` | `5000` | Polling interval (ms) |
| `QE_FORCE_CONSERVATIVE` | `false` | Conservative-only mode |
| `QE_COOLING_PERIOD` | `10` | Iterations after 3+ losses |
| `QE_EV_GAP_MIN` | `0.05` | Minimum EV for trade (5%) |
| `QE_KELLY_MIN_FRAC` | `0.25` | Kelly lower bound |
| `QE_KELLY_MAX_FRAC` | `0.50` | Kelly upper bound |
| `QE_ALPACA_API_KEY` | — | Alpaca API key |
| `QE_ALPACA_SECRET_KEY` | — | Alpaca secret key |
| `QE_POLYMARKET_API_KEY` | — | Polymarket CLOB key |
| `QE_POLYMARKET_SECRET` | — | Polymarket CLOB secret |
| `QE_POLYGON_API_KEY` | — | Polygon.io WebSocket key |
| `QE_X_BEARER_TOKEN` | — | X/Twitter stream token |
| `QE_FRED_API_KEY` | — | FRED economic data key |
| `QE_TELEGRAM_BOT_TOKEN` | — | Telegram alert bot token |
| `QE_TELEGRAM_CHAT_ID` | — | Telegram alert chat ID |
| `QE_VAULT_TYPE` | `env` | `env` or `encrypted` |
| `QE_VAULT_MASTER_KEY` | — | Encrypted vault master key |

---

## 10. Deployment

### Docker
```bash
docker compose up -d
curl localhost:8080/health
curl localhost:8080/metrics
```

### systemd
```bash
sudo cp deploy/quantengine.service /etc/systemd/system/
sudo systemctl enable --now quantengine
journalctl -u quantengine -f
```

### Local Development
```bash
julia --project=. -t auto bin/run_pipeline.jl BTC-USD,AAPL
julia --project=. bin/run_analysis.jl AAPL
julia --project=. bin/run_backtest.jl AAPL --fast
julia --project=. bin/run_scanner.jl watchlist.txt --portfolio --capital 50000
julia --project=. bin/run_tuning.jl 7 AAPL --evals 50
```

---

## 11. Dependencies

All pure Julia. No Python. No binary ML frameworks. No GPU required.

| Package | Purpose |
|---------|---------|
| HTTP | REST APIs, WebSocket, health server |
| JSON | Data parsing, audit logs, vault |
| SQLite | Trade persistence, session resume |
| JLD2 | Weight cache serialization |
| Optim | LBFGS optimization (NN training, ensemble weights, GARCH) |
| Plots | Chart generation (9 dashboards, backtest equity curves) |
| Luxor | PDF report generation |
| StatsBase | Advanced statistics |
| SpecialFunctions | erf for Black-Scholes, Bayesian |
| Distributed | Multi-process NN parallelism |
| Statistics | Basic statistics |
| LinearAlgebra | Matrix operations |

---

*Generated March 17, 2026 — QuantEngine v2.0 (33-Model Engine, 1,229 tests)*
