#!/usr/bin/env julia
# ── QuantEngine Strategy Lab ─────────────────────────────────
# Automated strategy testing and learning system.
# Tests multiple MACD configurations + model combinations on real data.
# Learns from wins/losses and adapts until finding profitable configs.
#
# Usage:
#   julia --project=. bin/run_strategy_lab.jl BTC-USD
#   julia --project=. bin/run_strategy_lab.jl AAPL --target-streak 10
#   julia --project=. bin/run_strategy_lab.jl ETH-USD --rounds 50

using QuantEngine
using Printf
using Statistics
using Dates

# ── Strategy Performance Tracker ─────────────────────────────
mutable struct StrategyRecord
    name::String
    wins::Int
    losses::Int
    total_pnl::Float64
    max_streak::Int        # longest consecutive win streak
    current_streak::Int    # current streak (positive = wins)
    trades::Vector{Float64}  # PnL per trade
    avg_hold_bars::Float64
    best_pnl::Float64
    worst_pnl::Float64
end

StrategyRecord(name) = StrategyRecord(name, 0, 0, 0.0, 0, 0, Float64[], 0.0, -Inf, Inf)

function record_trade!(rec::StrategyRecord, pnl::Float64, hold_bars::Int)
    push!(rec.trades, pnl)
    rec.total_pnl += pnl
    rec.avg_hold_bars = (rec.avg_hold_bars * (length(rec.trades) - 1) + hold_bars) / length(rec.trades)
    rec.best_pnl = max(rec.best_pnl, pnl)
    rec.worst_pnl = min(rec.worst_pnl, pnl)
    if pnl > 0
        rec.wins += 1
        rec.current_streak = rec.current_streak > 0 ? rec.current_streak + 1 : 1
    else
        rec.losses += 1
        rec.current_streak = rec.current_streak < 0 ? rec.current_streak - 1 : -1
    end
    rec.max_streak = max(rec.max_streak, rec.current_streak)
end

win_rate(r::StrategyRecord) = r.wins + r.losses > 0 ? r.wins / (r.wins + r.losses) * 100 : 0.0
profit_factor(r::StrategyRecord) = begin
    wins = sum(t for t in r.trades if t > 0; init=0.0)
    losses = abs(sum(t for t in r.trades if t < 0; init=0.0))
    losses > 0 ? wins / losses : wins > 0 ? Inf : 0.0
end

# ── MACD Strategy Configurations ─────────────────────────────
struct StrategyConfig
    name::String
    macd_configs::Vector{MACDConfig}
    entry_threshold::Float64     # min confidence to enter (0-100)
    consensus_required::Float64  # min % agreement across configs
    tp_multiplier::Float64       # take-profit as multiple of daily vol
    sl_multiplier::Float64       # stop-loss as multiple of daily vol
    max_hold_bars::Int           # max bars to hold
    use_trend_filter::Bool       # only trade with trend
    use_volume_filter::Bool      # require volume confirmation
end

# ── Generate strategy configurations to test ─────────────────
function generate_strategies()::Vector{StrategyConfig}
    strategies = StrategyConfig[]

    # User-requested MACD configs
    macd_9_15_3 = MACDConfig("MACD-9/15/3", 9, 15, 3, 0.0)
    macd_4_16_3 = MACDConfig("MACD-4/16/3", 4, 16, 3, 0.0)
    macd_6_20_15 = MACDConfig("MACD-6/20/15", 6, 20, 15, 50.0)
    macd_classic = MACDConfig("MACD-Classic", 12, 26, 9, 0.0)
    macd_fast = MACDConfig("MACD-Fast", 5, 13, 6, 0.0)
    macd_scalp = MACDConfig("MACD-Scalp", 2, 8, 3, 0.0)
    macd_momentum = MACDConfig("MACD-Momentum", 8, 21, 5, 0.0)

    # Strategy 1: User's MACD triple stack (all 3 must agree)
    push!(strategies, StrategyConfig(
        "TripleMACD-Strict",
        [macd_9_15_3, macd_4_16_3, macd_6_20_15],
        60.0, 100.0, 2.0, 1.0, 20, true, false
    ))

    # Strategy 2: Triple MACD with relaxed consensus
    push!(strategies, StrategyConfig(
        "TripleMACD-Relaxed",
        [macd_9_15_3, macd_4_16_3, macd_6_20_15],
        50.0, 66.0, 2.5, 1.5, 30, false, false
    ))

    # Strategy 3: Fast MACD only (short-term scalping)
    push!(strategies, StrategyConfig(
        "FastMACD-Scalp",
        [macd_scalp, macd_fast],
        55.0, 50.0, 1.5, 0.8, 10, false, false
    ))

    # Strategy 4: Classic MACD with trend filter
    push!(strategies, StrategyConfig(
        "ClassicMACD-Trend",
        [macd_classic],
        50.0, 50.0, 2.0, 1.0, 25, true, false
    ))

    # Strategy 5: Momentum MACD combo
    push!(strategies, StrategyConfig(
        "MomentumMACD",
        [macd_momentum, macd_9_15_3],
        55.0, 50.0, 2.5, 1.2, 20, true, false
    ))

    # Strategy 6: All MACDs must agree (highest conviction)
    push!(strategies, StrategyConfig(
        "AllMACD-Consensus",
        [macd_classic, macd_fast, macd_momentum, macd_9_15_3],
        65.0, 75.0, 3.0, 1.0, 30, true, true
    ))

    # Strategy 7: Fast scalp with tight stops
    push!(strategies, StrategyConfig(
        "TightScalp",
        [macd_scalp],
        45.0, 50.0, 1.0, 0.5, 5, false, false
    ))

    # Strategy 8: Wide swing with patience
    push!(strategies, StrategyConfig(
        "WideSwing",
        [macd_classic, MACDConfig("MACD-Slow", 19, 39, 9, 0.0)],
        60.0, 50.0, 3.5, 2.0, 60, true, false
    ))

    # Strategy 9: MACD 4/16/3 solo (user requested)
    push!(strategies, StrategyConfig(
        "MACD-4/16/3-Solo",
        [macd_4_16_3],
        50.0, 50.0, 2.0, 1.0, 15, false, false
    ))

    # Strategy 10: MACD 9/15/3 with volume
    push!(strategies, StrategyConfig(
        "MACD-9/15/3-Volume",
        [macd_9_15_3],
        50.0, 50.0, 2.0, 1.0, 15, false, true
    ))

    # Strategy 11: Aggressive crossover scalp
    push!(strategies, StrategyConfig(
        "CrossoverScalp",
        [macd_4_16_3, macd_scalp],
        40.0, 50.0, 1.2, 0.6, 8, false, false
    ))

    # Strategy 12: Conservative momentum
    push!(strategies, StrategyConfig(
        "ConservativeMom",
        [macd_classic, macd_momentum],
        65.0, 100.0, 2.5, 1.5, 40, true, true
    ))

    return strategies
end

# ── Simulate a single trade ──────────────────────────────────
function simulate_trade(prices::Vector{Float64}, volumes::Vector{Float64},
                        entry_idx::Int, strategy::StrategyConfig,
                        direction::Symbol, daily_vol::Float64,
                        asset_type::Symbol)
    n = length(prices)
    if entry_idx >= n
        return nothing
    end

    entry_price = prices[min(entry_idx + 1, n)]  # fill next bar

    # Cost model
    costs = realistic_costs(asset_type)
    cost_frac = round_trip_cost_fraction(costs)

    # TP/SL from volatility × multipliers
    tp_pct = daily_vol * sqrt(strategy.max_hold_bars) * strategy.tp_multiplier * 100.0
    sl_pct = daily_vol * sqrt(strategy.max_hold_bars) * strategy.sl_multiplier * 100.0
    tp_pct = clamp(tp_pct, 0.3, 30.0)
    sl_pct = clamp(sl_pct, 0.2, 15.0)

    # Walk forward
    exit_idx = entry_idx
    exit_price = entry_price
    exit_reason = :time_expired
    bars_held = 0

    for idx in (entry_idx + 1):min(entry_idx + strategy.max_hold_bars, n)
        current = prices[idx]
        bars_held += 1

        pnl_pct = if direction == :buy
            (current / entry_price - 1.0) * 100.0
        else
            (1.0 - current / entry_price) * 100.0
        end

        if pnl_pct >= tp_pct
            exit_idx = idx; exit_price = current; exit_reason = :take_profit; break
        elseif pnl_pct <= -sl_pct
            exit_idx = idx; exit_price = current; exit_reason = :stop_loss; break
        end

        exit_idx = idx; exit_price = current
    end

    # Calculate PnL after costs
    raw_pnl_pct = if direction == :buy
        (exit_price / entry_price - 1.0) * 100.0
    else
        (1.0 - exit_price / entry_price) * 100.0
    end
    net_pnl_pct = raw_pnl_pct - cost_frac * 100.0

    return (pnl_pct=net_pnl_pct, bars_held=bars_held, exit_reason=exit_reason,
            entry_price=entry_price, exit_price=exit_price, direction=direction)
end

# ── Run a single strategy across all available data ──────────
function backtest_strategy(prices::Vector{Float64}, volumes::Vector{Float64},
                           returns::Vector{Float64}, strategy::StrategyConfig,
                           asset_type::Symbol; verbose::Bool=false)
    n = length(prices)
    record = StrategyRecord(strategy.name)

    # Need enough data for the slowest MACD
    max_slow = maximum(c.slow + c.signal for c in strategy.macd_configs)
    lookback = max(max_slow + 20, 50)

    daily_vol = std(returns[max(1, length(returns)-59):end])
    daily_vol = max(daily_vol, 0.005)  # floor at 0.5%

    # Scan through data looking for entry signals
    idx = lookback
    while idx <= n - 5  # need at least 5 bars after entry
        # Evaluate all MACD configs on data up to current bar
        window = prices[max(1, idx-lookback*2):idx]

        signals = [evaluate_macd(window, c) for c in strategy.macd_configs]
        consensus = macd_consensus(signals)

        # Apply filters
        should_trade = false
        direction = consensus.direction

        if direction in (:buy, :sell) &&
           consensus.confidence >= strategy.entry_threshold &&
           consensus.agreement_pct >= strategy.consensus_required

            # Trend filter
            if strategy.use_trend_filter && length(window) >= 20
                trend = (window[end] - window[end-19]) / window[end-19]
                if direction == :buy && trend < -0.02
                    direction = :hold  # don't buy in downtrend
                elseif direction == :sell && trend > 0.02
                    direction = :hold  # don't sell in uptrend
                end
            end

            # Volume filter
            if strategy.use_volume_filter && idx > 20
                recent_vol = mean(volumes[max(1,idx-4):idx])
                avg_vol = mean(volumes[max(1,idx-19):idx])
                if recent_vol < avg_vol * 0.8
                    direction = :hold  # low volume, skip
                end
            end

            should_trade = direction in (:buy, :sell)
        end

        if should_trade
            result = simulate_trade(prices, volumes, idx, strategy, direction,
                                    daily_vol, asset_type)
            if result !== nothing
                record_trade!(record, result.pnl_pct, result.bars_held)
                if verbose
                    emoji = result.pnl_pct > 0 ? "+" : "-"
                    @printf("    [%s] %s %s @ \$%.2f → \$%.2f | %s%.1f%% (%s, %d bars)\n",
                            strategy.name, uppercase(string(result.direction)),
                            result.exit_reason == :take_profit ? "TP" :
                            result.exit_reason == :stop_loss ? "SL" : "TIME",
                            result.entry_price, result.exit_price,
                            emoji, abs(result.pnl_pct), result.exit_reason, result.bars_held)
                end
                # Skip ahead past the trade
                idx += result.bars_held + 1
                continue
            end
        end

        idx += 1
    end

    return record
end

# ── Learning Engine ──────────────────────────────────────────
mutable struct LearningEngine
    strategy_scores::Dict{String, Float64}  # strategy → score
    best_configs::Vector{Tuple{String, Float64}}  # top performers
    round::Int
    total_trades::Int
    best_streak::Int
    best_strategy::String
end

LearningEngine() = LearningEngine(Dict(), [], 0, 0, 0, "none")

function update_learning!(engine::LearningEngine, record::StrategyRecord)
    # Score = win_rate * profit_factor * (1 + max_streak/10)
    wr = win_rate(record)
    pf = profit_factor(record)
    streak_bonus = 1.0 + record.max_streak / 10.0
    score = wr * min(pf, 5.0) * streak_bonus / 100.0  # normalize

    engine.strategy_scores[record.name] = score
    engine.total_trades += length(record.trades)

    if record.max_streak > engine.best_streak
        engine.best_streak = record.max_streak
        engine.best_strategy = record.name
    end
end

function mutate_strategy(base::StrategyConfig, round_num::Int)::StrategyConfig
    # Aggressively explore parameter space — wider variance each round
    exploration = 0.3 + round_num * 0.02  # increases with rounds
    tp_adj = 1.0 + (rand() - 0.5) * exploration * 2
    sl_adj = 1.0 + (rand() - 0.5) * exploration * 2
    hold_adj = clamp(Base.round(Int, base.max_hold_bars * (0.5 + rand())), 3, 80)
    thresh_adj = clamp(base.entry_threshold + (rand() - 0.5) * 20, 30.0, 80.0)
    cons_adj = clamp(base.consensus_required + (rand() - 0.5) * 30, 30.0, 100.0)

    # Also mutate MACD parameters sometimes
    new_configs = copy(base.macd_configs)
    if rand() < 0.3 && !isempty(new_configs)
        idx = rand(1:length(new_configs))
        c = new_configs[idx]
        new_fast = clamp(c.fast + rand(-3:3), 2, 20)
        new_slow = clamp(c.slow + rand(-5:5), new_fast + 2, 50)
        new_sig = clamp(c.signal + rand(-3:3), 2, 20)
        new_thresh = max(0.0, c.threshold + (rand() - 0.5) * 20)
        new_configs[idx] = MACDConfig("$(c.name)-m$(round_num)", new_fast, new_slow, new_sig, new_thresh)
    end

    # Randomly toggle filters
    trend = rand() < 0.7 ? base.use_trend_filter : !base.use_trend_filter
    vol = rand() < 0.8 ? base.use_volume_filter : !base.use_volume_filter

    return StrategyConfig(
        "$(base.name)-v$(round_num)",
        new_configs,
        thresh_adj,
        cons_adj,
        clamp(base.tp_multiplier * tp_adj, 0.5, 5.0),
        clamp(base.sl_multiplier * sl_adj, 0.3, 3.0),
        hold_adj,
        trend,
        vol
    )
end

# ── Main ─────────────────────────────────────────────────────
function main()
    if isempty(ARGS)
        println("Usage: julia --project=. bin/run_strategy_lab.jl TICKER [--target-streak N] [--rounds N]")
        return
    end

    ticker = ARGS[1]
    target_streak = 10
    max_rounds = 30

    for i in eachindex(ARGS)
        if ARGS[i] == "--target-streak" && i < length(ARGS)
            target_streak = parse(Int, ARGS[i+1])
        elseif ARGS[i] == "--rounds" && i < length(ARGS)
            max_rounds = parse(Int, ARGS[i+1])
        end
    end

    asset_type = detect_asset_type(ticker)
    display = asset_type == :polymarket ? replace(ticker, "poly:" => "") : uppercase(ticker)

    println()
    println("╔══════════════════════════════════════════════════════════════╗")
    println("║     STRATEGY LAB — Automated Learning Engine               ║")
    println("╚══════════════════════════════════════════════════════════════╝")
    println("  Asset:          $display ($asset_type)")
    println("  Target streak:  $target_streak consecutive wins")
    println("  Max rounds:     $max_rounds")

    # Fetch data
    println("\n  Fetching historical data...")
    stock = fetch_ohlcv(display; period="5y")
    prices = stock.adj
    volumes = stock.volume
    high = stock.high
    low = stock.low
    returns = diff(log.(prices))
    println("  Data: $(length(prices)) bars ($(stock.dates[1]) → $(stock.dates[end]))")

    costs = realistic_costs(asset_type)
    @printf("  Costs: %.0f bps round-trip (min edge: %.2f%%)\n",
            round_trip_cost_bps(costs), minimum_edge_required(asset_type) * 100)

    # Initialize
    engine = LearningEngine()
    strategies = generate_strategies()
    println("  Strategies: $(length(strategies)) initial configurations")
    println()

    # ── Round loop ───────────────────────────────────────────
    found_target = false

    for rnd in 1:max_rounds
        engine.round = rnd
        println("═" ^ 64)
        @printf("  ROUND %d/%d — Testing %d strategies\n", rnd, max_rounds, length(strategies))
        println("═" ^ 64)

        round_results = StrategyRecord[]

        for strategy in strategies
            record = backtest_strategy(prices, volumes, returns, strategy,
                                       asset_type; verbose=false)
            push!(round_results, record)
            update_learning!(engine, record)
        end

        # Sort by score
        sort!(round_results, by=r -> begin
            wr = win_rate(r)
            pf = profit_factor(r)
            wr * min(pf, 5.0) * (1 + r.max_streak / 10.0) / 100.0
        end, rev=true)

        # Print results
        println()
        println("  ┌─────────────────────────────────┬───────┬────────┬──────────┬────────┬────────┐")
        println("  │ Strategy                        │ Trades│Win Rate│ PF       │ Streak │ PnL    │")
        println("  ├─────────────────────────────────┼───────┼────────┼──────────┼────────┼────────┤")
        for r in round_results
            nt = r.wins + r.losses
            if nt == 0 continue end
            wr = win_rate(r)
            pf = profit_factor(r)
            streak_str = r.max_streak > 0 ? "+$(r.max_streak)" : "$(r.current_streak)"
            pnl_str = r.total_pnl >= 0 ? "+$(round(r.total_pnl, digits=1))%" : "$(round(r.total_pnl, digits=1))%"
            @printf("  │ %-31s │ %5d │ %5.1f%% │ %8.2f │ %6s │ %6s │\n",
                    first(r.name, 31), nt, wr, pf, streak_str, pnl_str)
        end
        println("  └─────────────────────────────────┴───────┴────────┴──────────┴────────┴────────┘")

        # Check for target streak
        best_this_round = round_results[1]
        if best_this_round.max_streak >= target_streak
            found_target = true
            println()
            println("  ★ TARGET REACHED! $(best_this_round.name) achieved $(best_this_round.max_streak) consecutive wins!")
            println("    Win Rate: $(round(win_rate(best_this_round), digits=1))%")
            println("    Profit Factor: $(round(profit_factor(best_this_round), digits=2))")
            println("    Total PnL: $(round(best_this_round.total_pnl, digits=1))%")
            break
        end

        # ── Learning: Evolve strategies for next round ────────
        # Keep top 5, mutate them, add new experiments
        top_n = min(5, length(round_results))
        top_strategies = round_results[1:top_n]

        new_strategies = StrategyConfig[]

        # Keep original strategies that performed well
        for r in top_strategies
            orig = findfirst(s -> s.name == r.name, strategies)
            if orig !== nothing
                push!(new_strategies, strategies[orig])
            end
        end

        # Mutate top performers
        for r in top_strategies[1:min(3, length(top_strategies))]
            orig = findfirst(s -> s.name == r.name, strategies)
            if orig !== nothing
                mutated = mutate_strategy(strategies[orig], rnd)
                push!(new_strategies, mutated)
            end
        end

        # Add some fresh strategies from the base set
        base_strats = generate_strategies()
        for s in base_strats
            if !any(ns -> ns.name == s.name, new_strategies)
                push!(new_strategies, s)
            end
        end

        strategies = new_strategies

        println()
        @printf("  Learning: Best streak so far = %d (%s)\n",
                engine.best_streak, engine.best_strategy)
        println("  Next round: $(length(strategies)) strategies ($(top_n) kept + mutations + fresh)")
    end

    # ── Final Summary ────────────────────────────────────────
    println()
    println("╔══════════════════════════════════════════════════════════════╗")
    println("║                    STRATEGY LAB RESULTS                    ║")
    println("╠══════════════════════════════════════════════════════════════╣")
    @printf("║  Asset:          %-42s║\n", display)
    @printf("║  Rounds:         %-42d║\n", engine.round)
    @printf("║  Total trades:   %-42d║\n", engine.total_trades)
    @printf("║  Best streak:    %-42d║\n", engine.best_streak)
    @printf("║  Best strategy:  %-42s║\n", first(engine.best_strategy, 42))
    println("╠══════════════════════════════════════════════════════════════╣")

    if found_target
        println("║  ★ TARGET ACHIEVED: $(target_streak)+ consecutive winning trades!         ║")
    else
        println("║  Target of $(target_streak) consecutive wins not yet reached.             ║")
        println("║  Increase --rounds or adjust strategy parameters.          ║")
    end
    println("╚══════════════════════════════════════════════════════════════╝")

    # Print top strategies with their scores
    println("\n  Top Strategies by Score:")
    sorted_scores = sort(collect(engine.strategy_scores), by=x->x[2], rev=true)
    for (i, (name, score)) in enumerate(sorted_scores[1:min(10, length(sorted_scores))])
        @printf("    %2d. %-35s  score: %.4f\n", i, name, score)
    end
end

main()
