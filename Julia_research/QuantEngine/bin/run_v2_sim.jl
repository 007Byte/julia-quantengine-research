#!/usr/bin/env julia
#
# V2 Strategy — 5-model composite on hourly BTC with regime gating + leverage
# Based on research findings:
# - XGBoost + RF + AR(1) regime + GARCH vol + Logistic continuation
# - AR(1) gates the signal: momentum regime = follow trees, mean-reversion = fade
# - GARCH sets TP/SL from volatility forecast
# - 500+ hourly bars lookback (21+ days)
# - 3x leverage (Binance futures)

push!(LOAD_PATH, joinpath(@__DIR__, ".."))
println("Loading QuantEngine...")
flush(stdout)
using QuantEngine
using Dates, Printf, Statistics, HTTP, JSON
println("Loaded.\n")

function fetch_hourly(symbol::String; bars::Int=1500)
    all_c, all_h, all_l, all_v = Float64[], Float64[], Float64[], Float64[]
    all_t = DateTime[]
    et = round(Int, time() * 1000)
    while length(all_c) < bars
        lim = min(1000, bars - length(all_c))
        url = "https://api.binance.us/api/v3/klines?symbol=$symbol&interval=1h&limit=$lim&endTime=$et"
        data = JSON.parse(String(HTTP.get(url; readtimeout=30).body))
        isempty(data) && break
        for c in data
            pushfirst!(all_t, unix2datetime(c[1]/1000))
            pushfirst!(all_h, parse(Float64, c[3]))
            pushfirst!(all_l, parse(Float64, c[4]))
            pushfirst!(all_c, parse(Float64, c[5]))
            pushfirst!(all_v, parse(Float64, c[6]))
        end
        et = round(Int, data[1][1]) - 1
        length(data) < lim && break
    end
    (t=all_t, c=all_c, h=all_h, l=all_l, v=all_v)
end

function run_v2(;
    capital=100_000.0, sim_hours=720, leverage=3.0,
    lookback=500, signal_interval=4,
    min_signal=0.57, size_pct=0.45,
    base_stop_pct=1.5, max_hold=36,
    cost_bps=8.0, funding_bps_day=1.0,
    verbose=true)

    d = fetch_hourly("BTCUSDT"; bars=sim_hours + lookback + 50)
    prices, highs, lows, volumes = d.c, d.h, d.l, d.v
    n = length(prices)
    rets = diff(log.(prices))
    sim_start = n - sim_hours

    eff_size = size_pct * leverage
    println("═" ^ 60)
    @printf("  V2 STRATEGY — BTC %dx LEVERAGED HOURLY\n", round(Int, leverage))
    @printf("  Capital: \$%d | %d hours | %d-bar lookback\n",
            round(Int, capital), sim_hours, lookback)
    @printf("  Signal every %dh | Min p=%.2f | Eff size=%.0f%%\n",
            signal_interval, min_signal, eff_size*100)
    println("  5-model composite: XGB + RF + AR(1) regime + GARCH vol + Logistic")
    println("═" ^ 60)

    eq = capital
    pos = nothing
    trades = NamedTuple[]
    eq_curve = Float64[eq]

    for bi in sim_start:n-1
        bn = bi - sim_start + 1
        cp = prices[bi+1]
        ct = bi+1 <= length(d.t) ? d.t[bi+1] : d.t[end]

        # ── Exit ──
        if pos !== nothing
            dir, ep, notional, margin, eb, vol_forecast = pos
            pp = dir == :long ? (cp/ep-1)*100 : (1-cp/ep)*100
            bars = bn - eb
            # Dynamic stop: tighter when vol is low, wider when high
            dyn_stop = base_stop_pct * max(vol_forecast / 0.03, 0.5)
            dyn_stop = clamp(dyn_stop, base_stop_pct * 0.5, base_stop_pct * 2.0)
            fc = notional * funding_bps_day / 10000 * (bars / 24)

            ex = nothing
            if pp <= -dyn_stop
                ex = :stop
            elseif pp >= dyn_stop * 2.0  # 2:1 reward/risk
                ex = :target
            elseif bars >= max_hold
                ex = :time
            end

            if ex !== nothing
                gpnl = notional * pp / 100
                cost = notional * cost_bps / 10000
                npnl = gpnl - cost - fc
                eq += npnl
                push!(trades, (bar=bn, time=ct, dir=dir, entry=ep, exit=cp,
                    notional=notional, pnl_pct=pp, lev_pnl=pp*leverage,
                    net_pnl=npnl, hours=bars, reason=ex, vol=vol_forecast))
                verbose && @printf("  %s %5s EXIT  %6.0f→%6.0f %+5.1f%% (lev:%+5.1f%%) %+6.0f %s Eq=%.0f\n",
                    Dates.format(ct, "mm-dd HH:MM"), uppercase(string(dir)),
                    ep, cp, pp, pp*leverage, npnl, ex, eq)
                pos = nothing
            end
        end

        # ── Signal every N hours ──
        if pos === nothing && bn % signal_interval == 0 && bi >= lookback + 5
            tr_e = bi
            tr_s = max(1, tr_e - lookback)

            p_sl = prices[tr_s:tr_e+1]
            r_sl = rets[tr_s:min(tr_e, length(rets))]
            v_sl = volumes[tr_s:tr_e+1]
            h_sl = highs[tr_s:tr_e+1]
            l_sl = lows[tr_s:tr_e+1]

            length(r_sl) < 60 && continue

            # Feature matrix
            X_all, y_all = try
                x, y, _, _ = QuantEngine.compute_features(p_sl, r_sl, v_sl; high=h_sl, low=l_sl)
                (x, y)
            catch; continue; end

            size(X_all, 1) < 60 && continue
            sp = max(1, round(Int, size(X_all,1)*0.8))
            X_tr, y_tr = X_all[1:sp,:], y_all[1:sp]
            X_te, y_te = X_all[sp+1:end,:], y_all[sp+1:end]
            size(X_te, 1) < 5 && continue

            # ── 5-model composite ──
            probs = Float64[]
            dirs = Symbol[]

            # 1. XGBoost
            r7 = try QuantEngine.run_xgboost(X_tr, y_tr, X_te, y_te, r_sl, :crypto) catch; nothing end
            if r7 !== nothing && hasproperty(r7, :probability) && 0 < r7.probability < 1
                push!(probs, r7.probability)
                push!(dirs, r7.probability > 0.5 ? :up : :down)
            end

            # 2. Random Forest
            r5 = try QuantEngine.run_random_forest(X_tr, y_tr, X_te, y_te) catch; nothing end
            if r5 !== nothing && hasproperty(r5, :probability) && 0 < r5.probability < 1
                push!(probs, r5.probability)
                push!(dirs, r5.probability > 0.5 ? :up : :down)
            end

            # 3. AR(1) regime filter
            ar1 = try QuantEngine.run_ar1(r_sl) catch; nothing end
            regime = :unknown
            if ar1 !== nothing && hasproperty(ar1, :regime)
                regime = ar1.regime
                if hasproperty(ar1, :probability) && 0 < ar1.probability < 1
                    push!(probs, ar1.probability)
                end
            end

            # 4. GARCH volatility
            garch = try QuantEngine.run_garch_egarch(r_sl; vol_data=v_sl) catch; nothing end
            vol_forecast = 0.03  # default 3% daily
            if garch !== nothing && hasproperty(garch, :σ_annual_forecast)
                vol_forecast = garch.σ_annual_forecast / sqrt(8760)  # hourly vol
            end

            # 5. Logistic continuation
            log22 = try QuantEngine.run_logistic_regression(r_sl, p_sl[2:end], v_sl[2:end]) catch; nothing end
            if log22 !== nothing && hasproperty(log22, :probability) && 0 < log22.probability < 1
                push!(probs, log22.probability)
            end

            length(probs) < 2 && continue
            # Use MAX of tree models (best conviction) not average
            tree_probs = Float64[]
            r7 !== nothing && hasproperty(r7, :probability) && push!(tree_probs, r7.probability)
            r5 !== nothing && hasproperty(r5, :probability) && push!(tree_probs, r5.probability)
            best_tree_p = isempty(tree_probs) ? 0.5 : maximum(tree_probs)
            avg_p = mean(probs)  # still use for general direction

            # Regime from AR(1) — string matching
            regime_str = string(regime)
            is_momentum = occursin("MOMENTUM", regime_str)
            is_meanrev = occursin("MEAN", regime_str) && occursin("REVERSION", regime_str)

            ma50 = mean(prices[max(1,bi-48):bi+1])
            ma100 = bi >= 100 ? mean(prices[max(1,bi-98):bi+1]) : cp
            trend_up = ma50 > ma100
            trend_down = ma50 < ma100

            sig = nothing

            # Use best_tree_p for threshold (strongest model's conviction)
            if best_tree_p >= min_signal && trend_up
                sig = :long
            elseif best_tree_p <= (1-min_signal) && trend_down
                sig = :short
            # Also: if mean-reversion regime + oversold in uptrend = buy dip
            elseif is_meanrev && avg_p < 0.45 && trend_up
                sig = :long
            elseif is_meanrev && avg_p > 0.55 && trend_down
                sig = :short
            end

            if sig !== nothing
                conv = abs(avg_p - 0.5) * 2
                sf = clamp(size_pct * max(conv, 0.4), 0.20, size_pct)
                margin = eq * sf
                notional = margin * leverage
                ep = sig == :long ? cp * (1 + cost_bps/20000) : cp * (1 - cost_bps/20000)
                pos = (sig, ep, notional, margin, bn, vol_forecast)

                verbose && @printf("  %s %5s ENTER %6.0f margin=%.0f notional=%.0f p=%.3f regime=%s\n",
                    Dates.format(ct, "mm-dd HH:MM"), uppercase(string(sig)),
                    ep, margin, notional, avg_p, regime)
            end
        end

        push!(eq_curve, eq)
    end

    # Close open
    if pos !== nothing
        dir, ep, notional, margin, eb, vf = pos
        fp = prices[end]
        pp = dir == :long ? (fp/ep-1)*100 : (1-fp/ep)*100
        bars = length(eq_curve) - eb
        fc = notional * funding_bps_day / 10000 * (bars/24)
        npnl = notional * pp / 100 - notional * cost_bps / 10000 - fc
        eq += npnl
        push!(trades, (bar=sim_hours, time=d.t[end], dir=dir, entry=ep, exit=fp,
            notional=notional, pnl_pct=pp, lev_pnl=pp*leverage,
            net_pnl=npnl, hours=bars, reason=:end_sim, vol=vf))
        push!(eq_curve, eq)
    end

    # Results
    nt = length(trades)
    wins = filter(t -> t.net_pnl > 0, trades)
    losses = filter(t -> t.net_pnl <= 0, trades)
    wr = nt > 0 ? length(wins)/nt*100 : 0
    tr = (eq/capital-1)*100
    gp = isempty(wins) ? 0.0 : sum(t.net_pnl for t in wins)
    gl = isempty(losses) ? 1e-8 : abs(sum(t.net_pnl for t in losses))
    pf = gp / gl
    mdd = 0.0; pk = eq_curve[1]
    for e in eq_curve; pk=max(pk,e); mdd=max(mdd,(pk-e)/pk); end
    bh = (prices[end]/prices[sim_start]-1)*100
    monthly = tr / (sim_hours / 720)

    println()
    println("═" ^ 60)
    @printf("  V2 RESULTS — BTC %dx\n", round(Int, leverage))
    println("─" ^ 60)
    @printf("  \$%d → \$%.0f  (%+.2f%%)\n", round(Int,capital), eq, tr)
    @printf("  Monthly: %+.2f%%\n", monthly)
    @printf("  Trades: %d  WR: %.1f%%  PF: %.2f  MaxDD: %.2f%%\n", nt, wr, pf, mdd*100)
    @printf("  B&H: %+.2f%%  Alpha: %+.2f%%\n", bh, tr-bh)
    monthly >= 10.0 ? println("  ★ TARGET 10%/month HIT") :
        @printf("  Target: %.1f%% short\n", 10-monthly)
    println("═" ^ 60)

    return (eq=eq, tr=tr, monthly=monthly, wr=wr, pf=pf, nt=nt, mdd=mdd*100, trades=trades)
end

# ── Sweep ──
println("╔═════════════════════════════════════════════════════╗")
println("║  V2 STRATEGY — 5-MODEL COMPOSITE + REGIME GATING   ║")
println("╚═════════════════════════════════════════════════════╝\n")

configs = [
    (3.0, 0.57, 0.45, 1.5, 36, 4, "3x-balanced"),
    (3.0, 0.55, 0.50, 1.2, 24, 4, "3x-active"),
    (4.0, 0.57, 0.45, 1.5, 36, 4, "4x-balanced"),
    (4.0, 0.55, 0.50, 1.2, 24, 4, "4x-active"),
    (5.0, 0.55, 0.50, 1.5, 24, 4, "5x-active"),
    (3.0, 0.55, 0.50, 1.5, 48, 6, "3x-swing"),
    (5.0, 0.54, 0.45, 1.0, 18, 3, "5x-scalp"),
]

best_m = -Inf
for (lev, sig, sz, stop, hold, interval, label) in configs
    @printf("▸ %s (lev=%dx sig=%.2f sz=%.0f%% stop=%.1f%% hold=%dh)\n",
            label, round(Int,lev), sig, sz*100, stop, hold)
    r = run_v2(; leverage=lev, min_signal=sig, size_pct=sz,
        base_stop_pct=stop, max_hold=hold, signal_interval=interval,
        sim_hours=720, verbose=false)
    @printf("  → %+.2f%%/mo  WR:%.1f%%  PF:%.2f  Trades:%d  DD:%.1f%%\n\n",
            r.monthly, r.wr, r.pf, r.nt, r.mdd)
    if r.monthly > best_m
        global best_m = r.monthly
        global best_label = label
    end
    r.monthly >= 10 && (println("  ★ TARGET HIT"); break)
end

@printf("\nBest: %s → %+.2f%%/month\n", best_label, best_m)

# Run best verbose
println("\n\n▶ Running best config verbose:\n")
# Re-run the best one... for now just report
