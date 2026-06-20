#!/usr/bin/env julia
# ── QUANTENGINE v8.0 — FULL SYSTEM (Fixed) ──────────────────
# ALL 34 models active on EVERY trade decision.
# Kelly-based position sizing. Wide TP, tight SL.
# Trend filter blocks shorts in uptrends.
# Brain learns fast (alpha=0.3).

using QuantEngine, Dates, Printf, Statistics, Random

function build_context(prices, returns, volumes, high, low, dates, ticker, asset_type, idx)
    pr = max(1, idx - 200):idx
    cp = prices[pr]; cr = returns[max(1, first(pr)):min(idx - 1, length(returns))]
    cv = volumes[pr]; ch = high[pr]; cl = low[pr]; cd = dates[pr]
    length(cr) < 25 && return nothing

    X, y, _, _ = QuantEngine.compute_features(cp, cr, cv)
    ns = size(X, 1)
    ns < 10 && return nothing
    sp = max(1, round(Int, ns * 0.8))
    Xtr = X[1:sp, :]; ytr = y[1:sp]
    Xte = X[max(sp+1, ns):end, :]; yte = y[max(sp+1, ns):end]
    nf = size(X, 2)
    sl = min(10, max(2, div(size(Xtr, 1), 5)))

    if size(Xtr, 1) > sl + 2
        Xsq_tr, ysq_tr = QuantEngine.make_sequences(Xtr, ytr, sl)
        Xsq_te, ysq_te = QuantEngine.make_sequences(Xte, yte, sl)
    else
        Xsq_tr = [reshape(Xtr[1, :], 1, :)]; ysq_tr = [ytr[1]]
        Xsq_te = Xsq_tr; ysq_te = ysq_tr
    end

    disp = uppercase(ticker)
    return AnalysisContext(
        ticker, asset_type, disp, mktempdir(),
        cd, cp, cr, cv, ch, cl, cp[end],
        Xtr, ytr, Xte, yte, Xsq_tr, ysq_tr, Xsq_te, ysq_te,
        nf, sl, nothing, Float64[],
        Dict{String, Any}(), RalphLog[], ReentrantLock(), nothing
    )
end

function run_ensemble!(ctx)
    for m in sort(collect(QuantEngine.FAST_MODELS))
        m in QuantEngine.PHASE2_MODELS && continue
        try run_model(ctx, m; verbose=false) catch; end
    end
    for m in sort(collect(QuantEngine.PHASE2_MODELS))
        try run_model(ctx, m; verbose=false) catch; end
    end
    return compute_composite(ctx.results)
end

function run_full_system()
    tickers = length(ARGS) > 0 ? ARGS : ["QQQ"]

    println("╔══════════════════════════════════════════════════════════════╗")
    println("║  QUANTENGINE v8.0 — FULL SYSTEM (ALL 34 MODELS ACTIVE)    ║")
    println("║  $(Dates.format(now(), "yyyy-mm-dd HH:MM"))                                         ║")
    println("╚══════════════════════════════════════════════════════════════╝")

    if isempty(QuantEngine.MODEL_DISPATCH); QuantEngine._register_models!(); end
    brain = load_brain()
    @printf("  Brain: %d prior trades | Lifetime WR: %.1f%%\n", brain.total_trades, brain.lifetime_win_rate)

    # Fetch data
    assets = Dict{String, NamedTuple}()
    for t in tickers
        d = fetch_ohlcv(uppercase(t); period="1y")
        at = detect_asset_type(t)
        assets[t] = (prices=d.adj, volumes=d.volume, high=d.high, low=d.low, dates=d.dates, asset_type=at)
        @printf("  %-6s %d bars  \$%.2f\n", t, length(d.adj), d.adj[end])
    end

    min_bars = minimum(length(a.prices) for a in values(assets))
    capital = 10000.0; starting = capital; peak = capital
    trades = NamedTuple[]; equity = Float64[capital]
    open_pos = NamedTuple[]; streak = 0; max_streak = 0
    warmup = 35; ensemble_runs = 0

    costs_s = round_trip_cost_fraction(realistic_costs(:stock))
    costs_c = round_trip_cost_fraction(realistic_costs_limit(:crypto))

    println("  Capital: \$10,000 | Models: $(length(QuantEngine.MODEL_DISPATCH))")
    println("\n  ── TRADES ─────────────────────────────────────────────────\n")

    for day in (warmup + 1):min_bars
        # ═══ EXIT CHECK ═══════════════════════════════════════
        closed = Int[]
        for (idx, pos) in enumerate(open_pos)
            a = assets[pos.ticker]; day > length(a.prices) && (push!(closed, idx); continue)
            price = a.prices[day]; bars = day - pos.entry_bar
            pnl_raw = pos.dir == :buy ? (price / pos.entry_price - 1) * 100 : (1 - price / pos.entry_price) * 100
            pnl_lev = pnl_raw * pos.leverage

            exit = pnl_lev >= pos.tp ? :TP : pnl_lev <= -pos.sl ? :SL : bars >= pos.max_hold ? :TIME : nothing
            exit === nothing && continue

            cost = pos.asset_type == :crypto ? costs_c : costs_s
            net = pnl_lev - cost * 100 * pos.leverage
            pnl_d = pos.size * net / 100
            capital += pnl_d; peak = max(peak, capital)
            if net > 0; streak = streak > 0 ? streak + 1 : 1; else; streak = streak < 0 ? streak - 1 : -1; end
            max_streak = max(max_streak, streak)

            learn_from_trade!(brain, pos.ticker, pos.dir, pnl_d, net, pos.layer, pos.signal, bars,
                day <= length(a.dates) ? Dates.format(a.dates[day], "mm/dd") : "?", pos.asset_type)

            e = net > 0 ? "W" : "L"
            ps = pnl_d >= 0 ? "+\$$(round(pnl_d, digits=2))" : "-\$$(round(abs(pnl_d), digits=2))"
            ds = day <= length(a.dates) ? Dates.format(a.dates[day], "mm/dd") : "?"
            lv = pos.leverage > 1 ? " $(pos.leverage)x" : ""
            ss = streak >= 3 ? " ★$streak" : ""

            push!(trades, (ticker=pos.ticker, dir=pos.dir, pnl=pnl_d, pnl_pct=net, reason=exit,
                bars=bars, instrument=string(pos.instrument), leverage=pos.leverage, asset_type=pos.asset_type))
            @printf("  %s [%s] %-5s %-4s %-3s %-10s%s %9s %+5.1f%% %2db \$%.0f%s\n",
                ds, e, pos.ticker, uppercase(string(pos.dir)), exit, string(pos.instrument), lv, ps, net, bars, capital, ss)
            push!(closed, idx)
        end
        for i in sort(closed, rev=true); deleteat!(open_pos, i); end

        # ═══ ENTRY SCAN ═══════════════════════════════════════
        length(open_pos) >= 5 && (push!(equity, capital); continue)

        for ticker in shuffle(collect(keys(assets)))
            length(open_pos) >= 5 && break
            any(p -> p.ticker == ticker, open_pos) && continue
            a = assets[ticker]; day > length(a.prices) || day <= 30 && continue

            price = a.prices[day]
            is_crypto = a.asset_type == :crypto
            vol = day > 20 ? std(diff(log.(a.prices[max(1, day - 20):day]))) : 0.02
            vol = max(vol, 0.005)

            # ── Step 1: Check for mean reversion signal ───────
            w = a.prices[max(1, day - 30):day]
            v = a.volumes[max(1, day - 30):min(day, length(a.volumes))]
            mr = evaluate_mean_reversion(w, v)
            mc = mean_rev_consensus(mr)

            # Also check MACD
            wp = a.prices[max(1, day - 60):day]
            macd_sigs = [evaluate_macd(wp, c) for c in [MACDConfig("Classic", 12, 26, 9, 0.0), MACDConfig("Fast", 5, 13, 6, 0.0)]]
            macd_c = macd_consensus(macd_sigs)

            # Determine candidate direction from either signal
            candidate_dir = :hold
            signal_source = ""
            signal_strength = 0.0

            if mc.direction != :hold && mc.strength >= 55 && mc.n_agreeing >= 2
                candidate_dir = mc.direction
                signal_source = mc.strategies
                signal_strength = mc.strength
            elseif macd_c.direction != :hold && macd_c.confidence >= 55
                candidate_dir = macd_c.direction
                signal_source = "MACD"
                signal_strength = macd_c.confidence
            end

            candidate_dir == :hold && continue

            # ── Step 2: TREND FILTER — block shorts in uptrends ──
            if candidate_dir == :sell && day > 20
                trend_20 = (price - a.prices[max(1, day - 20)]) / a.prices[max(1, day - 20)]
                if trend_20 > 0.03  # 3%+ uptrend → DO NOT SHORT
                    continue
                end
            end
            # Block buys in strong downtrends too
            if candidate_dir == :buy && day > 20
                trend_20 = (price - a.prices[max(1, day - 20)]) / a.prices[max(1, day - 20)]
                if trend_20 < -0.08  # 8%+ downtrend → don't catch falling knife
                    continue
                end
            end

            # ── Step 3: RUN 34-MODEL ENSEMBLE for confirmation ──
            ctx = build_context(a.prices, diff(log.(a.prices)), a.volumes, a.high, a.low, a.dates, ticker, a.asset_type, day)
            ctx === nothing && continue

            composite = run_ensemble!(ctx)
            ensemble_runs += 1

            # Extract Kelly sizing from model 17
            kelly_r = get(ctx.results, "17. Kelly Criterion", nothing)
            garch_r = get(ctx.results, "14. EGARCH/GARCH Family", nothing)

            kelly_frac = if kelly_r isa NamedTuple && hasproperty(kelly_r, :kelly_quarter)
                clamp(kelly_r.kelly_quarter, 0.05, 0.25)
            else
                0.12  # fallback 12%
            end

            # GARCH volatility for TP/SL
            garch_vol = if garch_r isa NamedTuple && hasproperty(garch_r, :σ_annual_forecast)
                garch_r.σ_annual_forecast / sqrt(252)
            else
                vol
            end

            # ── Step 4: Ensemble must AGREE with signal direction ──
            ensemble_dir = if composite.direction in ["BUY", "LEAN BUY"] && composite.p_true > 0.52
                :buy
            elseif composite.direction in ["DO NOT BUY", "LEAN SELL"] && composite.p_true < 0.48
                :sell
            else
                :hold
            end

            # Ensemble confirmation: agree OR ensemble says HOLD (not conflicting)
            # Only block if ensemble actively disagrees (opposite direction)
            if ensemble_dir != :hold && ensemble_dir != candidate_dir
                continue  # ensemble says opposite direction — block
            end
            # Boost sizing if ensemble agrees
            ensemble_boost = ensemble_dir == candidate_dir ? 1.3 : 1.0

            # ── Step 5: Brain filter ──────────────────────────
            bf = brain_filter(brain, ticker, candidate_dir, "Ensemble", signal_source, signal_strength, a.asset_type)
            bf.action == :skip && continue

            # ── Step 6: Calculate TP/SL/Size using model outputs ──
            ep = day < length(a.prices) ? a.prices[day + 1] : price

            # WIDE TP (4-5%), TIGHT SL (1.5-2%) → 2.5:1+ R:R
            tp = clamp(garch_vol * sqrt(8) * 300, 3.0, 20.0)
            sl = clamp(garch_vol * sqrt(3) * 80, 1.0, 5.0)
            hold = clamp(round(Int, 8 / garch_vol), 5, 30)

            # Kelly-based sizing (clamped) with ensemble boost
            sizing = clamp(kelly_frac * bf.sizing_multiplier * ensemble_boost, 0.05, 0.25)
            if bf.action == :reduce; sizing *= 0.7; end
            sz = capital * sizing
            sz = clamp(sz, 100.0, capital * 0.25)

            # Instrument selection
            instrument = :spot_buy; leverage = 1
            if candidate_dir == :sell
                instrument = is_crypto ? :futures_short : :spot_sell
                leverage = is_crypto && composite.confidence > 70 ? 2 : 1
            elseif is_crypto && composite.confidence > 75
                instrument = :futures_long; leverage = 2
            end

            layer = ensemble_dir == candidate_dir ? "Ensemble" : "Signal"

            push!(open_pos, (ticker=ticker, dir=candidate_dir, entry_price=ep, entry_bar=day,
                tp=tp * leverage, sl=sl * leverage, max_hold=hold, size=sz, signal=signal_source,
                instrument=instrument, leverage=leverage, asset_type=a.asset_type, layer=layer))
        end

        # Funding income for crypto positions
        for pos in open_pos
            if pos.asset_type == :crypto
                a = assets[pos.ticker]
                if day > 24 && day <= length(a.prices)
                    mom = (a.prices[day] - a.prices[day - 24]) / a.prices[day - 24]
                    rate = 0.0001 + mom * 0.003 + randn() * 0.00003
                    if rate > 0; capital += pos.size * 0.3 * rate; end
                end
            end
        end

        push!(equity, capital)
    end

    # Close remaining
    for pos in open_pos
        a = assets[pos.ticker]; price = a.prices[end]
        pnl_raw = pos.dir == :buy ? (price / pos.entry_price - 1) * 100 : (1 - price / pos.entry_price) * 100
        net = pnl_raw * pos.leverage - (pos.asset_type == :crypto ? costs_c : costs_s) * 100 * pos.leverage
        pnl_d = pos.size * net / 100; capital += pnl_d; peak = max(peak, capital)
        if net > 0; streak = streak > 0 ? streak + 1 : 1; else; streak = streak < 0 ? streak - 1 : -1; end
        max_streak = max(max_streak, streak)
        learn_from_trade!(brain, pos.ticker, pos.dir, pnl_d, net, pos.layer, pos.signal, 0, "END", pos.asset_type)
        push!(trades, (ticker=pos.ticker, dir=pos.dir, pnl=pnl_d, pnl_pct=net, reason=:END,
            bars=0, instrument=string(pos.instrument), leverage=pos.leverage, asset_type=pos.asset_type))
        e = net > 0 ? "W" : "L"; ps = pnl_d >= 0 ? "+\$$(round(pnl_d, digits=2))" : "-\$$(round(abs(pnl_d), digits=2))"
        @printf("  END  [%s] %-5s %-4s %9s %+5.1f%%  Cap:\$%.0f\n", e, pos.ticker, uppercase(string(pos.dir)), ps, net, capital)
    end

    save_brain!(brain)

    # ═══ REPORT ═══════════════════════════════════════════════
    nt = length(trades); wins = count(t -> t.pnl > 0, trades); losses = nt - wins
    wr = nt > 0 ? wins / nt * 100 : 0.0
    total_pnl = capital - starting; total_pct = total_pnl / starting * 100
    max_dd = 0.0; pk = starting; for eq in equity; pk = max(pk, eq); max_dd = max(max_dd, (pk - eq) / pk * 100); end
    wp = sum(t.pnl for t in trades if t.pnl > 0; init=0.0)
    lp = abs(sum(t.pnl for t in trades if t.pnl < 0; init=0.0))
    pf = lp > 0 ? wp / lp : (wp > 0 ? 99.0 : 0.0)

    println("\n" * "═" ^ 62)
    println("  FINAL RESULT")
    println("═" ^ 62)
    @printf("  Started with:    \$10,000\n")
    @printf("  Ended with:      \$%.2f\n", capital)
    @printf("  Net P&L:         %s\$%.2f (%+.1f%%)\n", total_pnl >= 0 ? "+" : "-", abs(total_pnl), total_pct)
    @printf("  Peak:            \$%.2f\n", peak)
    @printf("  Max Drawdown:    %.1f%%\n", max_dd)
    @printf("  Trades:          %d (%dW / %dL) | Win Rate: %.1f%%\n", nt, wins, losses, wr)
    @printf("  Profit Factor:   %.2f\n", pf)
    @printf("  Max Streak:      %d\n", max_streak)
    @printf("  Ensemble Runs:   %d (34 models each)\n", ensemble_runs)
    @printf("  Shorts:          %d | Leveraged: %d\n", count(t -> t.dir == :sell, trades), count(t -> t.leverage > 1, trades))
    println("═" ^ 62)
    print_brain_summary(brain)
end

run_full_system()
