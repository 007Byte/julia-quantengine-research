# QuantEngine — Production Specification

**Version:** 7.1 (Launch Hardened + Signal Cards + Live L2 + Sentiment v2)
**Date:** March 17, 2026
**Language:** Julia 1.12
**Codebase:** ~17,500 lines source | ~5,000 lines tests | ~130 source files | 37 test suites | 1,561 tests | 0 failures

---

## 1. What This System Is

QuantEngine is an autonomous quantitative trading system for stocks, crypto, and prediction markets. It uses a 34-model ensemble with 18 features, adapts model selection per asset per regime, sizes positions with cost-adjusted loss-averse Kelly criterion, and continuously learns from outcomes. The system is built for **survival first, profit second**.

**Three asset classes, three exchanges:**

| Asset Class | Data | Execution | Real-Time Feed |
|------------|------|-----------|----------------|
| Stocks | Yahoo Finance | Alpaca REST API v2 | Polygon.io WebSocket |
| Crypto | Yahoo Finance | Future adapter | Binance WebSocket |
| Prediction Markets | Polymarket API | Polymarket CLOB | X/Twitter Stream |

---

## 2. Core Design Principles

| Principle | How It's Enforced |
|-----------|-------------------|
| **Never chase losses** | Dynamic throttle hard-capped at Kelly × 1.0. Behind schedule → reduce, never increase. |
| **Costs are real** | Realistic slippage hardcoded per asset. Crypto: 61 bps RT. Polymarket: 401 bps RT. Cannot be disabled. |
| **Prove before trust** | 500+ out-of-sample trades before model promotion/demotion. 55% confidence floor. |
| **Protect capital** | 2% max daily risk. 12 defense layers. Circuit breakers non-overridable. |
| **Validate before live** | CPCV backtest + regime split + Monte Carlo stress test must ALL pass. |
| **Realistic expectations** | Goal projections: 11% / 34% / 72% annual (not fantasy). 5-year horizon. |

---

## 3. Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│                  MINUTE DATA INGESTION                            │
│  Binance WS · Polygon WS · X Stream · Yahoo · FRED · Polymarket  │
│  Binance L2 · Polymarket CLOB · MinuteDataManager (24h windows)  │
└──────────────────────────┬────────────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────────────┐
│              DATA PROFILING + COST GATE                           │
│  profile_data() → regime, vol, momentum, CVD signal               │
│  realistic_costs() → slippage + fees + spread per asset class     │
│  minimum_edge_required() → reject trades below cost threshold     │
└──────────────────────────┬────────────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────────────┐
│           ADAPTIVE MODEL SELECTION (500-trade proven)             │
│  select_models(profile) → optimal subset (6-20 of 34 models)     │
│  55% confidence floor · Core models NEVER demoted                │
│  5 strategies: trend_follow · mean_revert · arb · mm · event     │
└──────────────────────────┬────────────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────────────┐
│                    18-FEATURE MATRIX                              │
│  Returns(5) · Vol · VolChg · RSI · Mom · FracDiff(2)              │
│  Spread · OrderImbalance · TradeVelocity                          │
│  DepthImbalance · BookPressure · SpreadBps · CVD_Divergence       │
└──────────────────────────┬────────────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────────────┐
│           SELECTED MODELS + POLYMARKET QUANT LAYER                │
│  7 NN (JLD2 cached) · 22 fast (threaded) · 8 dependent           │
│  Polymarket: Bayesian blend · Calibration · Fee-aware EV          │
│  Binary Kelly · Logit edge · Fee-zone filter · Instant screener   │
│  Plugin registry for m35+ (zero-edit extensibility)              │
└──────────────────────────┬────────────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────────────┐
│       ORCHESTRATOR (11 Rules) + LOSS-AVERSE THROTTLE             │
│  Kelly capped at 1.0 · 2% daily risk cap · Never chases losses   │
│  Correlation-adjusted · Behind schedule → conservative NOT aggressive │
└──────────────────────────┬────────────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────────────┐
│    EXECUTION + MM (adverse selection guarded)                     │
│  Paper · Alpaca · Polymarket CLOB                                 │
│  MM: inventory hard limits + auto-unwind + CVD/pressure check     │
│  All trades must clear minimum_edge_required() after costs        │
└──────────────────────────┬────────────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────────────┐
│            CONTINUOUS LEARNING (conservative)                     │
│  Retrain NN every 24h · Calibration every 10 trades               │
│  500-trade minimum before adaptation · A/B test with auto-promote │
│  Goal tracker with realistic projections                          │
└──────────────────────────┬────────────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────────────┐
│            PERSISTENCE + MONITORING                               │
│  SQLite · JSONL audit · JLD2 weights · Telegram · /health         │
│  Structured JSON logging · Session resume                         │
└───────────────────────────────────────────────────────────────────┘
```

---

## 4. The 34-Model Ensemble

| # | Model | Category | Key Feature |
|---|-------|----------|-------------|
| 1 | LSTM | Deep Learning | JLD2 weight-cached |
| 2 | GRU | Deep Learning | JLD2 weight-cached |
| 3 | Helformer | Deep Learning | Transformer+LSTM+HW, cached |
| 4 | LSTM-GARCH | Hybrid | Phase 2 |
| 5 | Random Forest | ML | CPCV accuracy |
| 6 | LightGBM | ML | CPCV accuracy |
| 7 | XGBoost | ML | CPCV accuracy |
| 8 | Conv-LSTM | Deep Learning | Cached |
| 9 | BiLSTM | Deep Learning | Cached |
| 10 | SGD | ML | Online learner |
| 11 | TFT | Deep Learning | Cached |
| 12 | Ensemble Stack | ML | Phase 2 |
| 13 | MLP | Deep Learning | Cached |
| 14 | GARCH/EGARCH | Statistical | Reparameterized (persistence < 1) |
| 15 | RL (DQN) | Reinforcement | Optimal policy |
| 16 | LMSR | Market Pricing | Polymarket pricing |
| 17 | Kelly Criterion | Sizing | Regime-aware + cost-adjusted |
| 18 | EV Gap | Mispricing | Dynamic threshold + slippage |
| 19 | KL-Divergence | Info Theory | Phase 2 |
| 20 | Bregman Projection | Info Theory | Phase 2 |
| 21 | Bayesian Update | Probabilistic | 4 evidence sources + tweets + FRED |
| 22 | Logistic Regression | Statistical | Continuation/reversal |
| 23 | AR(1) | Statistical | Regime detection |
| 24 | Black-Scholes | Derivatives | Options + 5 Greeks |
| 25 | Crank-Nicolson FD | Derivatives | American options |
| 26 | Term Structure | Interest Rates | Nelson-Siegel + Vasicek |
| 27 | Martingale Detection | No-Arbitrage | Phase 2 |
| 28 | Meta-Labeling | Advanced ML | Bet/no-bet (Lopez de Prado) |
| 29 | FracDiff Signal | Advanced ML | Memory-preserving |
| 30 | Triple-Barrier | Advanced ML | Regime classification |
| 31 | Kalman Filter | Prediction Markets | Probability smoothing |
| 32 | Time Decay | Prediction Markets | Volatility compression |
| 33 | Cross-Market Arb | Prediction Markets | Multi-platform spreads |
| 34 | Momentum-Sentiment | Plugin Example | 5-day momentum + tweet fusion |

---

## 5. The 18-Feature Matrix

| # | Feature | Type |
|---|---------|------|
| 1-5 | Return lags (t through t-4) | Price |
| 6 | Vol(20) | Volatility |
| 7 | VolChg | Volume |
| 8 | RSI(14) | Momentum |
| 9 | Mom(10) | Momentum |
| 10-11 | FracDiff(price, logprice) | Memory (Lopez de Prado) |
| 12 | Spread(HL) | Microstructure |
| 13 | OrderImbalance | Microstructure |
| 14 | TradeVelocity | Microstructure |
| 15 | DepthImbalance | L2 Order Book |
| 16 | BookPressure | L2 Order Book |
| 17 | SpreadBps | L2 Order Book |
| 18 | CVD_Divergence | Cumulative Volume Delta |

---

## 6. Realistic Transaction Costs (Non-Disableable)

| Asset | Fee | Slippage | Spread | Round-Trip | Min Edge |
|-------|-----|----------|--------|-----------|----------|
| **Stocks** | 1 bps | 5 bps | 3 bps | 18 bps | 0.27% |
| **Crypto** | 10 bps | 15 bps | 5 bps | 61 bps | 0.92% |
| **Polymarket** | 50 bps | 100 bps | 50 bps | 401 bps | 6.02% |

Every EV calculation, Kelly sizing, and backtest applies these costs. Polymarket needs **6%+ edge** to be profitable. The system enforces this.

---

## 7. Loss-Averse Dynamic Throttle

Kelly scale is **hard-capped at 1.0** (never more aggressive than baseline). Maximum daily risk: **2%** (non-overridable).

| Condition | Kelly Scale | Behavior |
|-----------|------------|----------|
| Drawdown > 15% | × 0.15 | Survival mode |
| Drawdown 10-15% | × 0.25 | Emergency conservative |
| Drawdown 5-10% | × 0.50 | Reduced sizing |
| Any loss | × 0.75 | Conservative |
| Behind schedule | × 0.85 | Conservative (NOT chasing) |
| On track | × 1.00 | Normal |
| Strong growth | × 0.60 | Protect gains |
| 3x+ initial | Additional × 0.85 | Protecting compound |
| 10x+ initial | Additional × 0.80 | Strong protection |

---

## 8. Three-Gate Validation (Must All Pass)

### Gate 1: CPCV Backtest

`run_cpcv_backtest(ticker)` — C(6,2)=15 purged folds, 10-bar purge, 5-bar embargo. All returns cost-adjusted.

**Blocks launch if:** any fold negative, overall Sharpe < 1.0, or < 20 trades.

### Gate 2: Regime-Split Backtest

`run_regime_backtest(ticker)` — separate walk-forward in bull/bear/high_vol/low_vol.

**Blocks launch if:** any regime has negative returns.

### Gate 3: Monte Carlo Stress Test

`run_stress_test(returns)` — 1,000 paths with fat tails (2% chance of 3-6σ crashes).

**Blocks launch if:** survival < 95%, median unprofitable, or 95th percentile DD > 15%.

### Automated Pre-Flight

```bash
julia --project=. -t auto bin/run_preflight.jl BTC-USD,ETH-USD
```

Runs all three gates + cost sanity check. Prints CLEARED or FAILED with reasons.

---

## 9. Hardened Adaptive Selection

| Parameter | Value |
|-----------|-------|
| Min trades for adapt | **500** |
| Confidence floor | **55%** |
| Core protected | 14, 17, 18, 21, 22, 23 (never demoted) |
| Below floor fallback | Core models only |
| Audit | Full JSON logging of every selection |

---

## 10. Market-Making Safety

| Guard | Trigger | Action |
|-------|---------|--------|
| Adverse selection | Long + bearish CVD | Stop buying |
| Adverse selection | Short + bullish CVD | Stop selling |
| Strong flow | |pressure| > 0.6 | Pause MM |
| Inventory warning | > 80% of max | Reduce quotes |
| Inventory breach | > max (500 shares) | Auto-unwind to 50% |

---

## 11. Goal Tracker (Realistic)

| Scenario | Annual Return | $10K → $10M |
|----------|--------------|-------------|
| Conservative | 11% (index fund) | 62 years |
| Base Case | 34% (good quant) | 24 years |
| Optimistic | 72% (exceptional) | 13 years |

Required daily return uses **5-year horizon**. System never generates unrealistic urgency.

---

## 12. Security (12 Defense Layers)

| # | Layer | Protection |
|---|-------|-----------|
| 1 | Input Validation | Injection prevention |
| 2 | Data Sanitizer | NaN/Inf/negative |
| 3 | RALPH Wrapper | Model crash isolation |
| 4 | Hard Pipeline Gates | Negative-EV prevention |
| 5 | Circuit Breakers | Loss/drawdown/position limits |
| 6 | Execution Mode Guard | PAPER/LIVE enum |
| 7 | Rate Limiter | API compliance |
| 8 | Audit Logger | Decision trail (rotating JSONL) |
| 9 | File Permissions | 0o700/0o600 |
| 10 | Encrypted Vault | SHA-256 PBKDF2, 50K rounds |
| 11 | Structured Logging | JSON error detection |
| 12 | Telegram Alerts | Critical events + correlation |

---

## 13. Launch Procedure

```bash
# Step 1: Pre-flight validation (all gates must pass)
julia --project=. -t auto bin/run_preflight.jl BTC-USD,ETH-USD

# Step 2: Paper trading (minimum 30 days, 500+ trades)
QE_EXECUTION_MODE=PAPER QE_FORCE_CONSERVATIVE=true QE_INITIAL_BANKROLL=10000 \
julia --project=. -t auto bin/run_pipeline.jl BTC-USD,ETH-USD

# Step 3: Small live (one asset, minimum Kelly, after paper validates)
QE_EXECUTION_MODE=LIVE QE_FORCE_CONSERVATIVE=true QE_INITIAL_BANKROLL=5000 \
QE_KELLY_MAX_FRAC=0.15 \
julia --project=. -t auto bin/run_pipeline.jl BTC-USD

# Step 4: Scale (after 14+ days positive live equity)
QE_EXECUTION_MODE=LIVE QE_FORCE_CONSERVATIVE=true QE_INITIAL_BANKROLL=25000 \
QE_KELLY_MAX_FRAC=0.20 \
julia --project=. -t auto bin/run_pipeline.jl BTC-USD,ETH-USD
```

---

## 14. Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `QE_EXECUTION_MODE` | `PAPER` | Must be explicit `LIVE` |
| `QE_INITIAL_BANKROLL` | `2000` | Starting capital |
| `QE_MAX_POSITION_PCT` | `0.10` | Max 10% per position |
| `QE_MAX_DAILY_LOSS_PCT` | `0.05` | Halt after 5% daily loss |
| `QE_MAX_DRAWDOWN_PCT` | `0.15` | Halt after 15% drawdown |
| `QE_MAX_CONCURRENT_POS` | `5` | Max open positions |
| `QE_FORCE_CONSERVATIVE` | `false` | Conservative-only mode |
| `QE_KELLY_MAX_FRAC` | `0.50` | Kelly upper bound |
| `QE_ALPACA_API_KEY` | — | Alpaca trading |
| `QE_POLYMARKET_API_KEY` | — | Polymarket CLOB |
| `QE_POLYGON_API_KEY` | — | Polygon.io WebSocket |
| `QE_X_BEARER_TOKEN` | — | X/Twitter stream |
| `QE_TELEGRAM_BOT_TOKEN` | — | Telegram alerts |

---

## 15. What Can Still Be Improved

| Priority | Item | Status |
|----------|------|--------|
| ~~High~~ | ~~Sentiment embeddings~~ | **DONE: `score_sentiment_v2()` with lexicon + phrases + negation + position weighting** |
| ~~High~~ | ~~Live L2 depth streaming~~ | **DONE: `LiveBookManager` with Binance/Polymarket polling feeds** |
| ~~High~~ | ~~Visual signal cards~~ | **DONE: `print_signal_card()` with ANSI colors, SL/TP1/TP2, recommendations** |
| High | Options execution (IBKR adapter) | Not built |
| Medium | Web dashboard (Genie.jl) | Not built |
| Low | Config hot-reload | Not built |
| Low | GPU support (Flux.jl) | Not built |

---

## 16. System Metrics

| Metric | Count |
|--------|-------|
| Models | 34 + plugin registry |
| Features | 18 |
| Tests | **1,561** |
| Test suites | 37 |
| Source files | ~130 |
| Source lines | ~17,500 |
| Test lines | ~5,000 |
| Exchanges | 3 |
| Data feeds | 7 + 2 order book + minute processor |
| Defense layers | 12 |
| Orchestrator rules | 11 |
| Strategy types | 5 |
| CLI scripts | 8 |
| Dependencies | 15 (all pure Julia) |
| Validation gates | 3 (CPCV + regime + Monte Carlo) |

---

## 17. Dependencies

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
| Statistics | Basic statistics |
| LinearAlgebra | Matrix operations |
| Dates | Timestamps |
| Printf | Formatted output |
| Random | Monte Carlo, sampling |

---

*Generated March 17, 2026 — QuantEngine v7.1*
*34 Models · 18 Features · 3 Exchanges · 1,561 Tests · 0 Failures*
*CPCV Validated · Stress Tested · Loss-Averse · Cost-Adjusted · Signal Cards · Live L2 · Survival First*
