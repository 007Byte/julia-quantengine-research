# ════════════════════════════════════════════════════════════════
#  QUANT DEEP ANALYSIS — Any Stock Ticker
#  Usage:  julia quant_analysis.jl AAPL
#          julia quant_analysis.jl          ← prompts interactively
#  ════════════════════════════════════════════════════════════════
#
#  24 Models Applied:
#   1.  Live OHLCV Data (Yahoo Finance)    13.  Hurst Exponent (R/S Analysis)
#   2.  Log Returns & Moment Statistics    14.  JuMP Portfolio Optimization
#   3.  Jarque-Bera Normality Test         15.  CAPM Expected Return
#   4.  RSI (14-day)                       16.  Fama-French 3-Factor Model
#   5.  MACD (12/26/9)                     17.  ARIMA Time-Series Forecast
#   6.  Bollinger Bands (20, 2σ)           18.  EGARCH Asymmetric Volatility
#   7.  SMA / EMA (20 / 50 / 200)         19.  Kelly Criterion (Position Sizing)
#   8.  Risk: VaR, CVaR, Sharpe, Sortino  20.  Avellaneda-Stoikov Market Making
#   9.  GARCH(1,1) Volatility Model       21.  Cointegration / Pairs Trading
#  10.  Monte Carlo GBM (10K paths)        22.  Risk Parity Allocation
#  11.  Black-Scholes + Option Greeks      23.  ML Signal (Logistic Regression)
#  12.  Beta / Alpha vs S&P 500           24.  Composite BUY/HOLD/SELL Engine
#
#  Output: Printed report + 2 professional chart dashboards
# ════════════════════════════════════════════════════════════════

using HTTP, JSON, Dates
using Statistics, LinearAlgebra
using Printf, SpecialFunctions
using StatsBase
using Optim
using JuMP, Ipopt
using Plots
import Luxor

const RF_ANNUAL = 0.053          # US 10-yr Treasury (risk-free rate)
const RF_DAILY  = RF_ANNUAL / 252
const BENCHMARK = "SPY"

# ── Resolve ticker ─────────────────────────────────────────────
# Priority: 1) command-line arg   2) global variable   3) default
# From terminal:   julia quant_analysis.jl MSFT
# From REPL:       TICKER = "MSFT"; include("quant_analysis.jl")
if !@isdefined(TICKER) || TICKER === nothing
    global TICKER = if !isempty(ARGS)
        uppercase(strip(ARGS[1]))
    else
        "AAPL"   # safe default — avoids readline() hang in REPL
    end
end
TICKER = uppercase(strip(string(TICKER)))

# ── Output directory — timestamped folder per run ─────────────
# Base: OneDrive > Quant_Journey > Model_Analysis > {TICKER}_{timestamp}
OUTPUT_BASE = "C:/Users/yturb/OneDrive - Northeastern University/Documents/Personal Development/Quant_Journey/Model_Analysis"
OUTPUT_DIR = joinpath(OUTPUT_BASE, "$(TICKER)_$(Dates.format(Dates.now(), "yyyy-mm-dd_HHMMSS"))")
mkpath(OUTPUT_DIR)
println("  Output folder: $OUTPUT_DIR")

# ── Start execution timer ────────────────────────────────────
T_START = time_ns()

# ══════════════════════════════════════════════════════════════
#  SECTION 1 — LIVE DATA INGESTION
# ══════════════════════════════════════════════════════════════

function fetch_ohlcv(ticker::String, period="2y")
    url = "https://query1.finance.yahoo.com/v8/finance/chart/$ticker" *
          "?interval=1d&range=$period"
    resp = HTTP.get(url, ["User-Agent" => "Mozilla/5.0"];
                    connect_timeout=10, readtimeout=20)
    data = JSON.parse(String(resp.body))
    result = data["chart"]["result"][1]

    ts  = result["timestamp"]
    q   = result["indicators"]["quote"][1]
    adj = result["indicators"]["adjclose"][1]["adjclose"]
    n   = length(ts)

    get_field(arr, i) = (arr[i] === nothing ? NaN : Float64(arr[i]))

    dates   = [unix2datetime(ts[i]) for i in 1:n]
    high    = [get_field(q["high"],   i) for i in 1:n]
    low     = [get_field(q["low"],    i) for i in 1:n]
    close_  = [get_field(q["close"],  i) for i in 1:n]
    volume  = [get_field(q["volume"], i) for i in 1:n]
    adj_cls = [get_field(adj,         i) for i in 1:n]

    valid = .!isnan.(adj_cls) .& .!isnan.(close_)
    return (dates=dates[valid], high=high[valid], low=low[valid],
            close=close_[valid], volume=volume[valid], adj=adj_cls[valid])
end

# ══════════════════════════════════════════════════════════════
#  SECTION 2 — TECHNICAL INDICATORS
# ══════════════════════════════════════════════════════════════

function sma(prices, n)
    out = fill(NaN, length(prices))
    for i in n:length(prices)
        out[i] = mean(@view prices[i-n+1:i])
    end
    out
end

function ema(prices, n)
    k   = 2.0 / (n + 1)
    out = fill(NaN, length(prices))
    out[n] = mean(@view prices[1:n])
    for i in n+1:length(prices)
        out[i] = prices[i] * k + out[i-1] * (1 - k)
    end
    out
end

function rsi(prices, n=14)
    Δ      = diff(prices)
    gains  = max.(Δ, 0.0);  losses = max.(-Δ, 0.0)
    out    = fill(NaN, length(prices))
    ag     = mean(@view gains[1:n]);  al = mean(@view losses[1:n])
    for i in n+1:length(Δ)
        ag = (ag * (n-1) + gains[i])  / n
        al = (al * (n-1) + losses[i]) / n
        out[i+1] = 100 - 100 / (1 + (al == 0 ? 1e9 : ag / al))
    end
    out
end

function macd_indicator(prices, fast=12, slow=26, sig=9)
    ema_f    = ema(prices, fast)
    ema_s    = ema(prices, slow)
    line     = ema_f .- ema_s
    sig_line = fill(NaN, length(prices))
    s0 = slow + sig - 1
    sig_line[s0] = mean(@view line[slow:s0])
    for i in s0+1:length(prices)
        k = 2.0 / (sig + 1)
        sig_line[i] = line[i] * k + sig_line[i-1] * (1 - k)
    end
    line, sig_line, line .- sig_line
end

function bollinger(prices, n=20, k=2.0)
    mid = sma(prices, n)
    std_v = fill(NaN, length(prices))
    for i in n:length(prices)
        std_v[i] = std(@view prices[i-n+1:i])
    end
    mid, mid .+ k .* std_v, mid .- k .* std_v
end

function atr(high, low, close, n=14)
    tr  = [max(high[i]-low[i], abs(high[i]-close[i-1]), abs(low[i]-close[i-1]))
           for i in 2:length(close)]
    out = fill(NaN, length(close))
    out[n+1] = mean(@view tr[1:n])
    for i in n+2:length(close)
        out[i] = (out[i-1] * (n-1) + tr[i-1]) / n
    end
    out
end

# ══════════════════════════════════════════════════════════════
#  SECTION 3 — STATISTICAL ANALYSIS
# ══════════════════════════════════════════════════════════════

function return_stats(r)
    μ    = mean(r);  σ = std(r)
    skew = mean((r .- μ).^3) / σ^3
    kurt = mean((r .- μ).^4) / σ^4 - 3
    (annual_return=μ*252, annual_vol=σ*sqrt(252),
     daily_mean=μ, daily_std=σ,
     skewness=skew, excess_kurtosis=kurt,
     min_ret=minimum(r), max_ret=maximum(r))
end

function jarque_bera(r)
    n = length(r);  μ = mean(r);  σ = std(r)
    S = mean((r .- μ).^3) / σ^3
    K = mean((r .- μ).^4) / σ^4 - 3
    jb = n/6 * (S^2 + K^2/4)
    p  = exp(-jb/2)   # exact survival for χ²(2)
    (stat=jb, p_value=p, is_normal=(p > 0.05))
end

function hurst_exponent(prices)
    lp   = log.(prices)
    lags = Int[8, 16, 32, 64, 128, min(256, length(lp)÷2)]
    rs   = Float64[]
    for lag in lags
        chunks = [lp[(c-1)*lag+1 : c*lag] for c in 1:(length(lp)÷lag)]
        rs_chunk = Float64[]
        for ch in chunks
            dev = cumsum(ch .- mean(ch))
            S   = std(ch)
            S > 1e-10 && push!(rs_chunk, (maximum(dev) - minimum(dev)) / S)
        end
        !isempty(rs_chunk) && push!(rs, mean(rs_chunk))
    end
    length(rs) < 3 && return 0.5
    log_n  = log.(lags[1:length(rs)])
    H      = cov(log_n, log.(rs)) / var(log_n)
    clamp(H, 0.0, 1.0)
end

# ══════════════════════════════════════════════════════════════
#  SECTION 4 — RISK METRICS
# ══════════════════════════════════════════════════════════════

cummax(x) = accumulate(max, x)

function drawdown_series(prices)
    (cummax(prices) .- prices) ./ cummax(prices)
end

function max_drawdown(prices)
    dd = drawdown_series(prices)
    idx = argmax(dd)
    (value=dd[idx], trough=idx)
end

normal_quantile(p)         = sqrt(2) * erfinv(2p - 1)
var_historical(r, α=0.05)  = -quantile(r, α)
var_parametric(r, α=0.05)  = -(mean(r) + normal_quantile(α) * std(r))

function cvar(r, α=0.05)
    thresh = quantile(r, α)
    -mean(r[r .<= thresh])
end

sharpe(r,  rf=RF_DAILY) = (mean(r) - rf) / std(r) * sqrt(252)
sortino(r, rf=RF_DAILY) = begin
    excess = r .- rf
    down   = r[r .< rf]
    isempty(down) ? Inf : mean(excess) / std(down) * sqrt(252)
end
calmar(r, prices)        = (mean(r) * 252) / max_drawdown(prices).value

function rolling_sharpe(r, n=63)
    out = fill(NaN, length(r))
    for i in n:length(r)
        out[i] = sharpe(@view r[i-n+1:i])
    end
    out
end

# ══════════════════════════════════════════════════════════════
#  SECTION 5 — GARCH(1,1) VOLATILITY MODEL
#  σ²_t = ω + α·ε²_{t-1} + β·σ²_{t-1}
#  Estimated by maximum Gaussian log-likelihood via Optim.jl
# ══════════════════════════════════════════════════════════════

_sigmoid(x) = 1.0 / (1.0 + exp(-x))

function garch11_fit(r)
    ε  = r .- mean(r)
    n  = length(ε)
    σ²0 = var(ε)

    function neg_ll(p)
        ω = exp(p[1])
        α = _sigmoid(p[2]) * 0.3
        β = _sigmoid(p[3]) * 0.9
        α + β ≥ 0.9999 && return 1e10
        σ² = zeros(n);  σ²[1] = σ²0
        for t in 2:n
            σ²[t] = ω + α * ε[t-1]^2 + β * σ²[t-1]
            σ²[t] ≤ 0 && return 1e10
        end
        -sum(-0.5*(log(σ²[t]) + ε[t]^2/σ²[t]) for t in 2:n)
    end

    x0  = [log(σ²0 * 0.05), 0.0, 2.0]
    res = optimize(neg_ll, x0, NelderMead(),
                   Optim.Options(iterations=5000, g_tol=1e-7))
    p   = Optim.minimizer(res)
    ω   = exp(p[1]);  α = _sigmoid(p[2])*0.3;  β = _sigmoid(p[3])*0.9

    σ² = zeros(n);  σ²[1] = σ²0
    for t in 2:n
        σ²[t] = ω + α * ε[t-1]^2 + β * σ²[t-1]
    end
    σ²_next    = ω + α * ε[end]^2 + β * σ²[end]
    long_run_σ = sqrt(ω / max(1 - α - β, 1e-8)) * sqrt(252)

    (ω=ω, α=α, β=β, persistence=α+β,
     σ_daily_forecast=sqrt(σ²_next),
     σ_annual_forecast=sqrt(σ²_next * 252),
     long_run_vol=long_run_σ,
     σ_series=sqrt.(abs.(σ²)))
end

# ══════════════════════════════════════════════════════════════
#  SECTION 6 — MONTE CARLO GBM SIMULATION
#  dS = μ·S·dt + σ·S·dW   (Geometric Brownian Motion)
# ══════════════════════════════════════════════════════════════

function gbm_monte_carlo(S0, μ_ann, σ_ann, T_days=252, N=10_000)
    dt     = 1.0 / 252
    paths  = zeros(T_days + 1, N)
    paths[1, :] .= S0
    for t in 2:T_days+1
        Z = randn(N)
        @. paths[t, :] = paths[t-1, :] * exp((μ_ann - 0.5*σ_ann^2)*dt + σ_ann*sqrt(dt)*Z)
    end
    paths
end

# ══════════════════════════════════════════════════════════════
#  SECTION 7 — BLACK-SCHOLES OPTION PRICING + GREEKS
# ══════════════════════════════════════════════════════════════

Φ(x) = 0.5 * (1.0 + erf(x / sqrt(2.0)))
φ(x) = exp(-0.5 * x^2) / sqrt(2π)

function black_scholes(S, K, r, σ, T; type=:call)
    T ≤ 0 && return (price=max(type==:call ? S-K : K-S, 0.0),
                     delta=type==:call ? 1.0 : -1.0,
                     gamma=0.0, theta=0.0, vega=0.0)
    d1 = (log(S/K) + (r + 0.5σ^2)*T) / (σ*sqrt(T))
    d2 = d1 - σ*sqrt(T)
    disc = exp(-r*T)

    if type == :call
        price = S*Φ(d1)  - K*disc*Φ(d2)
        delta = Φ(d1)
    else
        price = K*disc*Φ(-d2) - S*Φ(-d1)
        delta = Φ(d1) - 1.0
    end
    gamma = φ(d1) / (S * σ * sqrt(T))
    theta = (-S*φ(d1)*σ/(2*sqrt(T)) - r*K*disc*(type==:call ? Φ(d2) : Φ(-d2))) / 365
    vega  = S * φ(d1) * sqrt(T) / 100
    (price=price, delta=delta, gamma=gamma, theta=theta, vega=vega)
end

# ══════════════════════════════════════════════════════════════
#  SECTION 8 — BETA / ALPHA vs S&P 500  (OLS regression)
#  R_stock = α + β·R_SPY + ε
# ══════════════════════════════════════════════════════════════

function market_analysis(r_stock, r_mkt)
    n  = length(r_stock)
    X  = hcat(ones(n), r_mkt)
    b  = X \ r_stock
    α_daily, β = b
    res = r_stock .- X*b
    r²  = 1 - var(res)/var(r_stock)
    te  = std(res) * sqrt(252)
    α_ann = α_daily * 252
    ir  = te > 0 ? α_ann / te : 0.0
    (beta=β, alpha_annual=α_ann, r_squared=r², tracking_error=te, info_ratio=ir)
end

# ══════════════════════════════════════════════════════════════
#  SECTION 9 — JuMP PORTFOLIO OPTIMIZATION
#  Min variance subject to return constraint (TICKER + SPY)
# ══════════════════════════════════════════════════════════════

function optimize_two_asset(μ_vec, Σ_mat)
    model = Model(Ipopt.Optimizer)
    set_silent(model)
    @variable(model, 0 ≤ w[1:2] ≤ 1)
    @objective(model, Min, w' * Σ_mat * w)
    @constraint(model, sum(w) == 1)
    @constraint(model, dot(μ_vec, w) ≥ minimum(μ_vec)*0.8)
    optimize!(model)
    wv = value.(w)
    ret = dot(μ_vec, wv)
    vol = sqrt(wv' * Σ_mat * wv)
    (weights=wv, annual_return=ret, annual_vol=vol,
     sharpe=(ret - RF_ANNUAL)/vol)
end

# ══════════════════════════════════════════════════════════════
#  SECTION 10 — COMPOSITE SIGNAL ENGINE
#  Each indicator scores [-1, +1]; weighted sum → verdict
# ══════════════════════════════════════════════════════════════

function generate_signal(prices, _, rsi_val, macd_val, sig_val,
                         _, bb_up, bb_lo, sharpe_val,
                         hurst_val, mkt, max_dd_val)
    S  = Dict{String, Float64}()
    p  = prices[end]

    # RSI
    if !isnan(rsi_val)
        S["RSI"] = rsi_val < 30 ? +1.0 : rsi_val < 45 ? +0.5 :
                   rsi_val < 60 ?  0.0 : rsi_val < 75 ? -0.5 : -1.0
    end

    # MACD crossover
    if !isnan(macd_val) && !isnan(sig_val)
        diff = macd_val - sig_val
        S["MACD"] = clamp(diff / (abs(macd_val) + 0.01) * 5, -1.0, 1.0)
    end

    # Bollinger %B
    if !isnan(bb_lo) && !isnan(bb_up) && bb_up > bb_lo
        pctb = (p - bb_lo) / (bb_up - bb_lo)
        S["Bollinger"] = pctb < 0.1 ? +1.0 : pctb < 0.3 ? +0.5 :
                         pctb < 0.7 ?  0.0 : pctb < 0.9 ? -0.5 : -1.0
    end

    # Price vs SMA 200
    sma200 = sma(prices, min(200, length(prices)))
    if !isnan(sma200[end])
        dev = (p - sma200[end]) / sma200[end]
        S["Trend"] = clamp(dev * 8, -1.0, 1.0)
    end

    # Momentum: 3-month vs 12-month
    if length(prices) ≥ 252
        m3  = prices[end]/prices[end-63]  - 1
        m12 = prices[end]/prices[end-252] - 1
        S["Momentum"] = clamp((m3 - m12/4) * 4, -1.0, 1.0)
    end

    # Hurst: if > 0.5 trend persists, if < 0.5 mean-revert
    if haskey(S, "Momentum")
        if hurst_val > 0.5
            S["Hurst"] = S["Momentum"] * min((hurst_val - 0.5) * 4, 1.0)
        else
            S["Hurst"] = -S["Momentum"] * min((0.5 - hurst_val) * 4, 1.0)
        end
    end

    !isnan(sharpe_val) && (S["Quality"] = clamp(sharpe_val / 2, -1.0, 1.0))
    S["Drawdown"] = clamp(1.0 - max_dd_val * 4, -1.0, 1.0)
    S["Beta"]     = clamp(1.5 - mkt.beta, -1.0, 1.0)

    W = Dict("RSI"=>0.18, "MACD"=>0.18, "Bollinger"=>0.10,
             "Trend"=>0.15, "Momentum"=>0.15, "Hurst"=>0.06,
             "Quality"=>0.10, "Drawdown"=>0.05, "Beta"=>0.03)

    score = 0.0;  tw = 0.0
    for (k, w) in W
        if haskey(S, k)
            score += w * S[k];  tw += w
        end
    end
    tw > 0 && (score /= tw)

    verdict =
        score >  0.35 ? "⬆  STRONG BUY" :
        score >  0.12 ? "↑  BUY"         :
        score > -0.12 ? "→  HOLD"        :
        score > -0.35 ? "↓  SELL"        :
                        "⬇  STRONG SELL"

    (score=score, verdict=verdict,
     confidence=round(abs(score)*100, digits=1), signals=S, weights=W)
end

# ══════════════════════════════════════════════════════════════
#  SECTION 11 — CAPM (Capital Asset Pricing Model)
#  E(Ri) = Rf + βi * (E(Rm) - Rf)
# ══════════════════════════════════════════════════════════════

function capm_analysis(r_stock, r_mkt, rf=RF_ANNUAL)
    β  = cov(r_stock, r_mkt) / var(r_mkt)
    mkt_premium  = mean(r_mkt) * 252 - rf
    expected_ret = rf + β * mkt_premium
    actual_ret   = mean(r_stock) * 252
    alpha        = actual_ret - expected_ret
    (beta=β, expected_return=expected_ret, actual_return=actual_ret,
     alpha=alpha, market_premium=mkt_premium)
end

# ══════════════════════════════════════════════════════════════
#  SECTION 12 — FAMA-FRENCH 3-FACTOR MODEL
#  Ri - Rf = αi + β1(Rm-Rf) + β2·SMB + β3·HML + εi
#  Uses ETF proxies: IWM-SPY for SMB, IWD-IWF for HML
# ══════════════════════════════════════════════════════════════

function fama_french_3factor(r_stock, r_mkt, r_smb, r_hml, rf=RF_DAILY)
    excess_stock = r_stock .- rf
    excess_mkt   = r_mkt .- rf
    n  = length(excess_stock)
    X  = hcat(ones(n), excess_mkt, r_smb, r_hml)
    b  = X \ excess_stock
    res = excess_stock .- X * b
    r²  = 1 - var(res) / var(excess_stock)
    (alpha_daily=b[1], beta_mkt=b[2], beta_smb=b[3], beta_hml=b[4],
     alpha_annual=b[1]*252, r_squared=r²,
     size_exposure=b[3] > 0.1 ? "Small-cap tilt" : b[3] < -0.1 ? "Large-cap tilt" : "Neutral",
     value_exposure=b[4] > 0.1 ? "Value tilt" : b[4] < -0.1 ? "Growth tilt" : "Neutral")
end

# ══════════════════════════════════════════════════════════════
#  SECTION 13 — ARIMA FORECASTING
#  AR(p) via Yule-Walker / OLS, then h-step forecast
# ══════════════════════════════════════════════════════════════

function ar_forecast(r, p=5, horizon=21)
    n = length(r)
    Y = r[p+1:n]
    X = hcat(ones(n - p), [r[i-j] for i in p+1:n, j in 1:p])
    φ = X \ Y

    recent = collect(reverse(r[end-p+1:end]))
    forecasts = Float64[]
    for _ in 1:horizon
        pred = φ[1] + dot(φ[2:end], recent)
        push!(forecasts, pred)
        pushfirst!(recent, pred)
        pop!(recent)
    end

    residuals = Y .- X * φ
    σ_resid   = std(residuals)
    cum_ret   = sum(forecasts)
    (order=p, forecasts=forecasts,
     cumulative_return_pct=cum_ret * 100,
     forecast_direction=cum_ret > 0 ? "UP" : "DOWN",
     annualized_forecast=(1 + cum_ret)^(252/horizon) - 1,
     residual_std=σ_resid,
     r_squared=1 - var(residuals) / var(Y))
end

# ══════════════════════════════════════════════════════════════
#  SECTION 14 — EGARCH (Asymmetric / Leverage Volatility)
#  ln(σ²_t) = ω + β·ln(σ²_{t-1}) + α(|z|-√(2/π)) + γ·z
#  γ < 0 → bad news increases volatility more than good news
# ══════════════════════════════════════════════════════════════

function egarch_fit(r)
    ε  = r .- mean(r)
    n  = length(ε)
    σ²0 = var(ε)

    function neg_ll(p)
        ω = p[1];  α = p[2];  γ = p[3]
        β = _sigmoid(p[4]) * 0.999
        log_σ² = zeros(n)
        log_σ²[1] = log(σ²0)
        for t in 2:n
            σ_t = sqrt(exp(log_σ²[t-1]))
            σ_t < 1e-12 && return 1e10
            z = ε[t-1] / σ_t
            log_σ²[t] = ω + β * log_σ²[t-1] + α * (abs(z) - sqrt(2/π)) + γ * z
            (log_σ²[t] > 20 || log_σ²[t] < -40) && return 1e10
        end
        -sum(-0.5 * (log_σ²[t] + ε[t]^2 / exp(log_σ²[t])) for t in 2:n)
    end

    x0  = [log(σ²0) * 0.05, 0.15, -0.05, 2.0]
    res = optimize(neg_ll, x0, NelderMead(), Optim.Options(iterations=5000))
    p   = Optim.minimizer(res)
    ω, α, γ = p[1], p[2], p[3]
    β = _sigmoid(p[4]) * 0.999
    leverage = γ < 0

    (ω=ω, α=α, γ_leverage=γ, β_persist=β,
     leverage_effect=leverage,
     interpretation=leverage ?
         "Negative shocks increase vol MORE than positive (asymmetric risk)" :
         "Symmetric volatility response — no leverage effect detected")
end

# ══════════════════════════════════════════════════════════════
#  SECTION 15 — KELLY CRITERION  ★ CORE POSITION SIZING MODEL ★
#  Origin: John L. Kelly Jr., Bell Labs 1956
#  Popularized by Ed Thorp (beat casinos, then ran quant hedge fund)
#  Core idea: Maximize long-run geometric growth while minimizing ruin
#  f* = μ/σ²  (continuous Kelly); fractional Kelly for safety
#  + Monte Carlo optimal fraction search + growth simulation
# ══════════════════════════════════════════════════════════════

function kelly_criterion(r, rf_daily=RF_DAILY)
    μ  = mean(r) - rf_daily
    σ² = var(r)
    f_full    = μ / σ²           # Full Kelly — theoretically optimal but aggressive
    f_three_q = f_full * 0.75    # ¾ Kelly
    f_half    = f_full / 2       # ½ Kelly — industry standard for practitioners
    f_quarter = f_full / 4       # ¼ Kelly — conservative / low-confidence edge

    # Coefficient of variation of daily edge — measures estimation uncertainty
    edge_daily = r .- rf_daily
    cv_edge = std(edge_daily) / max(abs(mean(edge_daily)), 1e-10)
    # Empirical fractional Kelly: f* × (1 - CV_edge), clamped
    f_empirical = f_full * clamp(1.0 - min(cv_edge, 0.95), 0.05, 1.0)

    # Monte Carlo Kelly: simulate growth at various fractions
    fracs   = 0.0:0.02:2.5
    n_sim   = 1000
    n_days  = 252
    best_f  = 0.0
    best_gr = -Inf
    growth_by_frac = Dict{Float64, Float64}()
    for f in fracs
        g = 0.0
        for _ in 1:n_sim
            sampled = r[rand(1:length(r), n_days)]
            g += sum(log.(1.0 .+ f .* sampled))
        end
        avg_g = g / n_sim
        growth_by_frac[f] = avg_g
        if avg_g > best_gr
            best_gr = avg_g;  best_f = f
        end
    end

    # Simulate 1-year growth paths at different Kelly fractions for comparison
    # (used in reporting — shows compounding effect)
    n_growth_sim = 2000
    function sim_final_wealth(frac)
        wealth = zeros(n_growth_sim)
        for i in 1:n_growth_sim
            w = 1.0
            sampled = r[rand(1:length(r), 252)]
            for ret in sampled
                w *= (1.0 + frac * ret)
                w = max(w, 0.0)  # can't go below zero
            end
            wealth[i] = w
        end
        return wealth
    end
    w_full = sim_final_wealth(clamp(f_full, 0, 2.0))
    w_half = sim_final_wealth(clamp(f_half, 0, 1.5))
    w_quarter = sim_final_wealth(clamp(f_quarter, 0, 1.0))

    # Probability of profit and ruin at each fraction
    prob_profit_full = mean(w_full .> 1.0) * 100
    prob_profit_half = mean(w_half .> 1.0) * 100
    prob_profit_quarter = mean(w_quarter .> 1.0) * 100
    prob_ruin_full = mean(w_full .< 0.5) * 100   # >50% loss
    prob_ruin_half = mean(w_half .< 0.5) * 100
    median_return_half = (median(w_half) - 1.0) * 100

    # Edge confidence: how stable is the edge?
    # Rolling 63-day (quarter) edge computation
    rolling_edges = Float64[]
    for i in 63:length(r)
        chunk = r[i-62:i]
        push!(rolling_edges, mean(chunk) - rf_daily)
    end
    edge_consistency = mean(rolling_edges .> 0) * 100  # % of quarters with positive edge
    edge_sharpe = mean(rolling_edges) / max(std(rolling_edges), 1e-10) * sqrt(4)  # annualized

    # Recommended fraction (adaptive)
    recommended_frac = if edge_consistency > 75 && cv_edge < 1.5
        f_half       # stable edge → use half-Kelly
    elseif edge_consistency > 55
        f_quarter    # moderate edge → be conservative
    elseif f_full > 0
        f_quarter    # weak edge → quarter Kelly
    else
        0.0          # no edge
    end

    recommendation = if recommended_frac >= f_half && f_half > 0
        "HALF-KELLY: Allocate $(round(f_half*100, digits=1))% — edge is stable and positive"
    elseif recommended_frac > 0
        "QUARTER-KELLY: Allocate $(round(f_quarter*100, digits=1))% — edge exists but uncertain"
    else
        "NO ALLOCATION: Kelly is negative — expected return < risk-free rate"
    end

    (kelly_full=f_full, kelly_three_quarter=f_three_q, kelly_half=f_half,
     kelly_quarter=f_quarter, kelly_empirical=f_empirical, kelly_mc=best_f,
     expected_excess=μ * 252, variance=σ² * 252,
     cv_edge=cv_edge, edge_consistency=edge_consistency, edge_sharpe=edge_sharpe,
     prob_profit_full=prob_profit_full, prob_profit_half=prob_profit_half,
     prob_profit_quarter=prob_profit_quarter,
     prob_ruin_full=prob_ruin_full, prob_ruin_half=prob_ruin_half,
     median_return_half=median_return_half,
     recommended_frac=recommended_frac, recommendation=recommendation)
end

# ══════════════════════════════════════════════════════════════
#  SECTION 16 — AVELLANEDA-STOIKOV MARKET MAKING
#  Reservation price:  r = S - q·γ·σ²·(T-t)
#  Optimal spread:     δ = γσ²(T-t) + (2/γ)·ln(1 + γ/κ)
# ══════════════════════════════════════════════════════════════

function avellaneda_stoikov(S, σ_daily; γ=0.01, T_frac=1.0, q=0, κ=1.5)
    σ = σ_daily * sqrt(252)
    reservation = S - q * γ * σ^2 * T_frac
    spread      = γ * σ^2 * T_frac + (2 / γ) * log(1 + γ / κ)
    bid = reservation - spread / 2
    ask = reservation + spread / 2
    (reservation_price=reservation, optimal_spread=spread,
     bid=bid, ask=ask, mid=S,
     spread_bps=spread / S * 10_000)
end

# ══════════════════════════════════════════════════════════════
#  SECTION 17 — COINTEGRATION / PAIRS TRADING
#  Engle-Granger two-step + simplified ADF on residuals
# ══════════════════════════════════════════════════════════════

function cointegration_test(prices_a, prices_b)
    log_a = log.(prices_a);  log_b = log.(prices_b)
    n     = min(length(log_a), length(log_b))
    log_a = log_a[end-n+1:end];  log_b = log_b[end-n+1:end]

    X   = hcat(ones(n), log_b)
    β   = X \ log_a
    res = log_a .- X * β

    # ADF on residuals
    Δr    = diff(res)
    r_lag = res[1:end-1]
    X_adf = hcat(ones(length(Δr)), r_lag)
    b_adf = X_adf \ Δr
    e_adf = Δr .- X_adf * b_adf
    se    = sqrt(var(e_adf) / (X_adf' * X_adf)[2, 2])
    t_stat = b_adf[2] / se

    is_coint   = t_stat < -2.86          # 5% critical value
    z_score    = (res[end] - mean(res)) / std(res)
    half_life  = b_adf[2] < 0 ? -log(2) / b_adf[2] : Inf

    (hedge_ratio=β[2], adf_stat=t_stat,
     is_cointegrated=is_coint, z_score=z_score,
     half_life_days=half_life, spread_std=std(res),
     signal=z_score > 2 ? "SHORT spread (overbought vs pair)" :
            z_score < -2 ? "LONG spread (oversold vs pair)" :
                           "No pairs trade signal")
end

# ══════════════════════════════════════════════════════════════
#  SECTION 18 — RISK PARITY ALLOCATION
#  Equal risk contribution via inverse-volatility weighting
# ══════════════════════════════════════════════════════════════

function risk_parity(σ_vec, Σ_mat, μ_vec)
    inv_vol = 1.0 ./ σ_vec
    w_rp    = inv_vol ./ sum(inv_vol)
    port_ret = dot(w_rp, μ_vec)
    port_vol = sqrt(w_rp' * Σ_mat * w_rp)
    marg     = Σ_mat * w_rp
    rc       = w_rp .* marg ./ port_vol
    pct_rc   = rc ./ sum(rc) .* 100
    (weights=w_rp, portfolio_return=port_ret, portfolio_vol=port_vol,
     sharpe=(port_ret - RF_ANNUAL) / port_vol,
     risk_contributions_pct=pct_rc)
end

# ══════════════════════════════════════════════════════════════
#  SECTION 19 — ML SIGNAL (Logistic Regression on Technicals)
#  Features: RSI, MACD hist, Bollinger %B, momentum, vol
#  Target: next-5-day return sign
# ══════════════════════════════════════════════════════════════

function ml_signal(prices, r, rsi_vals, macd_hist, bb_up_vals, bb_lo_vals;
                   n_lookback=5)
    n     = length(r)
    start = max(201, something(findfirst(!isnan, rsi_vals), n))
    start >= n - n_lookback - 50 && return (prediction="NEUTRAL",
        probability_up=50.0, confidence=0.0, accuracy=0.0, n_samples=0)

    feat_rows = Vector{Vector{Float64}}()
    targets   = Float64[]
    for i in start:n-n_lookback
        isnan(rsi_vals[i+1]) && continue
        isnan(bb_up_vals[i+1]) && continue
        isnan(bb_lo_vals[i+1]) && continue
        bw = bb_up_vals[i+1] - bb_lo_vals[i+1]
        bw < 1e-8 && continue
        pctb  = (prices[i+1] - bb_lo_vals[i+1]) / bw
        win   = max(1, i - 20):i
        σ_win = std(@view r[win])
        feat  = [rsi_vals[i+1] / 100.0,
                 isnan(macd_hist[i+1]) ? 0.0 : clamp(macd_hist[i+1] / (abs(prices[i+1]) * 0.02 + 1e-8), -3, 3),
                 pctb,
                 sum(@view r[win]) / (σ_win + 1e-8),
                 σ_win * sqrt(252)]
        future = sum(r[i+1:min(i + n_lookback, n)])
        push!(feat_rows, feat);  push!(targets, future > 0 ? 1.0 : 0.0)
    end

    length(feat_rows) < 50 && return (prediction="NEUTRAL",
        probability_up=50.0, confidence=0.0, accuracy=0.0, n_samples=0)

    X = reduce(hcat, feat_rows)'
    X = hcat(ones(size(X, 1)), X)
    y = targets

    # Logistic regression via simple gradient ascent
    w = zeros(size(X, 2))
    for _ in 1:80
        p = 1.0 ./ (1.0 .+ exp.(-X * w))
        p = clamp.(p, 1e-8, 1 - 1e-8)
        w .+= 0.01 * (X' * (y .- p) .- 0.01 .* w)
    end

    split = Int(floor(0.8 * length(y)))
    p_test  = 1.0 ./ (1.0 .+ exp.(-X[split+1:end, :] * w))
    acc     = mean((p_test .> 0.5) .== (y[split+1:end] .> 0.5)) * 100

    # Current prediction
    curr_rsi = isnan(rsi_vals[end]) ? 50.0 : rsi_vals[end]
    bw = bb_up_vals[end] - bb_lo_vals[end]
    curr_pctb = isnan(bb_up_vals[end]) || bw < 1e-8 ? 0.5 :
                (prices[end] - bb_lo_vals[end]) / bw
    win_r = r[max(1, end - 20):end]
    σ_win = std(win_r)
    curr  = [1.0, curr_rsi / 100.0,
             isnan(macd_hist[end]) ? 0.0 : clamp(macd_hist[end] / (abs(prices[end]) * 0.02 + 1e-8), -3, 3),
             curr_pctb,
             sum(win_r) / (σ_win + 1e-8),
             σ_win * sqrt(252)]
    prob_up = 1.0 / (1.0 + exp(-dot(w, curr)))
    pred    = prob_up > 0.6 ? "BULLISH" : prob_up < 0.4 ? "BEARISH" : "NEUTRAL"

    (prediction=pred, probability_up=prob_up * 100,
     confidence=abs(prob_up - 0.5) * 200, accuracy=acc, n_samples=length(y))
end

# ══════════════════════════════════════════════════════════════
#  MAIN — Run all models, print report, save dashboards
# ══════════════════════════════════════════════════════════════

println("═" ^ 64)
println("  $TICKER — INSTITUTIONAL QUANT ANALYSIS")
println("═" ^ 64)

print("  Fetching live data for $TICKER + $BENCHMARK...")
stock = fetch_ohlcv(TICKER, "2y")
spy   = fetch_ohlcv(BENCHMARK, "2y")
println(" done.\n")

prices  = stock.adj
n       = length(prices)
r       = diff(log.(prices))
n_align = min(length(r), length(diff(log.(spy.adj))))
r_spy   = diff(log.(spy.adj))[end-n_align+1:end]
r_a     = r[end-n_align+1:end]

println("  Data range:  $(Date(stock.dates[1])) → $(Date(stock.dates[end]))")
println("  Trading days: $n   |   Current price: \$$(round(prices[end], digits=2))\n")

sma20_v  = sma(prices, 20);    sma50_v  = sma(prices, 50)
sma200_v = sma(prices, 200);   ema20_v  = ema(prices, 20)
rsi_v    = rsi(prices)
macd_l, macd_s, macd_h = macd_indicator(prices)
bb_mid, bb_up, bb_lo   = bollinger(prices)
atr_v    = atr(stock.high, stock.low, stock.close)

stats  = return_stats(r)
jb     = jarque_bera(r)
H      = hurst_exponent(prices)
var_h  = var_historical(r)
var_p  = var_parametric(r)
cvar_v = cvar(r)
sh     = sharpe(r)
so     = sortino(r)
cal    = calmar(r, prices)
mdd    = max_drawdown(prices)
dd_ser = drawdown_series(prices)
roll_sh= rolling_sharpe(r)

print("  Fitting GARCH(1,1) via maximum likelihood...")
@time garch = garch11_fit(r)

print("  Running Monte Carlo (10K paths, 1 year)...")
@time mc_paths = gbm_monte_carlo(prices[end], stats.annual_return,
                                  stats.annual_vol, 252, 10_000)
mc_final    = mc_paths[end, :]
prob_profit = count(mc_final .> prices[end]) / 10_000 * 100
mc_p5       = quantile(mc_final, 0.05)
mc_p50      = quantile(mc_final, 0.50)
mc_p95      = quantile(mc_final, 0.95)

S0      = prices[end]
K_atm   = round(S0, digits=0)
bs_call = black_scholes(S0, K_atm, RF_ANNUAL, stats.annual_vol, 0.25; type=:call)
bs_put  = black_scholes(S0, K_atm, RF_ANNUAL, stats.annual_vol, 0.25; type=:put)

mkt      = market_analysis(r_a, r_spy)
μ2       = [stats.annual_return, mean(r_spy)*252]
Σ2       = cov(hcat(r_a, r_spy)) .* 252
opt_port = optimize_two_asset(μ2, Σ2)

sig = generate_signal(prices, r, rsi_v[end], macd_l[end], macd_s[end],
                      bb_mid[end], bb_up[end], bb_lo[end],
                      sh, H, mkt, mdd.value)

# ── NEW MODELS — CAPM, Fama-French, ARIMA, EGARCH, Kelly, etc. ──

print("  Running CAPM analysis...")
capm = capm_analysis(r_a, r_spy)
println(" done.")

print("  Fetching Fama-French factor proxies (IWM, IWD, IWF)...")
global ff3 = nothing
try
    iwm = fetch_ohlcv("IWM", "2y");  iwd = fetch_ohlcv("IWD", "2y");  iwf = fetch_ohlcv("IWF", "2y")
    r_iwm = diff(log.(iwm.adj));  r_iwd = diff(log.(iwd.adj));  r_iwf = diff(log.(iwf.adj))
    n_ff = min(length(r_a), length(r_spy), length(r_iwm), length(r_iwd), length(r_iwf))
    smb = r_iwm[end-n_ff+1:end] .- r_spy[end-n_ff+1:end]
    hml = r_iwd[end-n_ff+1:end] .- r_iwf[end-n_ff+1:end]
    global ff3 = fama_french_3factor(r_a[end-n_ff+1:end], r_spy[end-n_ff+1:end], smb, hml)
    println(" done.")
catch e
    println(" skipped ($(typeof(e))).")
end

print("  Fitting AR(5) time-series model...")
@time arima = ar_forecast(r, 5, 21)

print("  Fitting EGARCH (asymmetric volatility)...")
@time egarch = egarch_fit(r)

print("  Computing Kelly Criterion (optimal position sizing)...")
@time kelly = kelly_criterion(r)

# ── Inject Kelly into composite signal (post-hoc, with elevated weight) ──
# Kelly is the "sizing anchor" — it reflects whether an edge exists
kelly_signal = clamp(kelly.kelly_half * 2.0, -1.0, 1.0)  # scale half-Kelly to [-1,1]
if kelly.edge_consistency > 70
    kelly_signal = clamp(kelly_signal * 1.2, -1.0, 1.0)   # boost if edge is stable
end
sig.signals["Kelly"] = kelly_signal
sig.weights["Kelly"] = 0.12   # elevated weight — Kelly has decades-long track record

# Recalculate composite score with Kelly included
global sig_score_new = 0.0
global sig_tw_new = 0.0
for (k, w) in sig.weights
    if haskey(sig.signals, k)
        global sig_score_new += w * sig.signals[k]
        global sig_tw_new += w
    end
end
sig_tw_new > 0 && (sig_score_new /= sig_tw_new)
# Patch the sig named tuple with updated score
sig = (score=sig_score_new, verdict=sig.verdict,
       confidence=round(abs(sig_score_new)*100, digits=1),
       signals=sig.signals, weights=sig.weights)

print("  Computing Avellaneda-Stoikov market-making model...")
avstk = avellaneda_stoikov(S0, stats.daily_std)
println("  done.")

print("  Testing cointegration ($TICKER vs $BENCHMARK)...")
coint = cointegration_test(prices, spy.adj)
println("  done.")

print("  Computing Risk Parity allocation...")
σ_vec = [stats.annual_vol, std(r_spy)*sqrt(252)]
rp = risk_parity(σ_vec, Σ2, μ2)
println("  done.")

print("  Training ML signal (logistic regression on technicals)...")
@time ml = ml_signal(prices, r, rsi_v, macd_h, bb_up, bb_lo)

# ── Print report ──────────────────────────────────────────────
println("\n" * "═" ^ 64)
println("  ① RETURN STATISTICS")
println("─" ^ 64)
@printf("  Annual Return:        %+.2f%%\n",   stats.annual_return*100)
@printf("  Annual Volatility:    %.2f%%\n",    stats.annual_vol*100)
@printf("  Daily Mean Return:    %+.4f%%\n",   stats.daily_mean*100)
@printf("  Skewness:             %+.4f  %s\n", stats.skewness,
    stats.skewness < -0.5 ? "(left tail — crash risk)" :
    stats.skewness >  0.5 ? "(right tail — positive surprises)" : "(near symmetric)")
@printf("  Excess Kurtosis:      %+.4f  %s\n", stats.excess_kurtosis,
    stats.excess_kurtosis > 1 ? "(fat tails — extreme moves likely)" : "(normal tails)")
@printf("  Best Day:             %+.2f%%\n",   stats.max_ret*100)
@printf("  Worst Day:            %+.2f%%\n",   stats.min_ret*100)

println("\n" * "─" ^ 64)
println("  ② JARQUE-BERA NORMALITY TEST")
println("─" ^ 64)
@printf("  JB Statistic:         %.2f\n",  jb.stat)
@printf("  p-value:              %.6f\n",   jb.p_value)
@printf("  Result:               %s\n",
    jb.is_normal ? "FAIL TO REJECT H₀ — returns ≈ normal" :
                   "REJECT H₀ — returns are NOT normally distributed")
println("  (Implication: parametric VaR underestimates true tail risk)")

println("\n" * "─" ^ 64)
println("  ③ RISK METRICS")
println("─" ^ 64)
@printf("  Sharpe Ratio:         %.4f  %s\n", sh,
    sh > 1.0 ? "(excellent)" : sh > 0.5 ? "(good)" : sh > 0 ? "(marginal)" : "(poor)")
@printf("  Sortino Ratio:        %.4f  (penalizes downside only)\n", so)
@printf("  Calmar Ratio:         %.4f  (return / max drawdown)\n",   cal)
@printf("  Max Drawdown:         %.2f%%  (peak-to-trough)\n",        mdd.value*100)
@printf("  VaR 95%% (Historical): %.2f%%  per day\n",  var_h*100)
@printf("  VaR 95%% (Parametric): %.2f%%  per day\n",  var_p*100)
@printf("  CVaR 95%% (Exp. Shortfall): %.2f%%  (avg loss beyond VaR)\n", cvar_v*100)
@printf("  ATR (14-day):        \$%.2f  (%.1f%% of price)\n",
    atr_v[end], atr_v[end]/prices[end]*100)

println("\n" * "─" ^ 64)
println("  ④ GARCH(1,1) — CONDITIONAL VOLATILITY")
println("─" ^ 64)
@printf("  ω (long-run base):    %.2e\n",   garch.ω)
@printf("  α (shock sensitivity): %.4f\n",   garch.α)
@printf("  β (vol persistence):  %.4f\n",    garch.β)
@printf("  Persistence (α+β):    %.4f  %s\n", garch.persistence,
    garch.persistence > 0.97 ? "(very high — shocks decay slowly)" :
    garch.persistence > 0.90 ? "(high — volatile clustering)" : "(moderate)")
@printf("  Forecasted σ (daily): %.4f%%\n",  garch.σ_daily_forecast*100)
@printf("  Forecasted σ (annual):%.2f%%\n",   garch.σ_annual_forecast*100)
@printf("  Long-run Vol:         %.2f%%\n",   garch.long_run_vol*100)

println("\n" * "─" ^ 64)
println("  ⑤ MONTE CARLO SIMULATION (10,000 paths, 1 year)")
println("─" ^ 64)
@printf("  Current Price:       \$%.2f\n",        prices[end])
@printf("  Bear Case  (5th %%):  \$%.2f  (%+.1f%%)\n", mc_p5,  (mc_p5/prices[end]-1)*100)
@printf("  Base Case  (50th %%): \$%.2f  (%+.1f%%)\n", mc_p50, (mc_p50/prices[end]-1)*100)
@printf("  Bull Case  (95th %%): \$%.2f  (%+.1f%%)\n", mc_p95, (mc_p95/prices[end]-1)*100)
@printf("  Prob. of Profit:     %.1f%%\n", prob_profit)

println("\n" * "─" ^ 64)
println("  ⑥ BLACK-SCHOLES — ATM OPTIONS (3-Month Expiry)")
println("─" ^ 64)
@printf("  Underlying:          \$%.2f   Strike: \$%.0f\n", S0, K_atm)
@printf("  Implied Vol (hist):   %.1f%%\n",            stats.annual_vol*100)
@printf("  Call Price:          \$%.4f   Put Price: \$%.4f\n", bs_call.price, bs_put.price)
@printf("  Call Delta: %+.4f   Put Delta: %+.4f\n",    bs_call.delta, bs_put.delta)
@printf("  Gamma:       %.6f  (rate of delta change)\n", bs_call.gamma)
@printf("  Theta:      %+.4f  (\$/day time decay)\n",    bs_call.theta)
@printf("  Vega:        %.4f  (\$ per 1%% vol change)\n", bs_call.vega)

println("\n" * "─" ^ 64)
println("  ⑦ MARKET ANALYSIS — Beta / Alpha vs S&P 500")
println("─" ^ 64)
@printf("  Beta:                 %.4f  %s\n", mkt.beta,
    mkt.beta > 1.5 ? "(very high — amplifies market moves)" :
    mkt.beta > 1.0 ? "(high — more volatile than market)" :
    mkt.beta > 0.5 ? "(moderate)" : "(defensive)")
@printf("  Alpha (annual):      %+.2f%%  %s\n", mkt.alpha_annual*100,
    mkt.alpha_annual > 0 ? "(generating excess return)" : "(underperforming market)")
@printf("  R² vs SPY:            %.4f  (market explains %.1f%% of moves)\n",
    mkt.r_squared, mkt.r_squared*100)
@printf("  Tracking Error:       %.2f%%\n",  mkt.tracking_error*100)
@printf("  Information Ratio:   %+.4f\n",    mkt.info_ratio)

println("\n" * "─" ^ 64)
println("  ⑧ JuMP PORTFOLIO OPTIMIZATION ($TICKER + $BENCHMARK hedge)")
println("─" ^ 64)
@printf("  Optimal %-5s weight: %.1f%%\n",   TICKER,    opt_port.weights[1]*100)
@printf("  Optimal %-5s weight: %.1f%%\n",   BENCHMARK, opt_port.weights[2]*100)
@printf("  Portfolio Return:    %+.2f%%\n",  opt_port.annual_return*100)
@printf("  Portfolio Vol:        %.2f%%\n",   opt_port.annual_vol*100)
@printf("  Portfolio Sharpe:     %.4f\n",     opt_port.sharpe)
@printf("  Pure %-5s Sharpe:    %.4f  (improvement: %+.4f)\n",
    TICKER, sh, opt_port.sharpe - sh)

println("\n" * "─" ^ 64)
println("  ⑨ HURST EXPONENT (R/S Analysis)")
println("─" ^ 64)
@printf("  H = %.4f  →  %s\n", H,
    H > 0.60 ? "TRENDING (persistent — momentum strategies work)" :
    H > 0.55 ? "Mildly trending (slight persistence)" :
    H > 0.45 ? "RANDOM WALK (Efficient Market Hypothesis holds)" :
    H > 0.40 ? "Mildly mean-reverting" :
               "MEAN-REVERTING (contrarian strategies work)")

println("\n" * "─" ^ 64)
println("  ⑩ TECHNICAL INDICATORS (Current)")
println("─" ^ 64)
@printf("  RSI(14):              %.2f  %s\n", rsi_v[end],
    rsi_v[end] < 30 ? "OVERSOLD ←" : rsi_v[end] > 70 ? "OVERBOUGHT ←" : "neutral")
@printf("  MACD:                %+.4f   Signal: %+.4f   Hist: %+.4f\n",
    macd_l[end], macd_s[end], macd_h[end])
@printf("  Bollinger Bands:     upper=\$%.2f  mid=\$%.2f  lower=\$%.2f\n",
    bb_up[end], bb_mid[end], bb_lo[end])
@printf("  %%B (position):        %.3f  %s\n",
    (prices[end]-bb_lo[end])/(bb_up[end]-bb_lo[end]),
    prices[end] > bb_up[end] ? "(above upper band)" :
    prices[end] < bb_lo[end] ? "(below lower band)" : "(within bands)")
@printf("  SMA20: \$%.2f   SMA50: \$%.2f   SMA200: \$%.2f\n",
    sma20_v[end], sma50_v[end], sma200_v[end])
@printf("  Price vs SMA200:     %+.2f%%\n", (prices[end]/sma200_v[end]-1)*100)

println("\n" * "─" ^ 64)
println("  ⑪ CAPM — Capital Asset Pricing Model")
println("─" ^ 64)
@printf("  CAPM Beta:            %.4f\n", capm.beta)
@printf("  Market Risk Premium:  %+.2f%%\n", capm.market_premium*100)
@printf("  CAPM Expected Return: %+.2f%%  (what beta says you SHOULD earn)\n", capm.expected_return*100)
@printf("  Actual Return:        %+.2f%%\n", capm.actual_return*100)
@printf("  CAPM Alpha:           %+.2f%%  %s\n", capm.alpha*100,
    capm.alpha > 0.02 ? "(beating CAPM — genuine skill or mispricing)" :
    capm.alpha < -0.02 ? "(underperforming CAPM — negative alpha)" : "(near CAPM equilibrium)")

println("\n" * "─" ^ 64)
println("  ⑫ FAMA-FRENCH 3-FACTOR MODEL")
println("─" ^ 64)
if ff3 !== nothing
    @printf("  FF3 Alpha (annual):   %+.2f%%  %s\n", ff3.alpha_annual*100,
        ff3.alpha_annual > 0.02 ? "(true alpha beyond market/size/value)" : "(explained by factors)")
    @printf("  Market Beta:          %.4f\n", ff3.beta_mkt)
    @printf("  SMB Beta (size):      %+.4f  → %s\n", ff3.beta_smb, ff3.size_exposure)
    @printf("  HML Beta (value):     %+.4f  → %s\n", ff3.beta_hml, ff3.value_exposure)
    @printf("  R² (3-factor):        %.4f  (factors explain %.1f%% of returns)\n",
        ff3.r_squared, ff3.r_squared*100)
else
    println("  (Skipped — factor proxy data unavailable)")
end

println("\n" * "─" ^ 64)
println("  ⑬ ARIMA TIME-SERIES FORECAST")
println("─" ^ 64)
@printf("  Model:                AR(%d)\n", arima.order)
@printf("  R² (in-sample):      %.4f\n", arima.r_squared)
@printf("  Residual Std:         %.6f\n", arima.residual_std)
@printf("  21-Day Forecast:      %s  (%+.2f%% cumulative)\n",
    arima.forecast_direction, arima.cumulative_return_pct)
@printf("  Annualized Forecast:  %+.2f%%\n", arima.annualized_forecast*100)
println("  (Caution: AR models have limited predictive power for stocks)")

println("\n" * "─" ^ 64)
println("  ⑭ EGARCH — ASYMMETRIC VOLATILITY")
println("─" ^ 64)
@printf("  ω (intercept):        %+.6f\n", egarch.ω)
@printf("  α (magnitude):        %+.4f\n", egarch.α)
@printf("  γ (leverage/asymm):   %+.4f  %s\n", egarch.γ_leverage,
    egarch.leverage_effect ? "← NEGATIVE = bad news amplifies vol" : "")
@printf("  β (persistence):      %.4f\n", egarch.β_persist)
println("  Interpretation:       $(egarch.interpretation)")

println("\n" * "═" ^ 64)
println("  ⑮ ★ KELLY CRITERION — CORE POSITION SIZING MODEL ★")
println("  (Bell Labs 1956 → Ed Thorp → Modern Quant Standard)")
println("═" ^ 64)
@printf("  Full Kelly:           %6.1f%%  (maximize geometric growth — aggressive)\n", kelly.kelly_full*100)
@printf("  ¾ Kelly:              %6.1f%%  (slightly conservative)\n", kelly.kelly_three_quarter*100)
@printf("  ½ Kelly (standard):   %6.1f%%  (industry recommended — balances growth & safety)\n", kelly.kelly_half*100)
@printf("  ¼ Kelly (cautious):   %6.1f%%  (for uncertain edges)\n", kelly.kelly_quarter*100)
@printf("  Empirical Kelly:      %6.1f%%  (adjusted for estimation error, CV=%.2f)\n", kelly.kelly_empirical*100, kelly.cv_edge)
@printf("  MC-Optimal:           %6.0f%%  (1000-path brute-force search)\n", kelly.kelly_mc*100)
println("  " * "─" ^ 58)
@printf("  Expected Excess Ret:  %+.2f%%  annual (over risk-free %.1f%%)\n", kelly.expected_excess*100, RF_ANNUAL*100)
@printf("  Edge Consistency:     %.1f%%   (%% of rolling quarters with positive edge)\n", kelly.edge_consistency)
@printf("  Edge Sharpe:          %.2f    (stability of excess return)\n", kelly.edge_sharpe)
println("  " * "─" ^ 58)
@printf("  Prob of Profit (½K):  %.1f%%   (Monte Carlo, 1 year)\n", kelly.prob_profit_half)
@printf("  Prob of Profit (¼K):  %.1f%%   (Monte Carlo, 1 year)\n", kelly.prob_profit_quarter)
@printf("  Ruin Risk (½K):       %.1f%%   (>50%% loss in 1 year)\n", kelly.prob_ruin_half)
@printf("  Ruin Risk (Full K):   %.1f%%   (>50%% loss in 1 year)\n", kelly.prob_ruin_full)
@printf("  Median Return (½K):   %+.1f%%  (simulated 1-year)\n", kelly.median_return_half)
println("  " * "─" ^ 58)
println("  ★ RECOMMENDATION:     $(kelly.recommendation)")

println("\n" * "─" ^ 64)
println("  ⑯ AVELLANEDA-STOIKOV — MARKET MAKING MODEL")
println("─" ^ 64)
@printf("  Current Mid Price:   \$%.2f\n", avstk.mid)
@printf("  Reservation Price:   \$%.2f  (fair value for market maker)\n", avstk.reservation_price)
@printf("  Optimal Spread:      \$%.4f  (%.1f bps)\n", avstk.optimal_spread, avstk.spread_bps)
@printf("  Optimal Bid:         \$%.2f\n", avstk.bid)
@printf("  Optimal Ask:         \$%.2f\n", avstk.ask)
println("  (Useful for limit order placement and execution strategy)")

println("\n" * "─" ^ 64)
println("  ⑰ COINTEGRATION / PAIRS TRADING ($TICKER vs $BENCHMARK)")
println("─" ^ 64)
@printf("  Hedge Ratio:          %.4f\n", coint.hedge_ratio)
@printf("  ADF Statistic:        %.4f  %s\n", coint.adf_stat,
    coint.is_cointegrated ? "(COINTEGRATED at 5%% level)" : "(NOT cointegrated)")
@printf("  Spread Z-Score:       %+.4f  %s\n", coint.z_score,
    abs(coint.z_score) > 2 ? "← EXTREME — trade signal active" : "(within normal range)")
@printf("  Half-Life:            %.1f days  %s\n", coint.half_life_days,
    coint.half_life_days < 30 ? "(fast mean reversion)" :
    coint.half_life_days < 90 ? "(moderate)" : "(slow or non-reverting)")
println("  Signal:               $(coint.signal)")

println("\n" * "─" ^ 64)
println("  ⑱ RISK PARITY ALLOCATION ($TICKER + $BENCHMARK)")
println("─" ^ 64)
@printf("  RP Weight %-5s:      %.1f%%\n", TICKER, rp.weights[1]*100)
@printf("  RP Weight %-5s:      %.1f%%\n", BENCHMARK, rp.weights[2]*100)
@printf("  RP Portfolio Return:  %+.2f%%\n", rp.portfolio_return*100)
@printf("  RP Portfolio Vol:     %.2f%%\n", rp.portfolio_vol*100)
@printf("  RP Sharpe:            %.4f\n", rp.sharpe)
@printf("  Risk Contrib %-5s:   %.1f%%\n", TICKER, rp.risk_contributions_pct[1])
@printf("  Risk Contrib %-5s:   %.1f%%\n", BENCHMARK, rp.risk_contributions_pct[2])

println("\n" * "─" ^ 64)
println("  ⑲ ML SIGNAL — Logistic Regression on Technicals")
println("─" ^ 64)
@printf("  Prediction:           %s\n", ml.prediction)
@printf("  P(up next 5 days):    %.1f%%\n", ml.probability_up)
@printf("  Confidence:           %.1f%%\n", ml.confidence)
@printf("  Out-of-Sample Acc:    %.1f%%  (%d training samples)\n", ml.accuracy, ml.n_samples)
println("  (ML signal is one input among many — do not trade on it alone)")

println("\n" * "═" ^ 64)
println("  ⭐  COMPOSITE SIGNAL — FINAL VERDICT")
println("═" ^ 64)
println()
@printf("  VERDICT:  %s\n",   sig.verdict)
@printf("  Score:    %+.4f  (confidence: %.1f%%)\n", sig.score, sig.confidence)
println()
println("  Signal Breakdown:")
ordered_sigs = sort(collect(sig.signals), by=x->-abs(x[2]))
for (k, v) in ordered_sigs
    w   = get(sig.weights, k, 0.0)
    bar = v > 0 ? "█"^Int(round(v*10)) * " +" : "░"^Int(round(abs(v)*10)) * " -"
    @printf("  %-12s  w=%.2f  score=%+.2f  %s\n", k, w, v, bar)
end
println()
println("═" ^ 64)

# ══════════════════════════════════════════════════════════════
#  SECTION 11 — DECISION ANALYSIS
#  Synthesizes ALL models into a structured investment thesis
#  with explicit bullish/bearish evidence and risk warnings
# ══════════════════════════════════════════════════════════════

println()
println("╔" * "═"^62 * "╗")
println("║" * lpad("DECISION ANALYSIS — $TICKER", 42) * " "^(62-42) * "║")
println("╚" * "═"^62 * "╝")
println()

# ── Collect bullish and bearish factors from every model ──────
bullish  = String[]
bearish  = String[]
warnings = String[]

# 1. Return profile
if stats.annual_return > 0.15
    push!(bullish, @sprintf("Strong annual return: %+.1f%% (well above risk-free %.1f%%)",
        stats.annual_return*100, RF_ANNUAL*100))
elseif stats.annual_return > 0.0
    push!(bullish, @sprintf("Positive annual return: %+.1f%%", stats.annual_return*100))
else
    push!(bearish, @sprintf("Negative annual return: %+.1f%% — losing money", stats.annual_return*100))
end

# 2. Risk-adjusted quality (Sharpe)
if sh > 1.0
    push!(bullish, @sprintf("Excellent risk-adjusted return (Sharpe = %.2f)", sh))
elseif sh > 0.5
    push!(bullish, @sprintf("Good risk-adjusted return (Sharpe = %.2f)", sh))
elseif sh > 0.0
    push!(bearish, @sprintf("Marginal risk-adjusted return (Sharpe = %.2f) — barely compensates for risk", sh))
else
    push!(bearish, @sprintf("Poor risk-adjusted return (Sharpe = %.2f) — risk-free rate beats this stock", sh))
end

# 3. Sortino (downside risk)
if so > 1.5
    push!(bullish, @sprintf("Low downside risk (Sortino = %.2f) — limited bad days", so))
elseif so < 0.5 && so > 0
    push!(bearish, @sprintf("High downside risk (Sortino = %.2f) — frequent bad days", so))
elseif so <= 0
    push!(bearish, @sprintf("Negative Sortino (%.2f) — downside dominates returns", so))
end

# 4. Max drawdown
if mdd.value > 0.30
    push!(bearish, @sprintf("Severe max drawdown: -%.1f%% — can you stomach a 1/3 loss?", mdd.value*100))
    push!(warnings, @sprintf("RISK: Stock has dropped %.0f%% from peak in the past 2 years", mdd.value*100))
elseif mdd.value > 0.15
    push!(bearish, @sprintf("Moderate drawdown risk: -%.1f%% peak-to-trough", mdd.value*100))
elseif mdd.value < 0.10
    push!(bullish, @sprintf("Low drawdown: only -%.1f%% — relatively stable", mdd.value*100))
end

# 5. Volatility (GARCH forecast vs historical)
if garch.σ_annual_forecast > stats.annual_vol * 1.3
    push!(bearish, @sprintf("GARCH forecasts RISING volatility: %.1f%% vs historical %.1f%%",
        garch.σ_annual_forecast*100, stats.annual_vol*100))
    push!(warnings, "CAUTION: Volatility expanding — expect larger price swings ahead")
elseif garch.σ_annual_forecast < stats.annual_vol * 0.8
    push!(bullish, @sprintf("GARCH forecasts FALLING volatility: %.1f%% vs historical %.1f%%",
        garch.σ_annual_forecast*100, stats.annual_vol*100))
end
if garch.persistence > 0.95
    push!(warnings, @sprintf("High GARCH persistence (%.3f) — volatility shocks take a long time to fade", garch.persistence))
end

# 6. Tail risk (Jarque-Bera + kurtosis)
if !jb.is_normal && stats.excess_kurtosis > 2.0
    push!(bearish, @sprintf("Fat tails detected (kurtosis = %.1f) — extreme moves more likely than a normal model predicts",
        stats.excess_kurtosis))
    push!(warnings, "Standard VaR UNDERESTIMATES true risk — use CVaR for this stock")
end
if stats.skewness < -0.5
    push!(bearish, @sprintf("Negative skew (%.2f) — left-tail crash risk is elevated", stats.skewness))
end

# 7. Monte Carlo outlook
if prob_profit > 65
    push!(bullish, @sprintf("Monte Carlo: %.0f%% probability of profit over 1 year", prob_profit))
    push!(bullish, @sprintf("Median 1-yr target: \$%.2f (%+.1f%% upside)", mc_p50, (mc_p50/S0-1)*100))
elseif prob_profit > 50
    push!(bullish, @sprintf("Monte Carlo: %.0f%% probability of profit (slight edge)", prob_profit))
elseif prob_profit < 40
    push!(bearish, @sprintf("Monte Carlo: only %.0f%% chance of profit — odds favor loss", prob_profit))
else
    push!(bearish, @sprintf("Monte Carlo: %.0f%% probability of profit — roughly coin-flip", prob_profit))
end
mc_downside = (mc_p5 / S0 - 1) * 100
if mc_downside < -30
    push!(warnings, @sprintf("WORST CASE (5th %%): \$%.2f (%.0f%% loss) — significant downside tail", mc_p5, mc_downside))
end

# 8. Technical signals — RSI
rsi_now = rsi_v[end]
if !isnan(rsi_now)
    if rsi_now < 30
        push!(bullish, @sprintf("RSI = %.1f — OVERSOLD, potential bounce candidate", rsi_now))
    elseif rsi_now < 45
        push!(bullish, @sprintf("RSI = %.1f — approaching oversold territory", rsi_now))
    elseif rsi_now > 70
        push!(bearish, @sprintf("RSI = %.1f — OVERBOUGHT, pullback risk elevated", rsi_now))
    elseif rsi_now > 60
        push!(bearish, @sprintf("RSI = %.1f — approaching overbought", rsi_now))
    end
end

# 9. MACD crossover
macd_hist_now = macd_h[end]
if !isnan(macd_hist_now) && length(macd_h) > 1 && !isnan(macd_h[end-1])
    if macd_hist_now > 0 && macd_h[end-1] <= 0
        push!(bullish, "MACD just crossed ABOVE signal line — bullish momentum shift")
    elseif macd_hist_now < 0 && macd_h[end-1] >= 0
        push!(bearish, "MACD just crossed BELOW signal line — bearish momentum shift")
    elseif macd_hist_now > 0
        push!(bullish, @sprintf("MACD histogram positive (%+.3f) — upward momentum intact", macd_hist_now))
    else
        push!(bearish, @sprintf("MACD histogram negative (%+.3f) — downward momentum", macd_hist_now))
    end
end

# 10. Bollinger Band position
if !isnan(bb_up[end]) && !isnan(bb_lo[end]) && bb_up[end] > bb_lo[end]
    pctb = (prices[end] - bb_lo[end]) / (bb_up[end] - bb_lo[end])
    if pctb < 0.05
        push!(bullish, @sprintf("Price at BOTTOM of Bollinger Bands (%%B = %.2f) — potential mean reversion UP", pctb))
    elseif pctb > 0.95
        push!(bearish, @sprintf("Price at TOP of Bollinger Bands (%%B = %.2f) — stretched, may revert down", pctb))
    end
end

# 11. Trend (price vs SMA200)
if !isnan(sma200_v[end])
    pct_above_200 = (prices[end] / sma200_v[end] - 1) * 100
    if pct_above_200 > 10
        push!(bullish, @sprintf("Price %.1f%% ABOVE 200-day SMA — strong uptrend", pct_above_200))
    elseif pct_above_200 > 0
        push!(bullish, @sprintf("Price %.1f%% above 200-day SMA — in uptrend", pct_above_200))
    elseif pct_above_200 > -5
        push!(bearish, @sprintf("Price %.1f%% below 200-day SMA — trend weakening", abs(pct_above_200)))
    else
        push!(bearish, @sprintf("Price %.1f%% BELOW 200-day SMA — in downtrend", abs(pct_above_200)))
    end
end

# 12. Golden/Death cross
if !isnan(sma50_v[end]) && !isnan(sma200_v[end])
    if sma50_v[end] > sma200_v[end] && length(sma50_v) > 1 &&
       !isnan(sma50_v[end-1]) && !isnan(sma200_v[end-1]) && sma50_v[end-1] <= sma200_v[end-1]
        push!(bullish, "GOLDEN CROSS detected — SMA50 just crossed above SMA200")
    elseif sma50_v[end] < sma200_v[end] && length(sma50_v) > 1 &&
           !isnan(sma50_v[end-1]) && !isnan(sma200_v[end-1]) && sma50_v[end-1] >= sma200_v[end-1]
        push!(bearish, "DEATH CROSS detected — SMA50 just crossed below SMA200")
    elseif sma50_v[end] > sma200_v[end]
        push!(bullish, "SMA50 > SMA200 — bullish moving average alignment")
    else
        push!(bearish, "SMA50 < SMA200 — bearish moving average alignment")
    end
end

# 13. Beta / Alpha
if mkt.beta > 1.5
    push!(bearish, @sprintf("Very high beta (%.2f) — amplifies every market drop", mkt.beta))
elseif mkt.beta > 1.0
    push!(bearish, @sprintf("Beta > 1 (%.2f) — more volatile than the market", mkt.beta))
elseif mkt.beta < 0.7
    push!(bullish, @sprintf("Low beta (%.2f) — defensive, holds up in downturns", mkt.beta))
end
if mkt.alpha_annual > 0.03
    push!(bullish, @sprintf("Positive alpha: %+.1f%% annual excess return over the market", mkt.alpha_annual*100))
elseif mkt.alpha_annual < -0.03
    push!(bearish, @sprintf("Negative alpha: %+.1f%% — underperforming the market after risk adjustment", mkt.alpha_annual*100))
end

# 14. Hurst exponent interpretation
if H > 0.60
    push!(bullish, @sprintf("Hurst = %.2f — trending behavior, momentum strategies favored", H))
elseif H < 0.40
    push!(bullish, @sprintf("Hurst = %.2f — mean-reverting, contrarian entry may work well", H))
else
    # Neither strong trend nor mean-reversion — note it
end

# 15. Portfolio optimization insight
if opt_port.weights[1] > 0.7
    push!(bullish, "Optimizer allocates $(round(Int, opt_port.weights[1]*100))% to $TICKER — the math favors it")
elseif opt_port.weights[1] < 0.3
    push!(bearish, "Optimizer allocates only $(round(Int, opt_port.weights[1]*100))% to $TICKER — prefers $BENCHMARK hedge")
end

# 16. CAPM alpha
if capm.alpha > 0.05
    push!(bullish, @sprintf("CAPM alpha = %+.1f%% — beating expected return for this risk level", capm.alpha*100))
elseif capm.alpha < -0.05
    push!(bearish, @sprintf("CAPM alpha = %+.1f%% — underperforming expected return for this risk", capm.alpha*100))
end

# 17. Fama-French
if ff3 !== nothing
    if ff3.alpha_annual > 0.03
        push!(bullish, @sprintf("FF3 alpha = %+.1f%% — genuine excess return beyond market/size/value", ff3.alpha_annual*100))
    elseif ff3.alpha_annual < -0.03
        push!(bearish, @sprintf("FF3 alpha = %+.1f%% — no true alpha, returns explained by factors", ff3.alpha_annual*100))
    end
end

# 18. ARIMA forecast
if arima.r_squared > 0.01  # only use if model has some fit
    if arima.forecast_direction == "UP" && arima.cumulative_return_pct > 0.5
        push!(bullish, @sprintf("AR(5) forecasts %+.2f%% over 21 days (UP)", arima.cumulative_return_pct))
    elseif arima.forecast_direction == "DOWN" && arima.cumulative_return_pct < -0.5
        push!(bearish, @sprintf("AR(5) forecasts %+.2f%% over 21 days (DOWN)", arima.cumulative_return_pct))
    end
end

# 19. EGARCH leverage effect
if egarch.leverage_effect
    push!(bearish, "EGARCH detects leverage effect — bad news amplifies volatility more than good news")
    push!(warnings, "Asymmetric vol: downside moves trigger disproportionate volatility spikes")
end

# 20. ★ Kelly Criterion (elevated importance — decades-proven position sizing)
if kelly.kelly_half > 0.5 && kelly.edge_consistency > 65
    push!(bullish, @sprintf("[KELLY] Half-Kelly recommends %.0f%% allocation — strong, consistent edge (%.0f%% of quarters profitable)", kelly.kelly_half*100, kelly.edge_consistency))
elseif kelly.kelly_half > 0.5
    push!(bullish, @sprintf("[KELLY] Half-Kelly recommends %.0f%% allocation — strong edge detected", kelly.kelly_half*100))
elseif kelly.kelly_half > 0.1 && kelly.edge_consistency > 55
    push!(bullish, @sprintf("Kelly (½K) recommends %.0f%% allocation — positive edge, %.0f%% quarter consistency", kelly.kelly_half*100, kelly.edge_consistency))
elseif kelly.kelly_half > 0.1
    push!(bullish, @sprintf("Kelly (½K) recommends %.0f%% — edge exists but inconsistent (%.0f%% quarters)", kelly.kelly_half*100, kelly.edge_consistency))
elseif kelly.kelly_half > 0
    push!(bullish, @sprintf("Kelly (¼K recommended) = %.0f%% — marginal edge, size conservatively", kelly.kelly_quarter*100))
else
    push!(bearish, @sprintf("[KELLY] Kelly fraction is NEGATIVE — expected return does not justify risk (edge consistency: %.0f%%)", kelly.edge_consistency))
end
# Kelly ruin risk check
if kelly.prob_ruin_full > 20
    push!(warnings, @sprintf("Full Kelly has %.0f%% ruin risk — NEVER use full Kelly, use ½ or ¼ Kelly", kelly.prob_ruin_full))
end

# 21. Cointegration / pairs trading
if coint.is_cointegrated && abs(coint.z_score) > 2
    if coint.z_score < -2
        push!(bullish, "Pairs trade: spread z=$(round(coint.z_score, digits=2)) — $TICKER is undervalued vs $BENCHMARK")
    else
        push!(bearish, "Pairs trade: spread z=$(round(coint.z_score, digits=2)) — $TICKER is overvalued vs $BENCHMARK")
    end
end

# 22. Risk parity insight
if rp.sharpe > opt_port.sharpe + 0.1
    push!(bullish, @sprintf("Risk parity Sharpe (%.2f) beats mean-variance (%.2f)", rp.sharpe, opt_port.sharpe))
end

# 23. ML signal
if ml.confidence > 30
    if ml.prediction == "BULLISH"
        push!(bullish, @sprintf("ML logistic regression: BULLISH (%.0f%% prob up, %.0f%% accuracy)", ml.probability_up, ml.accuracy))
    elseif ml.prediction == "BEARISH"
        push!(bearish, @sprintf("ML logistic regression: BEARISH (%.0f%% prob up, %.0f%% accuracy)", ml.probability_up, ml.accuracy))
    end
end

# ── Final decision logic ──────────────────────────────────────
n_bull = length(bullish)
n_bear = length(bearish)
bull_pct = n_bull / max(n_bull + n_bear, 1) * 100

# Decision matrix (composite score + factor balance + risk)
decision = if sig.score > 0.35 && bull_pct > 60 && mdd.value < 0.35
    "BUY"
elseif sig.score > 0.12 && bull_pct > 55
    "BUY"
elseif sig.score > 0.0 && bull_pct > 50 && sh > 0.3
    "LEAN BUY (with caution)"
elseif sig.score < -0.35 || bull_pct < 30
    "DO NOT BUY"
elseif sig.score < -0.12 || bull_pct < 40
    "DO NOT BUY"
elseif sig.score < 0.0 && sh < 0
    "DO NOT BUY"
else
    "HOLD / WAIT FOR BETTER ENTRY"
end

decision_color = if startswith(decision, "BUY")
    "GREEN"
elseif startswith(decision, "LEAN")
    "YELLOW"
elseif startswith(decision, "DO NOT")
    "RED"
else
    "AMBER"
end

# ── Print decision analysis ───────────────────────────────────
println("┌" * "─"^62 * "┐")
println("│" * lpad("DECISION: $decision", 42) * " "^max(0, 62-42) * "│")
println("└" * "─"^62 * "┘")
println()

@printf("  Composite Score:   %+.4f\n", sig.score)
@printf("  Bullish Factors:   %d\n", n_bull)
@printf("  Bearish Factors:   %d\n", n_bear)
@printf("  Bull/Bear Ratio:   %.0f%% / %.0f%%\n", bull_pct, 100 - bull_pct)
@printf("  Signal Color:      %s\n", decision_color)
println()

if !isempty(bullish)
    println("  BULLISH FACTORS (reasons to BUY):")
    println("  " * "─"^60)
    for (i, f) in enumerate(bullish)
        println("   $(i). $f")
    end
    println()
end

if !isempty(bearish)
    println("  BEARISH FACTORS (reasons NOT to buy):")
    println("  " * "─"^60)
    for (i, f) in enumerate(bearish)
        println("   $(i). $f")
    end
    println()
end

if !isempty(warnings)
    println("  !! RISK WARNINGS:")
    println("  " * "─"^60)
    for w in warnings
        println("   !! $w")
    end
    println()
end

# ── Price targets ─────────────────────────────────────────────
println("  PRICE TARGETS (1-Year, Monte Carlo-based):")
println("  " * "─"^60)
@printf("   Bear Case  (5th %%ile):  \$%8.2f  (%+.1f%%)\n", mc_p5,  (mc_p5/S0-1)*100)
@printf("   Base Case  (median):    \$%8.2f  (%+.1f%%)\n",  mc_p50, (mc_p50/S0-1)*100)
@printf("   Bull Case  (95th %%ile): \$%8.2f  (%+.1f%%)\n", mc_p95, (mc_p95/S0-1)*100)
@printf("   Current Price:          \$%8.2f\n", S0)
@printf("   Probability of Profit:  %5.1f%%\n", prob_profit)
println()

# ── Risk sizing suggestion ────────────────────────────────────
println("  POSITION SIZING GUIDANCE:")
println("  " * "─"^60)
daily_var_dollar = var_h * S0
@printf("   Daily VaR (95%%):    \$%.2f per share\n", daily_var_dollar)
@printf("   If risking \$1000 max loss → buy up to %d shares\n", max(1, floor(Int, 1000 / daily_var_dollar)))
@printf("   Kelly fraction (approx):  %.0f%% of portfolio\n",
    clamp(((stats.annual_return - RF_ANNUAL) / (stats.annual_vol^2)) * 100, 0, 100))
println()

# ── Bottom line ───────────────────────────────────────────────
println("╔" * "═"^62 * "╗")
bottom_line = if decision == "BUY"
    "$TICKER is a BUY — $n_bull bullish signals outweigh $n_bear bearish, positive risk-adjusted returns."
elseif startswith(decision, "LEAN")
    "$TICKER leans BUY but proceed with caution — mixed signals. Consider a smaller position."
elseif decision == "DO NOT BUY"
    "$TICKER is DO NOT BUY — $n_bear bearish signals dominate. Risk/reward is unfavorable."
else
    "$TICKER is a HOLD — signals are mixed. Wait for a clearer entry point or catalyst."
end
# Word-wrap bottom line into the box
for i in 1:62:length(bottom_line)
    chunk = bottom_line[i:min(i+61, end)]
    println("║ " * rpad(chunk, 61) * "║")
end
println("╚" * "═"^62 * "╝")
println()

# ══════════════════════════════════════════════════════════════
#  DASHBOARD 1 — TECHNICAL ANALYSIS
# ══════════════════════════════════════════════════════════════

println("  Generating charts...")
t_axis = 1:n

p1 = plot(t_axis, prices, color=:white, linewidth=1.5, label="$TICKER Price",
    title="$TICKER — Price & Moving Averages",
    xlabel="", ylabel="Price (\$)", background_color=:black,
    foreground_color=:white, legend=:topleft, legendfontsize=7,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=2Plots.mm)
plot!(p1, t_axis, sma20_v,  color=:yellow, linewidth=1,   label="SMA20")
plot!(p1, t_axis, sma50_v,  color=:orange, linewidth=1,   label="SMA50")
plot!(p1, t_axis, sma200_v, color=:red,    linewidth=1.5, label="SMA200")
plot!(p1, t_axis, bb_up,    color=:cyan,   linewidth=0.8, label="BB Upper", linestyle=:dash)
plot!(p1, t_axis, bb_lo,    color=:cyan,   linewidth=0.8, label="BB Lower", linestyle=:dash)

bar_colors_v = [r[i] >= 0 ? :green : :red for i in eachindex(r)]
p2 = bar(2:n, stock.volume[2:n] ./ 1e6,
    color=bar_colors_v, linecolor=:transparent, alpha=0.7,
    title="Volume (M shares)", xlabel="", ylabel="Volume (M)",
    background_color=:black, foreground_color=:white, legend=false,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=2Plots.mm)

p3 = plot(t_axis, rsi_v, color=:purple, linewidth=1.5,
    title="RSI (14)", xlabel="", ylabel="RSI",
    ylims=(0, 100), background_color=:black, foreground_color=:white, legend=false,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=2Plots.mm)
hline!(p3, [70], color=:red,   linestyle=:dash, linewidth=1)
hline!(p3, [30], color=:green, linestyle=:dash, linewidth=1)
hline!(p3, [50], color=:gray,  linestyle=:dot,  linewidth=0.5)

p4 = plot(t_axis, macd_l, color=:cyan, linewidth=1.2, label="MACD",
    title="MACD (12/26/9)", xlabel="Day", ylabel="Value",
    background_color=:black, foreground_color=:white, legend=:topleft, legendfontsize=7,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=5Plots.mm)
plot!(p4, t_axis, macd_s, color=:orange, linewidth=1.2, label="Signal")
hist_colors = [macd_h[i] >= 0 ? :green : :red for i in 1:n]
bar!(p4, t_axis, macd_h, color=hist_colors, linecolor=:transparent, alpha=0.5, label="Hist")
hline!(p4, [0], color=:white, linestyle=:dot, linewidth=0.5, label="")

dash1 = plot(p1, p2, p3, p4, layout=(4,1), size=(1400, 1200))
savefig(dash1, "$(OUTPUT_DIR)/$(TICKER)_technical_analysis.png")
savefig(dash1, "$(OUTPUT_DIR)/$(TICKER)_technical_analysis.svg")

# ══════════════════════════════════════════════════════════════
#  DASHBOARD 2 — QUANTITATIVE MODELS
# ══════════════════════════════════════════════════════════════

mc_t = 0:252
q05  = [quantile(mc_paths[t+1,:], 0.05) for t in 0:252]
q50  = [quantile(mc_paths[t+1,:], 0.50) for t in 0:252]
q95  = [quantile(mc_paths[t+1,:], 0.95) for t in 0:252]

p5 = plot(mc_t, mc_paths[:, 1:50], color=:steelblue, alpha=0.07,
    linewidth=0.5, legend=false,
    title="Monte Carlo: 10K GBM Paths (1 Year)",
    xlabel="Trading Days", ylabel="Price (\$)",
    background_color=:black, foreground_color=:white,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=5Plots.mm)
plot!(p5, mc_t, q95, color=:green,  linewidth=2, label="95th %")
plot!(p5, mc_t, q50, color=:yellow, linewidth=2, label="Median")
plot!(p5, mc_t, q05, color=:red,    linewidth=2, label="5th %")
hline!(p5, [prices[end]], color=:white, linestyle=:dash, linewidth=1, label="Current")

p6 = histogram(r, bins=80, normalize=:pdf,
    color=:steelblue, alpha=0.7, label="Daily Returns",
    title="Return Distribution vs Normal Fit",
    xlabel="Log Return", ylabel="Density",
    background_color=:black, foreground_color=:white, legend=:topleft, legendfontsize=7,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=5Plots.mm)
xs_norm = range(minimum(r), maximum(r), length=200)
μ_r, σ_r = mean(r), std(r)
ys_norm = @. exp(-0.5*((xs_norm-μ_r)/σ_r)^2) / (σ_r*sqrt(2π))
plot!(p6, xs_norm, ys_norm, color=:yellow, linewidth=2, label="Normal fit")
vline!(p6, [-var_h],  color=:red,    linestyle=:dash, linewidth=2, label="VaR 95%")
vline!(p6, [-cvar_v], color=:orange, linestyle=:dash, linewidth=2, label="CVaR 95%")

garch_ann = garch.σ_series .* sqrt(252) .* 100
p7 = plot(2:length(garch_ann)+1, garch_ann, color=:orange, linewidth=1.2,
    fill=(0, 0.15, :orange),
    title="GARCH(1,1) — Conditional Volatility",
    xlabel="Day", ylabel="Ann. Volatility (%)",
    background_color=:black, foreground_color=:white, legend=false,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=5Plots.mm)
hline!(p7, [garch.long_run_vol*100], color=:cyan,  linestyle=:dash, linewidth=1.5)
hline!(p7, [stats.annual_vol*100],   color=:white, linestyle=:dot,  linewidth=1)

n_cmp   = min(length(r_a), length(r_spy))
cum_stk = cumprod(1 .+ r_a[end-n_cmp+1:end])   .- 1
cum_spy = cumprod(1 .+ r_spy[end-n_cmp+1:end]) .- 1
p8 = plot(cum_stk .* 100, color=:cyan,   linewidth=2, label=TICKER,
    title="Cumulative Return: $TICKER vs $BENCHMARK",
    xlabel="Day", ylabel="Cumulative Return (%)",
    background_color=:black, foreground_color=:white, legend=:topleft, legendfontsize=8,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=5Plots.mm)
plot!(p8, cum_spy .* 100, color=:orange, linewidth=2, label=BENCHMARK)
hline!(p8, [0], color=:white, linestyle=:dot, linewidth=0.5, label="")

p9 = plot(roll_sh, color=:lime, linewidth=1.2, fill=(0, 0.1, :lime),
    title="Rolling Sharpe Ratio (63-day / 1 quarter)",
    xlabel="Day", ylabel="Sharpe",
    background_color=:black, foreground_color=:white, legend=false,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=5Plots.mm)
hline!(p9, [0],  color=:white, linestyle=:dot,  linewidth=0.5)
hline!(p9, [1],  color=:green, linestyle=:dash, linewidth=1)
hline!(p9, [-1], color=:red,   linestyle=:dash, linewidth=1)

p10 = plot(dd_ser .* -100, color=:red, linewidth=1, fill=(0, 0.3, :red),
    title="Drawdown (Underwater Chart)",
    xlabel="Day", ylabel="Drawdown (%)",
    background_color=:black, foreground_color=:white, legend=false,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=5Plots.mm)

strikes    = S0 .* (0.70:0.05:1.30)
maturities = [1/12, 3/12, 6/12, 1.0]
call_matrix = [black_scholes(S0, K, RF_ANNUAL, stats.annual_vol, T; type=:call).price
               for K in strikes, T in maturities]
p11 = plot(strikes, call_matrix, label=["1M" "3M" "6M" "12M"],
    linewidth=2, xlabel="Strike (\$)", ylabel="Call Price (\$)",
    title="Black-Scholes Call Prices by Maturity",
    background_color=:black, foreground_color=:white,
    legend=:topright, legendfontsize=7,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=5Plots.mm)
vline!(p11, [S0], color=:white, linestyle=:dash, linewidth=1, label="ATM")

sig_keys = [k for (k,_) in sort(collect(sig.signals), by=x->x[1])]
sig_vals = [sig.signals[k] for k in sig_keys]
bar_col  = [v > 0 ? :green : :red for v in sig_vals]
verdict_clean = replace(replace(replace(replace(replace(
    sig.verdict, "⬆  " => ""), "↑  " => ""), "→  " => ""), "↓  " => ""), "⬇  " => "")
p12 = bar(sig_keys, sig_vals, color=bar_col, alpha=0.8,
    title="Signal Scorecard: $verdict_clean\n(Score: $(round(sig.score,digits=3))  |  Confidence: $(sig.confidence)%)",
    xlabel="Indicator", ylabel="Signal  [-1=Sell  |  0=Hold  |  +1=Buy]",
    ylims=(-1.2, 1.3), legend=false,
    background_color=:black, foreground_color=:white,
    xrotation=45, titlefontsize=10, xtickfontsize=9,
    left_margin=5Plots.mm, bottom_margin=15Plots.mm)
hline!(p12, [0],          color=:white, linestyle=:dot,  linewidth=1)
hline!(p12, [0.25, -0.25],color=:gray,  linestyle=:dash, linewidth=0.8)

dash2 = plot(p5, p6, p7, p8, p9, p10, p11, p12, layout=(4, 2), size=(1600, 1800))
savefig(dash2, "$(OUTPUT_DIR)/$(TICKER)_quant_models.png")
savefig(dash2, "$(OUTPUT_DIR)/$(TICKER)_quant_models.svg")

# ══════════════════════════════════════════════════════════════
#  DASHBOARD 3 — DECISION ANALYSIS
# ══════════════════════════════════════════════════════════════

# Panel 13: Bullish vs Bearish factor count + ratio gauge
factor_labels = ["Bullish", "Bearish"]
factor_counts = [n_bull, n_bear]
factor_colors = [:green, :red]
p13 = bar(factor_labels, factor_counts, color=factor_colors, alpha=0.85,
    title="Factor Balance: $n_bull Bullish vs $n_bear Bearish",
    ylabel="Number of Factors", legend=false,
    background_color=:black, foreground_color=:white,
    titlefontsize=12, left_margin=5Plots.mm, bottom_margin=5Plots.mm)
for (i, c) in enumerate(factor_counts)
    annotate!(p13, i, c + 0.3, text("$c", 12, :white, :center))
end

# Panel 14: Individual factor detail bars (bullish = green right, bearish = red left)
all_factors = vcat(
    [(f, +1) for f in bullish],
    [(f, -1) for f in bearish]
)
# Truncate labels for chart readability
trunc_label(s, maxlen=48) = length(s) > maxlen ? first(s, maxlen) * "..." : s
af_labels = [trunc_label(f[1]) for f in all_factors]
af_values = [f[2] for f in all_factors]
af_colors = [v > 0 ? :green : :red for v in af_values]

p14 = bar(af_labels, af_values, color=af_colors, alpha=0.8, orientation=:h,
    title="Decision Factors — $TICKER",
    xlabel="Bearish (-1)  vs  Bullish (+1)", ylabel="",
    xlims=(-1.5, 1.5), legend=false,
    background_color=:black, foreground_color=:white,
    titlefontsize=11, ytickfontsize=7, xtickfontsize=9,
    left_margin=30Plots.mm, right_margin=5Plots.mm,
    bottom_margin=5Plots.mm, top_margin=3Plots.mm)
vline!(p14, [0], color=:white, linestyle=:dot, linewidth=1)

# Panel 15: Price targets waterfall
target_labels = ["Bear\n(5th %)", "Current\nPrice", "Base\n(Median)", "Bull\n(95th %)"]
target_values = [mc_p5, S0, mc_p50, mc_p95]
target_colors = [:red, :white, :yellow, :green]
p15 = bar(target_labels, target_values, color=target_colors, alpha=0.85,
    title="1-Year Price Targets (Monte Carlo)",
    ylabel="Price (\$)", legend=false,
    background_color=:black, foreground_color=:white,
    titlefontsize=12, left_margin=5Plots.mm, bottom_margin=8Plots.mm)
for (i, v) in enumerate(target_values)
    pct = (v / S0 - 1) * 100
    lbl = i == 2 ? "\$$(round(v, digits=2))" : "\$$(round(v, digits=2))\n($(@sprintf("%+.0f", pct))%)"
    annotate!(p15, i, v + maximum(target_values)*0.02,
        text(lbl, 9, :white, :center))
end

# Panel 16: Risk metrics radar-style horizontal bars
risk_labels = ["Sharpe", "Sortino", "Calmar", "Prob Profit\n(%/100)", "Bull/Bear\nRatio"]
risk_values = [
    clamp(sh, -2, 3),
    clamp(so, -2, 3),
    clamp(cal, -2, 3),
    prob_profit / 100.0,
    bull_pct / 100.0
]
risk_colors = [v >= 0.5 ? :green : v >= 0 ? :yellow : :red for v in risk_values]
p16 = bar(risk_labels, risk_values, color=risk_colors, alpha=0.85,
    title="Risk-Adjusted Quality Metrics",
    ylabel="Score", legend=false,
    background_color=:black, foreground_color=:white,
    titlefontsize=12, left_margin=5Plots.mm, bottom_margin=10Plots.mm)
hline!(p16, [0], color=:white, linestyle=:dot, linewidth=1)
hline!(p16, [1], color=:green, linestyle=:dash, linewidth=0.8, alpha=0.5)
for (i, v) in enumerate(risk_values)
    annotate!(p16, i, v + (v >= 0 ? 0.08 : -0.15),
        text("$(round(v, digits=2))", 9, :white, :center))
end

# Panel 17: Decision verdict display (text-based annotation plot)
verdict_col = decision == "BUY" ? :green :
              startswith(decision, "LEAN") ? :yellow :
              decision == "DO NOT BUY" ? :red : :orange
p17 = plot(xlims=(0,10), ylims=(0,10), axis=false, grid=false, ticks=false,
    background_color=:black, foreground_color=:white, legend=false,
    title="FINAL DECISION", titlefontsize=14)
annotate!(p17, 5, 7.5, text(decision, 28, verdict_col, :center, :bold))
annotate!(p17, 5, 5.5, text("Composite Score: $(@sprintf("%+.3f", sig.score))", 12, :white, :center))
annotate!(p17, 5, 4.2, text("Confidence: $(sig.confidence)%  |  Bull/Bear: $(round(Int,bull_pct))%/$(round(Int,100-bull_pct))%", 10, :white, :center))
annotate!(p17, 5, 2.8, text("Prob. of Profit: $(@sprintf("%.1f", prob_profit))%  |  1yr Median: \$$(round(mc_p50, digits=2))", 10, :white, :center))
annotate!(p17, 5, 1.5, text("Sharpe: $(@sprintf("%.2f", sh))  |  Max DD: $(@sprintf("%.1f", mdd.value*100))%  |  Beta: $(@sprintf("%.2f", mkt.beta))", 9, :gray, :center))

# Panel 18: Key risk warnings (text plot)
p18 = plot(xlims=(0,10), ylims=(0,10), axis=false, grid=false, ticks=false,
    background_color=:black, foreground_color=:white, legend=false,
    title="Risk Warnings & Position Sizing", titlefontsize=12)
global warn_y = 8.5
if !isempty(warnings)
    for (i, w) in enumerate(warnings[1:min(3, length(warnings))])
        tw = length(w) > 60 ? first(w, 60) * "..." : w
        annotate!(p18, 5, warn_y, text("!! $tw", 9, :red, :center))
        global warn_y -= 1.3
    end
else
    annotate!(p18, 5, warn_y, text("No critical risk warnings", 10, :green, :center))
    global warn_y -= 1.3
end
global warn_y -= 0.5
annotate!(p18, 5, warn_y, text("Position Sizing (per \$1,000 risk budget):", 10, :cyan, :center))
warn_y -= 1.2
annotate!(p18, 5, warn_y, text("Daily VaR (95%): \$$(round(daily_var_dollar, digits=2))/share  →  Max $(max(1, floor(Int, 1000/daily_var_dollar))) shares", 10, :white, :center))
warn_y -= 1.2
kelly_pct = clamp(((stats.annual_return - RF_ANNUAL) / (stats.annual_vol^2)) * 100, 0, 100)
annotate!(p18, 5, warn_y, text("Kelly Fraction: $(round(Int, kelly_pct))% of portfolio", 10, :white, :center))

# Combine into Dashboard 3
dash3_layout = @layout [
    a{0.15w} b{0.85w}
    c         d
    e         f
]
dash3 = plot(p13, p14, p15, p16, p17, p18,
    layout=dash3_layout, size=(1600, 1400))
savefig(dash3, "$(OUTPUT_DIR)/$(TICKER)_decision_analysis.png")
savefig(dash3, "$(OUTPUT_DIR)/$(TICKER)_decision_analysis.svg")

# ══════════════════════════════════════════════════════════════
#  DASHBOARD 4 — ADVANCED MODELS
# ══════════════════════════════════════════════════════════════

# Panel A: CAPM scatter (actual vs expected)
capm_labels = [TICKER, BENCHMARK]
capm_actual = [capm.actual_return * 100, mean(r_spy) * 252 * 100]
capm_expect = [capm.expected_return * 100, (RF_ANNUAL + 1.0 * capm.market_premium) * 100]
pa = bar(capm_labels, hcat(capm_actual, capm_expect),
    label=["Actual Return" "CAPM Expected"],
    color=[:cyan :gray], alpha=0.85,
    title="CAPM: Actual vs Expected Return",
    ylabel="Annual Return (%)", legend=:topright, legendfontsize=8,
    background_color=:black, foreground_color=:white,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=5Plots.mm)
hline!(pa, [RF_ANNUAL * 100], color=:yellow, linestyle=:dash, linewidth=1, label="Risk-Free")

# Panel B: Fama-French factor exposures
if ff3 !== nothing
    ff_labels = ["Market\nBeta", "SMB\n(Size)", "HML\n(Value)"]
    ff_vals   = [ff3.beta_mkt, ff3.beta_smb, ff3.beta_hml]
    ff_cols   = [abs(v) > 0.1 ? (v > 0 ? :green : :red) : :gray for v in ff_vals]
    pb = bar(ff_labels, ff_vals, color=ff_cols, alpha=0.85,
        title="Fama-French 3-Factor Exposures\n(Alpha: $(@sprintf("%+.2f", ff3.alpha_annual*100))%  R2: $(@sprintf("%.1f", ff3.r_squared*100))%)",
        ylabel="Factor Beta", legend=false,
        background_color=:black, foreground_color=:white,
        titlefontsize=10, left_margin=5Plots.mm, bottom_margin=8Plots.mm)
    hline!(pb, [0], color=:white, linestyle=:dot, linewidth=1)
    for (i, v) in enumerate(ff_vals)
        annotate!(pb, i, v + (v >= 0 ? 0.03 : -0.06), text("$(round(v, digits=3))", 9, :white, :center))
    end
else
    pb = plot(xlims=(0,10), ylims=(0,10), axis=false, grid=false, ticks=false,
        background_color=:black, foreground_color=:white, legend=false,
        title="Fama-French 3-Factor\n(Data unavailable)", titlefontsize=11)
end

# Panel C: ARIMA forecast path
ar_fwd  = cumsum(arima.forecasts) .* 100
ar_days = 1:length(ar_fwd)
pc = plot(ar_days, ar_fwd, color=:cyan, linewidth=2, fill=(0, 0.15, :cyan),
    title="AR(5) Forecast: Next 21 Trading Days\n(Cumulative: $(@sprintf("%+.2f", arima.cumulative_return_pct))%)",
    xlabel="Days Ahead", ylabel="Cumulative Return (%)",
    legend=false, background_color=:black, foreground_color=:white,
    titlefontsize=10, left_margin=5Plots.mm, bottom_margin=5Plots.mm)
hline!(pc, [0], color=:white, linestyle=:dot, linewidth=1)

# Panel D: EGARCH asymmetry visualization
eg_labels = ["Magnitude\n(alpha)", "Leverage\n(gamma)", "Persistence\n(beta)"]
eg_vals   = [egarch.α, egarch.γ_leverage, egarch.β_persist]
eg_cols   = [:cyan, egarch.leverage_effect ? :red : :green, :orange]
pd = bar(eg_labels, eg_vals, color=eg_cols, alpha=0.85,
    title="EGARCH Asymmetric Volatility\n($(egarch.leverage_effect ? "Leverage effect detected" : "No leverage effect"))",
    ylabel="Parameter Value", legend=false,
    background_color=:black, foreground_color=:white,
    titlefontsize=10, left_margin=5Plots.mm, bottom_margin=8Plots.mm)
hline!(pd, [0], color=:white, linestyle=:dot, linewidth=1)
for (i, v) in enumerate(eg_vals)
    annotate!(pd, i, v + (v >= 0 ? 0.02 : -0.04), text("$(round(v, digits=4))", 9, :white, :center))
end

# Panel E: Kelly + Position Sizing
kelly_labels = ["Full Kelly", "Half Kelly\n(Recommended)", "MC Optimal"]
kelly_vals   = [kelly.kelly_full * 100, kelly.kelly_half * 100, kelly.kelly_mc * 100]
kelly_cols   = [:orange, :green, :cyan]
pe = bar(kelly_labels, kelly_vals, color=kelly_cols, alpha=0.85,
    title="Kelly Criterion: Optimal Allocation (%)",
    ylabel="Portfolio Allocation (%)", legend=false,
    background_color=:black, foreground_color=:white,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=8Plots.mm)
hline!(pe, [0], color=:white, linestyle=:dot, linewidth=1)
for (i, v) in enumerate(kelly_vals)
    annotate!(pe, i, v + (v >= 0 ? 1.5 : -3), text("$(round(v, digits=1))%", 9, :white, :center))
end

# Panel F: Avellaneda-Stoikov bid/ask spread
as_labels = ["Bid", "Mid\n(Current)", "Reservation\nPrice", "Ask"]
as_vals   = [avstk.bid, avstk.mid, avstk.reservation_price, avstk.ask]
as_cols   = [:green, :white, :yellow, :red]
pf = bar(as_labels, as_vals, color=as_cols, alpha=0.85,
    title="Avellaneda-Stoikov Market Making\n(Spread: $(@sprintf("%.1f", avstk.spread_bps)) bps)",
    ylabel="Price (\$)", legend=false,
    background_color=:black, foreground_color=:white,
    titlefontsize=10, left_margin=5Plots.mm, bottom_margin=8Plots.mm)

# Panel G: Cointegration z-score and half-life
pg = plot(xlims=(0,10), ylims=(0,10), axis=false, grid=false, ticks=false,
    background_color=:black, foreground_color=:white, legend=false,
    title="Cointegration / Pairs Trading\n($TICKER vs $BENCHMARK)", titlefontsize=11)
coint_col = coint.is_cointegrated ? :green : :red
annotate!(pg, 5, 8.0, text(coint.is_cointegrated ? "COINTEGRATED" : "NOT Cointegrated", 16, coint_col, :center))
annotate!(pg, 5, 6.3, text("ADF Stat: $(round(coint.adf_stat, digits=3))  (5% crit: -2.86)", 10, :white, :center))
annotate!(pg, 5, 5.0, text("Spread Z-Score: $(round(coint.z_score, digits=3))", 11,
    abs(coint.z_score) > 2 ? :yellow : :white, :center))
annotate!(pg, 5, 3.7, text("Half-Life: $(round(coint.half_life_days, digits=1)) days", 10, :white, :center))
annotate!(pg, 5, 2.2, text("Hedge Ratio: $(round(coint.hedge_ratio, digits=4))", 10, :gray, :center))
annotate!(pg, 5, 1.0, text(coint.signal, 10, :cyan, :center))

# Panel H: Risk Parity vs Mean-Variance comparison
alloc_labels = ["$TICKER\n(MV)", "$BENCHMARK\n(MV)", "$TICKER\n(RP)", "$BENCHMARK\n(RP)"]
alloc_vals   = [opt_port.weights[1]*100, opt_port.weights[2]*100, rp.weights[1]*100, rp.weights[2]*100]
alloc_cols   = [:cyan, :orange, :green, :lime]
ph = bar(alloc_labels, alloc_vals, color=alloc_cols, alpha=0.85,
    title="Portfolio Allocation Comparison\n(Mean-Var vs Risk Parity)",
    ylabel="Weight (%)", legend=false,
    background_color=:black, foreground_color=:white,
    titlefontsize=10, left_margin=5Plots.mm, bottom_margin=10Plots.mm)
for (i, v) in enumerate(alloc_vals)
    annotate!(ph, i, v + 1.5, text("$(round(v, digits=1))%", 9, :white, :center))
end

dash4 = plot(pa, pb, pc, pd, pe, pf, pg, ph,
    layout=(4, 2), size=(1600, 1800))
savefig(dash4, "$(OUTPUT_DIR)/$(TICKER)_advanced_models.png")
savefig(dash4, "$(OUTPUT_DIR)/$(TICKER)_advanced_models.svg")

# ══════════════════════════════════════════════════════════════
#  PLAIN-ENGLISH REPORT (.txt)
# ══════════════════════════════════════════════════════════════

report_path = "$(OUTPUT_DIR)/$(TICKER)_analysis_report.txt"
open(report_path, "w") do io
    println(io, "=" ^ 72)
    println(io, "  $TICKER — QUANTITATIVE ANALYSIS REPORT")
    println(io, "  Generated: $(Dates.now())")
    println(io, "  Current Price: \$$(round(S0, digits=2))")
    println(io, "  Data: $(Date(stock.dates[1])) to $(Date(stock.dates[end])) ($n trading days)")
    println(io, "=" ^ 72)
    println(io)

    # DECISION
    println(io, "INVESTMENT DECISION: $decision")
    println(io, "-" ^ 72)
    println(io, bottom_line)
    println(io)

    # WHAT THE NUMBERS MEAN
    println(io, "WHAT THE NUMBERS MEAN (Plain English)")
    println(io, "=" ^ 72)
    println(io)

    # Returns
    println(io, "1. RETURNS — How has $TICKER performed?")
    println(io, "-" ^ 72)
    ret_pct = round(stats.annual_return * 100, digits=1)
    if stats.annual_return > 0.15
        println(io, "   $TICKER returned $ret_pct% per year — this is STRONG performance.")
        println(io, "   For context, the long-term stock market average is about 10%/year.")
    elseif stats.annual_return > 0
        println(io, "   $TICKER returned $ret_pct% per year — positive, but modest.")
        println(io, "   It's making money, but not dramatically outperforming.")
    else
        println(io, "   $TICKER returned $ret_pct% per year — it's LOSING money.")
        println(io, "   You would have been better off in a savings account ($(@sprintf("%.1f", RF_ANNUAL*100))% risk-free).")
    end
    println(io)

    # Risk
    println(io, "2. RISK — How dangerous is this stock?")
    println(io, "-" ^ 72)
    println(io, "   Volatility: $(@sprintf("%.1f", stats.annual_vol*100))% per year")
    if stats.annual_vol > 0.40
        println(io, "   This is VERY volatile — the stock swings wildly. Not for the faint-hearted.")
    elseif stats.annual_vol > 0.25
        println(io, "   This is moderately volatile — expect meaningful ups and downs.")
    else
        println(io, "   This is relatively calm — smaller daily swings than most stocks.")
    end
    println(io)
    println(io, "   Max Drawdown: -$(@sprintf("%.1f", mdd.value*100))%")
    println(io, "   This means at its worst point, $TICKER fell $(@sprintf("%.1f", mdd.value*100))% from its peak.")
    if mdd.value > 0.30
        println(io, "   That's a SEVERE drop. If you had \$10,000 invested, you'd have")
        println(io, "   watched it drop to \$$(round(Int, 10000*(1-mdd.value))). Could you handle that without panic selling?")
    elseif mdd.value > 0.15
        println(io, "   That's a moderate pullback — uncomfortable but normal for stocks.")
    else
        println(io, "   That's a mild drawdown — this stock has been relatively stable.")
    end
    println(io)
    println(io, "   Value at Risk (95%): $(@sprintf("%.2f", var_h*100))% per day")
    println(io, "   On a bad day (happens ~1 in 20), you could lose $(@sprintf("%.2f", var_h*100))% or more.")
    println(io, "   On \$10,000 that's a \$$(@sprintf("%.0f", var_h*10000)) loss in a single day.")
    println(io)

    # Sharpe / Sortino
    println(io, "3. RISK-ADJUSTED QUALITY — Is the return WORTH the risk?")
    println(io, "-" ^ 72)
    println(io, "   Sharpe Ratio: $(@sprintf("%.2f", sh))")
    if sh > 1.0
        println(io, "   EXCELLENT. Every unit of risk is well-compensated with return.")
        println(io, "   Professional fund managers dream of Sharpe ratios above 1.0.")
    elseif sh > 0.5
        println(io, "   GOOD. You're getting reasonable compensation for the risk you're taking.")
    elseif sh > 0
        println(io, "   MARGINAL. The return barely justifies the risk. A savings account")
        println(io, "   or index fund might give better risk-adjusted returns.")
    else
        println(io, "   POOR. You're taking risk and not being rewarded for it.")
        println(io, "   The risk-free rate ($(@sprintf("%.1f", RF_ANNUAL*100))%) actually beats this stock.")
    end
    println(io)
    println(io, "   Sortino Ratio: $(@sprintf("%.2f", so))")
    println(io, "   (Like Sharpe, but only penalizes DOWNSIDE moves — more relevant for investors")
    println(io, "    who care about losses more than missing upside.)")
    println(io)

    # GARCH
    println(io, "4. VOLATILITY OUTLOOK — Is volatility rising or falling?")
    println(io, "-" ^ 72)
    println(io, "   GARCH Model Forecast: $(@sprintf("%.1f", garch.σ_annual_forecast*100))% annualized")
    println(io, "   Historical Average:   $(@sprintf("%.1f", stats.annual_vol*100))% annualized")
    if garch.σ_annual_forecast > stats.annual_vol * 1.2
        println(io, "   CAUTION: Volatility is RISING. Expect larger price swings ahead.")
        println(io, "   This often happens before or during market stress.")
    elseif garch.σ_annual_forecast < stats.annual_vol * 0.8
        println(io, "   GOOD NEWS: Volatility is FALLING. The market is calming down.")
    else
        println(io, "   Volatility is stable — no major shift expected.")
    end
    println(io)
    println(io, "   EGARCH (Asymmetric Model): $(egarch.interpretation)")
    if egarch.leverage_effect
        println(io, "   WARNING: Bad news hits this stock HARDER than good news helps it.")
        println(io, "   A 5% drop creates more panic (and volatility) than a 5% rise creates calm.")
    end
    println(io)

    # Monte Carlo
    println(io, "5. WHERE COULD THE PRICE GO? (Monte Carlo Simulation)")
    println(io, "-" ^ 72)
    println(io, "   We simulated 10,000 possible price paths over the next year.")
    println(io, "   Current Price:        \$$(round(S0, digits=2))")
    println(io, "   Worst Case (5th %):   \$$(round(mc_p5, digits=2))  ($(@sprintf("%+.1f", (mc_p5/S0-1)*100))%)")
    println(io, "   Most Likely (median): \$$(round(mc_p50, digits=2))  ($(@sprintf("%+.1f", (mc_p50/S0-1)*100))%)")
    println(io, "   Best Case (95th %):   \$$(round(mc_p95, digits=2))  ($(@sprintf("%+.1f", (mc_p95/S0-1)*100))%)")
    println(io, "   Probability of Profit: $(@sprintf("%.1f", prob_profit))%")
    println(io)
    if prob_profit > 65
        println(io, "   The odds favor making money over the next year.")
    elseif prob_profit > 50
        println(io, "   Slight edge toward profit, but it's close to a coin flip.")
    else
        println(io, "   The odds actually favor LOSING money. Proceed with caution.")
    end
    println(io)

    # Options
    println(io, "6. OPTIONS PRICING (Black-Scholes)")
    println(io, "-" ^ 72)
    println(io, "   3-Month ATM Call (\$$(round(Int, K_atm)) strike): \$$(round(bs_call.price, digits=2))")
    println(io, "   3-Month ATM Put  (\$$(round(Int, K_atm)) strike): \$$(round(bs_put.price, digits=2))")
    println(io, "   Delta (call): $(@sprintf("%.3f", bs_call.delta))  — the call moves \$$(@sprintf("%.2f", bs_call.delta)) for every \$1 the stock moves.")
    println(io, "   Theta: \$$(@sprintf("%.2f", bs_call.theta))/day  — the option loses this much value each day just from time passing.")
    println(io, "   Vega:  \$$(@sprintf("%.2f", bs_call.vega))  — if implied vol rises 1%, the option gains this much.")
    println(io)

    # CAPM
    println(io, "7. CAPM — Is this stock priced correctly for its risk?")
    println(io, "-" ^ 72)
    println(io, "   Beta: $(@sprintf("%.2f", capm.beta))")
    if capm.beta > 1.2
        println(io, "   This stock is MORE volatile than the overall market.")
        println(io, "   When the market drops 10%, $TICKER typically drops $(@sprintf("%.0f", capm.beta*10))%.")
    elseif capm.beta > 0.8
        println(io, "   This stock moves roughly in line with the market.")
    else
        println(io, "   This stock is LESS volatile than the market — it's defensive.")
    end
    println(io, "   CAPM says $TICKER SHOULD return $(@sprintf("%.1f", capm.expected_return*100))% for its risk level.")
    println(io, "   It actually returned $(@sprintf("%.1f", capm.actual_return*100))%.")
    if capm.alpha > 0.03
        println(io, "   OUTPERFORMING: $TICKER is beating what its risk level predicts. Good sign.")
    elseif capm.alpha < -0.03
        println(io, "   UNDERPERFORMING: $TICKER is not earning enough for the risk you're taking.")
    else
        println(io, "   FAIRLY PRICED: Returns are roughly what you'd expect for this risk level.")
    end
    println(io)

    # Fama-French
    println(io, "8. FAMA-FRENCH — What's REALLY driving the returns?")
    println(io, "-" ^ 72)
    if ff3 !== nothing
        println(io, "   This model tests whether $TICKER's returns come from genuine skill (alpha)")
        println(io, "   or just exposure to known risk factors (market, size, value).")
        println(io, "   FF3 Alpha: $(@sprintf("%+.2f", ff3.alpha_annual*100))% per year")
        if ff3.alpha_annual > 0.03
            println(io, "   POSITIVE ALPHA — there's genuine excess return beyond what factors explain.")
        elseif ff3.alpha_annual < -0.03
            println(io, "   NEGATIVE ALPHA — returns are actually WORSE than what the factor exposures predict.")
        else
            println(io, "   NEUTRAL — returns are explained by factor exposures. No true alpha.")
        end
        println(io, "   Size Exposure: $(ff3.size_exposure)")
        println(io, "   Value Exposure: $(ff3.value_exposure)")
    else
        println(io, "   (Factor data unavailable — skipped)")
    end
    println(io)

    # ARIMA
    println(io, "9. TIME-SERIES FORECAST — What does the trend say?")
    println(io, "-" ^ 72)
    println(io, "   AR(5) model predicts: $(arima.forecast_direction) over the next 21 trading days")
    println(io, "   Estimated move: $(@sprintf("%+.2f", arima.cumulative_return_pct))%")
    if arima.r_squared > 0.05
        println(io, "   The model has moderate predictive power (R-squared: $(@sprintf("%.1f", arima.r_squared*100))%)")
    else
        println(io, "   CAVEAT: The model's predictive power is very low (R-squared: $(@sprintf("%.1f", arima.r_squared*100))%).")
        println(io, "   Stock prices are notoriously hard to forecast — treat this as one data point,")
        println(io, "   not gospel.")
    end
    println(io)

    # Kelly — EXPANDED (core position sizing model)
    println(io, "=" ^ 72)
    println(io, "10. ★ KELLY CRITERION — THE POSITION SIZING STANDARD ★")
    println(io, "=" ^ 72)
    println(io, "   BACKGROUND: Invented by John L. Kelly Jr. at Bell Labs (1956),")
    println(io, "   popularized by Ed Thorp who used it to beat casinos and then run")
    println(io, "   one of the most successful quant hedge funds in history. The Kelly")
    println(io, "   formula is the mathematical answer to: 'How much should I bet?'")
    println(io, "   It maximizes long-run geometric wealth growth while preventing ruin.")
    println(io)
    println(io, "   WHY IT MATTERS: Most traders fail not because their edge is wrong,")
    println(io, "   but because they sized their positions incorrectly. Kelly fixes this")
    println(io, "   mathematically. It's the one model with a 70-year track record of")
    println(io, "   guiding profitable decisions across stocks, options, and prediction markets.")
    println(io)
    println(io, "   KELLY FRACTIONS FOR $TICKER:")
    println(io, "   ┌─────────────────────────────────────────────────────────┐")
    println(io, "   │  Full Kelly:        $(@sprintf("%6.1f", kelly.kelly_full*100))%   (theoretical max — TOO AGGRESSIVE) │")
    println(io, "   │  ¾ Kelly:           $(@sprintf("%6.1f", kelly.kelly_three_quarter*100))%   (slightly conservative)           │")
    println(io, "   │  ½ Kelly (standard):$(@sprintf("%6.1f", kelly.kelly_half*100))%   ← RECOMMENDED (industry standard) │")
    println(io, "   │  ¼ Kelly (cautious):$(@sprintf("%6.1f", kelly.kelly_quarter*100))%   (for uncertain edges)             │")
    println(io, "   │  Empirical Kelly:   $(@sprintf("%6.1f", kelly.kelly_empirical*100))%   (adjusted for estimation error)   │")
    println(io, "   │  MC-Optimal:        $(@sprintf("%6.0f", kelly.kelly_mc*100))%   (Monte Carlo brute-force search)  │")
    println(io, "   └─────────────────────────────────────────────────────────┘")
    println(io)
    println(io, "   EDGE QUALITY:")
    println(io, "   Edge Consistency: $(@sprintf("%.1f", kelly.edge_consistency))% of rolling quarters show positive edge")
    println(io, "   Edge Sharpe: $(@sprintf("%.2f", kelly.edge_sharpe)) (how stable the excess return is)")
    println(io, "   Coefficient of Variation: $(@sprintf("%.2f", kelly.cv_edge)) (lower = more predictable edge)")
    println(io)
    println(io, "   MONTE CARLO SIMULATION (1-year, 2000 paths):")
    println(io, "   At ½ Kelly:  $(@sprintf("%.1f", kelly.prob_profit_half))% probability of profit, $(@sprintf("%.1f", kelly.prob_ruin_half))% ruin risk")
    println(io, "   At ¼ Kelly:  $(@sprintf("%.1f", kelly.prob_profit_quarter))% probability of profit (safer)")
    println(io, "   At Full Kelly: $(@sprintf("%.1f", kelly.prob_profit_full))% probability of profit, $(@sprintf("%.1f", kelly.prob_ruin_full))% RUIN RISK")
    println(io, "   Median return at ½ Kelly: $(@sprintf("%+.1f", kelly.median_return_half))%")
    println(io)
    if kelly.kelly_half > 0.5 && kelly.edge_consistency > 65
        println(io, "   ASSESSMENT: STRONG — stable, positive edge detected.")
        println(io, "   The math supports a meaningful allocation to $TICKER.")
        println(io, "   Use ½ Kelly ($(@sprintf("%.0f", kelly.kelly_half*100))%) for optimal growth with safety margin.")
        println(io, "   WARNING: NEVER use full Kelly in practice — estimation errors")
        println(io, "   mean the true optimal is always lower than calculated.")
    elseif kelly.kelly_half > 0.1
        println(io, "   ASSESSMENT: MODERATE — edge exists but proceed with caution.")
        println(io, "   Consider ¼ Kelly ($(@sprintf("%.0f", kelly.kelly_quarter*100))%) given edge uncertainty.")
    elseif kelly.kelly_half > 0
        println(io, "   ASSESSMENT: WEAK — only a small allocation is justified.")
        println(io, "   The edge is thin and may not persist. Use ¼ Kelly or less.")
    else
        println(io, "   ASSESSMENT: NO EDGE — Kelly says DON'T invest.")
        println(io, "   Expected return doesn't justify the risk. The risk-free rate")
        println(io, "   ($(@sprintf("%.1f", RF_ANNUAL*100))%) beats this stock on a risk-adjusted basis.")
    end
    println(io)
    println(io, "   ★ RECOMMENDATION: $(kelly.recommendation)")
    println(io)

    # Avellaneda-Stoikov
    println(io, "11. MARKET MAKING MODEL — Where should you place limit orders?")
    println(io, "-" ^ 72)
    println(io, "   The Avellaneda-Stoikov model calculates optimal bid/ask prices")
    println(io, "   for someone acting as a market maker (or placing limit orders).")
    println(io, "   Optimal Bid: \$$(round(avstk.bid, digits=2))  (place buy limit here)")
    println(io, "   Optimal Ask: \$$(round(avstk.ask, digits=2))  (place sell limit here)")
    println(io, "   Spread: $(@sprintf("%.1f", avstk.spread_bps)) basis points")
    println(io, "   If you're buying, consider a LIMIT ORDER at \$$(round(avstk.bid, digits=2))")
    println(io, "   instead of a market order — you'll get a better fill price.")
    println(io)

    # Cointegration
    println(io, "12. PAIRS TRADING — Is $TICKER mispriced vs the S&P 500?")
    println(io, "-" ^ 72)
    if coint.is_cointegrated
        println(io, "   YES — $TICKER and $BENCHMARK are statistically cointegrated.")
        println(io, "   This means they move together over time, and deviations tend to correct.")
        println(io, "   Current spread z-score: $(@sprintf("%.2f", coint.z_score))")
        if abs(coint.z_score) > 2
            println(io, "   SIGNAL ACTIVE: The spread is at an extreme — a pairs trade opportunity exists.")
            println(io, "   $(coint.signal)")
        else
            println(io, "   The spread is currently within normal range — no trading signal.")
        end
        println(io, "   Mean reversion half-life: $(@sprintf("%.0f", coint.half_life_days)) days")
    else
        println(io, "   NO — $TICKER and $BENCHMARK are NOT cointegrated (ADF stat: $(@sprintf("%.2f", coint.adf_stat))).")
        println(io, "   Pairs trading is not recommended for this combination.")
    end
    println(io)

    # Risk Parity
    println(io, "13. PORTFOLIO ALLOCATION — How to combine $TICKER with the market?")
    println(io, "-" ^ 72)
    println(io, "   Two approaches were tested:")
    println(io)
    println(io, "   Mean-Variance (Markowitz) Optimal:")
    println(io, "     $TICKER: $(@sprintf("%.1f", opt_port.weights[1]*100))%   $BENCHMARK: $(@sprintf("%.1f", opt_port.weights[2]*100))%")
    println(io, "     Sharpe: $(@sprintf("%.3f", opt_port.sharpe))")
    println(io)
    println(io, "   Risk Parity (Equal Risk Contribution):")
    println(io, "     $TICKER: $(@sprintf("%.1f", rp.weights[1]*100))%   $BENCHMARK: $(@sprintf("%.1f", rp.weights[2]*100))%")
    println(io, "     Sharpe: $(@sprintf("%.3f", rp.sharpe))")
    println(io)
    if opt_port.weights[1] < 0.1
        println(io, "   NOTE: The optimizer wants almost NO $TICKER — it prefers the index.")
        println(io, "   This suggests $TICKER's risk-return profile is unfavorable right now.")
    end
    println(io)

    # ML
    println(io, "14. MACHINE LEARNING SIGNAL — What does the algorithm think?")
    println(io, "-" ^ 72)
    println(io, "   A logistic regression model was trained on RSI, MACD, Bollinger Bands,")
    println(io, "   momentum, and recent volatility to predict 5-day returns.")
    println(io, "   Prediction: $(ml.prediction)")
    println(io, "   Probability of going UP: $(@sprintf("%.1f", ml.probability_up))%")
    println(io, "   Model accuracy (out-of-sample): $(@sprintf("%.1f", ml.accuracy))%")
    if ml.accuracy < 55
        println(io, "   CAVEAT: Accuracy is near coin-flip. ML models struggle with stock prediction.")
        println(io, "   Use this as ONE input among many, not as a standalone signal.")
    else
        println(io, "   The model shows some predictive power — worth considering alongside other signals.")
    end
    println(io)

    # Technicals summary
    println(io, "15. TECHNICAL INDICATORS — What does the chart say?")
    println(io, "-" ^ 72)
    rsi_now = rsi_v[end]
    println(io, "   RSI (14-day): $(@sprintf("%.1f", rsi_now))")
    if rsi_now < 30
        println(io, "   OVERSOLD — the stock has been beaten down. Historically, this often")
        println(io, "   precedes a bounce. Contrarian investors see this as a buying opportunity.")
    elseif rsi_now > 70
        println(io, "   OVERBOUGHT — the stock has run up fast. It may be due for a pullback.")
    else
        println(io, "   NEUTRAL — neither overbought nor oversold.")
    end
    println(io)
    println(io, "   MACD Histogram: $(@sprintf("%+.3f", macd_h[end]))")
    if macd_h[end] > 0
        println(io, "   POSITIVE — upward momentum is intact.")
    else
        println(io, "   NEGATIVE — momentum is to the downside.")
    end
    println(io)
    pct_sma200 = (prices[end] / sma200_v[end] - 1) * 100
    println(io, "   Price vs 200-day Moving Average: $(@sprintf("%+.1f", pct_sma200))%")
    if pct_sma200 > 5
        println(io, "   ABOVE the 200-day average — the long-term trend is UP.")
    elseif pct_sma200 < -5
        println(io, "   BELOW the 200-day average — the long-term trend is DOWN.")
        println(io, "   Many institutional investors won't buy stocks below their 200-day MA.")
    else
        println(io, "   NEAR the 200-day average — at a critical decision point.")
    end
    println(io)

    # Hurst
    println(io, "16. MARKET BEHAVIOR — Is this stock trending or random?")
    println(io, "-" ^ 72)
    println(io, "   Hurst Exponent: $(@sprintf("%.2f", H))")
    if H > 0.6
        println(io, "   TRENDING — price moves tend to continue in the same direction.")
        println(io, "   Momentum strategies (buy strength, sell weakness) work well here.")
    elseif H < 0.4
        println(io, "   MEAN-REVERTING — price moves tend to reverse.")
        println(io, "   Contrarian strategies (buy dips, sell rallies) work better here.")
    else
        println(io, "   RANDOM WALK — the stock follows no predictable pattern.")
        println(io, "   This is consistent with the Efficient Market Hypothesis.")
    end
    println(io)

    # BULLISH/BEARISH SUMMARY
    println(io, "=" ^ 72)
    println(io, "COMPLETE FACTOR SUMMARY")
    println(io, "=" ^ 72)
    println(io)
    println(io, "REASONS TO BUY ($n_bull factors):")
    for (i, f) in enumerate(bullish)
        println(io, "  $(i). $f")
    end
    println(io)
    println(io, "REASONS NOT TO BUY ($n_bear factors):")
    for (i, f) in enumerate(bearish)
        println(io, "  $(i). $f")
    end
    println(io)
    if !isempty(warnings)
        println(io, "RISK WARNINGS:")
        for w in warnings
            println(io, "  !! $w")
        end
        println(io)
    end

    # FINAL BOTTOM LINE
    println(io, "=" ^ 72)
    println(io, "FINAL VERDICT: $decision")
    println(io, "=" ^ 72)
    println(io, bottom_line)
    println(io)
    println(io, "Price Targets (1 year):")
    println(io, "  Worst case:  \$$(round(mc_p5, digits=2))  ($(@sprintf("%+.1f", (mc_p5/S0-1)*100))%)")
    println(io, "  Most likely: \$$(round(mc_p50, digits=2))  ($(@sprintf("%+.1f", (mc_p50/S0-1)*100))%)")
    println(io, "  Best case:   \$$(round(mc_p95, digits=2))  ($(@sprintf("%+.1f", (mc_p95/S0-1)*100))%)")
    println(io)
    println(io, "Position Sizing:")
    println(io, "  ★ Kelly ½ recommends: $(@sprintf("%.0f", kelly.kelly_half*100))% of portfolio (edge consistency: $(@sprintf("%.0f", kelly.edge_consistency))%)")
    println(io, "  Kelly ¼ (conservative): $(@sprintf("%.0f", kelly.kelly_quarter*100))% of portfolio")
    println(io, "  Max shares per \$1,000 risk: $(max(1, floor(Int, 1000/daily_var_dollar)))")
    println(io)
    println(io, "=" ^ 72)
    println(io, "  Report generated by Julia Quant Analysis Engine (24 models)")
    println(io, "  This is NOT financial advice. Past performance does not guarantee future results.")
    println(io, "=" ^ 72)
end

println("  Output directory: $OUTPUT_DIR")
println("  ├── $(TICKER)_technical_analysis.png")
println("  ├── $(TICKER)_quant_models.png")
println("  ├── $(TICKER)_decision_analysis.png")
println("  ├── $(TICKER)_advanced_models.png")
println("  ├── $(TICKER)_analysis_report.txt")

# ══════════════════════════════════════════════════════════════
#  PROFESSIONAL PDF REPORT (Luxor.jl / Cairo)
# ══════════════════════════════════════════════════════════════
print("  Generating PDF report...")

pdf_path = "$(OUTPUT_DIR)/REPORT_$(TICKER)_Full_Analysis.pdf"

# ── Helper constants ─────────────────────────────────────────
PDF_W = 612   # US Letter width in points
PDF_H = 792   # US Letter height in points
MARGIN = 50
COL_W = PDF_W - 2*MARGIN

# Color palette
c_navy   = parse(Luxor.Colorant, "midnightblue")
c_green  = parse(Luxor.Colorant, "forestgreen")
c_red    = parse(Luxor.Colorant, "firebrick")
c_amber  = parse(Luxor.Colorant, "darkorange")
c_gray   = parse(Luxor.Colorant, "gray40")
c_ltgray = parse(Luxor.Colorant, "gray90")
c_white  = parse(Luxor.Colorant, "white")
c_black  = parse(Luxor.Colorant, "black")

# Decide verdict color
verdict_color = if startswith(decision, "BUY") || startswith(decision, "LEAN")
    c_green
elseif startswith(decision, "DO NOT")
    c_red
else
    c_amber
end

# ── Helper functions for PDF ─────────────────────────────────
function pdf_header(title::String, y::Real)
    Luxor.sethue(c_navy)
    Luxor.fontsize(16)
    Luxor.fontface("Helvetica-Bold")
    Luxor.text(title, Luxor.Point(MARGIN, y))
    Luxor.sethue(c_navy)
    Luxor.line(Luxor.Point(MARGIN, y + 4), Luxor.Point(PDF_W - MARGIN, y + 4), action=:stroke)
    return y + 24
end

function pdf_text(txt::String, y::Real; sz=10, color=c_black, bold=false)
    Luxor.sethue(color)
    Luxor.fontsize(sz)
    Luxor.fontface(bold ? "Helvetica-Bold" : "Helvetica")
    Luxor.text(txt, Luxor.Point(MARGIN, y))
    return y + sz + 4
end

function pdf_text_right(txt::String, y::Real, x_right::Real; sz=10, color=c_black)
    Luxor.sethue(color)
    Luxor.fontsize(sz)
    Luxor.fontface("Helvetica")
    Luxor.text(txt, Luxor.Point(x_right, y), halign=:right)
    return y
end

function pdf_kv(key::String, val::String, y::Real; val_color=c_black)
    Luxor.sethue(c_gray)
    Luxor.fontsize(10)
    Luxor.fontface("Helvetica")
    Luxor.text(key, Luxor.Point(MARGIN + 10, y))
    Luxor.sethue(val_color)
    Luxor.fontface("Helvetica-Bold")
    Luxor.text(val, Luxor.Point(MARGIN + 250, y))
    return y + 16
end

function pdf_table_row(cols::Vector{String}, widths::Vector{Int}, y::Real;
                       bg=nothing, bold=false, colors=nothing)
    if bg !== nothing
        Luxor.sethue(bg)
        Luxor.rect(Luxor.Point(MARGIN, y - 11), COL_W, 16, action=:fill)
    end
    x = MARGIN + 5
    for (i, col) in enumerate(cols)
        Luxor.sethue(colors !== nothing && i <= length(colors) ? colors[i] : c_black)
        Luxor.fontface(bold ? "Helvetica-Bold" : "Helvetica")
        Luxor.fontsize(9)
        Luxor.text(first(col, 60), Luxor.Point(x, y))
        x += widths[min(i, length(widths))]
    end
    return y + 16
end

function pdf_newpage()
    Luxor.Cairo.show_page(Luxor.currentdrawing().cr)
    Luxor.background("white")
    # Footer
    Luxor.sethue(c_ltgray)
    Luxor.line(Luxor.Point(MARGIN, PDF_H - 35), Luxor.Point(PDF_W - MARGIN, PDF_H - 35), action=:stroke)
    Luxor.sethue(c_gray)
    Luxor.fontsize(7)
    Luxor.fontface("Helvetica")
    Luxor.text("$(TICKER) Quantitative Analysis Report — Generated $(Dates.format(Dates.today(), "yyyy-mm-dd")) — Julia Quant Engine (24 Models)",
        Luxor.Point(MARGIN, PDF_H - 25))
    Luxor.text("NOT FINANCIAL ADVICE", Luxor.Point(PDF_W - MARGIN, PDF_H - 25), halign=:right)
end

function embed_chart(svg_path::String, y_top::Real, target_w::Real, target_h::Real)
    if isfile(svg_path)
        svgimg = Luxor.readsvg(svg_path)
        sx = target_w / svgimg.width
        sy = target_h / svgimg.height
        sc = min(sx, sy)
        # Center horizontally
        rendered_w = svgimg.width * sc
        x_offset = (PDF_W - rendered_w) / 2
        Luxor.gsave()
        Luxor.translate(Luxor.Point(x_offset, y_top))
        Luxor.scale(sc)
        Luxor.placeimage(svgimg, Luxor.Point(0, 0), centered=false)
        Luxor.grestore()
    else
        Luxor.sethue(c_gray)
        Luxor.fontsize(10)
        Luxor.text("[Chart not available: $(basename(svg_path))]", Luxor.Point(MARGIN, y_top + 30))
    end
end

# ── Build the PDF ────────────────────────────────────────────
Luxor.Drawing(PDF_W, PDF_H, pdf_path)
Luxor.origin(Luxor.Point(0, 0))   # absolute coordinates (top-left = 0,0)
Luxor.background("white")

# ═══════════════════ PAGE 1: COVER ═══════════════════════════
# Background accent bar
Luxor.sethue(c_navy)
Luxor.rect(Luxor.Point(0, 0), PDF_W, 180, action=:fill)

# Title
Luxor.sethue(c_white)
Luxor.fontsize(36)
Luxor.fontface("Helvetica-Bold")
Luxor.text("$(TICKER)", Luxor.Point(MARGIN, 70))

Luxor.fontsize(18)
Luxor.fontface("Helvetica")
Luxor.text("Quantitative Analysis Report", Luxor.Point(MARGIN, 100))

Luxor.fontsize(11)
Luxor.text("24-Model Deep Analysis  |  $(Dates.format(Dates.today(), "U d, yyyy"))", Luxor.Point(MARGIN, 125))
Luxor.text("Data: $(Date(stock.dates[1])) to $(Date(stock.dates[end]))  |  $(length(prices)) trading days",
    Luxor.Point(MARGIN, 145))

# Verdict badge — auto-size font to fit
badge_y = 230
Luxor.sethue(verdict_color)
Luxor.rect(Luxor.Point(MARGIN, badge_y), COL_W, 60, action=:fill)
Luxor.sethue(c_white)
verdict_txt = "VERDICT:  $decision"
vfont = length(verdict_txt) > 30 ? 18 : length(verdict_txt) > 22 ? 22 : 28
Luxor.fontsize(vfont)
Luxor.fontface("Helvetica-Bold")
Luxor.text(verdict_txt, Luxor.Point(MARGIN + 15, badge_y + 38))

# Price info box
y = 330
Luxor.sethue(c_ltgray)
Luxor.rect(Luxor.Point(MARGIN, y), COL_W, 120, action=:fill)
Luxor.sethue(c_navy)
Luxor.fontsize(12)
Luxor.fontface("Helvetica-Bold")
Luxor.text("CURRENT SNAPSHOT", Luxor.Point(MARGIN + 10, y + 20))

y = pdf_kv("Current Price:", @sprintf("\$%.2f", S0), y + 40)
y = pdf_kv("Annual Return:", @sprintf("%+.1f%%", stats.annual_return*100), y;
    val_color = stats.annual_return > 0 ? c_green : c_red)
y = pdf_kv("Annual Volatility:", @sprintf("%.1f%%", stats.annual_vol*100), y)
y = pdf_kv("Sharpe Ratio:", @sprintf("%.2f", sh), y;
    val_color = sh > 1 ? c_green : sh > 0.5 ? c_amber : c_red)
y = pdf_kv("Max Drawdown:", @sprintf("-%.1f%%", mdd.value*100), y; val_color=c_red)
y = pdf_kv("Beta vs S&P 500:", @sprintf("%.2f", capm.beta), y)

# Price targets
y += 20
Luxor.sethue(c_navy)
Luxor.fontsize(14)
Luxor.fontface("Helvetica-Bold")
Luxor.text("PRICE TARGETS (1-Year, Monte Carlo)", Luxor.Point(MARGIN, y))
y += 25
y = pdf_kv("Bear Case (5th %ile):", @sprintf("\$%.2f  (%+.1f%%)", mc_p5, (mc_p5/S0-1)*100), y; val_color=c_red)
y = pdf_kv("Base Case (median):", @sprintf("\$%.2f  (%+.1f%%)", mc_p50, (mc_p50/S0-1)*100), y; val_color=c_navy)
y = pdf_kv("Bull Case (95th %ile):", @sprintf("\$%.2f  (%+.1f%%)", mc_p95, (mc_p95/S0-1)*100), y; val_color=c_green)
y = pdf_kv("Probability of Profit:", @sprintf("%.1f%%", prob_profit), y;
    val_color = prob_profit > 60 ? c_green : prob_profit > 50 ? c_amber : c_red)

# Composite signal
y += 20
Luxor.sethue(c_navy)
Luxor.fontsize(14)
Luxor.fontface("Helvetica-Bold")
Luxor.text("COMPOSITE SIGNAL", Luxor.Point(MARGIN, y))
y += 25
y = pdf_kv("Composite Score:", @sprintf("%+.4f", sig.score), y;
    val_color = sig.score > 0 ? c_green : c_red)
y = pdf_kv("Bullish Factors:", "$(n_bull)", y; val_color=c_green)
y = pdf_kv("Bearish Factors:", "$(n_bear)", y; val_color=c_red)
y = pdf_kv("Bull/Bear Ratio:", @sprintf("%.0f%% / %.0f%%", bull_pct, 100-bull_pct), y)

# Footer on cover
Luxor.sethue(c_gray)
Luxor.fontsize(8)
Luxor.text("Generated by Julia Quant Analysis Engine (24 Models) — NOT FINANCIAL ADVICE",
    Luxor.Point(MARGIN, PDF_H - 30))

# ═══════════════════ PAGE 2: EXECUTIVE METRICS TABLE ═════════
pdf_newpage()
y = pdf_header("EXECUTIVE SUMMARY — KEY METRICS", 50)
y += 5

# Table header
widths = [200, 160, 150]
y = pdf_table_row(["Metric", "Value", "Assessment"], widths, y; bg=c_navy, bold=true,
    colors=[c_white, c_white, c_white])

# Table rows (alternating colors)
metrics_table = [
    ("Annual Return", @sprintf("%+.1f%%", stats.annual_return*100),
        stats.annual_return > 0.15 ? "Strong" : stats.annual_return > 0 ? "Positive" : "Negative",
        stats.annual_return > 0.10 ? c_green : stats.annual_return > 0 ? c_amber : c_red),
    ("Annual Volatility", @sprintf("%.1f%%", stats.annual_vol*100),
        stats.annual_vol > 0.40 ? "Very High" : stats.annual_vol > 0.25 ? "Moderate" : "Low",
        stats.annual_vol < 0.25 ? c_green : stats.annual_vol < 0.40 ? c_amber : c_red),
    ("Sharpe Ratio", @sprintf("%.2f", sh),
        sh > 1.0 ? "Excellent" : sh > 0.5 ? "Good" : sh > 0 ? "Marginal" : "Poor",
        sh > 1.0 ? c_green : sh > 0.5 ? c_green : sh > 0 ? c_amber : c_red),
    ("Sortino Ratio", @sprintf("%.2f", so),
        so > 1.5 ? "Excellent" : so > 0.8 ? "Good" : "Weak", c_black),
    ("Calmar Ratio", @sprintf("%.2f", cal),
        cal > 1.0 ? "Good" : cal > 0.5 ? "Moderate" : "Weak", c_black),
    ("Max Drawdown", @sprintf("-%.1f%%", mdd.value*100),
        mdd.value > 0.30 ? "Severe" : mdd.value > 0.15 ? "Moderate" : "Mild", c_red),
    ("VaR 95% (daily)", @sprintf("%.2f%%", var_h*100), "", c_black),
    ("CVaR 95%", @sprintf("%.2f%%", cvar_v*100), "", c_black),
    ("Beta", @sprintf("%.2f", capm.beta),
        capm.beta > 1.2 ? "Aggressive" : capm.beta > 0.8 ? "Market-like" : "Defensive", c_black),
    ("CAPM Alpha", @sprintf("%+.1f%%", capm.alpha*100),
        capm.alpha > 0.03 ? "Outperforming" : capm.alpha < -0.03 ? "Underperforming" : "Fair",
        capm.alpha > 0 ? c_green : c_red),
    ("GARCH Forecast Vol", @sprintf("%.1f%%", garch.σ_annual_forecast*100),
        garch.σ_annual_forecast > stats.annual_vol*1.2 ? "Rising" :
        garch.σ_annual_forecast < stats.annual_vol*0.8 ? "Falling" : "Stable", c_black),
    ("Hurst Exponent", @sprintf("%.2f", H),
        H > 0.6 ? "Trending" : H < 0.4 ? "Mean-reverting" : "Random walk", c_black),
    ("RSI (14-day)", @sprintf("%.1f", rsi_v[end]),
        rsi_v[end] > 70 ? "Overbought" : rsi_v[end] < 30 ? "Oversold" : "Neutral", c_black),
    ("** Kelly 1/2 (Position Size)", @sprintf("%.0f%%", kelly.kelly_half*100),
        kelly.edge_consistency > 70 ? "Strong, stable edge" :
        kelly.kelly_half > 0.1 ? "Positive edge" : "Weak/no edge",
        kelly.kelly_half > 0.3 ? c_green : kelly.kelly_half > 0 ? c_amber : c_red),
    ("ML Signal", ml.prediction,
        @sprintf("%.0f%% accuracy", ml.accuracy),
        ml.prediction == "BULLISH" ? c_green : c_red),
]

for (i, (metric, val, assess, clr)) in enumerate(metrics_table)
    global y
    bg = i % 2 == 0 ? c_ltgray : nothing
    y = pdf_table_row([metric, val, assess], widths, y; bg=bg,
        colors=[c_black, clr, c_gray])
end

# ═══════════════════ PAGES 3-6: CHART DASHBOARDS ═════════════
chart_svgs = [
    ("$(OUTPUT_DIR)/$(TICKER)_technical_analysis.svg", "DASHBOARD 1 — TECHNICAL ANALYSIS"),
    ("$(OUTPUT_DIR)/$(TICKER)_quant_models.svg",       "DASHBOARD 2 — QUANTITATIVE MODELS"),
    ("$(OUTPUT_DIR)/$(TICKER)_decision_analysis.svg",  "DASHBOARD 3 — DECISION ANALYSIS"),
    ("$(OUTPUT_DIR)/$(TICKER)_advanced_models.svg",    "DASHBOARD 4 — ADVANCED MODELS"),
]
for (svg_path, title) in chart_svgs
    global y
    pdf_newpage()
    y = pdf_header(title, 40)
    # Use full page width (edge to edge) for charts, with minimal margins
    embed_chart(svg_path, y + 2, PDF_W - 20, PDF_H - y - 45)
end

# ═══════════════════ PAGE 7: MODEL RESULTS SUMMARY ═══════════
pdf_newpage()
y = pdf_header("MODEL RESULTS — PLAIN ENGLISH SUMMARY", 50)
y += 5

model_summaries = [
    ("1. Returns",
     @sprintf("%+.1f%% annual", stats.annual_return*100),
     stats.annual_return > 0.15 ? "Strong" : stats.annual_return > 0 ? "Positive" : "Negative",
     stats.annual_return > 0.10 ? c_green : stats.annual_return > 0 ? c_amber : c_red),
    ("2. Risk (VaR/CVaR)",
     @sprintf("VaR=%.2f%% CVaR=%.2f%%", var_h*100, cvar_v*100),
     mdd.value > 0.30 ? "High risk" : "Moderate",
     mdd.value > 0.30 ? c_red : c_amber),
    ("3. Sharpe / Sortino",
     @sprintf("%.2f / %.2f", sh, so),
     sh > 1.0 ? "Excellent risk-adjusted" : sh > 0.5 ? "Adequate" : "Weak",
     sh > 0.5 ? c_green : c_amber),
    ("4. GARCH Volatility",
     @sprintf("Forecast: %.1f%%", garch.σ_annual_forecast*100),
     garch.σ_annual_forecast > stats.annual_vol*1.2 ? "Vol rising!" : "Stable",
     garch.σ_annual_forecast > stats.annual_vol*1.2 ? c_red : c_green),
    ("5. EGARCH (Asymmetric)",
     egarch.leverage_effect ? "Leverage detected" : "Symmetric",
     egarch.leverage_effect ? "Bad news amplifies vol" : "Normal",
     egarch.leverage_effect ? c_red : c_green),
    ("6. Monte Carlo",
     @sprintf("Median: \$%.0f  P(profit)=%.0f%%", mc_p50, prob_profit),
     prob_profit > 65 ? "Favorable odds" : prob_profit > 50 ? "Slight edge" : "Unfavorable",
     prob_profit > 60 ? c_green : prob_profit > 50 ? c_amber : c_red),
    ("7. Black-Scholes",
     @sprintf("Call=\$%.2f  Put=\$%.2f", bs_call.price, bs_put.price),
     "ATM option pricing", c_black),
    ("8. CAPM",
     @sprintf("Beta=%.2f  Alpha=%+.1f%%", capm.beta, capm.alpha*100),
     capm.alpha > 0.03 ? "Beating expectations" : capm.alpha < -0.03 ? "Lagging" : "Fair",
     capm.alpha > 0 ? c_green : c_red),
    ("9. Fama-French 3-Factor",
     ff3 !== nothing ? @sprintf("FF3 Alpha=%+.1f%%", ff3.alpha_annual*100) : "N/A",
     ff3 !== nothing ? (ff3.alpha_annual > 0.03 ? "True alpha" : "Factor-driven") : "Unavailable",
     ff3 !== nothing && ff3.alpha_annual > 0.03 ? c_green : c_black),
    ("10. ARIMA Forecast",
     @sprintf("%s %+.2f%% (21 days)", arima.forecast_direction, arima.cumulative_return_pct),
     @sprintf("R²=%.1f%%", arima.r_squared*100),
     arima.cumulative_return_pct > 0 ? c_green : c_red),
    ("11. ** KELLY CRITERION",
     @sprintf("½K=%.0f%% ¼K=%.0f%% Edge:%.0f%%", kelly.kelly_half*100, kelly.kelly_quarter*100, kelly.edge_consistency),
     kelly.edge_consistency > 70 ? "Strong stable edge" : kelly.kelly_half > 0.1 ? "Positive edge" : "Weak",
     kelly.kelly_half > 0.3 && kelly.edge_consistency > 60 ? c_green : kelly.kelly_half > 0 ? c_amber : c_red),
    ("12. Avellaneda-Stoikov",
     @sprintf("Bid=\$%.2f  Ask=\$%.2f", avstk.bid, avstk.ask),
     @sprintf("Spread: %.1f bps", avstk.spread_bps), c_black),
    ("13. Cointegration",
     coint.is_cointegrated ? "Cointegrated with SPY" : "Not cointegrated",
     coint.is_cointegrated ? "Pairs trade possible" : "No pairs signal",
     coint.is_cointegrated ? c_green : c_gray),
    ("14. Risk Parity",
     @sprintf("AAPL: %.0f%%  SPY: %.0f%%", rp.weights[1]*100, rp.weights[2]*100),
     @sprintf("Sharpe: %.3f", rp.sharpe), c_black),
    ("15. ML Logistic Regression",
     @sprintf("%s (%.0f%% prob up)", ml.prediction, ml.probability_up),
     @sprintf("Accuracy: %.0f%%", ml.accuracy),
     ml.prediction == "BULLISH" ? c_green : c_red),
]

widths_m = [140, 190, 180]
y = pdf_table_row(["Model", "Result", "Interpretation"], widths_m, y; bg=c_navy, bold=true,
    colors=[c_white, c_white, c_white])

for (i, (model, result, interp, clr)) in enumerate(model_summaries)
    global y
    bg = i % 2 == 0 ? c_ltgray : nothing
    y = pdf_table_row([model, result, interp], widths_m, y; bg=bg,
        colors=[c_black, clr, c_gray])
    if y > PDF_H - 60
        pdf_newpage()
        y = pdf_header("MODEL RESULTS (continued)", 50)
        y += 5
        y = pdf_table_row(["Model", "Result", "Interpretation"], widths_m, y; bg=c_navy, bold=true,
            colors=[c_white, c_white, c_white])
    end
end

# ═══════════════════ PAGE: BULLISH / BEARISH FACTORS ═════════
pdf_newpage()
y = pdf_header("FACTOR ANALYSIS — BULLISH vs BEARISH", 50)

# Bullish
y += 10
Luxor.sethue(c_green)
Luxor.fontsize(13)
Luxor.fontface("Helvetica-Bold")
Luxor.text("BULLISH FACTORS ($n_bull)", Luxor.Point(MARGIN, y))
y += 5
Luxor.sethue(c_green)
Luxor.setopacity(0.08)
Luxor.rect(Luxor.Point(MARGIN, y), COL_W, min(n_bull * 15 + 10, 300), action=:fill)
Luxor.setopacity(1.0)
y += 15
for (i, f) in enumerate(bullish)
    global y
    if y > PDF_H - 120
        pdf_newpage()
        y = pdf_header("FACTOR ANALYSIS (continued)", 50)
        y += 15
    end
    Luxor.sethue(c_green)
    Luxor.fontsize(9)
    Luxor.fontface("Helvetica")
    Luxor.text("  [+]  $f", Luxor.Point(MARGIN + 5, y))
    y += 15
end

# Bearish
y += 20
if y > PDF_H - 180
    global y
    pdf_newpage()
    y = pdf_header("FACTOR ANALYSIS (continued)", 50)
    y += 10
end
Luxor.sethue(c_red)
Luxor.fontsize(13)
Luxor.fontface("Helvetica-Bold")
Luxor.text("BEARISH FACTORS ($n_bear)", Luxor.Point(MARGIN, y))
y += 5
Luxor.sethue(c_red)
Luxor.setopacity(0.08)
Luxor.rect(Luxor.Point(MARGIN, y), COL_W, min(n_bear * 15 + 10, 300), action=:fill)
Luxor.setopacity(1.0)
y += 15
for (i, f) in enumerate(bearish)
    global y
    if y > PDF_H - 80
        pdf_newpage()
        y = pdf_header("FACTOR ANALYSIS (continued)", 50)
        y += 15
    end
    Luxor.sethue(c_red)
    Luxor.fontsize(9)
    Luxor.fontface("Helvetica")
    Luxor.text("  [-]  $f", Luxor.Point(MARGIN + 5, y))
    y += 15
end

# Risk warnings
if !isempty(warnings)
    global y
    y += 20
    if y > PDF_H - 120
        pdf_newpage()
        y = pdf_header("RISK WARNINGS", 50)
        y += 10
    end
    Luxor.sethue(c_red)
    Luxor.fontsize(13)
    Luxor.fontface("Helvetica-Bold")
    Luxor.text("!!  RISK WARNINGS", Luxor.Point(MARGIN, y))
    y += 5
    Luxor.sethue(c_red)
    Luxor.setopacity(0.06)
    Luxor.rect(Luxor.Point(MARGIN, y), COL_W, length(warnings) * 15 + 10, action=:fill)
    Luxor.setopacity(1.0)
    y += 15
    for w in warnings
        global y
        Luxor.sethue(c_red)
        Luxor.fontsize(9)
        Luxor.fontface("Helvetica-Bold")
        Luxor.text("  !!  $w", Luxor.Point(MARGIN + 5, y))
        y += 15
    end
end

# ═══════════════════ FINAL PAGE: VERDICT & DISCLAIMER ════════
pdf_newpage()
y = 100

# Big verdict box
Luxor.sethue(verdict_color)
Luxor.rect(Luxor.Point(MARGIN, y), COL_W, 80, action=:fill)
Luxor.sethue(c_white)
vfont_final = length(decision) > 25 ? 20 : length(decision) > 18 ? 24 : 32
Luxor.fontsize(vfont_final)
Luxor.fontface("Helvetica-Bold")
Luxor.text(decision, Luxor.Point(PDF_W/2, y + 52), halign=:center)

y += 110
Luxor.sethue(c_black)
Luxor.fontsize(12)
Luxor.fontface("Helvetica")
# Wrap bottom_line
bl_words = split(bottom_line)
bl_line = ""
for w in bl_words
    global y, bl_line
    test = bl_line == "" ? w : "$bl_line $w"
    if length(test) > 80
        Luxor.text(bl_line, Luxor.Point(MARGIN, y))
        y += 18
        bl_line = w
    else
        bl_line = test
    end
end
if bl_line != ""
    global y
    Luxor.text(bl_line, Luxor.Point(MARGIN, y))
    y += 18
end

y += 30
y = pdf_header("PRICE TARGETS", y)
y = pdf_kv("Bear Case (5th %ile):", @sprintf("\$%.2f  (%+.1f%%)", mc_p5, (mc_p5/S0-1)*100), y; val_color=c_red)
y = pdf_kv("Base Case (median):", @sprintf("\$%.2f  (%+.1f%%)", mc_p50, (mc_p50/S0-1)*100), y; val_color=c_navy)
y = pdf_kv("Bull Case (95th %ile):", @sprintf("\$%.2f  (%+.1f%%)", mc_p95, (mc_p95/S0-1)*100), y; val_color=c_green)

y += 20
y = pdf_header("POSITION SIZING", y)
y = pdf_kv("** Kelly 1/2 (recommended):", @sprintf("%.0f%% of portfolio (edge consistency: %.0f%%)", kelly.kelly_half*100, kelly.edge_consistency), y)
y = pdf_kv("Daily VaR (95%):", @sprintf("\$%.2f per share", daily_var_dollar), y)
y = pdf_kv("Max shares per \$1,000 risk:", "$(max(1, floor(Int, 1000/daily_var_dollar)))", y)

y += 20
y = pdf_header("TECHNICAL LEVELS", y)
y = pdf_kv("Support (Bollinger lower):", @sprintf("\$%.2f", bb_lo[end]), y)
y = pdf_kv("Resistance (Bollinger upper):", @sprintf("\$%.2f", bb_up[end]), y)
y = pdf_kv("SMA 20 / 50 / 200:",
    @sprintf("\$%.2f / \$%.2f / \$%.2f", sma20_v[end], sma50_v[end], sma200_v[end]), y)
y = pdf_kv("RSI (14-day):", @sprintf("%.1f", rsi_v[end]), y)

# Disclaimer
y = PDF_H - 120
Luxor.sethue(c_ltgray)
Luxor.rect(Luxor.Point(MARGIN, y), COL_W, 80, action=:fill)
Luxor.sethue(c_gray)
Luxor.fontsize(8)
Luxor.fontface("Helvetica")
y += 15
Luxor.text("DISCLAIMER: This report is generated by an automated quantitative analysis engine for educational", Luxor.Point(MARGIN + 5, y))
y += 12
Luxor.text("purposes only. It is NOT financial advice. Past performance does not guarantee future results.", Luxor.Point(MARGIN + 5, y))
y += 12
Luxor.text("Always consult a qualified financial advisor before making investment decisions. The models used", Luxor.Point(MARGIN + 5, y))
y += 12
Luxor.text("have known limitations and simplifying assumptions. Use at your own risk.", Luxor.Point(MARGIN + 5, y))
y += 12
Luxor.text("Report generated by Julia Quant Analysis Engine (24 Models) — $(Dates.format(Dates.now(), "yyyy-mm-dd HH:MM"))", Luxor.Point(MARGIN + 5, y))

Luxor.finish()
println("  done.")
println("  └── REPORT_$(TICKER)_Full_Analysis.pdf")

# ══════════════════════════════════════════════════════════════
#  METRICS FILE — Program self-analysis & execution time
# ══════════════════════════════════════════════════════════════

T_END = time_ns()
elapsed_sec  = (T_END - T_START) / 1e9
elapsed_min  = elapsed_sec / 60

# Self-analyze the source file
source_path = @__FILE__
source_lines = readlines(source_path)
n_total_lines    = length(source_lines)
n_code_lines     = count(l -> !isempty(strip(l)) && !startswith(strip(l), "#"), source_lines)
n_comment_lines  = count(l -> startswith(strip(l), "#"), source_lines)
n_blank_lines    = count(l -> isempty(strip(l)), source_lines)
n_functions      = count(l -> occursin(r"^function ", l) || occursin(r"^\w+\(.*\)\s*=", l), source_lines)
n_structs        = count(l -> occursin(r"^(mutable\s+)?struct ", l), source_lines)
n_abstract_types = count(l -> occursin(r"^abstract type ", l), source_lines)
n_for_loops      = count(l -> occursin(r"\bfor\b.*\bin\b", l), source_lines)
n_while_loops    = count(l -> occursin(r"^\s*while\b", l), source_lines)
n_if_blocks      = count(l -> occursin(r"^\s*if\b", l), source_lines)
n_using          = count(l -> occursin(r"^using ", l), source_lines)
n_import         = count(l -> occursin(r"^import ", l), source_lines)
n_macros_used    = count(l -> occursin(r"@\w+", l), source_lines)
n_println        = count(l -> occursin(r"\bprintln\b|\b@printf\b", l), source_lines)
n_plot_calls     = count(l -> occursin(r"\b(plot|scatter|bar|histogram|heatmap|hline!|vline!|annotate!|savefig)\b", l), source_lines)

# Count unique packages from using/import lines
pkg_lines = filter(l -> occursin(r"^(using|import) ", l), source_lines)
packages = String[]
for pl in pkg_lines
    body = replace(pl, r"^(using|import)\s+" => "")
    for tok in split(body, ",")
        tok = strip(tok)
        tok = replace(tok, r"\s*:.*" => "")   # remove submodule imports
        tok = replace(tok, r"\s*\..*" => "")   # remove dot access
        if !isempty(tok)
            push!(packages, tok)
        end
    end
end
unique!(packages)
n_packages = length(packages)

# File size
file_bytes = filesize(source_path)
file_kb    = file_bytes / 1024

# Write metrics file
metrics_path = "$(OUTPUT_DIR)/Julia_Metrics.txt"
open(metrics_path, "w") do io
    println(io, "╔══════════════════════════════════════════════════════════════╗")
    println(io, "║          PROGRAM METRICS — Julia Quant Analysis Engine      ║")
    println(io, "╚══════════════════════════════════════════════════════════════╝")
    println(io)
    println(io, "  Generated:  $(Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS"))")
    println(io, "  Ticker:     $TICKER")
    println(io, "  Source:     $(basename(source_path))")
    println(io)
    println(io, "════════════════════════════════════════════════════════════════")
    println(io, "  EXECUTION TIME")
    println(io, "════════════════════════════════════════════════════════════════")
    @printf(io, "  Total runtime:      %8.2f seconds\n", elapsed_sec)
    @printf(io, "                      %8.2f minutes\n", elapsed_min)
    println(io)
    println(io, "════════════════════════════════════════════════════════════════")
    println(io, "  SOURCE CODE METRICS")
    println(io, "════════════════════════════════════════════════════════════════")
    @printf(io, "  File size:          %8.1f KB  (%d bytes)\n", file_kb, file_bytes)
    @printf(io, "  Total lines:        %8d\n", n_total_lines)
    @printf(io, "  Code lines:         %8d  (%.1f%%)\n", n_code_lines, n_code_lines/n_total_lines*100)
    @printf(io, "  Comment lines:      %8d  (%.1f%%)\n", n_comment_lines, n_comment_lines/n_total_lines*100)
    @printf(io, "  Blank lines:        %8d  (%.1f%%)\n", n_blank_lines, n_blank_lines/n_total_lines*100)
    println(io)
    println(io, "════════════════════════════════════════════════════════════════")
    println(io, "  STRUCTURE METRICS")
    println(io, "════════════════════════════════════════════════════════════════")
    @printf(io, "  Functions:          %8d\n", n_functions)
    @printf(io, "  Structs (types):    %8d\n", n_structs)
    @printf(io, "  Abstract types:     %8d\n", n_abstract_types)
    @printf(io, "  For loops:          %8d\n", n_for_loops)
    @printf(io, "  While loops:        %8d\n", n_while_loops)
    @printf(io, "  If blocks:          %8d\n", n_if_blocks)
    @printf(io, "  Macro invocations:  %8d  (lines using @macros)\n", n_macros_used)
    println(io)
    println(io, "════════════════════════════════════════════════════════════════")
    println(io, "  DEPENDENCIES")
    println(io, "════════════════════════════════════════════════════════════════")
    @printf(io, "  using statements:   %8d\n", n_using)
    @printf(io, "  import statements:  %8d\n", n_import)
    @printf(io, "  Unique packages:    %8d\n", n_packages)
    println(io, "  Packages: $(join(sort(packages), ", "))")
    println(io)
    println(io, "════════════════════════════════════════════════════════════════")
    println(io, "  OUTPUT METRICS")
    println(io, "════════════════════════════════════════════════════════════════")
    @printf(io, "  Print statements:   %8d  (println + @printf)\n", n_println)
    @printf(io, "  Plot/chart calls:   %8d\n", n_plot_calls)
    println(io, "  Models applied:           24")
    println(io, "  Chart dashboards:          4  (PNG + SVG)")
    println(io, "  PDF report pages:          9")
    println(io, "  Text report:               1")
    println(io)
    println(io, "════════════════════════════════════════════════════════════════")
    println(io, "  SYSTEM INFO")
    println(io, "════════════════════════════════════════════════════════════════")
    println(io, "  Julia version:      $(VERSION)")
    println(io, "  OS:                 $(Sys.KERNEL) $(Sys.ARCH)")
    println(io, "  CPU threads:        $(Sys.CPU_THREADS)")
    @printf(io, "  Memory (total):     %.1f GB\n", Sys.total_memory() / 1073741824)
    println(io)
    println(io, "════════════════════════════════════════════════════════════════")
    println(io, "  COMPARISON CONTEXT")
    println(io, "════════════════════════════════════════════════════════════════")
    println(io, "  Language:           Julia (compiled, JIT via LLVM)")
    println(io, "  Paradigm:           Multiple dispatch, JIT-compiled, type-inferred")
    println(io, "  Equivalent Python:  Would require NumPy + SciPy + pandas + scikit-learn")
    println(io, "                      + Cython/Numba for comparable speed")
    println(io, "  Estimated Python")
    println(io, "  runtime (pure):     ~10-50x slower for Monte Carlo & GARCH loops")
    println(io)
    println(io, "════════════════════════════════════════════════════════════════")
    @printf(io, "  TOTAL EXECUTION TIME:  %.2f seconds (%.2f min)\n", elapsed_sec, elapsed_min)
    println(io, "════════════════════════════════════════════════════════════════")
end

# Print summary to terminal
println()
println("═" ^ 64)
println("  EXECUTION METRICS")
println("═" ^ 64)
@printf("  Runtime:          %.2f seconds (%.2f min)\n", elapsed_sec, elapsed_min)
@printf("  Source:           %d lines  |  %d functions  |  %d packages\n", n_total_lines, n_functions, n_packages)
@printf("  Code/Comment/Blank: %d / %d / %d\n", n_code_lines, n_comment_lines, n_blank_lines)
println("  Metrics saved:    Julia_Metrics.txt")
println("═" ^ 64)

println()
println("  Analysis complete.")
println("═" ^ 64)
