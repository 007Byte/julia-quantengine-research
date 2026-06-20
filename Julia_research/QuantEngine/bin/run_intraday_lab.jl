#!/usr/bin/env julia
# ── QuantEngine Intraday Strategy Lab ────────────────────────
# Calibrated for 5-minute crypto data.
# Key calibration from SOL-USD analysis:
#   - 5-min vol: 0.27%, daily est: 4.58%
#   - Need >0.92% move to clear 61 bps costs
#   - 60-bar (5hr) windows: 20.8% move >2%, 10% move >3%
#   - 120-bar (10hr) windows: 34.7% move >2%, 19.9% move >3%
#   → Use 60-120 bar holds, 2-3% TP, 1.5-2% SL
#   → Trade selectively: only strong signals, max ~2-4 trades/day

using QuantEngine
using Printf
using Statistics
using Dates

# ── Intraday MACD Configs (tuned for 5-min bars) ────────────
const INTRADAY_CONFIGS = [
    # Faster MACDs for intraday — shorter periods capture 5-min momentum
    MACDConfig("5m-Fast",        5, 13, 6, 0.0),
    MACDConfig("5m-Scalp",       3, 10, 4, 0.0),
    MACDConfig("5m-Medium",      8, 21, 5, 0.0),
    MACDConfig("5m-Classic",    12, 26, 9, 0.0),
    MACDConfig("5m-Trend",      15, 35, 10, 0.0),
    MACDConfig("5m-4/16/3",      4, 16, 3, 0.0),
    MACDConfig("5m-9/15/3",      9, 15, 3, 0.0),
]

struct IntradayStrategy
    name::String
    configs::Vector{MACDConfig}
    min_confidence::Float64
    min_consensus::Float64
    tp_pct::Float64          # fixed TP in percent (not vol-based)
    sl_pct::Float64          # fixed SL in percent
    max_hold_bars::Int       # in 5-min bars
    trend_lookback::Int      # bars to check trend
    min_trend_pct::Float64   # minimum trend move to confirm
    cooldown_bars::Int       # bars to wait between trades
end

function generate_intraday_strategies()
    s = IntradayStrategy[]

    # Strategy 1: Swing Catcher — wait for big moves (60-bar holds ≈ 5 hours)
    push!(s, IntradayStrategy("SwingCatch-5hr",
        [MACDConfig("5m-Classic", 12, 26, 9, 0.0), MACDConfig("5m-Trend", 15, 35, 10, 0.0)],
        55.0, 50.0, 2.5, 1.5, 72, 60, 0.5, 30))

    # Strategy 2: Momentum Rider — ride 10-hour trends
    push!(s, IntradayStrategy("MomRider-10hr",
        [MACDConfig("5m-Classic", 12, 26, 9, 0.0), MACDConfig("5m-Medium", 8, 21, 5, 0.0)],
        55.0, 50.0, 3.0, 1.5, 120, 60, 0.8, 40))

    # Strategy 3: Selective Triple — all 3 MACDs must agree, 8hr hold
    push!(s, IntradayStrategy("Selective-8hr",
        [MACDConfig("5m-9/15/3", 9, 15, 3, 0.0), MACDConfig("5m-4/16/3", 4, 16, 3, 0.0), MACDConfig("5m-Classic", 12, 26, 9, 0.0)],
        60.0, 100.0, 2.5, 1.2, 96, 48, 0.5, 36))

    # Strategy 4: Trend Sniper — only with strong trend, tight SL
    push!(s, IntradayStrategy("TrendSnipe-6hr",
        [MACDConfig("5m-Trend", 15, 35, 10, 0.0)],
        50.0, 50.0, 3.0, 1.0, 72, 72, 1.0, 24))

    # Strategy 5: Wide Net — patient hold, wide TP
    push!(s, IntradayStrategy("WideNet-12hr",
        [MACDConfig("5m-Classic", 12, 26, 9, 0.0), MACDConfig("5m-Trend", 15, 35, 10, 0.0)],
        60.0, 100.0, 4.0, 2.0, 144, 72, 1.0, 48))

    # Strategy 6: Conservative 4/16/3 — the user's config, recalibrated
    push!(s, IntradayStrategy("Cons-4/16/3",
        [MACDConfig("5m-4/16/3", 4, 16, 3, 0.0)],
        50.0, 50.0, 2.0, 1.2, 60, 48, 0.3, 20))

    # Strategy 7: Multi-timeframe consensus (fast + slow must agree)
    push!(s, IntradayStrategy("MultiTF-Consensus",
        [MACDConfig("5m-Fast", 5, 13, 6, 0.0), MACDConfig("5m-Classic", 12, 26, 9, 0.0), MACDConfig("5m-Trend", 15, 35, 10, 0.0)],
        65.0, 66.0, 3.0, 1.5, 96, 60, 0.5, 36))

    # Strategy 8: Aggressive Breakout — wide TP, accept bigger SL
    push!(s, IntradayStrategy("Breakout-8hr",
        [MACDConfig("5m-Medium", 8, 21, 5, 0.0), MACDConfig("5m-9/15/3", 9, 15, 3, 0.0)],
        55.0, 50.0, 4.0, 2.5, 96, 48, 0.8, 30))

    # Strategy 9: Ultra-selective — very high conviction, rare trades
    push!(s, IntradayStrategy("UltraSelect",
        [MACDConfig("5m-Classic", 12, 26, 9, 0.0), MACDConfig("5m-Trend", 15, 35, 10, 0.0), MACDConfig("5m-Medium", 8, 21, 5, 0.0)],
        70.0, 100.0, 3.5, 1.5, 120, 72, 1.2, 60))

    # Strategy 10: Quick Scalp — fast in/out, needs big initial move
    push!(s, IntradayStrategy("QuickScalp-2hr",
        [MACDConfig("5m-Fast", 5, 13, 6, 0.0), MACDConfig("5m-Scalp", 3, 10, 4, 0.0)],
        60.0, 100.0, 1.5, 0.8, 24, 24, 0.5, 12))

    return s
end

mutable struct TradeRecord
    wins::Int; losses::Int; total_pnl::Float64; streak::Int; max_streak::Int; trades::Vector{Float64}
end
TradeRecord() = TradeRecord(0, 0, 0.0, 0, 0, Float64[])

function run_intraday_backtest(prices, volumes, dates, strat::IntradayStrategy, cost_frac::Float64)
    n = length(prices)
    rec = TradeRecord()
    warmup = max(maximum(c.slow + c.signal for c in strat.configs) + 10, strat.trend_lookback + 10)

    idx = warmup + 1
    last_trade_bar = 0

    while idx <= n - strat.max_hold_bars - 2
        # Cooldown
        if idx - last_trade_bar < strat.cooldown_bars
            idx += 1; continue
        end

        window = prices[max(1, idx - warmup * 2):idx]

        # Evaluate MACD signals
        signals = [evaluate_macd(window, c) for c in strat.configs]
        consensus = macd_consensus(signals)

        if consensus.direction in (:buy, :sell) &&
           consensus.confidence >= strat.min_confidence &&
           consensus.agreement_pct >= strat.min_consensus

            direction = consensus.direction

            # Trend filter
            if strat.trend_lookback > 0 && idx > strat.trend_lookback
                trend = (prices[idx] - prices[idx - strat.trend_lookback]) / prices[idx - strat.trend_lookback] * 100
                if direction == :buy && trend < -strat.min_trend_pct
                    idx += 1; continue
                elseif direction == :sell && trend > strat.min_trend_pct
                    idx += 1; continue
                end
            end

            # Simulate trade
            entry_price = prices[min(idx + 1, n)]
            exit_price = entry_price
            exit_reason = :time_expired
            bars_held = 0

            for j in (idx + 2):min(idx + strat.max_hold_bars, n)
                bars_held += 1
                cp = prices[j]
                pnl = direction == :buy ? (cp / entry_price - 1.0) * 100 : (1.0 - cp / entry_price) * 100

                if pnl >= strat.tp_pct
                    exit_price = cp; exit_reason = :tp; break
                elseif pnl <= -strat.sl_pct
                    exit_price = cp; exit_reason = :sl; break
                end
                exit_price = cp
            end

            raw_pnl = direction == :buy ? (exit_price / entry_price - 1.0) * 100 : (1.0 - exit_price / entry_price) * 100
            net_pnl = raw_pnl - cost_frac * 100

            push!(rec.trades, net_pnl)
            rec.total_pnl += net_pnl
            if net_pnl > 0
                rec.wins += 1; rec.streak = rec.streak > 0 ? rec.streak + 1 : 1
            else
                rec.losses += 1; rec.streak = rec.streak < 0 ? rec.streak - 1 : -1
            end
            rec.max_streak = max(rec.max_streak, rec.streak)

            last_trade_bar = idx + bars_held
            idx = last_trade_bar + 1
            continue
        end
        idx += 1
    end
    return rec
end

function mutate_intraday(base::IntradayStrategy, gen::Int)
    tp = clamp(base.tp_pct + (rand() - 0.5) * 1.5, 1.0, 6.0)
    sl = clamp(base.sl_pct + (rand() - 0.5) * 1.0, 0.5, 4.0)
    hold = clamp(base.max_hold_bars + rand(-30:30), 24, 200)
    conf = clamp(base.min_confidence + (rand() - 0.5) * 15, 40.0, 80.0)
    cons = clamp(base.min_consensus + (rand() - 0.5) * 20, 30.0, 100.0)
    cool = clamp(base.cooldown_bars + rand(-10:10), 6, 80)
    trend_lb = clamp(base.trend_lookback + rand(-20:20), 12, 120)
    trend_pct = clamp(base.min_trend_pct + (rand() - 0.5) * 0.5, 0.0, 2.0)

    # Mutate MACD params sometimes
    configs = copy(base.configs)
    if rand() < 0.3 && !isempty(configs)
        i = rand(1:length(configs))
        c = configs[i]
        nf = clamp(c.fast + rand(-2:2), 2, 20)
        ns = clamp(c.slow + rand(-4:4), nf + 2, 50)
        ng = clamp(c.signal + rand(-2:2), 2, 15)
        configs[i] = MACDConfig("$(c.name)-g$(gen)", nf, ns, ng, 0.0)
    end

    IntradayStrategy("$(base.name)-g$(gen)", configs, conf, cons, tp, sl, hold, trend_lb, trend_pct, cool)
end

function main()
    ticker = isempty(ARGS) ? "SOL-USD" : ARGS[1]
    target_streak = 10
    max_rounds = 40

    for i in eachindex(ARGS)
        if ARGS[i] == "--target-streak" && i < length(ARGS); target_streak = parse(Int, ARGS[i+1]); end
        if ARGS[i] == "--rounds" && i < length(ARGS); max_rounds = parse(Int, ARGS[i+1]); end
    end

    asset_type = detect_asset_type(ticker)
    costs = realistic_costs(asset_type)
    cost_frac = round_trip_cost_fraction(costs)

    println("\n╔══════════════════════════════════════════════════════════════╗")
    println("║   INTRADAY STRATEGY LAB — 5-Minute Calibration            ║")
    println("╚══════════════════════════════════════════════════════════════╝")
    println("  Asset:     $(uppercase(ticker)) ($asset_type)")
    @printf("  Costs:     %.0f bps RT (need >%.2f%% per trade)\n", round_trip_cost_bps(costs), cost_frac * 100 * 1.5)
    println("  Target:    $target_streak consecutive wins")

    println("\n  Fetching 5-minute data...")
    data = fetch_binance_klines(ticker; interval="5m", start_date=today() - Day(150), end_date=today())
    prices = data.adj; volumes = data.volume; dates = data.dates
    returns = diff(log.(prices))
    vol_5m = std(returns) * 100
    println("  Loaded: $(length(prices)) bars ($(dates[1]) → $(dates[end]))")
    @printf("  5-min vol: %.3f%% | Est daily: %.2f%%\n", vol_5m, vol_5m * sqrt(288))

    strategies = generate_intraday_strategies()
    println("  Strategies: $(length(strategies)) intraday configs")

    best_overall_streak = 0
    best_overall_name = ""

    for rnd in 1:max_rounds
        println("\n" * "═" ^ 64)
        @printf("  ROUND %d/%d — Testing %d strategies\n", rnd, max_rounds, length(strategies))
        println("═" ^ 64)

        results = Tuple{String, TradeRecord}[]
        for strat in strategies
            rec = run_intraday_backtest(prices, volumes, dates, strat, cost_frac)
            push!(results, (strat.name, rec))
        end

        sort!(results, by=x -> begin
            r = x[2]; nt = r.wins + r.losses
            nt == 0 && return -999.0
            wr = r.wins / nt
            pf = r.total_pnl > 0 ? 1.0 + r.total_pnl / max(1.0, abs(sum(t for t in r.trades if t < 0; init=0.0))) : r.total_pnl / 100
            wr * (1 + r.max_streak / 5.0) * min(pf, 5.0)
        end, rev=true)

        println("\n  ┌────────────────────────────┬───────┬────────┬──────┬────────┬──────────┐")
        println("  │ Strategy                   │Trades │Win Rate│Streak│  PnL   │   PF     │")
        println("  ├────────────────────────────┼───────┼────────┼──────┼────────┼──────────┤")
        for (name, r) in results
            nt = r.wins + r.losses
            nt == 0 && continue
            wr = r.wins / nt * 100
            wp = sum(t for t in r.trades if t > 0; init=0.0)
            lp = abs(sum(t for t in r.trades if t < 0; init=0.0))
            pf = lp > 0 ? wp / lp : (wp > 0 ? 99.0 : 0.0)
            pnl_s = r.total_pnl >= 0 ? "+$(round(r.total_pnl, digits=1))%" : "$(round(r.total_pnl, digits=1))%"
            @printf("  │ %-26s │ %5d │ %5.1f%% │  %+3d │%7s │ %8.2f │\n",
                    first(name, 26), nt, wr, r.max_streak, pnl_s, pf)
        end
        println("  └────────────────────────────┴───────┴────────┴──────┴────────┴──────────┘")

        # Check target
        for (name, r) in results
            if r.max_streak >= target_streak
                println("\n  ★ TARGET HIT! $name achieved $(r.max_streak) consecutive wins!")
                nt = r.wins + r.losses
                @printf("    Win Rate: %.1f%% | Trades: %d | PnL: %+.1f%%\n", r.wins/nt*100, nt, r.total_pnl)

                # Print full report and exit
                println("\n╔══════════════════════════════════════════════════════════════╗")
                println("║   INTRADAY LAB RESULTS — TARGET ACHIEVED                   ║")
                @printf("║  Best: %-52s║\n", name)
                @printf("║  Streak: %-50d║\n", r.max_streak)
                @printf("║  Win Rate: %-48s║\n", "$(round(r.wins/nt*100, digits=1))%")
                @printf("║  Trades: %-50d║\n", nt)
                @printf("║  Total PnL: %-46s║\n", "$(round(r.total_pnl, digits=1))%")
                println("╚══════════════════════════════════════════════════════════════╝")
                return
            end
            if r.max_streak > best_overall_streak
                best_overall_streak = r.max_streak
                best_overall_name = name
            end
        end

        @printf("  Best streak so far: %d (%s)\n", best_overall_streak, best_overall_name)

        # Evolve: keep top 5, mutate top 3, keep base set
        top = results[1:min(5, length(results))]
        new_strats = IntradayStrategy[]

        # Keep original winners
        for (name, _) in top
            orig = findfirst(s -> s.name == name, strategies)
            orig !== nothing && push!(new_strats, strategies[orig])
        end

        # Mutate top 3
        for (name, _) in top[1:min(3, length(top))]
            orig = findfirst(s -> s.name == name, strategies)
            if orig !== nothing
                push!(new_strats, mutate_intraday(strategies[orig], rnd))
                push!(new_strats, mutate_intraday(strategies[orig], rnd + 100))  # 2 mutations each
            end
        end

        # Fresh base strategies
        for s in generate_intraday_strategies()
            any(ns -> ns.name == s.name, new_strats) || push!(new_strats, s)
        end

        strategies = new_strats
    end

    println("\n╔══════════════════════════════════════════════════════════════╗")
    println("║   INTRADAY LAB RESULTS                                     ║")
    @printf("║  Best streak: %-44d║\n", best_overall_streak)
    @printf("║  Best strategy: %-42s║\n", best_overall_name)
    @printf("║  Rounds: %-49d║\n", max_rounds)
    println("╚══════════════════════════════════════════════════════════════╝")
end

main()
