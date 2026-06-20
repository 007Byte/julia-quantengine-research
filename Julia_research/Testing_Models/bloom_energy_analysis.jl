# ════════════════════════════════════════════════════════════════
#  QUANT DEEP ANALYSIS — Any Stock Ticker
#  Usage:  julia bloom_energy_analysis.jl AAPL
#          julia bloom_energy_analysis.jl          ← prompts interactively
#  ════════════════════════════════════════════════════════════════
#
#  15 Models Applied:
#   1.  Live OHLCV Data (Yahoo Finance)     9.  GARCH(1,1) Volatility Model
#   2.  Log Returns & Moment Statistics    10.  Monte Carlo GBM (10K paths)
#   3.  Jarque-Bera Normality Test         11.  Black-Scholes + Option Greeks
#   4.  RSI (14-day)                       12.  Beta / Alpha vs S&P 500
#   5.  MACD (12/26/9)                     13.  Hurst Exponent (R/S Analysis)
#   6.  Bollinger Bands (20, 2σ)           14.  JuMP Portfolio Optimization
#   7.  SMA / EMA (20 / 50 / 200)         15.  Composite BUY/HOLD/SELL Engine
#   8.  Risk: VaR, CVaR, Sharpe, Sortino
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

const RF_ANNUAL = 0.053          # US 10-yr Treasury (risk-free rate)
const RF_DAILY  = RF_ANNUAL / 252
const BENCHMARK = "SPY"

# ── Resolve ticker ─────────────────────────────────────────────
# Priority: 1) command-line arg   2) global variable   3) default
# From terminal:   julia bloom_energy_analysis.jl MSFT
# From REPL:       TICKER = "MSFT"; include("bloom_energy_analysis.jl")
if !@isdefined(TICKER) || TICKER === nothing
    global TICKER = if !isempty(ARGS)
        uppercase(strip(ARGS[1]))
    else
        "AAPL"   # safe default — avoids readline() hang in REPL
    end
end
TICKER = uppercase(strip(string(TICKER)))

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
    # χ²(2) survival: exact for df=2
    p  = exp(-jb/2)
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
#  R_BE = α + β·R_SPY + ε
# ══════════════════════════════════════════════════════════════

function market_analysis(r_stock, r_mkt)
    n  = length(r_stock)
    X  = hcat(ones(n), r_mkt)
    b  = X \ r_stock          # OLS: [α_daily, β]
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
#  Maximize Sharpe: find optimal w for BE + hedge (GLD/TLT)
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

    # Sharpe quality
    !isnan(sharpe_val) && (S["Quality"] = clamp(sharpe_val / 2, -1.0, 1.0))

    # Drawdown penalty
    S["Drawdown"] = clamp(1.0 - max_dd_val * 4, -1.0, 1.0)

    # Beta (high beta = higher risk in down markets)
    S["Beta"] = clamp(1.5 - mkt.beta, -1.0, 1.0)

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
#  MAIN — Run all models and generate report + dashboards
# ══════════════════════════════════════════════════════════════

println("═" ^ 64)
println("  $TICKER — INSTITUTIONAL QUANT ANALYSIS")
println("═" ^ 64)

# ─ Fetch live data ────────────────────────────────────────────
print("  Fetching live data for $TICKER + SPY...")
be  = fetch_ohlcv(TICKER, "2y")
spy = fetch_ohlcv("SPY", "2y")
println(" done.\n")

prices  = be.adj
n       = length(prices)
r_be    = diff(log.(prices))           # log daily returns
n_align = min(length(r_be), length(diff(log.(spy.adj))))
r_spy   = diff(log.(spy.adj))[end-n_align+1:end]
r_be_a  = r_be[end-n_align+1:end]

println("  Data range:  $(Date(be.dates[1])) → $(Date(be.dates[end]))")
println("  Trading days: $n   |   Current price: \$$(round(prices[end], digits=2))\n")

# ─ Technical indicators ───────────────────────────────────────
sma20_v = sma(prices, 20);   sma50_v = sma(prices, 50)
sma200_v= sma(prices, 200);  ema20_v = ema(prices, 20)
rsi_v   = rsi(prices)
macd_l, macd_s, macd_h = macd_indicator(prices)
bb_mid, bb_up, bb_lo  = bollinger(prices)
atr_v   = atr(be.high, be.low, be.close)

# ─ Statistics ─────────────────────────────────────────────────
stats = return_stats(r_be)
jb    = jarque_bera(r_be)
H     = hurst_exponent(prices)

# ─ Risk metrics ───────────────────────────────────────────────
var_h  = var_historical(r_be)
var_p  = var_parametric(r_be)
cvar_v = cvar(r_be)
sh     = sharpe(r_be)
so     = sortino(r_be)
cal    = calmar(r_be, prices)
mdd    = max_drawdown(prices)
dd_ser = drawdown_series(prices)
roll_sh= rolling_sharpe(r_be)

# ─ GARCH(1,1) ─────────────────────────────────────────────────
print("  Fitting GARCH(1,1) via maximum likelihood...")
@time garch = garch11_fit(r_be)

# ─ Monte Carlo GBM ────────────────────────────────────────────
print("  Running Monte Carlo (10K paths, 1 year)...")
@time mc_paths = gbm_monte_carlo(prices[end], stats.annual_return,
                                  stats.annual_vol, 252, 10_000)
mc_final   = mc_paths[end, :]
prob_profit = count(mc_final .> prices[end]) / 10_000 * 100
mc_p5  = quantile(mc_final, 0.05)
mc_p50 = quantile(mc_final, 0.50)
mc_p95 = quantile(mc_final, 0.95)

# ─ Black-Scholes ──────────────────────────────────────────────
S0    = prices[end]
K_atm = round(S0, digits=0)
bs_call = black_scholes(S0, K_atm, RF_ANNUAL, stats.annual_vol, 0.25; type=:call)
bs_put  = black_scholes(S0, K_atm, RF_ANNUAL, stats.annual_vol, 0.25; type=:put)

# ─ Market analysis (Beta/Alpha) ───────────────────────────────
mkt = market_analysis(r_be_a, r_spy)

# ─ JuMP: optimal 2-asset portfolio (TICKER + SPY hedge) ──────
μ2 = [stats.annual_return, mean(r_spy)*252]
Σ2 = cov(hcat(r_be_a, r_spy)) .* 252
opt_port = optimize_two_asset(μ2, Σ2)

# ─ Signal engine ──────────────────────────────────────────────
sig = generate_signal(prices, r_be, rsi_v[end], macd_l[end], macd_s[end],
                      bb_mid[end], bb_up[end], bb_lo[end],
                      sh, H, mkt, mdd.value)

# ══════════════════════════════════════════════════════════════
#  PRINT FULL REPORT
# ══════════════════════════════════════════════════════════════

println("\n" * "═" ^ 64)
println("  ① RETURN STATISTICS")
println("─" ^ 64)
@printf("  Annual Return:        %+.2f%%\n",    stats.annual_return*100)
@printf("  Annual Volatility:    %.2f%%\n",     stats.annual_vol*100)
@printf("  Daily Mean Return:    %+.4f%%\n",    stats.daily_mean*100)
@printf("  Skewness:             %+.4f  %s\n",  stats.skewness,
    stats.skewness < -0.5 ? "(left tail — crash risk)" :
    stats.skewness >  0.5 ? "(right tail — positive surprises)" : "(near symmetric)")
@printf("  Excess Kurtosis:      %+.4f  %s\n",  stats.excess_kurtosis,
    stats.excess_kurtosis > 1 ? "(fat tails — extreme moves likely)" : "(normal tails)")
@printf("  Best Day:             %+.2f%%\n",    stats.max_ret*100)
@printf("  Worst Day:            %+.2f%%\n",    stats.min_ret*100)

println("\n" * "─" ^ 64)
println("  ② JARQUE-BERA NORMALITY TEST")
println("─" ^ 64)
@printf("  JB Statistic:         %.2f\n",       jb.stat)
@printf("  p-value:              %.6f\n",        jb.p_value)
@printf("  Result:               %s\n",
    jb.is_normal ? "FAIL TO REJECT H₀ — returns ≈ normal" :
                   "REJECT H₀ — returns are NOT normally distributed")
println("  (Implication: parametric VaR underestimates true tail risk)")

println("\n" * "─" ^ 64)
println("  ③ RISK METRICS")
println("─" ^ 64)
@printf("  Sharpe Ratio:         %.4f  %s\n",   sh,
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
@printf("  ω (long-run base):    %.2e\n",        garch.ω)
@printf("  α (shock sensitivity): %.4f\n",        garch.α)
@printf("  β (vol persistence):  %.4f\n",         garch.β)
@printf("  Persistence (α+β):    %.4f  %s\n",     garch.persistence,
    garch.persistence > 0.97 ? "(very high — shocks decay slowly)" :
    garch.persistence > 0.90 ? "(high — volatile clustering)" : "(moderate)")
@printf("  Forecasted σ (daily): %.4f%%\n",        garch.σ_daily_forecast*100)
@printf("  Forecasted σ (annual):%.2f%%\n",         garch.σ_annual_forecast*100)
@printf("  Long-run Vol:         %.2f%%\n",         garch.long_run_vol*100)

println("\n" * "─" ^ 64)
println("  ⑤ MONTE CARLO SIMULATION (10,000 paths, 1 year)")
println("─" ^ 64)
@printf("  Current Price:       \$%.2f\n",         prices[end])
@printf("  Bear Case  (5th %%):  \$%.2f  (%+.1f%%)\n", mc_p5,
    (mc_p5/prices[end]-1)*100)
@printf("  Base Case  (50th %%): \$%.2f  (%+.1f%%)\n", mc_p50,
    (mc_p50/prices[end]-1)*100)
@printf("  Bull Case  (95th %%): \$%.2f  (%+.1f%%)\n", mc_p95,
    (mc_p95/prices[end]-1)*100)
@printf("  Prob. of Profit:     %.1f%%\n",           prob_profit)

println("\n" * "─" ^ 64)
println("  ⑥ BLACK-SCHOLES — ATM OPTIONS (3-Month Expiry)")
println("─" ^ 64)
@printf("  Underlying:          \$%.2f   Strike: \$%.0f\n", S0, K_atm)
@printf("  Implied Vol (hist):   %.1f%%\n",              stats.annual_vol*100)
@printf("  Call Price:          \$%.4f   Put Price: \$%.4f\n",
    bs_call.price, bs_put.price)
@printf("  Call Delta: %+.4f   Put Delta: %+.4f\n",
    bs_call.delta, bs_put.delta)
@printf("  Gamma:       %.6f  (rate of delta change)\n",   bs_call.gamma)
@printf("  Theta:      %+.4f  (\$/day time decay)\n",      bs_call.theta)
@printf("  Vega:        %.4f  (\$ per 1%% vol change)\n",   bs_call.vega)

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
@printf("  Tracking Error:       %.2f%%\n",    mkt.tracking_error*100)
@printf("  Information Ratio:   %+.4f\n",       mkt.info_ratio)

println("\n" * "─" ^ 64)
println("  ⑧ JuMP PORTFOLIO OPTIMIZATION ($TICKER + SPY hedge)")
println("─" ^ 64)
@printf("  Optimal %-4s weight:  %.1f%%\n",  TICKER, opt_port.weights[1]*100)
@printf("  Optimal SPY weight:  %.1f%%\n",   opt_port.weights[2]*100)
@printf("  Portfolio Return:    %+.2f%%\n",  opt_port.annual_return*100)
@printf("  Portfolio Vol:        %.2f%%\n",   opt_port.annual_vol*100)
@printf("  Portfolio Sharpe:     %.4f\n",     opt_port.sharpe)
@printf("  Pure %-4s Sharpe:     %.4f  (improvement: %+.4f)\n", TICKER,
    sh, opt_port.sharpe - sh)

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

println("\n" * "═" ^ 64)
println("  ⭐  COMPOSITE SIGNAL — FINAL VERDICT")
println("═" ^ 64)
println()
@printf("  VERDICT:  %s\n",    sig.verdict)
@printf("  Score:    %+.4f  (confidence: %.1f%%)\n", sig.score, sig.confidence)
println()
println("  Signal Breakdown:")
ordered_sigs = sort(collect(sig.signals), by=x->-abs(x[2]))
for (k, v) in ordered_sigs
    w    = get(sig.weights, k, 0.0)
    bar  = v > 0 ? "█"^Int(round(v*10)) * " +" : "░"^Int(round(abs(v)*10)) * " -"
    @printf("  %-12s  w=%.2f  score=%+.2f  %s\n", k, w, v, bar)
end
println()
println("═" ^ 64)
println()

# ══════════════════════════════════════════════════════════════
#  DASHBOARD 1 — TECHNICAL ANALYSIS
# ══════════════════════════════════════════════════════════════

println("  Generating charts...")
t_axis = 1:n

# Panel 1: Price + MAs + Bollinger
p1 = plot(t_axis, prices, color=:white, linewidth=1.5, label="$TICKER Price",
    title="$TICKER — Price & Moving Averages",
    xlabel="", ylabel="Price (\$)", background_color=:black,
    foreground_color=:white, legend=:topleft, legendfontsize=7,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=2Plots.mm)
plot!(p1, t_axis, sma20_v,  color=:yellow,  linewidth=1, label="SMA20",  linestyle=:solid)
plot!(p1, t_axis, sma50_v,  color=:orange,  linewidth=1, label="SMA50",  linestyle=:solid)
plot!(p1, t_axis, sma200_v, color=:red,     linewidth=1.5, label="SMA200", linestyle=:solid)
plot!(p1, t_axis, bb_up,    color=:cyan,    linewidth=0.8, label="BB Upper", linestyle=:dash)
plot!(p1, t_axis, bb_lo,    color=:cyan,    linewidth=0.8, label="BB Lower", linestyle=:dash)

# Panel 2: Volume
bar_colors_v = [r_be[i] >= 0 ? :green : :red for i in eachindex(r_be)]
p2 = bar(2:n, be.volume[2:n] ./ 1e6,
    color=bar_colors_v, linecolor=:transparent, alpha=0.7,
    title="Volume (M shares)", xlabel="", ylabel="Volume (M)",
    background_color=:black, foreground_color=:white, legend=false,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=2Plots.mm)

# Panel 3: RSI
p3 = plot(t_axis, rsi_v, color=:purple, linewidth=1.5,
    title="RSI (14)", xlabel="", ylabel="RSI",
    ylims=(0, 100), background_color=:black, foreground_color=:white, legend=false,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=2Plots.mm)
hline!(p3, [70], color=:red,   linestyle=:dash, linewidth=1)
hline!(p3, [30], color=:green, linestyle=:dash, linewidth=1)
hline!(p3, [50], color=:gray,  linestyle=:dot,  linewidth=0.5)

# Panel 4: MACD
p4 = plot(t_axis, macd_l, color=:cyan, linewidth=1.2, label="MACD",
    title="MACD (12/26/9)", xlabel="Day", ylabel="Value",
    background_color=:black, foreground_color=:white, legend=:topleft, legendfontsize=7,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=5Plots.mm)
plot!(p4, t_axis, macd_s, color=:orange, linewidth=1.2, label="Signal")
hist_colors = [macd_h[i] >= 0 ? :green : :red for i in 1:n]
bar!(p4, t_axis, macd_h, color=hist_colors, linecolor=:transparent,
    alpha=0.5, label="Hist")
hline!(p4, [0], color=:white, linestyle=:dot, linewidth=0.5, label="")

dash1 = plot(p1, p2, p3, p4, layout=(4,1), size=(1400, 1200))
savefig(dash1, "C:/Users/yturb/$(TICKER)_technical_analysis.png")

# ══════════════════════════════════════════════════════════════
#  DASHBOARD 2 — QUANTITATIVE MODELS
# ══════════════════════════════════════════════════════════════

# Panel 5: Monte Carlo paths
n_mc_show = min(200, size(mc_paths,2))
mc_t = 0:252
q05  = [quantile(mc_paths[t+1,:], 0.05) for t in 0:252]
q25  = [quantile(mc_paths[t+1,:], 0.25) for t in 0:252]
q50  = [quantile(mc_paths[t+1,:], 0.50) for t in 0:252]
q75  = [quantile(mc_paths[t+1,:], 0.75) for t in 0:252]
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

# Panel 6: Return distribution
p6 = histogram(r_be, bins=80, normalize=:pdf,
    color=:steelblue, alpha=0.7, label="Daily Returns",
    title="Return Distribution vs Normal Fit",
    xlabel="Log Return", ylabel="Density",
    background_color=:black, foreground_color=:white, legend=:topleft, legendfontsize=7,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=5Plots.mm)
xs_norm = range(minimum(r_be), maximum(r_be), length=200)
μ_r, σ_r = mean(r_be), std(r_be)
ys_norm = @. exp(-0.5*((xs_norm-μ_r)/σ_r)^2) / (σ_r*sqrt(2π))
plot!(p6, xs_norm, ys_norm, color=:yellow, linewidth=2, label="Normal fit")
vline!(p6, [-var_h], color=:red,    linestyle=:dash, linewidth=2, label="VaR 95%")
vline!(p6, [-cvar_v],color=:orange, linestyle=:dash, linewidth=2, label="CVaR 95%")

# Panel 7: GARCH conditional volatility
garch_ann = garch.σ_series .* sqrt(252) .* 100
p7 = plot(2:length(garch_ann)+1, garch_ann, color=:orange, linewidth=1.2,
    fill=(0, 0.15, :orange),
    title="GARCH(1,1) — Conditional Volatility",
    xlabel="Day", ylabel="Ann. Volatility (%)",
    background_color=:black, foreground_color=:white, legend=false,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=5Plots.mm)
hline!(p7, [garch.long_run_vol*100], color=:cyan, linestyle=:dash, linewidth=1.5)
hline!(p7, [stats.annual_vol*100],   color=:white, linestyle=:dot,  linewidth=1)

# Panel 8: BE vs SPY cumulative returns
n_cmp = min(length(r_be_a), length(r_spy))
cum_be  = cumprod(1 .+ r_be_a[end-n_cmp+1:end]) .- 1
cum_spy = cumprod(1 .+ r_spy[end-n_cmp+1:end]) .- 1
p8 = plot(cum_be  .* 100, color=:cyan,  linewidth=2, label=TICKER,
    title="Cumulative Return: $TICKER vs $BENCHMARK",
    xlabel="Day", ylabel="Cumulative Return (%)",
    background_color=:black, foreground_color=:white, legend=:topleft, legendfontsize=8,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=5Plots.mm)
plot!(p8, cum_spy .* 100, color=:orange, linewidth=2, label=BENCHMARK)
hline!(p8, [0], color=:white, linestyle=:dot, linewidth=0.5, label="")

# Panel 9: Rolling Sharpe ratio
p9 = plot(roll_sh, color=:lime, linewidth=1.2,
    fill=(0, 0.1, :lime),
    title="Rolling Sharpe Ratio (63-day / 1 quarter)",
    xlabel="Day", ylabel="Sharpe",
    background_color=:black, foreground_color=:white, legend=false,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=5Plots.mm)
hline!(p9, [0],   color=:white, linestyle=:dot,  linewidth=0.5)
hline!(p9, [1],   color=:green, linestyle=:dash, linewidth=1)
hline!(p9, [-1],  color=:red,   linestyle=:dash, linewidth=1)

# Panel 10: Drawdown underwater chart
p10 = plot(dd_ser .* -100, color=:red, linewidth=1, fill=(0, 0.3, :red),
    title="Drawdown (Underwater Chart)",
    xlabel="Day", ylabel="Drawdown (%)",
    background_color=:black, foreground_color=:white, legend=false,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=5Plots.mm)

# Panel 11: Black-Scholes option surface (call prices at various strikes/maturities)
strikes   = S0 .* (0.70:0.05:1.30)
maturities = [1/12, 3/12, 6/12, 1.0]
call_matrix = [black_scholes(S0, K, RF_ANNUAL, stats.annual_vol, T; type=:call).price
               for K in strikes, T in maturities]
p11 = plot(strikes, call_matrix,
    label=["1M" "3M" "6M" "12M"],
    linewidth=2, xlabel="Strike (\$)", ylabel="Call Price (\$)",
    title="Black-Scholes Call Prices by Maturity",
    background_color=:black, foreground_color=:white,
    legend=:topright, legendfontsize=7,
    titlefontsize=11, left_margin=5Plots.mm, bottom_margin=5Plots.mm)
vline!(p11, [S0], color=:white, linestyle=:dash, linewidth=1, label="ATM")

# Panel 12: Signal scorecard
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
hline!(p12, [0],   color=:white, linestyle=:dot, linewidth=1)
hline!(p12, [0.25, -0.25], color=:gray, linestyle=:dash, linewidth=0.8)

dash2 = plot(p5, p6, p7, p8, p9, p10, p11, p12,
    layout=(4, 2), size=(1600, 1800))
savefig(dash2, "C:/Users/yturb/$(TICKER)_quant_models.png")

println("  $(TICKER)_technical_analysis.png  →  C:/Users/yturb/")
println("  $(TICKER)_quant_models.png        →  C:/Users/yturb/")
println()
println("  Analysis complete.")
println("═" ^ 64)
