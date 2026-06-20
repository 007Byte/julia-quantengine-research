# QuantEngine v7.0 — Production Specification

**Date:** March 17, 2026
**Language:** Julia 1.12
**Codebase:** ~18,500 lines source | ~135 files | 1,533 tests | 0 failures

---

## 1. Mission

QuantEngine is an autonomous quantitative trading system designed for long-term capital growth across stocks, crypto, and prediction markets. It uses a 34-model ensemble with 18 features, adapts its model selection per asset per regime, sizes positions conservatively using cost-adjusted Kelly criterion, and **never increases risk when losing**. The system is built for survival first, profit second.

---

## 2. Core Design Principles

| Principle | Implementation |
|-----------|---------------|
| **Never chase losses** | Dynamic throttle hard-capped at Kelly × 1.0. Losing → reduce, never increase. |
| **Costs are real** | Every EV, Kelly, and backtest calculation includes realistic slippage + fees + spread. |
| **Prove before trust** | 500+ out-of-sample trades required before any model gets promoted or demoted. |
| **Protect capital** | 2% max daily risk cap. 12 defense layers. Circuit breakers cannot be overridden. |
| **Realistic expectations** | Goal projections use 11%–72% annual (quant fund range), not fantasy returns. |

---

## 3. What Changed: v6 → v7 (Fatal Flaw Fixes)

| Fatal Flaw | v6 (Dangerous) | v7 (Fixed) |
|-----------|----------------|------------|
| Dynamic throttle | Throttled UP when behind (Kelly × 1.3) | **Kelly hard-capped at 1.0.** Behind → Kelly × 0.85. Never chases losses. |
| Transaction costs | Theoretical prices everywhere | **Realistic slippage model** for every asset class, applied to all calculations |
| Adaptive selection | 30-trade minimum to promote/demote | **500-trade minimum** + 55% confidence floor. Core models never demoted. |
| Market making | No adverse selection guard | **Stops quoting** when CVD/book pressure turns against inventory |
| Goal tracker | 0.15–0.50% daily (600%+ annual) | **Realistic: 11%/34%/72% annual.** 5-year horizon. |

---

## 4. Loss-Averse Dynamic Throttle

The throttle **only reduces risk, never increases it**. Kelly scale is clamped to [0.10, 1.00].

| Condition | Kelly Scale | Urgency | Logic |
|-----------|------------|---------|-------|
| Drawdown > 15% | × 0.15 | Patient | Minimum sizing, survival mode |
| Drawdown 10-15% | × 0.25 | Patient | Emergency conservative |
| Drawdown 5-10% | × 0.50 | Patient | Reduced sizing |
| Underwater (any loss) | × 0.75 | Patient | Conservative |
| Behind schedule | × 0.85 | Patient | **Does NOT increase risk** |
| Normal / on track | × 1.00 | Normal | Standard operation |
| Strong growth (>0.3%/day) | × 0.60 | Patient | Protect gains aggressively |
| Healthy growth (>0.1%/day) | × 0.80 | Normal | Slightly conservative |
| 3x+ initial capital | Additional × 0.85 | — | Protecting compound |
| 10x+ initial capital | Additional × 0.80 | — | Strong capital protection |

**Hard constraints:**
- Kelly scale can **never exceed 1.0** (never more aggressive than baseline)
- Maximum daily risk: **2% of bankroll** (non-overridable)
- Urgency is **never** `:immediate` (no panic trading)

---

## 5. Realistic Transaction Costs

Every edge calculation, Kelly sizing, and backtest simulation uses hard-coded realistic costs that **cannot be disabled**.

| Asset Type | Fee (bps) | Slippage (bps) | Spread (bps) | Round-Trip Total | Min Edge Required |
|-----------|-----------|---------------|-------------|-----------------|-------------------|
| **Stocks** | 1 | 5 | 3 | 18 bps | 0.27% |
| **Crypto** | 10 | 15 | 5 | 61 bps | 0.92% |
| **Polymarket** | 50 | 100 | 50 | 401 bps | 6.02% |

**Functions:**
- `realistic_costs(asset_type)` → `TransactionCosts` struct
- `round_trip_cost_bps(costs)` → total bps for a complete trade
- `minimum_edge_required(asset_type)` → minimum EV to overcome costs + 50% buffer
- `adjust_returns_for_costs(returns, asset_type)` → deducts costs from every return

Polymarket is expensive. A trade needs **6%+ edge** to be profitable after all frictions. The system enforces this automatically.

---

## 6. Hardened Adaptive Selection

| Parameter | Value | Reasoning |
|-----------|-------|-----------|
| Min trades for promote/demote | **500** | Prevents overfitting to recent noise |
| Confidence floor | **55%** | If no model exceeds this in a regime, fall back to core only |
| Core protected models | 14, 17, 18, 21, 22, 23 | GARCH, Kelly, EV Gap, Bayesian, Logistic, AR(1) — NEVER demoted |
| Selection audit | Full JSON logging | Every selection decision logged with regime, models, reasoning |

**Fallback behavior:** If 500+ trades have been recorded in a regime and NO model exceeds 55% accuracy, the system uses **core models only**. This prevents the system from trusting unproven models.

---

## 7. Market-Making Safety

### Adverse Selection Guard

| Condition | Action |
|-----------|--------|
| Long inventory + bearish CVD/book pressure | **Stop buying** |
| Short inventory + bullish CVD/book pressure | **Stop selling** |
| Strong directional flow (|pressure| > 0.6) | **Pause MM entirely** |

### Inventory Limits

| Level | Threshold | Action |
|-------|-----------|--------|
| Safe | < 80% of max (400 shares) | Normal quoting |
| Warning | 80-100% of max | Reduce quote sizes, skew toward unwind |
| Breach | > max (500 shares) | **Auto-unwind** excess to 50% of max |

---

## 8. Realistic Goal Projections

| Scenario | Annual Return | Daily Rate | $10K → $10M Timeline |
|----------|--------------|------------|---------------------|
| **Conservative** | 11% | 0.03% | 62.0 years |
| **Base Case** | 34% | 0.08% | 23.8 years |
| **Optimistic** | 72% | 0.15% | 12.6 years |

**Context:** Top quant funds (Renaissance, Two Sigma, Citadel) target 30-70% annual with billions in capital, massive data advantages, and dedicated infrastructure. These projections assume sustained edge — which requires continuous validation.

The "required daily return" calculation uses a **5-year horizon**, not 1 year. This prevents the goal tracker from generating unrealistic urgency.

---

## 9. Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│                  MINUTE DATA INGESTION                            │
│  Binance WS · Polygon WS · X Stream · Yahoo · FRED · Polymarket  │
│  → MinuteDataManager (24h windows, multi-timeframe aggregation)   │
└──────────────────────────┬────────────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────────────┐
│              DATA PROFILING + COST ESTIMATION                     │
│  profile_data() → regime, vol, momentum, CVD signal               │
│  realistic_costs() → slippage + fees + spread per asset class     │
│  minimum_edge_required() → threshold before any trade             │
└──────────────────────────┬────────────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────────────┐
│           ADAPTIVE MODEL SELECTION (500-trade proven)             │
│  select_models(profile) → optimal subset (6-20 of 34 models)     │
│  55% confidence floor: unproven → core only                      │
│  Core models (GARCH, Kelly, EV, Bayesian, Logistic, AR1) ALWAYS  │
└──────────────────────────┬────────────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────────────┐
│              18-FEATURE MATRIX                                    │
│  Returns(5) · Vol · VolChg · RSI · Mom · FracDiff(2)              │
│  Spread · OrderImbalance · TradeVelocity                          │
│  DepthImbalance · BookPressure · SpreadBps · CVD_Divergence       │
└──────────────────────────┬────────────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────────────┐
│           SELECTED MODELS + POLYMARKET QUANT LAYER                │
│  7 NN (weight-cached) · 19 fast (threaded) · 8 dependent          │
│  + Bayesian blend · Calibration · Fee-aware EV · Binary Kelly     │
└──────────────────────────┬────────────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────────────┐
│          ORCHESTRATOR (11 Rules) + LOSS-AVERSE THROTTLE           │
│  Kelly capped at 1.0 · 2% daily risk cap · Never chases losses   │
│  Correlation-adjusted sizing · Behind schedule → conservative     │
└──────────────────────────┬────────────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────────────┐
│       EXECUTION + MARKET MAKING (with adverse selection guard)    │
│  Paper · Alpaca · Polymarket CLOB                                 │
│  MM: inventory limits + auto-unwind + CVD/pressure check          │
│  All trades must clear minimum_edge_required() after costs        │
└──────────────────────────┬────────────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────────────┐
│            CONTINUOUS LEARNING (conservative)                     │
│  Retrain NN every 24h · Calibration every 10 trades               │
│  500-trade minimum before model adaptation                        │
│  A/B test with 50+ trades per arm before promotion                │
└──────────────────────────┬────────────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────────────┐
│            PERSISTENCE + MONITORING                               │
│  SQLite · JSONL audit · JLD2 weights · Telegram · /health         │
│  Structured JSON logging · Session resume · Goal tracker           │
└───────────────────────────────────────────────────────────────────┘
```

---

## 10. Security (12 Defense Layers)

| # | Layer | Protection |
|---|-------|-----------|
| 1 | Input Validation | Injection prevention |
| 2 | Data Sanitizer | NaN/Inf/negative |
| 3 | RALPH Wrapper | Model crash isolation |
| 4 | Hard Pipeline Gates | Negative-EV trade prevention |
| 5 | Circuit Breakers | Loss/drawdown/position limits |
| 6 | Execution Mode Guard | PAPER/LIVE enum |
| 7 | Rate Limiter | API compliance |
| 8 | Audit Logger | Decision trail |
| 9 | File Permissions | Access control |
| 10 | Encrypted Vault | Key protection (SHA-256 PBKDF2) |
| 11 | Structured Logging | Error detection |
| 12 | Telegram Alerts | Critical events + correlation warnings |

---

## 11. CPCV-Enforced Backtest (Launch Gate)

The system now includes a **mandatory CPCV validation** that blocks launch if any fold fails:

```julia
run_cpcv_backtest("BTC-USD"; n_groups=6, n_test_groups=2, purge=10, embargo=5)
```

**How it works:**
- Generates C(6,2) = 15 combinatorial purged folds
- Each fold trains models on purged training set, tests on held-out set
- **All returns are adjusted by realistic transaction costs** (crypto: 61 bps RT, Polymarket: 401 bps RT)
- Reports per-fold Sharpe, return, and expectancy

**Launch is BLOCKED if:**
- Any fold has negative expectancy after costs
- Overall Sharpe < 1.0
- Fewer than 20 trades across all folds

---

## 12. Monte Carlo Stress Test

```julia
run_stress_test(returns; n_paths=1000, horizon_days=252, kelly_fraction=0.15)
```

Simulates 1,000 portfolio paths with:
- **2% fat tail events** (3-6 sigma, 70% crashes / 30% melt-ups)
- **5% elevated volatility days** (historical × 1.5-2.5x)
- **93% normal days** (sampled from historical distribution)

**Passes if:**
- 95%+ of paths survive without hitting circuit breaker
- Median final value > initial capital
- 95th percentile max drawdown < 15%

---

## 13. Pre-Flight Validation (Automated)

One command runs ALL validation checks:

```bash
julia --project=. -t auto bin/run_preflight.jl BTC-USD,ETH-USD
```

**Checks (all must pass):**
1. Cost sanity (min edge > round-trip costs + 50% buffer)
2. CPCV backtest with costs (all folds positive, Sharpe ≥ 1.0)
3. Regime-split validation (positive in bull/bear/high_vol/low_vol)
4. Monte Carlo stress test (95%+ survival, median profitable)

**Output:** CLEARED FOR LIVE or FAILED with specific reasons.

---

## 14. Pre-Launch Validation Checklist

Before ANY real capital is deployed:

```bash
# 1. Run automated preflight (CPCV + regime + stress test)
julia --project=. -t auto bin/run_preflight.jl BTC-USD,ETH-USD
# ALL CHECKS MUST PASS

# 2. Paper trade for 30+ days
QE_EXECUTION_MODE=PAPER QE_FORCE_CONSERVATIVE=true QE_INITIAL_BANKROLL=10000 \
julia --project=. -t auto bin/run_pipeline.jl BTC-USD,ETH-USD
# REQUIRED: 500+ simulated trades, positive expectancy after costs

# 3. Review logs
# Check: slippage estimates match reality, no model demotion without 500+ trades,
# dynamic throttle never exceeds 1.0, MM stops on adverse selection

# 4. Small live (only after 30-day paper validates)
QE_EXECUTION_MODE=LIVE QE_FORCE_CONSERVATIVE=true QE_INITIAL_BANKROLL=5000 \
QE_KELLY_MAX_FRAC=0.15 \
julia --project=. -t auto bin/run_pipeline.jl BTC-USD
# Start with ONE asset, minimum Kelly, conservative only
```

---

## 12. What Can Still Be Improved

| Priority | Item | Status |
|----------|------|--------|
| High | FinBERT sentiment (feature 19) | Not built |
| High | Options execution (IBKR adapter) | Not built |
| High | Live L2 depth as streaming features | Infrastructure exists, not wired to features in real-time |
| Medium | Web dashboard (Genie.jl) | Not built |
| ~~Medium~~ | ~~Purged walk-forward enforcement~~ | **DONE: `run_cpcv_backtest()` with costs, launch gate** |
| ~~Medium~~ | ~~Monte Carlo stress testing~~ | **DONE: `run_stress_test()` with fat tails, 95% survival** |
| Low | Config hot-reload | Not built |
| Low | GPU support (Flux.jl) | Not built |

---

## 13. System Metrics

| Metric | Count |
|--------|-------|
| Models | 34 + adaptive selector + plugin registry |
| Features | 18 (including CVD + L2 order book) |
| Tests | **1,533** |
| Test suites | 37 |
| Exchanges | 3 (Paper, Alpaca, Polymarket) |
| Data feeds | 7 + 2 order book + minute processor |
| Defense layers | 12 |
| Orchestrator rules | 11 |
| Strategy types | 5 |
| Source lines | ~17,500 |

---

## 14. Dependencies

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

*Generated March 17, 2026 — QuantEngine v7.0 (Production Hardened)*
*34 Models · 18 Features · 1,533 Tests · CPCV Validated · Stress Tested · Survival First*
