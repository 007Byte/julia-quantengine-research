# ── Constants ─────────────────────────────────────────────────

const RF_ANNUAL = 0.053          # US 10-yr Treasury (risk-free rate)
const RF_DAILY  = RF_ANNUAL / 252
const BENCHMARK = "SPY"
const N_MODELS  = 34

const CRYPTO_TICKERS = Set(["BTC-USD","ETH-USD","SOL-USD","DOGE-USD","ADA-USD",
    "XRP-USD","DOT-USD","AVAX-USD","MATIC-USD","LINK-USD","BNB-USD","ATOM-USD",
    "UNI-USD","AAVE-USD","LTC-USD","FIL-USD","NEAR-USD","APT-USD","ARB-USD"])

const MODEL_NAMES = Dict(
    1  => "LSTM (BD-LSTM/ED-LSTM)",
    2  => "GRU",
    3  => "Helformer (Transformer+LSTM+HW)",
    4  => "LSTM-GARCH Hybrid",
    5  => "Random Forest",
    6  => "LightGBM",
    7  => "XGBoost",
    8  => "Conv-LSTM / CNN-LSTM",
    9  => "BiLSTM",
    10 => "SGD Classifier",
    11 => "Temporal Fusion Transformer",
    12 => "Ensemble Stacking",
    13 => "MLP",
    14 => "EGARCH / GARCH Family",
    15 => "Reinforcement Learning (DQN)",
    16 => "LMSR Pricing Model",
    17 => "Kelly Criterion",
    18 => "Expected Value (EV) Gap",
    19 => "KL-Divergence",
    20 => "Bregman Projection",
    21 => "Bayesian Update",
    22 => "Logistic Regression (Post-Trade)",
    23 => "AR(1) Autoregression",
    24 => "Black-Scholes Options Pricing",
    25 => "Crank-Nicolson FD Pricer",
    26 => "Term Structure (NS + Vasicek)",
    27 => "Martingale Detection (VR+Runs+ADF)",
    28 => "Meta-Labeling (Lopez de Prado)",
    29 => "Fractional Differentiation Signal",
    30 => "Triple-Barrier Regime",
    31 => "Kalman Filter (Prediction Market)",
    32 => "Time Decay (Prediction Market)",
    33 => "Cross-Market Arbitrage",
    34 => "Momentum-Sentiment Fusion",
)

# Models that depend on other models' results (must run in Phase 2)
const PHASE2_MODELS = Set([4, 12, 18, 19, 20, 21, 27, 28])

# Feature names for reporting
const FEATURE_NAMES = ["Ret(t)", "Ret(t-1)", "Ret(t-2)", "Ret(t-3)", "Ret(t-4)",
                       "Vol(20)", "VolChg", "RSI(14)", "Mom(10)",
                       "FracDiff(price)", "FracDiff(logprice)",
                       "Spread(HL)", "OrderImbalance", "TradeVelocity",
                       "DepthImbalance", "BookPressure", "SpreadBps",
                       "CVD_Divergence"]
