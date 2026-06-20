#!/usr/bin/env julia
# ── QuantEngine Live Trading Simulation ──────────────────────
# Simulates real-time trading by walking through historical data
# bar-by-bar, using learned MACD strategies to make decisions.
# The system only sees past data at each decision point (no look-ahead).
#
# Usage:
#   julia --project=. bin/run_live_sim.jl SOL-USD --interval 5m --days 150
#   julia --project=. bin/run_live_sim.jl BE --interval 1d --days 150

using QuantEngine
using Printf
using Statistics
using Dates

# ── Winning strategies from Strategy Lab (learned) ───────────
# These were the top performers across multiple assets:

function get_learned_strategies()
    # Strategy 1: ClassicMACD-Trend (best on BTC-USD: 55.7% WR, 1.81 PF)
    classic_trend = (
        name = "ClassicMACD-Trend",
        configs = [MACDConfig("MACD-Classic", 12, 26, 9, 0.0)],
        entry_threshold = 50.0,
        consensus_min = 50.0,
        tp_mult = 2.0,
        sl_mult = 1.0,
        max_hold = 25,
        trend_filter = true,
        volume_filter = false,
    )

    # Strategy 2: TripleMACD-Relaxed (best on ETH-USD: 63.9% WR, 2.09 PF, 10-streak!)
    triple_relaxed = (
        name = "TripleMACD-Relaxed",
        configs = [
            MACDConfig("MACD-9/15/3", 9, 15, 3, 0.0),
            MACDConfig("MACD-4/16/3", 4, 16, 3, 0.0),
            MACDConfig("MACD-6/20/15", 6, 20, 15, 50.0),
        ],
        entry_threshold = 50.0,
        consensus_min = 66.0,
        tp_mult = 2.5,
        sl_mult = 1.5,
        max_hold = 30,
        trend_filter = false,
        volume_filter = false,
    )

    # Strategy 3: AllMACD-Consensus (best on MSFT: 73.3% WR, 2.89 PF)
    all_consensus = (
        name = "AllMACD-Consensus",
        configs = [
            MACDConfig("MACD-Classic", 12, 26, 9, 0.0),
            MACDConfig("MACD-Fast", 5, 13, 6, 0.0),
            MACDConfig("MACD-Momentum", 8, 21, 5, 0.0),
            MACDConfig("MACD-9/15/3", 9, 15, 3, 0.0),
        ],
        entry_threshold = 65.0,
        consensus_min = 75.0,
        tp_mult = 3.0,
        sl_mult = 1.0,
        max_hold = 30,
        trend_filter = true,
        volume_filter = false,
    )

    # Strategy 4: TripleMACD-Strict (best on MSFT: 60% WR, 1.49 PF)
    triple_strict = (
        name = "TripleMACD-Strict",
        configs = [
            MACDConfig("MACD-9/15/3", 9, 15, 3, 0.0),
            MACDConfig("MACD-4/16/3", 4, 16, 3, 0.0),
            MACDConfig("MACD-6/20/15", 6, 20, 15, 50.0),
        ],
        entry_threshold = 60.0,
        consensus_min = 100.0,
        tp_mult = 2.0,
        sl_mult = 1.0,
        max_hold = 20,
        trend_filter = true,
        volume_filter = false,
    )

    return [classic_trend, triple_relaxed, all_consensus, triple_strict]
end

# ── Trade record ─────────────────────────────────────────────
struct LiveTrade
    trade_num::Int
    strategy::String
    direction::Symbol
    entry_bar::Int
    exit_bar::Int
    entry_price::Float64
    exit_price::Float64
    entry_time::DateTime
    exit_time::DateTime
    size_dollars::Float64
    pnl_dollars::Float64
    pnl_pct::Float64
    exit_reason::Symbol
    bars_held::Int
end

# ── Live simulation engine ───────────────────────────────────
function run_live_simulation(prices::Vector{Float64}, volumes::Vector{Float64},
                             dates::Vector{DateTime}, asset_type::Symbol,
                             ticker::String; initial_capital::Float64=10000.0,
                             verbose::Bool=true)
    n = length(prices)
    strategies = get_learned_strategies()
    costs = realistic_costs(asset_type)
    cost_frac = round_trip_cost_fraction(costs)

    # State
    capital = initial_capital
    peak_capital = initial_capital
    trades = LiveTrade[]
    equity_curve = Float64[initial_capital]
    in_position = false
    position_entry_bar = 0
    position_entry_price = 0.0
    position_direction = :hold
    position_strategy = ""
    position_tp = 0.0
    position_sl = 0.0
    position_max_hold = 0
    position_size = 0.0
    consecutive_wins = 0
    max_consecutive_wins = 0
    daily_pnl = 0.0

    # Warmup period: need enough bars for slowest MACD (26 slow + 9 signal + buffer)
    warmup = 80
    if n < warmup + 20
        error("Need at least $(warmup + 20) bars, got $n")
    end

    # Calculate rolling volatility
    returns = diff(log.(prices))

    verbose && println("\n  Starting live simulation: $(n) bars, warmup=$(warmup)")
    verbose && println("  Initial capital: \$$(initial_capital)")
    verbose && println("  Strategies: $(join([s.name for s in strategies], ", "))")
    verbose && println()

    for bar in (warmup+1):n
        # ── Position management (check exits first) ──────────
        if in_position
            current_price = prices[bar]
            bars_held = bar - position_entry_bar

            pnl_pct = if position_direction == :buy
                (current_price / position_entry_price - 1.0) * 100.0
            else
                (1.0 - current_price / position_entry_price) * 100.0
            end

            exit_reason = nothing

            if pnl_pct >= position_tp
                exit_reason = :take_profit
            elseif pnl_pct <= -position_sl
                exit_reason = :stop_loss
            elseif bars_held >= position_max_hold
                exit_reason = :time_expired
            end

            if exit_reason !== nothing
                # Close position
                net_pnl_pct = pnl_pct - cost_frac * 100.0
                pnl_dollars = position_size * net_pnl_pct / 100.0
                capital += pnl_dollars
                peak_capital = max(peak_capital, capital)

                trade = LiveTrade(
                    length(trades) + 1, position_strategy, position_direction,
                    position_entry_bar, bar, position_entry_price, current_price,
                    dates[position_entry_bar], dates[bar],
                    position_size, pnl_dollars, net_pnl_pct, exit_reason, bars_held
                )
                push!(trades, trade)

                if net_pnl_pct > 0
                    consecutive_wins += 1
                    max_consecutive_wins = max(max_consecutive_wins, consecutive_wins)
                else
                    consecutive_wins = 0
                end

                if verbose
                    emoji = net_pnl_pct > 0 ? "W" : "L"
                    pnl_str = pnl_dollars >= 0 ? "+\$$(round(pnl_dollars, digits=2))" : "-\$$(round(abs(pnl_dollars), digits=2))"
                    @printf("  [%s] #%d %s %s %s | %.2f → %.2f | %s (%+.1f%%) | %s %d bars | Cap: \$%.0f",
                            emoji, trade.trade_num, trade.strategy,
                            uppercase(string(position_direction)),
                            exit_reason == :take_profit ? "TP" : exit_reason == :stop_loss ? "SL" : "TIME",
                            position_entry_price, current_price,
                            pnl_str, net_pnl_pct, "", bars_held, capital)
                    if consecutive_wins >= 3
                        print(" [streak: $(consecutive_wins)]")
                    end
                    println()
                end

                in_position = false
            end
        end

        # ── Signal generation (only when flat) ───────────────
        if !in_position && bar < n - 5  # need room for a trade
            window = prices[max(1, bar-warmup*2):bar]
            vol_window = bar > 60 ? returns[max(1,bar-60):bar-1] : returns[max(1,bar-20):bar-1]
            daily_vol = std(vol_window)
            daily_vol = max(daily_vol, 0.003)

            # Evaluate all strategies, pick the best signal
            best_signal = nothing
            best_confidence = 0.0
            best_strat = nothing

            for strat in strategies
                signals = [evaluate_macd(window, c) for c in strat.configs]
                consensus = macd_consensus(signals)

                if consensus.direction in (:buy, :sell) &&
                   consensus.confidence >= strat.entry_threshold &&
                   consensus.agreement_pct >= strat.consensus_min

                    direction = consensus.direction

                    # Trend filter
                    if strat.trend_filter && length(window) >= 20
                        trend = (window[end] - window[end-19]) / window[end-19]
                        if direction == :buy && trend < -0.02
                            continue
                        elseif direction == :sell && trend > 0.02
                            continue
                        end
                    end

                    # Volume filter
                    if strat.volume_filter && bar > 20
                        recent_vol = mean(volumes[max(1,bar-4):bar])
                        avg_vol = mean(volumes[max(1,bar-19):bar])
                        if recent_vol < avg_vol * 0.8
                            continue
                        end
                    end

                    if consensus.confidence > best_confidence
                        best_confidence = consensus.confidence
                        best_signal = direction
                        best_strat = strat
                    end
                end
            end

            # Enter position if we have a signal
            if best_signal !== nothing && best_strat !== nothing
                position_entry_bar = bar
                position_entry_price = prices[min(bar + 1, n)]  # fill next bar
                position_direction = best_signal
                position_strategy = best_strat.name

                # Position sizing: 5% of capital (conservative)
                position_size = capital * 0.05

                # TP/SL from volatility
                tp = daily_vol * sqrt(best_strat.max_hold) * best_strat.tp_mult * 100.0
                sl = daily_vol * sqrt(best_strat.max_hold) * best_strat.sl_mult * 100.0
                position_tp = clamp(tp, 0.3, 30.0)
                position_sl = clamp(sl, 0.2, 15.0)
                position_max_hold = best_strat.max_hold

                in_position = true
            end
        end

        push!(equity_curve, capital)
    end

    return (trades=trades, equity_curve=equity_curve, final_capital=capital,
            peak_capital=peak_capital, max_consecutive_wins=max_consecutive_wins)
end

# ── Report generation ────────────────────────────────────────
function print_live_report(ticker::String, asset_type::Symbol, result, initial_capital::Float64,
                           n_bars::Int, interval::String, dates_range::Tuple)
    trades = result.trades
    n_trades = length(trades)

    if n_trades == 0
        println("  No trades executed.")
        return
    end

    wins = count(t -> t.pnl_pct > 0, trades)
    losses = n_trades - wins
    win_rate = wins / n_trades * 100
    total_pnl = sum(t -> t.pnl_dollars, trades)
    total_pnl_pct = (result.final_capital / initial_capital - 1.0) * 100
    avg_win = wins > 0 ? mean(t.pnl_pct for t in trades if t.pnl_pct > 0) : 0.0
    avg_loss = losses > 0 ? mean(t.pnl_pct for t in trades if t.pnl_pct <= 0) : 0.0
    win_pnl = sum(t.pnl_dollars for t in trades if t.pnl_dollars > 0; init=0.0)
    loss_pnl = abs(sum(t.pnl_dollars for t in trades if t.pnl_dollars < 0; init=0.0))
    pf = loss_pnl > 0 ? win_pnl / loss_pnl : Inf
    avg_hold = mean(t.bars_held for t in trades)
    max_dd = 0.0
    peak = initial_capital
    for eq in result.equity_curve
        peak = max(peak, eq)
        dd = (peak - eq) / peak * 100
        max_dd = max(max_dd, dd)
    end

    # Strategy breakdown
    strat_stats = Dict{String, NamedTuple}()
    for s in unique(t.strategy for t in trades)
        strades = filter(t -> t.strategy == s, trades)
        sw = count(t -> t.pnl_pct > 0, strades)
        sn = length(strades)
        spnl = sum(t.pnl_dollars for t in strades)
        strat_stats[s] = (trades=sn, wins=sw, win_rate=sw/sn*100, pnl=spnl)
    end

    # Exit reason breakdown
    tp_count = count(t -> t.exit_reason == :take_profit, trades)
    sl_count = count(t -> t.exit_reason == :stop_loss, trades)
    time_count = count(t -> t.exit_reason == :time_expired, trades)

    costs = realistic_costs(asset_type)

    println()
    println("╔══════════════════════════════════════════════════════════════════════╗")
    println("║           LIVE SIMULATION REPORT — $(rpad(ticker, 36))║")
    println("╠══════════════════════════════════════════════════════════════════════╣")
    @printf("║  Data:              %-48s║\n", "$(n_bars) bars @ $(interval) interval")
    @printf("║  Period:            %-48s║\n", "$(Dates.format(dates_range[1], "yyyy-mm-dd")) → $(Dates.format(dates_range[2], "yyyy-mm-dd"))")
    @printf("║  Costs:             %-48s║\n", "$(round(round_trip_cost_bps(costs), digits=0)) bps round-trip")
    println("╠══════════════════════════════════════════════════════════════════════╣")
    println("║  PERFORMANCE                                                        ║")
    @printf("║  Initial Capital:   \$%-47s║\n", "$(round(initial_capital, digits=2))")
    @printf("║  Final Capital:     \$%-47s║\n", "$(round(result.final_capital, digits=2))")
    pnl_str = total_pnl >= 0 ? "+\$$(round(total_pnl, digits=2)) (+$(round(total_pnl_pct, digits=1))%)" : "-\$$(round(abs(total_pnl), digits=2)) ($(round(total_pnl_pct, digits=1))%)"
    @printf("║  Total PnL:         %-48s║\n", pnl_str)
    @printf("║  Max Drawdown:      %-48s║\n", "$(round(max_dd, digits=1))%")
    @printf("║  Peak Capital:      \$%-47s║\n", "$(round(result.peak_capital, digits=2))")
    println("╠══════════════════════════════════════════════════════════════════════╣")
    println("║  TRADES                                                             ║")
    @printf("║  Total Trades:      %-48d║\n", n_trades)
    @printf("║  Wins / Losses:     %-48s║\n", "$wins / $losses")
    @printf("║  Win Rate:          %-48s║\n", "$(round(win_rate, digits=1))%")
    @printf("║  Profit Factor:     %-48s║\n", "$(round(pf, digits=2))")
    @printf("║  Avg Win:           %-48s║\n", "+$(round(avg_win, digits=2))%")
    @printf("║  Avg Loss:          %-48s║\n", "$(round(avg_loss, digits=2))%")
    @printf("║  Avg Hold:          %-48s║\n", "$(round(avg_hold, digits=1)) bars")
    @printf("║  Max Win Streak:    %-48d║\n", result.max_consecutive_wins)
    println("╠══════════════════════════════════════════════════════════════════════╣")
    println("║  EXIT REASONS                                                       ║")
    @printf("║  Take Profit:       %-48s║\n", "$(tp_count) ($(round(tp_count/n_trades*100, digits=0))%)")
    @printf("║  Stop Loss:         %-48s║\n", "$(sl_count) ($(round(sl_count/n_trades*100, digits=0))%)")
    @printf("║  Time Expired:      %-48s║\n", "$(time_count) ($(round(time_count/n_trades*100, digits=0))%)")
    println("╠══════════════════════════════════════════════════════════════════════╣")
    println("║  STRATEGY BREAKDOWN                                                 ║")
    for (name, stats) in sort(collect(strat_stats), by=x->x[2].pnl, rev=true)
        pnl_str = stats.pnl >= 0 ? "+\$$(round(stats.pnl, digits=2))" : "-\$$(round(abs(stats.pnl), digits=2))"
        @printf("║  %-22s %3d trades  %5.1f%% WR  %-19s║\n",
                name, stats.trades, stats.win_rate, pnl_str)
    end
    println("╠══════════════════════════════════════════════════════════════════════╣")

    # Print last 15 trades
    println("║  RECENT TRADES (last 15)                                            ║")
    println("║  ─────────────────────────────────────────────────────────────────── ║")
    for t in trades[max(1,end-14):end]
        emoji = t.pnl_pct > 0 ? "W" : "L"
        pnl = t.pnl_dollars >= 0 ? "+\$$(round(t.pnl_dollars, digits=2))" : "-\$$(round(abs(t.pnl_dollars), digits=2))"
        @printf("║  [%s] #%-3d %-15s %-4s %6.2f→%-6.2f %8s %+5.1f%% %3db %-4s║\n",
                emoji, t.trade_num, first(t.strategy, 15),
                uppercase(string(t.direction)),
                t.entry_price, t.exit_price,
                pnl, t.pnl_pct, t.bars_held,
                t.exit_reason == :take_profit ? "TP" : t.exit_reason == :stop_loss ? "SL" : "TIME")
    end
    println("╚══════════════════════════════════════════════════════════════════════╝")
end

# ── Main ─────────────────────────────────────────────────────
function main()
    if isempty(ARGS)
        println("Usage: julia --project=. bin/run_live_sim.jl TICKER [--interval 5m] [--days 150]")
        return
    end

    ticker = ARGS[1]
    interval = "5m"
    days = 150

    for i in eachindex(ARGS)
        if ARGS[i] == "--interval" && i < length(ARGS)
            interval = ARGS[i+1]
        elseif ARGS[i] == "--days" && i < length(ARGS)
            days = parse(Int, ARGS[i+1])
        end
    end

    asset_type = detect_asset_type(ticker)
    display = uppercase(ticker)

    println()
    println("╔══════════════════════════════════════════════════════════════╗")
    println("║     LIVE TRADING SIMULATION — Using Learned Strategies     ║")
    println("╚══════════════════════════════════════════════════════════════╝")
    println("  Asset:     $display ($asset_type)")
    println("  Interval:  $interval")
    println("  Period:    last $days days")
    println()

    # Fetch data
    println("  Fetching data...")
    local prices, volumes, dates, high, low

    if asset_type == :crypto
        data = fetch_binance_klines(ticker; interval=interval,
                                     start_date=today()-Day(days), end_date=today())
        prices = data.adj
        volumes = data.volume
        dates = data.dates
        high = data.high
        low = data.low
    else
        # Stocks: use daily data (no free minute source)
        data = fetch_ohlcv(display; period="1y")
        prices = data.adj
        volumes = data.volume
        dates = data.dates
        high = data.high
        low = data.low
        interval = "1d"
        println("  Note: Using daily bars for stocks (no free minute data source)")
    end

    println("  Loaded: $(length(prices)) bars ($(dates[1]) → $(dates[end]))")

    costs = realistic_costs(asset_type)
    @printf("  Costs: %.0f bps round-trip\n", round_trip_cost_bps(costs))
    println()
    println("  ── Simulation Running ──────────────────────────────────────")

    # Run simulation
    initial_capital = 10000.0
    result = run_live_simulation(prices, volumes, dates, asset_type, ticker;
                                 initial_capital=initial_capital, verbose=true)

    # Print full report
    print_live_report(ticker, asset_type, result, initial_capital,
                      length(prices), interval, (dates[1], dates[end]))
end

main()
