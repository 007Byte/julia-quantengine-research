# QuantEngine v8.0 — Definitive Technical Specification

**Date:** March 17, 2026
**Language:** Julia 1.12
**Source:** 16,332 lines | 127 files | 18 modules
**Tests:** 4,396 lines | 36 files | 35 suites | 1,561 passing | 0 failures
**Dependencies:** 15 (all pure Julia)

---

## 1. What This System Does

QuantEngine monitors stocks, crypto, and prediction markets minute-by-minute using a 34-model ensemble with 18 features. It automatically profiles each asset's current regime, selects the optimal model subset, calculates cost-adjusted position sizes using loss-averse Kelly criterion, executes through three exchanges, makes markets on liquid Polymarket contracts, learns from every trade outcome, and compounds returns — with survival as the primary objective.

---

## 2. System Metrics (Verified)

| Metric | Exact Count |
|--------|-------------|
| Source files | 127 |
| Source lines | 16,332 |
| Source modules | 18 subdirectories |
| Test files | 36 |
| Test lines | 4,396 |
| Test suites | 35 |
| Tests passing | 1,561 |
| Tests failing | 0 |
| Models | 34 (named) + plugin registry |
| Features | 18 |
| Exchanges | 3 (Paper, Alpaca, Polymarket CLOB) |
| Data feeds | 7 real-time + 2 order book + minute processor |
| CLI scripts | 8 |
| Dependencies | 15 |
| Defense layers | 12 |
| Orchestrator rules | 11 |
| Strategy types | 5 |
| Validation gates | 3 (CPCV + regime + Monte Carlo) |
| Exported symbols | 85+ |

---

## 3. Architecture

### 3.1 Complete Data Flow

```
┌───────────────────────────────────────────────────────────────────────┐
│                        DATA INGESTION LAYER                           │
│                                                                       │
│  Yahoo Finance ─── REST polling ─── stocks + crypto OHLCV             │
│  Binance ──────── WebSocket ────── crypto real-time trades            │
│  Polygon.io ───── WebSocket ────── stock real-time trades             │
│  Polymarket ───── REST + CLOB ──── prediction market prices/books     │
│  X/Twitter ────── Filtered stream ─ sentiment (negation+phrases)      │
│  FRED ─────────── REST API ──────── economic indicators               │
│  Kalshi ───────── REST API ──────── cross-market arb prices           │
│                                                                       │
│  All feeds → MinuteDataManager (24h rolling windows per asset)        │
│  L2 books → LiveBookManager (Binance + Polymarket depth polling)      │
│  Tweets → TweetBuffer (sentiment v2 scoring with 50+ lexicon)         │
│  Signals → SignalBuffer (FRED, polls, custom external data)           │
└───────────────────────────────┬───────────────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────────────┐
│                      FEATURE ENGINEERING                              │
│                                                                       │
│  compute_features(prices, returns, volumes; high, low, book_features) │
│                                                                       │
│  18-column matrix (Z-score standardized):                             │
│   1-5   Return lags: Ret(t), Ret(t-1), Ret(t-2), Ret(t-3), Ret(t-4) │
│   6     Vol(20): 20-day rolling std of returns                        │
│   7     VolChg: volume change ratio                                   │
│   8     RSI(14): Relative Strength Index                              │
│   9     Mom(10): 10-day momentum                                      │
│   10-11 FracDiff: fractional differentiation (price + log price)      │
│   12    Spread(HL): (high - low) / price (bid-ask proxy)              │
│   13    OrderImbalance: volume-weighted price momentum (5-bar)        │
│   14    TradeVelocity: volume acceleration (3-bar vs prior 3-bar)     │
│   15    DepthImbalance: (bid_depth - ask_depth) / total (L2)          │
│   16    BookPressure: depth imbalance × large-order amplifier (L2)    │
│   17    SpreadBps: bid-ask spread in basis points (L2)                │
│   18    CVD_Divergence: cumulative volume delta divergence score       │
│                                                                       │
│  Labels: binary (1.0 if next return > 0, else 0.0)                   │
│  Train/test split: 80/20 with sequence generation for RNN models      │
└───────────────────────────────┬───────────────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────────────┐
│                      DATA PROFILING                                   │
│                                                                       │
│  profile_data(prices, returns, volumes) → DataProfile                 │
│                                                                       │
│  Computed:                                                            │
│   trend_strength: [-1, +1] normalized 20-bar cumulative return        │
│   volatility_regime: :low / :normal / :high / :extreme                │
│   volume_regime: :thin / :normal / :heavy                             │
│   momentum_direction: :bullish / :bearish / :neutral                  │
│   spread_quality: :tight / :normal / :wide                            │
│   cvd_signal: :accumulation / :distribution / :neutral                │
│   hours_to_event: Float64 (Inf for stocks, actual for Polymarket)     │
│                                                                       │
│  Cost gate: realistic_costs(asset_type) →                             │
│   Stocks:     18 bps round-trip, 0.27% min edge                      │
│   Crypto:     61 bps round-trip, 0.92% min edge                      │
│   Polymarket: 401 bps round-trip, 6.02% min edge                     │
│  Trades below minimum_edge_required() are REJECTED.                   │
└───────────────────────────────┬───────────────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────────────┐
│                  ADAPTIVE MODEL SELECTION                             │
│                                                                       │
│  select_models(profile, engine) → AdaptiveStrategy                    │
│                                                                       │
│  Rules:                                                               │
│   Core always-on: [14, 17, 18, 21, 22, 23]                           │
│     (GARCH, Kelly, EV Gap, Bayesian, Logistic, AR1)                   │
│   Polymarket: +[16, 31, 32, 33] (LMSR, Kalman, Time Decay, Arb)      │
│   Stocks/Crypto: +[5, 6, 7] (RF, LightGBM, XGBoost with CPCV)       │
│   Strong trend: +[1, 2, 34] (LSTM, GRU, Momentum-Sentiment)          │
│   Extreme vol: +[27, 29] (Martingale, FracDiff); Kelly × 0.3         │
│   Heavy volume: +[10, 30] (SGD, Triple-Barrier); immediate            │
│   Near expiry: Kelly × 0.5; urgency = immediate                      │
│   CVD accumulation: Kelly × 1.1                                       │
│   CVD distribution: Kelly × 0.8                                       │
│                                                                       │
│  Adaptation (500-trade minimum):                                      │
│   Model accuracy < 45% in a regime (500+ trades) → DEMOTED           │
│   Model accuracy > 60% in a regime (500+ trades) → PROMOTED          │
│   Core models (14,17,18,21,22,23) → NEVER demoted                    │
│   No model > 55% accuracy after 500 trades → core only fallback      │
│                                                                       │
│  5 strategy types: trend_follow, mean_revert, arb, mm, event_driven  │
└───────────────────────────────┬───────────────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────────────┐
│                    34-MODEL ENSEMBLE                                  │
│                                                                       │
│  Phase 1A: 22 fast models (Threads.@threads parallel)                 │
│   [4,5,6,7,10,14,15,16,17,22,23,24,25,26,29,30,31,32,33,34+plugin] │
│                                                                       │
│  Phase 1B: 7 heavy NN models (Distributed.jl workers + JLD2 cache)   │
│   [1,2,3,8,9,11,13] = LSTM, GRU, Helformer, Conv-LSTM, BiLSTM,      │
│                        TFT, MLP                                       │
│   Cache: ~/.quantengine/weights/weight_cache.jld2                     │
│   First run: train from scratch (LBFGS, 25-40 iterations)            │
│   Subsequent: load cached θ (milliseconds instead of minutes)         │
│   Staleness: 7-day max age + data hash invalidation                   │
│   Incremental: get_cached_for_incremental() → warm-start θ            │
│                                                                       │
│  Phase 2: 8 dependent models (require Phase 1 results)               │
│   [4,12,18,19,20,21,27,28]                                           │
│                                                                       │
│  Each model wrapped in RALPH:                                         │
│   R = Review (check data availability)                                │
│   A = Analyze (execute with retry, max 2 attempts)                    │
│   L = Log (thread-safe result storage via ctx.lock)                   │
│   P = Print (validate outputs, detect NaN/Inf)                        │
│   H = Halt (safety check)                                             │
│                                                                       │
│  Plugin system: register_model!(35, "Name", :fast, fn)                │
│   run_model() checks MODEL_DISPATCH first, then plugin registry       │
│   Zero-edit extensibility for m35+                                    │
└───────────────────────────────┬───────────────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────────────┐
│               COMPOSITE SIGNAL + LEARNED WEIGHTS                     │
│                                                                       │
│  compute_composite(results; learned_weights=nothing)                  │
│                                                                       │
│  Default: accuracy-based weighting                                    │
│   w_i = max(accuracy_i - 0.45, 0.05)                                 │
│   Prefers CPCV accuracy over standard accuracy                        │
│   p_true = dot(w_normalized, probabilities)                           │
│                                                                       │
│  Optional: LBFGS-optimized learned weights                            │
│   learn_ensemble_weights(predictions_matrix, actuals)                 │
│   Softmax parameterization → positive, sum-to-1                       │
│   L2 regularization to prevent overfitting                            │
│                                                                       │
│  Output:                                                              │
│   direction: "BUY" / "LEAN BUY" / "HOLD" / "LEAN SELL" / "DO NOT BUY"│
│   score: [-1, 1]                                                      │
│   p_true: ensemble probability [0, 1]                                 │
│   confidence: [0, 100]                                                │
│   bull_pct: % of models voting bullish                                │
│                                                                       │
│  Polymarket Quant Layer (additional for prediction markets):          │
│   bayesian_blend(model_prob, market_prob; k_model, k_market)          │
│   calibrate_probability(raw_p, category_bias) — logit-space           │
│   buy_ev(fair, ask, fee) / sell_ev(fair, bid, fee)                    │
│   binary_kelly(fair_prob, all_in_cost) → f* = (p-c)/(1-c)            │
│   logit_edge(fair, market) — symmetric near 0 and 1                   │
│   fee_zone_quality(price) — 0 at 50¢ (worst), 1 at tails (best)      │
│   CalibrationTable — historical predicted vs actual by bucket         │
│   generate_poly_signal(quote, inputs) → full signal with action       │
└───────────────────────────────┬───────────────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────────────┐
│                    ORCHESTRATOR (11 Rules)                            │
│                                                                       │
│  orchestrate(state, config, tracker) → TradePlan                      │
│                                                                       │
│  Inputs: aggressive strategy, conservative strategy, portfolio state  │
│  Output: chosen strategy (aggressive / conservative / blend / skip)   │
│                                                                       │
│  Rule  1: Portfolio heat > 70% → force conservative                   │
│  Rule  2: Daily loss > 60% of limit → force conservative              │
│  Rule  3: Drawdown > 80% of max DD limit → SKIP                      │
│  Rule  4: Volatile regime + high KL divergence → conservative         │
│  Rule  5: Trending regime → lean aggressive (+20% blend weight)       │
│  Rule  6: QE_FORCE_CONSERVATIVE=true → override to conservative       │
│  Rule  7: Cooling period active → conservative only                   │
│  Rule  8: Strategies disagree on direction → SKIP                     │
│  Rule  9: Both HOLD + strong signal → force conservative buy          │
│  Rule 10: High edge consistency + good calibration → boost aggressive │
│  Rule 11: Correlation risk > 0.7 → force conservative                 │
│           Correlation risk > 0.4 → scale down blend weight            │
│                                                                       │
│  Dynamic Throttle (applied after orchestrator):                       │
│   Kelly hard-capped at 1.0 (NEVER exceeds baseline)                  │
│   Max daily risk: 2% (non-overridable)                                │
│   Losing money → reduce (0.15× to 0.75×)                             │
│   Behind schedule → conservative (0.85×), NOT chasing                 │
│   Ahead of schedule → protect (0.60× to 0.80×)                       │
│   3x+ initial → additional 0.85×                                      │
│   10x+ initial → additional 0.80×                                     │
│                                                                       │
│  Aggressive strategy: ¾ Kelly, market orders, short holds             │
│  Conservative strategy: ¼ Kelly, limit orders, long holds             │
│  Blend: weighted average of both (0.0 = all conservative, 1.0 = all)  │
└───────────────────────────────┬───────────────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────────────┐
│                    EXECUTION LAYER                                    │
│                                                                       │
│  3 Exchange Implementations (all implement AbstractExchange):         │
│                                                                       │
│  PaperExchange:                                                       │
│   Simulated fills at current/limit price                              │
│   Balance tracking, order log                                         │
│                                                                       │
│  AlpacaExchange:                                                      │
│   REST API v2 (stocks)                                                │
│   Paper: paper-api.alpaca.markets                                     │
│   Live: api.alpaca.markets                                            │
│   Order types: market, limit, stop_limit                              │
│   Position reconciliation with server-side state                      │
│   Rate limited: 180 req/min                                           │
│                                                                       │
│  PolymarketExchange:                                                  │
│   CLOB API (prediction markets)                                       │
│   Paper: simulated fills at limit_price                               │
│   Live: POST to clob.polymarket.com/order                             │
│   Position tracking per token ID                                      │
│   Rate limited: 60 req/min                                            │
│                                                                       │
│  Market Making (Polymarket only):                                     │
│   compute_mm_quotes(fair_prob, fee, inventory)                        │
│   Inventory-adjusted bid/ask spread                                   │
│   should_market_make() gate: volume > 10K, spread > 2¢, p ∈ [5,95]%  │
│   check_adverse_selection(cvd, pressure, inventory)                   │
│     → stops quoting when flow turns against inventory                 │
│   check_inventory_limits(): hard cap at 500 shares                    │
│     → auto-unwind excess to 50% of max                               │
│                                                                       │
│  Execution Mode Guard:                                                │
│   PAPER (default) → PaperExchange only                                │
│   LIVE → requires explicit QE_EXECUTION_MODE=LIVE                     │
│   LIVE + PaperExchange → ERROR (prevents accidental paper in LIVE)    │
└───────────────────────────────┬───────────────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────────────┐
│                    RISK MANAGEMENT (12 Layers)                        │
│                                                                       │
│  Layer  1: Input Validation — ticker allowlist regex                   │
│  Layer  2: Data Sanitizer — NaN/Inf/negative rejection                │
│  Layer  3: RALPH Wrapper — model crash isolation with retry            │
│  Layer  4: Hard Pipeline Gates — Steps 5,7 abort on failure           │
│  Layer  5: Circuit Breakers — daily loss, drawdown, cooling           │
│  Layer  6: Execution Mode Guard — PAPER/LIVE enum                     │
│  Layer  7: Rate Limiter — per-source token bucket                     │
│  Layer  8: Audit Logger — append-only JSONL, 50MB rotation            │
│  Layer  9: File Permissions — 0o700 dirs, 0o600 files                 │
│  Layer 10: Encrypted Vault — SHA-256 PBKDF2, 50K rounds              │
│  Layer 11: Structured Logging — JSON to stderr                        │
│  Layer 12: Telegram Alerts — trades, circuit breakers, correlation    │
│                                                                       │
│  CorrelationTracker: 60-day rolling pairwise correlations             │
│   correlation_adjusted_kelly() — reduces when correlated with book    │
│   portfolio_correlation_risk() — 0 (diversified) to 1 (concentrated) │
│   Alert at > 0.7 via Telegram                                         │
│                                                                       │
│  Realistic Transaction Costs (non-disableable):                       │
│   Stocks:     fee 1 + slip 5 + spread 3 = 18 bps RT                  │
│   Crypto:     fee 10 + slip 15 + spread 5 + funding 1 = 61 bps RT    │
│   Polymarket: fee 50 + slip 100 + spread 50 = 401 bps RT             │
│   minimum_edge_required() = RT_cost × 1.5 (50% safety buffer)        │
└───────────────────────────────┬───────────────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────────────┐
│                  CONTINUOUS LEARNING                                  │
│                                                                       │
│  LearningConfig:                                                      │
│   retrain_interval_hours: 24 (retrain NNs daily)                      │
│   calibration_update_trades: 10 (update CalibrationTable every 10)    │
│   min_samples_for_retrain: 50                                         │
│   auto_promote_ab: true                                               │
│                                                                       │
│  trigger_retrain!() — clears weight cache for fresh training          │
│  update_calibration_from_trades!() — feeds resolved trades back       │
│  record_model_outcome!() — accuracy per model per regime              │
│                                                                       │
│  A/B Testing:                                                         │
│   create_ab_test(config_a, config_b) — dual ensemble comparison       │
│   record_signal!() — track Sharpe, PnL, win rate per arm              │
│   check_ab_winner!() — auto-promote after 50+ trades per arm          │
│                                                                       │
│  Goal Tracker:                                                        │
│   goal_progress(engine) — completion %, daily growth, projected days  │
│   Scenarios: conservative 11%/yr, base 34%/yr, optimistic 72%/yr     │
│   dynamic_throttle(engine) — Kelly scale based on progress            │
│     NEVER exceeds 1.0. Behind → conservative. Losing → reduce.       │
│     2% max daily risk cap (non-overridable).                          │
└───────────────────────────────┬───────────────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────────────┐
│                    PERSISTENCE + MONITORING                           │
│                                                                       │
│  SQLite Database (3 tables):                                          │
│   trades: every closed trade with PnL, strategy, confidence           │
│   equity_snapshots: periodic bankroll/drawdown/positions              │
│   model_performance: accuracy, timing per model per run               │
│   Session resume: db_load_last_state() on startup                     │
│                                                                       │
│  Audit Trail: append-only JSONL, daily + 50MB size rotation           │
│  Weight Cache: JLD2 file, 7-day staleness, data hash invalidation    │
│                                                                       │
│  Health Server (/health + /metrics):                                  │
│   /health → JSON: status, bankroll, positions, trades, cooling        │
│   /metrics → Prometheus: bankroll, daily_pnl, positions, win_rate,    │
│              drawdown, consecutive_losses, cooling                     │
│                                                                       │
│  Telegram Alerts: send_alert(config, msg; level)                      │
│   Triggers: circuit breaker, trade execution, large PnL, errors       │
│   Rate limited: 30 msg/min, 1 msg/sec                                 │
│   alert_trade() — trade entry/exit with PnL                           │
│   alert_circuit_breaker() — critical risk events                      │
│                                                                       │
│  Signal Cards: print_signal_card(card)                                │
│   ANSI-colored terminal output                                        │
│   SL / TP1 / TP2 with percentage moves                                │
│   Direction arrow, confidence, R:R, Kelly %, hold time                 │
│   Trade recommendations from composite + CVD + orchestrator           │
└───────────────────────────────────────────────────────────────────────┘
```

### 3.2 Module Dependency Map

```
core/types ──→ core/constants ──→ core/config ──→ core/ralph ──→ core/logger
                                                                      │
core/model_registry ◄─────────────────────────────────────────────────┘
    │
security/vault
    │
data/ingestion ──→ data/features ──→ data/fracdiff ──→ data/triple_barrier ──→ data/cpcv
    │
nn/primitives ──→ nn/{lstm,gru,mlp,tree,holt_winters} ──→ nn/weight_cache
    │
models/m01..m34 ──→ models/polymarket_quant ──→ models/polymarket_mm
    │
data/sanitizer ──→ data/live_feed ──→ data/{websocket,binance,polygon,x_stream}
    │                                  data/{external_signals,orderbook,cvd}
    │                                  data/{polymarket_history,minute_processor}
    │                                  data/{live_book_feed,sentiment_embeddings}
    │
reporting/{composite,console,charts,text}
    │
orchestrator/runner ──→ execution/{interface,paper_trade}
    │
risk/rate_limiter ──→ pipeline/{types,config,event_bus}
    │
execution/{alpaca_exchange,polymarket_exchange}
    │
decision/types ──→ execution/audit_log
    │
risk/{position_tracker,circuit_breakers,correlation,slippage,stress_test}
    │
execution/alpaca_positions ──→ instruments/{types,polymarket,crypto,stocks,selector}
    │
pipeline/{triggers,steps} ──→ decision/{aggressive,conservative}
    │
orchestrator/{strategy_engine,adaptive_selector}
    │
storage/{database,queries} ──→ pipeline/{executor,loop,learning_loop}
    │
reporting/{pdf_report,trade_plan,signal_card}
    │
scanner/scanner ──→ risk/portfolio_optimizer
    │
tuning/{search_spaces,bayesian_opt,ab_testing}
    │
monitoring/{health,alerts} ──→ reporting/ensemble_optimizer
    │
backtest/{types,exchange,metrics,walk_forward,report,polymarket_backtest,regime_backtest,cpcv_backtest}
```

---

## 4. The 34-Model Ensemble

| # | Model | Category | Key Enhancement | Phase |
|---|-------|----------|----------------|-------|
| 1 | LSTM | Deep Learning | JLD2 weight-cached, warm-start | 1B |
| 2 | GRU | Deep Learning | JLD2 weight-cached | 1B |
| 3 | Helformer | Deep Learning | Transformer+LSTM+HW, cached | 1B |
| 4 | LSTM-GARCH | Hybrid | Uses LSTM result | 2 |
| 5 | Random Forest | ML | CPCV accuracy, 100 trees | 1A |
| 6 | LightGBM | ML | CPCV accuracy, leaf-wise | 1A |
| 7 | XGBoost | ML | CPCV accuracy, L2 regularized | 1A |
| 8 | Conv-LSTM | Deep Learning | Spatial-temporal, cached | 1B |
| 9 | BiLSTM | Deep Learning | Bidirectional, cached | 1B |
| 10 | SGD | ML | Online learner, real-time adapt | 1A |
| 11 | TFT | Deep Learning | Variable selection, cached | 1B |
| 12 | Ensemble Stack | ML | Stacks top models | 2 |
| 13 | MLP | Deep Learning | 2-hidden-layer, cached | 1B |
| 14 | GARCH/EGARCH | Statistical | Reparameterized (persistence < 1) | 1A |
| 15 | RL (DQN) | Reinforcement | Optimal buy/sell/hold policy | 1A |
| 16 | LMSR | Market Pricing | Polymarket pricing + slippage | 1A |
| 17 | Kelly Criterion | Sizing | Regime-aware + cost-adjusted | 1A |
| 18 | EV Gap | Mispricing | Dynamic threshold + slippage | 2 |
| 19 | KL-Divergence | Info Theory | Model vs market disagreement | 2 |
| 20 | Bregman Projection | Info Theory | Optimal probability weights | 2 |
| 21 | Bayesian Update | Probabilistic | 4 evidence + tweets + FRED | 2 |
| 22 | Logistic Regression | Statistical | Continuation/reversal | 1A |
| 23 | AR(1) | Statistical | Regime detection | 1A |
| 24 | Black-Scholes | Derivatives | Options + 5 Greeks | 1A |
| 25 | Crank-Nicolson FD | Derivatives | American options PDE | 1A |
| 26 | Term Structure | Interest Rates | Nelson-Siegel + Vasicek | 1A |
| 27 | Martingale Detection | No-Arbitrage | Variance ratio + runs + ADF | 2 |
| 28 | Meta-Labeling | Advanced ML | Bet/no-bet (Lopez de Prado) | 2 |
| 29 | FracDiff Signal | Advanced ML | Memory-preserving differencing | 1A |
| 30 | Triple-Barrier | Advanced ML | Regime classification by barriers | 1A |
| 31 | Kalman Filter | Prediction Markets | Probability smoothing + shocks | 1A |
| 32 | Time Decay | Prediction Markets | Volatility compression | 1A |
| 33 | Cross-Market Arb | Prediction Markets | Multi-platform spreads | 1A |
| 34 | Momentum-Sentiment | Plugin Example | 5-day momentum + tweet fusion | 1A |

---

## 5. Three-Gate Validation

### Gate 1: CPCV Backtest

```bash
run_cpcv_backtest("BTC-USD"; n_groups=6, n_test_groups=2, purge=10, embargo=5)
```

- C(6,2) = 15 purged folds. No information leakage.
- All returns adjusted by `realistic_costs(asset_type)`.
- **Blocks launch if:** any fold negative expectancy, overall Sharpe < 1.0, or < 20 trades.

### Gate 2: Regime-Split Backtest

```bash
run_regime_backtest("BTC-USD")
```

- Classifies bars as bull/bear/high_vol/low_vol.
- Separate walk-forward per regime.
- **Blocks launch if:** any regime has negative returns.

### Gate 3: Monte Carlo Stress Test

```bash
run_stress_test(returns; n_paths=1000, kelly_fraction=0.15)
```

- 1,000 paths with fat tails (2% chance of 3-6σ crash events).
- **Blocks launch if:** survival < 95%, median unprofitable, or 95th percentile DD > 15%.

### Automated Pre-Flight

```bash
julia --project=. -t auto bin/run_preflight.jl BTC-USD,ETH-USD
```

Runs all three gates + cost sanity. Prints **CLEARED** or **FAILED** with specific reasons.

---

## 6. Configuration (23 Environment Variables)

| Variable | Default | Description |
|----------|---------|-------------|
| `QE_EXECUTION_MODE` | `PAPER` | Must be explicit `LIVE` |
| `QE_INITIAL_BANKROLL` | `2000` | Starting capital ($) |
| `QE_MAX_POSITION_PCT` | `0.10` | Max 10% per position |
| `QE_MAX_DAILY_LOSS_PCT` | `0.05` | Halt after 5% daily loss |
| `QE_MAX_DRAWDOWN_PCT` | `0.15` | Halt after 15% drawdown |
| `QE_MAX_CONCURRENT_POS` | `5` | Max open positions |
| `QE_POLL_INTERVAL_MS` | `5000` | Polling interval (ms) |
| `QE_FORCE_CONSERVATIVE` | `false` | Conservative-only mode |
| `QE_COOLING_PERIOD` | `10` | Iterations after 3+ losses |
| `QE_EV_GAP_MIN` | `0.05` | Minimum EV (dynamic with vol) |
| `QE_KELLY_MIN_FRAC` | `0.25` | Kelly lower bound |
| `QE_KELLY_MAX_FRAC` | `0.50` | Kelly upper bound |
| `QE_ALPACA_API_KEY` | — | Alpaca trading |
| `QE_ALPACA_SECRET_KEY` | — | Alpaca secret |
| `QE_POLYMARKET_API_KEY` | — | Polymarket CLOB |
| `QE_POLYMARKET_SECRET` | — | Polymarket CLOB secret |
| `QE_POLYGON_API_KEY` | — | Polygon.io WebSocket |
| `QE_X_BEARER_TOKEN` | — | X/Twitter stream |
| `QE_FRED_API_KEY` | — | FRED economic data |
| `QE_TELEGRAM_BOT_TOKEN` | — | Telegram alerts |
| `QE_TELEGRAM_CHAT_ID` | — | Telegram chat |
| `QE_VAULT_TYPE` | `env` | `env` or `encrypted` |
| `QE_VAULT_MASTER_KEY` | — | Encrypted vault key |

---

## 7. Launch Procedure

```bash
# Step 1: Pre-flight validation (all 3 gates must pass)
julia --project=. -t auto bin/run_preflight.jl BTC-USD,ETH-USD

# Step 2: Paper trading (minimum 30 days)
QE_EXECUTION_MODE=PAPER QE_FORCE_CONSERVATIVE=true QE_INITIAL_BANKROLL=10000 \
julia --project=. -t auto bin/run_pipeline.jl BTC-USD,ETH-USD

# Step 3: Small live (one asset, minimum Kelly, after paper validates)
QE_EXECUTION_MODE=LIVE QE_FORCE_CONSERVATIVE=true QE_INITIAL_BANKROLL=5000 \
QE_KELLY_MAX_FRAC=0.15 julia --project=. -t auto bin/run_pipeline.jl BTC-USD

# Step 4: Scale (after 14+ days positive live equity)
QE_EXECUTION_MODE=LIVE QE_FORCE_CONSERVATIVE=true QE_INITIAL_BANKROLL=25000 \
QE_KELLY_MAX_FRAC=0.20 julia --project=. -t auto bin/run_pipeline.jl BTC-USD,ETH-USD
```

---

## 8. Deployment

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

---

## 9. What Can Still Be Improved

| Priority | Item | Status |
|----------|------|--------|
| High | Options execution (IBKR/Tastytrade adapter) | Not built |
| Medium | Web dashboard (Genie.jl) | Not built |
| Medium | Full FinBERT via ONNX runtime | Not built (have lexicon v2) |
| Low | Config hot-reload (YAML watch) | Not built |
| Low | GPU support (Flux.jl + CUDA) | Not built |

---

## 10. Dependencies

All pure Julia. No Python. No GPU required.

| Package | Purpose |
|---------|---------|
| HTTP | REST APIs, WebSocket, health server |
| JSON | Data parsing, audit logs, vault |
| SQLite | Trade persistence, session resume |
| JLD2 | Weight cache serialization |
| Optim | LBFGS (NN training, ensemble weights, GARCH) |
| Plots | Chart generation |
| Luxor | PDF report generation |
| StatsBase | Advanced statistics |
| SpecialFunctions | erf for Black-Scholes, Bayesian |
| Distributed | Multi-process NN parallelism |
| Statistics | Basic statistics |
| LinearAlgebra | Matrix operations |
| Dates | Timestamps |
| Printf | Formatted output |
| Random | Monte Carlo, sampling |

---

## 11. Test Coverage (35 Suites)

| # | Suite | What It Tests |
|---|-------|--------------|
| 1 | Input Validation | Ticker injection, ExecutionMode |
| 2 | Data Sanitizer | Price/volume/returns/OHLCV/Polymarket |
| 3 | Feature Engineering | 18-feature matrix, sequences |
| 4 | Composite Signal | Accuracy/learned weighting |
| 5 | Kelly Criterion | Regime awareness, cost adjustment |
| 6 | GARCH/EGARCH | Persistence < 1.0, forecast |
| 7 | Circuit Breakers | Cooling, exits, limits |
| 8 | Position Tracker | PnL, thread safety |
| 9 | Rate Limiter | Per-second/minute |
| 10 | Audit Logger | JSON Lines, rotation |
| 11 | FracDiff | Weights, ADF, find_min_d |
| 12 | CPCV | Purged splits, evaluate |
| 13 | RALPH | Retry, NaN handling |
| 14 | Backtest Engine | Folds, metrics |
| 15 | Database | CRUD, resume, leaderboard |
| 16 | Alpaca Exchange | URL selection, keys |
| 17 | WebSocket Feeds | Binance, state, thread safety |
| 18 | Vault | Roundtrip, wrong key, permissions |
| 19 | X Stream | Negation, bigrams, buffer |
| 20 | Scanner & Portfolio | Allocation, diversification |
| 21 | Tuning | Bayesian opt, search spaces |
| 22 | Monitoring | Health JSON, Prometheus |
| 23 | Weight Cache | JLD2, staleness, threading |
| 24 | Event Bus | Emit/take, timeout, concurrent |
| 25 | Ensemble Optimizer | Weight learning |
| 26 | Alerts | Config, level filtering |
| 27 | Prediction Markets | Kalman, time decay, arb, exchange |
| 28 | Profit Boosters | Microstructure, regime Kelly, A/B |
| 29 | Polymarket Quant | Logit, fees, calibration, signals |
| 30 | Advanced Features | L2 book, correlation, registry, MM |
| 31 | Final Features | CVD, learning loop, regime backtest |
| 32 | Adaptive Selector | Profiling, selection, 500-trade min |
| 33 | Hardening | Core protection, throttle, inventory, slippage, adverse selection |
| 34 | Launch Safety | Stress test, CPCV validation, throttle constraints |
| 35 | Signal Card | Sentiment v2, live book, card struct |

---

*QuantEngine v8.0 — March 17, 2026*
*34 Models · 18 Features · 127 Source Files · 16,332 Lines · 1,561 Tests · 0 Failures*
*CPCV Validated · Stress Tested · Loss-Averse · Cost-Adjusted · Survival First*
