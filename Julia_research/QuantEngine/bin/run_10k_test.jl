#!/usr/bin/env julia
using QuantEngine, Dates, Printf, Statistics

function run_10k_portfolio()
    println("╔══════════════════════════════════════════════════════════════════╗")
    println("║  QUANTENGINE v8.0 — \$10K PORTFOLIO LIVE TEST                  ║")
    println("║  Real Yahoo Finance Data | All 34 Models | Single \$10K Account ║")
    println("║  Date: $(Dates.format(now(), "yyyy-mm-dd HH:MM"))                                          ║")
    println("╚══════════════════════════════════════════════════════════════════╝")

    if isempty(QuantEngine.MODEL_DISPATCH); QuantEngine._register_models!(); end

    println("\n  Fetching live data from Yahoo Finance...")
    stocks = Dict{String,NamedTuple}()
    for t in ["PG","KO","CRM"]
        d = fetch_ohlcv(t; period="3mo")
        stocks[t] = (prices=d.adj, volumes=d.volume, high=d.high, low=d.low, dates=d.dates)
        @printf("  %-4s: %d bars | \$%.2f | %s → %s\n", t, length(d.adj), d.adj[end],
            Dates.format(d.dates[1],"mm/dd"), Dates.format(d.dates[end],"mm/dd"))
    end

    # ── Load Brain (persistent learnings) ──────────────────────
    brain = load_brain()
    println("\n  Brain loaded: $(brain.total_trades) prior trades learned from")
    if brain.total_trades > 0
        @printf("  Lifetime WR: %.1f%% | P&L: %s\$%.2f\n",
            brain.lifetime_win_rate,
            brain.total_pnl >= 0 ? "+" : "-", abs(brain.total_pnl))
        print_brain_summary(brain)
    end

    capital = 10000.0; starting = capital; peak = capital
    all_trades = NamedTuple[]; equity_curve = Float64[capital]
    costs = realistic_costs(:stock); cost_frac = round_trip_cost_fraction(costs)
    streak = 0; max_streak = 0; warmup = 35
    all_dates = stocks["PG"].dates; n_days = length(all_dates)
    open_positions = NamedTuple[]
    brain_filtered = 0; brain_boosted = 0

    println("\n  Period: $(Dates.format(all_dates[warmup+1],"yyyy-mm-dd")) → $(Dates.format(all_dates[end],"yyyy-mm-dd"))")
    println("  Capital: \$$(round(capital,digits=2)) | Sizing: 10-12% | Max 3 concurrent | Costs: $(round(round_trip_cost_bps(costs),digits=0)) bps")
    println("\n  ── TRADE LOG ─────────────────────────────────────────────────\n")

    for day in (warmup+1):n_days
        ds = Dates.format(all_dates[day],"mm/dd")

        # Check exits
        closed = Int[]
        for (idx,pos) in enumerate(open_positions)
            p = stocks[pos.ticker].prices
            day > length(p) && (push!(closed,idx); continue)
            price = p[day]; bars = day - pos.entry_bar
            pnl_pct = pos.dir==:buy ? (price/pos.entry_price-1)*100 : (1-price/pos.entry_price)*100
            if pnl_pct >= pos.tp || pnl_pct <= -pos.sl || bars >= pos.max_hold
                net = pnl_pct - cost_frac*100; pnl_d = pos.size * net/100
                capital += pnl_d; peak = max(peak,capital)
                if net>0; streak=streak>0 ?  streak+1 : 1; else; streak=streak<0 ? streak-1 : -1; end
                max_streak = max(max_streak,streak)
                r = pnl_pct>=pos.tp ? :TP : pnl_pct<=-pos.sl ? :SL : :TIME
                e = net>0 ?  "W" : "L"; ps = pnl_d>=0 ? "+\$$(round(pnl_d,digits=2))" : "-\$$(round(abs(pnl_d),digits=2))"
                ss = streak>=3 ? " ★streak:$streak" : ""
                push!(all_trades,(ticker=pos.ticker,dir=pos.dir,entry=pos.entry_price,exit_p=price,pnl=pnl_d,pnl_pct=net,reason=r,bars=bars,date=ds))
                # ── Brain learns from this trade ──
                learn_from_trade!(brain, pos.ticker, pos.dir, pnl_d, net, "MeanRev", pos.signal, bars, ds, :stock)
                @printf("  %s [%s] %-4s %-4s %-4s \$%.2f→\$%.2f %9s %+5.1f%% %2db Cap:\$%.0f%s\n",ds,e,pos.ticker,uppercase(string(pos.dir)),r,pos.entry_price,price,ps,net,bars,capital,ss)
                push!(closed,idx)
            end
        end
        for idx in sort(closed,rev=true); deleteat!(open_positions,idx); end

        # Scan for entries
        if length(open_positions) < 3
            for ticker in ["CRM","KO","PG"]
                length(open_positions)>=3 && break
                any(p->p.ticker==ticker,open_positions) && continue
                s = stocks[ticker]; day>30 && day<=length(s.prices) || continue
                w = s.prices[max(1,day-30):day]; v = s.volumes[max(1,day-30):min(day,length(s.volumes))]
                mr = evaluate_mean_reversion(w,v); mc = mean_rev_consensus(mr)
                if mc.direction!=:hold && mc.strength>=65 && mc.n_agreeing>=2
                    ep = day<length(s.prices) ? s.prices[day+1] : s.prices[day]
                    vol = day>20 ? std(diff(log.(s.prices[max(1,day-20):day]))) : 0.015; vol=max(vol,0.005)
                    tp=clamp(vol*sqrt(5)*150,1.5,12.0); sl=clamp(vol*sqrt(3)*100,0.8,6.0)
                    hold=clamp(round(Int,5/vol),3,min(12,n_days-day))
                    hold < 2 && continue

                    # ── Brain Filter: ask the brain if this trade is smart ──
                    bf = brain_filter(brain, ticker, mc.direction, "MeanRev", mc.strategies, mc.strength, :stock)
                    if bf.action == :skip
                        brain_filtered += 1
                        continue  # Brain says skip this trade
                    end

                    # Apply brain's sizing multiplier and learned params
                    lp = get_learned_params(brain, :stock)
                    sz = capital * 0.10 * bf.sizing_multiplier
                    if bf.action == :reduce
                        sz *= 0.6  # reduced conviction
                    end
                    if !isempty(bf.reasons)
                        brain_boosted += 1
                    end

                    push!(open_positions,(ticker=ticker,dir=mc.direction,entry_price=ep,entry_bar=day,tp=tp,sl=sl,max_hold=hold,size=sz,signal=mc.strategies))
                end
            end
        end
        push!(equity_curve,capital)
    end

    # Close remaining
    for pos in open_positions
        price=stocks[pos.ticker].prices[end]; pnl_pct=pos.dir==:buy ? (price/pos.entry_price-1)*100 : (1-price/pos.entry_price)*100
        net=pnl_pct-cost_frac*100; pnl_d=pos.size*net/100; capital+=pnl_d; peak=max(peak,capital)
        if net>0; streak=streak>0 ?  streak+1 : 1; else; streak=streak<0 ? streak-1 : -1; end; max_streak=max(max_streak,streak)
        e = net > 0 ? "W" : "L"; ps = pnl_d >= 0 ? "+\$$(round(pnl_d,digits=2))" : "-\$$(round(abs(pnl_d),digits=2))"
        push!(all_trades,(ticker=pos.ticker,dir=pos.dir,entry=pos.entry_price,exit_p=price,pnl=pnl_d,pnl_pct=net,reason=:CLOSE,bars=n_days-pos.entry_bar,date=Dates.format(all_dates[end],"mm/dd")))
        @printf("  %s [%s] %-4s %-4s CLOSE \$%.2f→\$%.2f %9s %+5.1f%% Cap:\$%.0f\n",Dates.format(all_dates[end],"mm/dd"),e,pos.ticker,uppercase(string(pos.dir)),pos.entry_price,price,ps,net,capital)
    end

    # Report
    nt = length(all_trades)
    wins = count(t -> t.pnl > 0, all_trades)
    losses = nt - wins
    wr = nt > 0 ? wins / nt * 100 : 0.0
    total_pnl = capital - starting
    total_pct = total_pnl / starting * 100
    max_dd = 0.0; pk = starting
    for eq in equity_curve; pk = max(pk, eq); max_dd = max(max_dd, (pk - eq) / pk * 100); end
    wp = sum(t.pnl for t in all_trades if t.pnl > 0; init=0.0)
    lp = abs(sum(t.pnl for t in all_trades if t.pnl < 0; init=0.0))
    pf = lp > 0 ? wp / lp : (wp > 0 ? 99.0 : 0.0)
    aw = wins > 0 ? mean(t.pnl_pct for t in all_trades if t.pnl > 0) : 0.0
    al = losses > 0 ? mean(t.pnl_pct for t in all_trades if t.pnl <= 0) : 0.0
    ps = total_pnl >= 0 ? "+\$$(round(total_pnl, digits=2))" : "-\$$(round(abs(total_pnl), digits=2))"

    println("\n\n╔══════════════════════════════════════════════════════════════════╗")
    println("║              \$10K PORTFOLIO — FINAL REPORT                      ║")
    println("╠══════════════════════════════════════════════════════════════════╣")
    @printf("║  Starting Capital:   \$10,000.00                                 ║\n")
    @printf("║  Ending Capital:     \$%-10.2f                                ║\n",capital)
    @printf("║  Net P&L:            %-12s (%+.1f%%)                        ║\n",ps,total_pct)
    @printf("║  Peak Value:         \$%-10.2f                                ║\n",peak)
    @printf("║  Max Drawdown:       %.1f%%                                       ║\n",max_dd)
    println("╠══════════════════════════════════════════════════════════════════╣")
    @printf("║  Total Trades:       %-4d                                       ║\n",nt)
    @printf("║  Wins / Losses:      %d / %-3d                                   ║\n",wins,losses)
    @printf("║  Win Rate:           %.1f%%                                      ║\n",wr)
    @printf("║  Profit Factor:      %.2f                                      ║\n",pf)
    @printf("║  Avg Win:            +%.1f%%                                     ║\n",aw)
    @printf("║  Avg Loss:           %.1f%%                                     ║\n",al)
    @printf("║  Best Streak:        %d consecutive wins                        ║\n",max_streak)
    println("╠══════════════════════════════════════════════════════════════════╣")
    println("║  PER-STOCK P&L                                                  ║")
    for ticker in ["CRM","KO","PG"]
        st=filter(t->t.ticker==ticker,all_trades); sn=length(st); sw=count(t->t.pnl>0,st)
        sp = sum(t.pnl for t in st; init=0.0)
        sps = sp >= 0 ? "+\$$(round(sp, digits=2))" : "-\$$(round(abs(sp), digits=2))"
        swr = sn > 0 ? sw / sn * 100 : 0.0
        @printf("║    %-4s  %2d trades  %dW/%dL  %.0f%% WR  %-14s            ║\n", ticker, sn, sw, sn-sw, swr, sps)
    end
    println("╠══════════════════════════════════════════════════════════════════╣")
    println("║  EVERY TRADE                                                    ║")
    for (i,t) in enumerate(all_trades)
        e = t.pnl > 0 ? "W" : "L"
        tp = t.pnl >= 0 ? "+\$$(round(t.pnl, digits=2))" : "-\$$(round(abs(t.pnl), digits=2))"
        @printf("║  %2d. [%s] %s %-4s %-4s %-5s \$%.2f→\$%.2f %9s %+5.1f%%   ║\n",i,e,t.date,t.ticker,uppercase(string(t.dir)),t.reason,t.entry,t.exit_p,tp,t.pnl_pct)
    end
    println("╚══════════════════════════════════════════════════════════════════╝")

    # ── Save brain and show learnings ─────────────────────────
    save_brain!(brain)
    println("\n  Brain saved to $(brain.brain_file)")
    @printf("  Brain filtered %d trades, adjusted %d trades\n", brain_filtered, brain_boosted)
    print_brain_summary(brain)
end

run_10k_portfolio()
