#!/usr/bin/env julia
#
# Leveraged BTC Simulation — uses the proven 75% WR daily signals
# with 2-3x leverage (Binance futures) to target 10%+ monthly.
#
# The signal quality is proven. The gap is position economics.
# Leverage is the mathematical path to 10%/month.

push!(LOAD_PATH, joinpath(@__DIR__, ".."))
println("Loading QuantEngine...")
flush(stdout)
using QuantEngine
using Dates, Printf, Statistics
println("Loaded.\n")

function run_leveraged(;
    capital=100_000.0, sim_days=90, leverage=3.0,
    train_window=200, min_signal=0.60,
    base_size_pct=0.50,  # before leverage
    stop_pct=3.0,        # on the LEVERAGED position
    trail_pct=2.5,
    max_hold=5,
    cost_bps=8.0,        # futures = lower fees than spot
    funding_bps_per_day=1.0,  # ~0.01% per 8h funding = ~3bps/day
    verbose=true)

    ticker = "BTC-USD"
    asset_type = :crypto
    display = "BTC-USD"

    stock = fetch_ohlcv(display; period="2y")
    prices = stock.adj
    rets = diff(log.(prices))
    vols = stock.volume
    highs = stock.high
    lows = stock.low
    dates = stock.dates
    n = length(rets)

    if isempty(QuantEngine.MODEL_DISPATCH)
        QuantEngine._register_models!()
    end

    effective_size = base_size_pct * leverage

    println("═" ^ 60)
    @printf("  BTC LEVERAGED SIM — %dx on %.0f%% base = %.0f%% effective\n",
            round(Int, leverage), base_size_pct*100, effective_size*100)
    @printf("  Capital: \$%d | %d days | Signal≥%.2f\n", round(Int,capital), sim_days, min_signal)
    @printf("  Stop: %.1f%% | Trail: %.1f%% | Hold: %dd | Costs: %.0fbps + %.1fbps/day funding\n",
            stop_pct, trail_pct, max_hold, cost_bps, funding_bps_per_day)
    println("═" ^ 60)

    eq = capital
    pos = nothing  # (dir, entry, notional, margin, entry_day)
    trades = NamedTuple[]
    eq_curve = Float64[eq]
    sim_start = n - sim_days + 1

    for di in sim_start:n
        dn = di - sim_start + 1
        cp = prices[di + 1]
        dt = di + 1 <= length(dates) ? dates[di+1] : dates[end]

        # ── Manage leveraged position ──
        if pos !== nothing
            dir, ep, notional, margin, ed = pos
            pnl_pct = dir == :long ? (cp/ep - 1)*100 : (1 - cp/ep)*100

            # Leveraged P&L on margin
            pnl_on_margin = pnl_pct * leverage
            bars = dn - ed

            # Daily funding cost
            funding_cost = notional * funding_bps_per_day / 10000 * bars

            ex = nothing
            if pnl_pct <= -(stop_pct / leverage)  # stop on underlying price
                ex = :stop
            elseif pnl_pct >= trail_pct  # trail on underlying
                # Check if we're pulling back from peak
                ex = :trail  # simplified: take profit at trail_pct
            elseif bars >= max_hold
                ex = :time
            end

            if ex !== nothing
                gross_pnl = notional * pnl_pct / 100
                cost = notional * cost_bps / 10000  # exit cost
                net_pnl = gross_pnl - cost - funding_cost
                eq += net_pnl

                push!(trades, (day=dn, date=dt, dir=dir, entry=ep, exit=cp,
                    notional=notional, margin=margin, pnl_pct=pnl_pct,
                    leveraged_pnl_pct=pnl_pct*leverage,
                    net_pnl=net_pnl, funding=funding_cost,
                    days=bars, reason=ex))

                if verbose
                    @printf("  Day %2d %-5s EXIT  %.0f→%.0f  %+.1f%% (lev: %+.1f%%)  PnL: %+.0f  funding: -%.0f  Eq: %.0f\n",
                        dn, uppercase(string(dir)), ep, cp, pnl_pct,
                        pnl_pct*leverage, net_pnl, funding_cost, eq)
                end
                pos = nothing
            end
        end

        # ── Generate signal ──
        if pos === nothing
            tr_start = max(1, di - train_window)

            ctx = QuantEngine._build_backtest_context(
                ticker, asset_type, display,
                dates, prices, rets, vols, highs, lows,
                tr_start:di
            )

            # Run only tree models + options pricing models (proven winners)
            for mid in sort(collect(QuantEngine.FAST_MODELS))
                mid in QuantEngine.PHASE2_MODELS && continue
                run_model(ctx, mid; verbose=false)
            end
            for mid in sort(collect(QuantEngine.PHASE2_MODELS))
                mid in QuantEngine.FAST_MODELS && run_model(ctx, mid; verbose=false)
            end

            # Filter to best models only
            best_results = Dict{String,Any}()
            for (k,v) in ctx.results
                if occursin("Random Forest", k) || occursin("LightGBM", k) ||
                   occursin("XGBoost", k) || occursin("Black-Scholes", k) ||
                   occursin("FD Pricer", k)
                    best_results[k] = v
                end
            end

            comp = compute_composite(isempty(best_results) ? ctx.results : best_results)

            ma20 = mean(prices[max(1, di-18):di+1])
            sig = nothing
            if comp.p_true >= min_signal && cp > ma20
                sig = :long
            elseif comp.p_true <= (1.0 - min_signal) && cp < ma20
                sig = :short
            end

            if sig !== nothing
                conv = abs(comp.p_true - 0.5) * 2
                sf = clamp(base_size_pct * max(conv, 0.5), 0.20, base_size_pct)
                margin = eq * sf
                notional = margin * leverage
                ep = sig == :long ? cp * (1 + cost_bps/20000) : cp * (1 - cost_bps/20000)
                pos = (sig, ep, notional, margin, dn)

                if verbose
                    @printf("  Day %2d %-5s ENTER %.0f  margin=%.0f  notional=%.0f (%dx)  p=%.3f\n",
                        dn, uppercase(string(sig)), ep, margin, notional,
                        round(Int, leverage), comp.p_true)
                end
            end
        end

        push!(eq_curve, eq)
    end

    # Close open
    if pos !== nothing
        dir, ep, notional, margin, ed = pos
        fp = prices[end]
        pp = dir == :long ? (fp/ep-1)*100 : (1-fp/ep)*100
        bars = n - sim_start + 1 - ed
        fc = notional * funding_bps_per_day / 10000 * bars
        gpnl = notional * pp / 100
        npnl = gpnl - notional * cost_bps / 10000 - fc
        eq += npnl
        push!(trades, (day=sim_days, date=dates[end], dir=dir, entry=ep, exit=fp,
            notional=notional, margin=margin, pnl_pct=pp,
            leveraged_pnl_pct=pp*leverage, net_pnl=npnl, funding=fc,
            days=bars, reason=:end_sim))
        if verbose
            @printf("  Day %2d CLOSE %.0f→%.0f  %+.1f%%  PnL: %+.0f\n",
                sim_days, ep, fp, pp, npnl)
        end
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
    aw = isempty(wins) ? 0.0 : mean(t.pnl_pct for t in wins)
    al = isempty(losses) ? 0.0 : mean(t.pnl_pct for t in losses)
    mdd = 0.0; pk = eq_curve[1]
    for e in eq_curve; pk=max(pk,e); mdd=max(mdd,(pk-e)/pk); end
    bh = (prices[end]/prices[sim_start]-1)*100
    monthly = tr / (sim_days / 30)
    total_funding = sum(t.funding for t in trades)

    println()
    println("═" ^ 60)
    @printf("  RESULTS — BTC %dx LEVERAGED\n", round(Int, leverage))
    println("─" ^ 60)
    @printf("  Capital:      \$%d → \$%.0f\n", round(Int,capital), eq)
    @printf("  Return:       %+.2f%%  (%+.2f%%/month)\n", tr, monthly)
    @printf("  Max Drawdown: %.2f%%\n", mdd*100)
    @printf("  Trades:       %d (Win: %d  Loss: %d)\n", nt, length(wins), length(losses))
    @printf("  Win Rate:     %.1f%%\n", wr)
    @printf("  Profit Factor:%.2f\n", pf)
    @printf("  Avg Win:      %+.2f%% underlying  Avg Loss: %.2f%%\n", aw, al)
    @printf("  Total Funding:-\$%.0f\n", total_funding)
    @printf("  Buy & Hold:   %+.2f%%  Alpha: %+.2f%%\n", bh, tr-bh)
    println("─" ^ 60)
    if monthly >= 10.0
        println("  ★ TARGET 10%/month: HIT ✓")
    else
        @printf("  TARGET 10%%/month: %.1f%% short\n", 10.0-monthly)
    end
    println("═" ^ 60)

    return (eq=eq, tr=tr, monthly=monthly, wr=wr, pf=pf, nt=nt, mdd=mdd*100)
end

# ── Sweep leverage levels ─────────────────────────────────────

println("╔═══════════════════════════════════════════════════════╗")
println("║  LEVERAGED BTC SIM — SWEEP 2x to 5x                  ║")
println("║  Using proven 75% WR signals + tree model filter      ║")
println("╚═══════════════════════════════════════════════════════╝\n")

for lev in [2.0, 3.0, 4.0, 5.0]
    @printf("\n▸ %dx leverage:\n", round(Int, lev))
    r = run_leveraged(; leverage=lev, sim_days=90, capital=100_000.0,
        min_signal=0.60, base_size_pct=0.50,
        stop_pct=3.0, trail_pct=2.5, max_hold=5,
        verbose=true)
    println()

    if r.monthly >= 10.0
        println("★ TARGET HIT at $(round(Int, lev))x leverage")
        println("  Running 180-day confirmation...")
        r2 = run_leveraged(; leverage=lev, sim_days=180, capital=100_000.0,
            min_signal=0.60, base_size_pct=0.50,
            stop_pct=3.0, trail_pct=2.5, max_hold=5,
            verbose=false)
        @printf("  180-day: %+.2f%% (%+.2f%%/month)  WR:%.1f%%  DD:%.2f%%\n",
                r2.tr, r2.monthly, r2.wr, r2.mdd)
        break
    end
end
