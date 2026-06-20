# QuantEngine v4.0 — Technical Specification

**Date:** March 17, 2026
**Language:** Julia 1.12
**Codebase:** ~15,000 lines source | ~115 files | 1,386 tests | 0 failures

---

## 1. What QuantEngine Is

QuantEngine is a fully autonomous quantitative trading system that monitors stocks, crypto, and prediction markets using a **34-model mathematical ensemble** with **17 engineered features**. It detects probability mispricings, sizes positions using cost-adjusted regime-aware Kelly criterion, executes trades across three exchanges, makes markets on liquid Polymarket contracts, manages risk through 12 defense-in-depth layers with correlation-aware portfolio controls, and reports results — all without human intervention.

---

## 2. What Changed: v3 → v4

| Feature | v3 | v4 |
|---------|----|----|
| Models | 33 | **34** (+ m34 Momentum-Sentiment Fusion via plugin) |
| Features | 14 | **17** (+ depth imbalance, book pressure, spread bps) |
| Orchestrator rules | 10 | **11** (+ correlation-adjusted sizing) |
| Market making | Module exists, not activated | **Live in pipeline loop** |
| Plugin system | Infrastructure only | **m31-m34 registered, fallback routing in run_model** |
| Correlation alerts | Not wired | **Active in loop, Telegram alerts at corr > 0.7** |

---

## 3. Architecture

```
┌───────────────────────────────────────────────────────────────────────┐
│                           DATA SOURCES                                │
│  Yahoo · Polymarket · Binance WS · Polygon WS · X Stream · FRED      │
│  Binance L2 Order Book · Polymarket CLOB Order Book                   │
└────────────────────────────┬──────────────────────────────────────────┘
                             │
┌────────────────────────────▼──────────────────────────────────────────┐
│                    17-FEATURE MATRIX                                   │
│  Returns(5) · Vol · VolChg · RSI · Momentum · FracDiff(2)             │
│  Spread · OrderImbalance · TradeVelocity                              │
│  DepthImbalance · BookPressure · SpreadBps                            │
└────────────────────────────┬──────────────────────────────────────────┘
                             │
┌────────────────────────────▼──────────────────────────────────────────┐
│                    34-MODEL ENSEMBLE                                  │
│                                                                       │
│  Phase 1A: 22 fast models (threaded)                                  │
│    ML: RF(CPCV), LightGBM(CPCV), XGBoost(CPCV), SGD                  │
│    Statistical: GARCH, Logistic, AR(1), Martingale                    │
│    Derivatives: Black-Scholes, Crank-Nicolson, Term Structure         │
│    Sizing: Kelly(regime+cost), EV Gap(dynamic), LMSR                  │
│    Advanced ML: FracDiff, Triple-Barrier, RL(DQN)                     │
│    Prediction Markets: Kalman, Time Decay, Cross-Market Arb           │
│    Plugin: m34 Momentum-Sentiment Fusion                              │
│                                                                       │
│  Phase 1B: 7 heavy NN models (workers, JLD2 weight-cached)           │
│    LSTM, GRU, Helformer, Conv-LSTM, BiLSTM, TFT, MLP                 │
│                                                                       │
│  Phase 2: 8 dependent models                                         │
│    LSTM-GARCH, Ensemble Stack, EV Gap, KL-Div, Bregman,              │
│    Bayesian(+tweets+FRED), Martingale, Meta-Labeling                  │
│                                                                       │
│  + Polymarket Quant Layer:                                            │
│    Bayesian blend · Fee-aware EV · Binary Kelly · Logit edge          │
│    Calibration table · Fee-zone filter · Instant screener             │
│                                                                       │
│  + Plugin Registry: register_model!(id, name, phase, fn)             │
└────────────────────────────┬──────────────────────────────────────────┘
                             │
┌────────────────────────────▼──────────────────────────────────────────┐
│          ORCHESTRATOR (11 Rules)                                      │
│                                                                       │
│   1. Portfolio heat > 70% → conservative                              │
│   2. Daily loss approaching limit → conservative                      │
│   3. Drawdown > 80% of max → SKIP                                    │
│   4. Volatile + high KL → conservative                                │
│   5. Trending regime → lean aggressive                                │
│   6. Force conservative override                                      │
│   7. Cooling period → conservative                                    │
│   8. Strategies disagree → SKIP                                       │
│   9. Both HOLD + strong signal → force conservative buy               │
│  10. High edge + good calibration → boost aggressive                  │
│  11. Correlation risk > 0.7 → conservative; > 0.4 → scale down       │
└────────────────────────────┬──────────────────────────────────────────┘
                             │
┌────────────────────────────▼──────────────────────────────────────────┐
│            EXECUTION + MARKET MAKING + RISK                           │
│                                                                       │
│  Exchanges: Paper · Alpaca · Polymarket CLOB                          │
│  Market Making: Auto-quotes on liquid Polymarket contracts             │
│    compute_mm_quotes() → inventory-adjusted bid/ask                   │
│    should_market_make() → volume/spread/probability gate              │
│  Risk: 12 layers + CorrelationTracker + portfolio_correlation_risk    │
│  Persistence: SQLite + JSONL audit + JLD2 weights                     │
│  Alerts: Telegram (trades, circuit breakers, correlation warnings)    │
│  Monitoring: /health + /metrics (Prometheus)                          │
│  A/B Testing: Dual ensemble with auto-promotion                       │
└───────────────────────────────────────────────────────────────────────┘
```

---

## 4. The 34-Model Ensemble

### Models 1-30 (Core)

| # | Model | Category | Key Enhancement |
|---|-------|----------|----------------|
| 1-3 | LSTM, GRU, Helformer | Deep Learning | JLD2 weight cache (12 min → <1 sec) |
| 5-7 | RF, LightGBM, XGBoost | ML | CPCV accuracy + 17-feature input |
| 8-9 | Conv-LSTM, BiLSTM | Deep Learning | JLD2 weight cache |
| 11,13 | TFT, MLP | Deep Learning | JLD2 weight cache |
| 14 | GARCH/EGARCH | Statistical | Reparameterized (persistence < 1.0) |
| 17 | Kelly Criterion | Sizing | Regime-aware + cost-adjusted |
| 18 | EV Gap | Mispricing | Dynamic threshold + slippage |
| 21 | Bayesian Update | Probabilistic | 4 evidence sources + tweets + FRED |
| 28 | Meta-Labeling | Advanced ML | Reduced overfitting (15 trees, depth 2) |

### Models 31-34 (Prediction Markets + Plugin)

| # | Model | What It Does | Registration |
|---|-------|-------------|-------------|
| 31 | Kalman Filter | Smooths noisy probabilities, shock detection | MODEL_DISPATCH + plugin registry |
| 32 | Time Decay | Volatility compression near expiry | MODEL_DISPATCH + plugin registry |
| 33 | Cross-Market Arb | Multi-platform spread detection | MODEL_DISPATCH + plugin registry |
| 34 | Momentum-Sentiment Fusion | 5-day momentum + tweet sentiment | **Plugin registry only** |

### Plugin System Usage

```julia
# Register a new model (no edits to runner.jl or constants.jl needed):
register_model!(35, "My Custom Model", :fast,
    (ctx) -> (probability=0.6, accuracy=0.55, direction="UP", model="Custom"))

# run_model automatically checks plugin registry as fallback
run_model(ctx, 35; verbose=true)  # works immediately
```

---

## 5. The 17-Feature Matrix

| # | Feature | Type | Source |
|---|---------|------|--------|
| 1-5 | Return lags | Price | returns[t] through returns[t-4] |
| 6 | Vol(20) | Volatility | 20-day rolling std |
| 7 | VolChg | Volume | Volume change ratio |
| 8 | RSI(14) | Momentum | Relative Strength Index |
| 9 | Mom(10) | Momentum | 10-day return sum |
| 10-11 | FracDiff | Memory | Fractional differentiation (Lopez de Prado) |
| 12 | Spread(HL) | Microstructure | (High - Low) / Price |
| 13 | OrderImbalance | Microstructure | Volume-weighted price momentum |
| 14 | TradeVelocity | Microstructure | Volume acceleration |
| **15** | **DepthImbalance** | **L2 Order Book** | **(bid_depth - ask_depth) / total** |
| **16** | **BookPressure** | **L2 Order Book** | **Depth imbalance × large-order amplifier** |
| **17** | **SpreadBps** | **L2 Order Book** | **Bid-ask spread in basis points** |

Features 15-17 activate when L2 order book data is passed via `compute_features(; book_features=...)`. Default to 0 in historical/backtest mode.

---

## 6. What Is Fully Automated

| Capability | How |
|-----------|-----|
| Market monitoring | Event-driven loop (WebSocket + polling fallback) |
| 34-model signal generation | Threaded fast models + cached heavy models |
| Correlation-aware sizing | Rule 11 reduces Kelly when correlated with positions |
| Market making | Auto-quotes on liquid Polymarket contracts every 50 iterations |
| Correlation alerts | Telegram warning when portfolio correlation > 0.7 |
| Position management | Stop-loss, take-profit, time exits + correlation monitoring |
| Session persistence | SQLite resume + JLD2 weight cache |
| A/B testing | Dual ensemble tracking with auto-promotion |
| Audit trail | Immutable JSONL + structured JSON logging |

---

## 7. Market-Making (Activated)

The market-making module now runs inside `run_money_printer()`:

```
Every 50 iterations:
  For each Polymarket asset:
    1. Fetch current price + volume
    2. should_market_make(volume, spread, price) → gate check
    3. If profitable:
       compute_mm_quotes(fair_prob, fee, inventory)
       → Inventory-adjusted bid/ask
       → Print quote if edge > 0.1¢/share
```

**Gate conditions (all must pass):**
- Volume > 10,000 (liquid enough)
- Spread > 2¢ (wide enough to profit)
- Price between 5¢ and 95¢ (not near resolution)

**Inventory management:**
- Long inventory → lower bid (less buying), raise ask (encourage selling)
- Size scales down as inventory approaches max (500 shares default)

---

## 8. Correlation-Aware Portfolio Risk

**CorrelationTracker** maintains a rolling 60-day correlation matrix across all traded assets.

**Pipeline integration (Rule 11):**
- `corr_risk > 0.7` → forces conservative mode + Telegram alert
- `corr_risk > 0.4` → scales down blend weight by `corr_risk × 30%`
- `corr_risk < 0.4` → no adjustment (positions are diversified)

**Example:** If you hold BTC-USD and try to add ETH-USD (historically ~0.8 correlation), the orchestrator automatically reduces position size to prevent concentrated crypto exposure.

---

## 9. Security (12 Defense Layers)

| # | Layer | What It Prevents |
|---|-------|-----------------|
| 1 | Input Validation | Ticker injection |
| 2 | Data Sanitizer | NaN/Inf/negative prices |
| 3 | RALPH Wrapper | Model crashes |
| 4 | Hard Pipeline Gates | Uncalibrated/negative-EV trades |
| 5 | Circuit Breakers | Daily loss, drawdown, position limits |
| 6 | Execution Mode Guard | PAPER/LIVE enum |
| 7 | Rate Limiter | API bans |
| 8 | Audit Logger | Untracked decisions |
| 9 | File Permissions | 0o700/0o600 |
| 10 | Encrypted Vault | SHA-256 PBKDF2, 50K rounds |
| 11 | Structured Logging | JSON to stderr |
| 12 | Telegram Alerts | Critical events + correlation warnings |

---

## 10. Polymarket Professional Stack

| Layer | Component | Edge |
|-------|-----------|------|
| Smoothing | Kalman Filter (m31) | Extract true probability from noise |
| Pricing | LMSR (m16) + fee curve | Accurate spread/slippage modeling |
| Mispricing | EV Gap (m18, dynamic) | Fee-aware, vol-scaled edge detection |
| Calibration | CalibrationTable | Auto-correct favorite-longshot bias |
| Timing | Time Decay (m32) | Optimal entry near expiry |
| Arbitrage | Cross-Market (m33) | Multi-platform spread detection |
| Sizing | Binary Kelly | `f* = (p - c) / (1 - c)` for $1/$0 contracts |
| Blending | Bayesian blend | Liquidity-weighted model↔market fusion |
| Filtering | Fee-zone quality | Avoid 45-55¢ fee death zone |
| Execution | PolymarketExchange | CLOB order placement |
| Market Making | MM module | Inventory-adjusted two-sided quotes |
| Screening | Instant screener | `p̂ > ask + fee + threshold` |

---

## 11. Test Coverage

**1,386 tests across 31 test suites:**

| Suite | What It Covers |
|-------|---------------|
| Input Validation | Ticker injection, ExecutionMode |
| Data Sanitizer | Price/volume/returns/OHLCV/Polymarket |
| Feature Engineering | 17-feature matrix, sequences |
| Composite Signal | Accuracy weighting, learned weights |
| Kelly Criterion | Regime awareness, cost adjustment |
| GARCH/EGARCH | Persistence < 1.0, forecast |
| Circuit Breakers | Cooling, exits, limits |
| Position Tracker | PnL, thread safety |
| Rate Limiter | Per-second/minute |
| Audit Logger | JSON Lines, rotation |
| FracDiff | Weights, ADF, find_min_d |
| CPCV | Purged splits, evaluate |
| RALPH | Retry, NaN handling |
| Backtest Engine | Folds, metrics, equity curve |
| Database | CRUD, resume, leaderboard |
| Alpaca Exchange | URL selection, keys |
| WebSocket Feeds | Binance messages, state, thread safety |
| Vault | Roundtrip, wrong key, permissions |
| X Stream | Negation sentiment, bigrams, buffer |
| Scanner & Portfolio | Allocation, diversification |
| Tuning | Bayesian opt, search spaces |
| Monitoring | Health JSON, Prometheus |
| Weight Cache | Store/retrieve, JLD2, staleness |
| Event Bus | Emit/take, timeout, concurrent |
| Ensemble Optimizer | Weight learning, composite integration |
| Alerts | Config, level filtering, rate limiting |
| Prediction Markets | Kalman, time decay, arb, Polymarket exchange |
| Profit Boosters | Microstructure, regime Kelly, dynamic EV, A/B testing |
| Polymarket Quant | Logit, fees, blend, calibration, binary Kelly, signals |
| Advanced Features | L2 orderbook, correlation, plugin registry, market-making |

---

## 12. Configuration

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
| `QE_KELLY_MIN_FRAC` / `MAX` | `0.25` / `0.50` | Kelly bounds |
| `QE_ALPACA_API_KEY` / `SECRET` | — | Alpaca stock trading |
| `QE_POLYMARKET_API_KEY` / `SECRET` | — | Polymarket CLOB |
| `QE_POLYGON_API_KEY` | — | Polygon.io WebSocket |
| `QE_X_BEARER_TOKEN` | — | X/Twitter stream |
| `QE_FRED_API_KEY` | — | FRED economic data |
| `QE_TELEGRAM_BOT_TOKEN` / `CHAT_ID` | — | Telegram alerts |
| `QE_VAULT_TYPE` / `MASTER_KEY` | `env` / — | Encrypted vault |

---

## 13. Deployment

```bash
# Docker
docker compose up -d
curl localhost:8080/health

# systemd
sudo systemctl enable --now quantengine

# Local (conservative mode for initial deployment)
QE_FORCE_CONSERVATIVE=true QE_INITIAL_BANKROLL=10000 \
julia --project=. -t auto bin/run_pipeline.jl BTC-USD,ETH-USD,AAPL

# Backtest before going live
julia --project=. bin/run_backtest.jl AAPL --fast --folds 8
julia --project=. bin/run_scanner.jl watchlist.txt --portfolio --capital 20000
```

---

## 14. What Can Still Be Improved

| Priority | Improvement | Expected Impact |
|----------|-------------|----------------|
| High | FinBERT sentiment (feature 18) | +5-15% p_true accuracy |
| High | Live Binance/Polymarket L2 depth as streaming features | Stronger real-time signals |
| High | Options execution (IBKR adapter) | New revenue stream |
| Medium | Web dashboard (Genie.jl) | Real-time monitoring UI |
| Medium | Incremental NN retraining (warm-start) | Faster regime adaptation |
| Medium | Config hot-reload (YAML watch) | No-restart parameter changes |
| Low | GPU support (Flux.jl + CUDA) | 100x NN training speed |
| Low | Formal ModelOutput type | Cleaner code, fewer runtime checks |

---

## 15. Dependencies

All pure Julia. No Python. No GPU required.

| Package | Purpose |
|---------|---------|
| HTTP | REST, WebSocket, health server |
| JSON | Parsing, audit, vault |
| SQLite | Persistence |
| JLD2 | Weight cache |
| Optim | LBFGS optimization |
| Plots | Charts |
| Luxor | PDF reports |
| StatsBase | Statistics |
| SpecialFunctions | Black-Scholes erf |
| Distributed | Multi-process NN |

---

*Generated March 17, 2026 — QuantEngine v4.0 (34 Models · 17 Features · 3 Exchanges · 1,386 Tests · 0 Failures)*
