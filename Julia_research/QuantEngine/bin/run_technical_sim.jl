#!/usr/bin/env julia
#
# Technical Strategy Sim — RSI + Bollinger + Z-Score + MACD on hourly BTC
# No ML models. Pure technical signals. Faster, more trades, proven indicators.
# Target: 10% per month.

push!(LOAD_PATH, joinpath(@__DIR__, ".."))
println("Loading QuantEngine...")
flush(stdout)
t0 = time()
using QuantEngine
using Dates, Printf, Statistics, HTTP, JSON
println("Loaded in $(round(time()-t0, digits=1))s\n")

function fetch_hourly(symbol::String; days::Int=90)
    all_c, all_h, all_l, all_v, all_t = Float64[], Float64[], Float64[], Float64[], DateTime[]
    et = round(Int, time() * 1000)
    needed = days * 24
    while length(all_c) < needed
        lim = min(1000, needed - length(all_c))
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
    return (t=all_t, c=all_c, h=all_h, l=all_l, v=all_v)
end

function run_technical(;
    symbol="BTCUSDT", capital=100_000.0, sim_hours=720,
    rsi_period=2, rsi_buy=15.0, rsi_sell=85.0,
    bb_period=20, bb_std=2.0,
    zscore_period=20, zscore_threshold=1.8,
    require_consensus=2,  # min indicators agreeing
    size_pct=0.40,
    stop_pct=1.5,
    tp_pct=3.0,
    max_hold=18,
    cost_bps=11.0,
    verbose=true)

    d = fetch_hourly(symbol; days=div(sim_hours, 24) + 30)
    prices, volumes = d.c, d.v
    n = length(prices)
    println("═" ^ 60)
    @printf("  TECHNICAL SIM — %s (%d hours)\n", symbol, sim_hours)
    println("  RSI(%d) buy<%.0f sell>%.0f | BB(%d,%.1f) | Z(%d,%.1f)", rsi_period, rsi_buy, rsi_sell, bb_period, bb_std, zscore_period, zscore_threshold)
    println("  Size=$(size_pct*100)% | Stop=$(stop_pct)% | TP=$(tp_pct)% | Hold=$(max_hold)h | Consensus≥$(require_consensus)")
    println("═" ^ 60)

    eq = capital
    pos = nothing
    trades = NamedTuple[]
    eq_curve = Float64[eq]
    sim_start = n - sim_hours

    for bi in sim_start:n-1
        bn = bi - sim_start + 1
        cp = prices[bi+1]
        ct = bi+1 <= length(d.t) ? d.t[bi+1] : d.t[end]

        # ── Exit logic ──
        if pos !== nothing
            dir, ep, sz, eb = pos
            pp = dir == :long ? (cp/ep-1)*100 : (1-cp/ep)*100
            bars = bn - eb
            ex = nothing

            if pp <= -stop_pct
                ex = :stop
            elseif pp >= tp_pct
                ex = :tp
            elseif bars >= max_hold
                ex = :time
            end

            if ex !== nothing
                cost = sz * cost_bps / 10000
                tpnl = sz * pp / 100 - cost
                eq += tpnl
                push!(trades, (bar=bn, time=ct, dir=dir, entry=ep, exit=cp,
                    size=sz, pnl=tpnl, pnl_pct=pp, hours=bars, reason=ex))
                verbose && @printf("  %s EXIT  %-5s %.0f→%.0f %+.1f%% %+.0f %s Eq=%.0f\n",
                    Dates.format(ct, "mm-dd HH:MM"), uppercase(string(dir)),
                    ep, cp, pp, tpnl, ex, eq)
                pos = nothing
            end
        end

        # ── Signal generation (every 2 hours) ──
        if pos === nothing && bn % 2 == 0 && bi >= bb_period + 5
            p_slice = prices[max(1,bi-bb_period-10):bi+1]
            v_slice = volumes[max(1,bi-bb_period-10):bi+1]

            buy_votes = 0
            sell_votes = 0

            # RSI(2)
            rsi = QuantEngine.compute_rsi(p_slice, rsi_period)
            rv = rsi[end]
            if rv < rsi_buy; buy_votes += 1; end
            if rv > rsi_sell; sell_votes += 1; end

            # Bollinger Bands
            bb = QuantEngine.bollinger_bands(p_slice; period=bb_period, num_std=bb_std)
            if !isnan(bb.pct_b[end])
                if bb.pct_b[end] < 0.05; buy_votes += 1; end
                if bb.pct_b[end] > 0.95; sell_votes += 1; end
            end

            # Z-score
            zs = QuantEngine.zscore_reversion(p_slice; lookback=zscore_period)
            zv = zs[end]
            if zv < -zscore_threshold; buy_votes += 1; end
            if zv > zscore_threshold; sell_votes += 1; end

            # Volume spike confirmation
            if length(v_slice) >= 10
                vr = v_slice[end] / max(mean(v_slice[end-9:end-1]), 1)
                hr_ret = (cp - prices[bi]) / prices[bi] * 100
                if vr > 1.5 && hr_ret < -1.0; buy_votes += 1; end
                if vr > 1.5 && hr_ret > 1.0; sell_votes += 1; end
            end

            # Macro trend: 100-bar (4-day) and 50-bar (2-day) MAs
            ma50 = bi >= 50 ? mean(prices[bi-48:bi+1]) : cp
            ma100 = bi >= 100 ? mean(prices[bi-98:bi+1]) : cp
            macro_up = ma50 > ma100
            macro_down = ma50 < ma100

            sig = nothing
            # Mean reversion WITH trend: buy oversold in uptrend, sell overbought in downtrend
            if buy_votes >= require_consensus && macro_up
                sig = :long
            elseif sell_votes >= require_consensus && macro_down
                sig = :short
            end

            if sig !== nothing
                sz = eq * size_pct
                ep = sig == :long ? cp * (1 + cost_bps/20000) : cp * (1 - cost_bps/20000)
                pos = (sig, ep, sz, bn)
                verbose && @printf("  %s ENTER %-5s %.0f size=%.0f votes=%d\n",
                    Dates.format(ct, "mm-dd HH:MM"), uppercase(string(sig)),
                    ep, sz, sig == :long ? buy_votes : sell_votes)
            end
        end

        push!(eq_curve, eq)
    end

    # Close open
    if pos !== nothing
        dir, ep, sz, eb = pos
        fp = prices[end]
        pp = dir == :long ? (fp/ep-1)*100 : (1-fp/ep)*100
        tpnl = sz * pp / 100 - sz * cost_bps / 10000
        eq += tpnl
        push!(trades, (bar=sim_hours, time=d.t[end], dir=dir, entry=ep, exit=fp,
            size=sz, pnl=tpnl, pnl_pct=pp, hours=sim_hours-(pos[4]), reason=:end_sim))
        push!(eq_curve, eq)
    end

    # Results
    nt = length(trades)
    wins = filter(t -> t.pnl > 0, trades)
    losses = filter(t -> t.pnl <= 0, trades)
    wr = nt > 0 ? length(wins)/nt*100 : 0
    tr = (eq/capital-1)*100
    gp = isempty(wins) ? 0.0 : sum(t.pnl for t in wins)
    gl = isempty(losses) ? 1e-8 : abs(sum(t.pnl for t in losses))
    pf = gp / gl
    aw = isempty(wins) ? 0.0 : mean(t.pnl_pct for t in wins)
    al = isempty(losses) ? 0.0 : mean(t.pnl_pct for t in losses)
    mdd = 0.0; pk = eq_curve[1]
    for e in eq_curve; pk=max(pk,e); mdd=max(mdd,(pk-e)/pk); end
    bh = (prices[end]/prices[sim_start]-1)*100
    monthly = tr / (sim_hours / 720)

    println()
    println("═" ^ 60)
    @printf("  RESULTS — %s\n", symbol)
    println("─" ^ 60)
    @printf("  %.0f → %.0f (%+.2f%%)\n", capital, eq, tr)
    @printf("  Monthly: %+.2f%%/month\n", monthly)
    @printf("  Trades: %d  WR: %.1f%%  PF: %.2f\n", nt, wr, pf)
    @printf("  AvgWin: %+.2f%%  AvgLoss: %.2f%%\n", aw, al)
    @printf("  MaxDD: %.2f%%  B&H: %+.2f%%  Alpha: %+.2f%%\n", mdd*100, bh, tr-bh)
    if monthly >= 10.0
        println("  ★ TARGET 10%/month: HIT ✓")
    else
        @printf("  TARGET 10%%/month: MISS (%.1f%% short)\n", 10.0-monthly)
    end
    println("═" ^ 60)

    return (eq=eq, tr=tr, monthly=monthly, wr=wr, pf=pf, nt=nt, mdd=mdd*100, aw=aw, al=al, bh=bh)
end

# ── Parameter sweep ───────────────────────────────────────────

println("╔════════════════════════════════════════════════════╗")
println("║  TECHNICAL STRATEGY PARAMETER SWEEP                ║")
println("║  Target: 10%/month on BTC hourly                   ║")
println("╚════════════════════════════════════════════════════╝\n")

best = nothing
best_monthly = -Inf

configs = [
    # rsi_buy, rsi_sell, consensus, size, stop, tp, hold, label
    (15, 85, 2, 0.40, 1.5, 3.0, 18, "balanced"),
    (10, 90, 2, 0.50, 1.0, 2.5, 12, "tight-extreme"),
    (20, 80, 2, 0.45, 2.0, 4.0, 24, "wider"),
    (15, 85, 1, 0.50, 1.5, 3.0, 18, "single-indicator"),
    (10, 90, 2, 0.55, 1.2, 3.5, 18, "concentrated-extreme"),
    (20, 80, 1, 0.40, 1.0, 2.0, 8, "fast-scalp"),
    (15, 85, 2, 0.50, 2.0, 5.0, 36, "big-swing"),
    (12, 88, 2, 0.45, 1.5, 3.0, 18, "tuned"),
]

for (rb, rs, cons, sz, stop, tp, hold, label) in configs
    println("▸ $label (RSI buy<$rb sell>$rs consensus≥$cons size=$(sz*100)%)")
    r = run_technical(; symbol="BTCUSDT", capital=100_000.0, sim_hours=720,
        rsi_buy=Float64(rb), rsi_sell=Float64(rs), require_consensus=cons,
        size_pct=sz, stop_pct=stop, tp_pct=tp, max_hold=hold, verbose=false)
    @printf("  → %+.2f%%/month  WR:%.1f%%  PF:%.2f  Trades:%d\n", r.monthly, r.wr, r.pf, r.nt)

    if r.monthly > best_monthly
        global best_monthly = r.monthly
        global best = (label=label, r=r, rb=rb, rs=rs, cons=cons, sz=sz, stop=stop, tp=tp, hold=hold)
    end
    if r.monthly >= 10.0
        println("  ★ TARGET HIT!")
        break
    end
    println()
end

println("\n")
if best !== nothing
    println("╔════════════════════════════════════════════════════╗")
    @printf("║  BEST: %-20s → %+.2f%%/month       ║\n", best.label, best_monthly)
    @printf("║  WR: %.1f%%  PF: %.2f  Trades: %d  DD: %.2f%%        ║\n",
            best.r.wr, best.r.pf, best.r.nt, best.r.mdd)
    if best_monthly >= 10.0
        println("║  ★ TARGET 10%/month: HIT                          ║")
    end
    println("╚════════════════════════════════════════════════════╝")

    # Re-run best with verbose
    println("\n▶ Best config with full trade log:\n")
    run_technical(; symbol="BTCUSDT", capital=100_000.0, sim_hours=720,
        rsi_buy=Float64(best.rb), rsi_sell=Float64(best.rs),
        require_consensus=best.cons, size_pct=best.sz,
        stop_pct=best.stop, tp_pct=best.tp, max_hold=best.hold, verbose=true)
end
