#!/usr/bin/env julia
# ── Multi-Timeframe Live Simulation (Approach B) ─────────────
# Daily MACD ensemble → direction bias (once per day)
# 5-min data → entry timing (pullback + L2/CVD confirmation)
# Hold 3-10 days using daily exit signals
# Limit orders → ~15 bps cost instead of 61 bps
#
# Usage:
#   julia --project=. bin/run_multitf_sim.jl BTC-USD
#   julia --project=. bin/run_multitf_sim.jl ETH-USD --days 150

using QuantEngine
using Printf
using Statistics
using Dates

# ── Multi-Timeframe Engine ───────────────────────────────────

struct DailyBias
    direction::Symbol      # :buy, :sell, :hold
    confidence::Float64    # 0-100
    strategy::String       # which strategy generated it
    daily_vol::Float64     # GARCH or rolling vol estimate
    trend_strength::Float64 # -1 to +1
end

struct MTFTrade
    num::Int
    direction::Symbol
    entry_time::DateTime
    exit_time::DateTime
    entry_price::Float64
    exit_price::Float64
    pnl_pct::Float64
    pnl_dollars::Float64
    hold_hours::Float64
    exit_reason::Symbol
    daily_bias_conf::Float64
    entry_method::String    # "pullback", "momentum", "breakout"
end

function compute_daily_bias(daily_prices::Vector{Float64})::DailyBias
    n = length(daily_prices)
    if n < 40
        return DailyBias(:hold, 0.0, "insufficient_data", 0.02, 0.0)
    end

    daily_returns = diff(log.(daily_prices))
    daily_vol = std(daily_returns[max(1,end-19):end])

    # 20-bar trend
    trend = (daily_prices[end] - daily_prices[max(1,end-19)]) / daily_prices[max(1,end-19)]
    trend_norm = clamp(trend / max(daily_vol * sqrt(20), 0.01), -1.0, 1.0)

    # Run all 4 learned MACD strategies on daily data
    configs_classic = [MACDConfig("Daily-Classic", 12, 26, 9, 0.0)]
    configs_triple = [
        MACDConfig("Daily-9/15/3", 9, 15, 3, 0.0),
        MACDConfig("Daily-4/16/3", 4, 16, 3, 0.0),
        MACDConfig("Daily-6/20/15", 6, 20, 15, 50.0),
    ]
    configs_consensus = [
        MACDConfig("Daily-Classic", 12, 26, 9, 0.0),
        MACDConfig("Daily-Fast", 5, 13, 6, 0.0),
        MACDConfig("Daily-Mom", 8, 21, 5, 0.0),
        MACDConfig("Daily-9/15/3", 9, 15, 3, 0.0),
    ]

    # Evaluate each strategy set
    sig_classic = macd_consensus([evaluate_macd(daily_prices, c) for c in configs_classic])
    sig_triple = macd_consensus([evaluate_macd(daily_prices, c) for c in configs_triple])
    sig_all = macd_consensus([evaluate_macd(daily_prices, c) for c in configs_consensus])

    # Voting: count how many strategy sets agree
    directions = [sig_classic.direction, sig_triple.direction, sig_all.direction]
    buy_votes = count(d -> d == :buy, directions)
    sell_votes = count(d -> d == :sell, directions)

    # Require majority + trend confirmation
    if buy_votes >= 2 && trend_norm > -0.3
        direction = :buy
        conf = mean([sig_classic.confidence, sig_triple.confidence, sig_all.confidence])
        # Trend filter: boost confidence if trend agrees, reduce if not
        conf *= (1.0 + trend_norm * 0.3)
        strat = buy_votes == 3 ? "unanimous_buy" : "majority_buy"
    elseif sell_votes >= 2 && trend_norm < 0.3
        direction = :sell
        conf = mean([sig_classic.confidence, sig_triple.confidence, sig_all.confidence])
        conf *= (1.0 - trend_norm * 0.3)
        strat = sell_votes == 3 ? "unanimous_sell" : "majority_sell"
    else
        direction = :hold
        conf = 0.0
        strat = "no_consensus"
    end

    return DailyBias(direction, clamp(conf, 0, 100), strat, daily_vol, trend_norm)
end

function find_5min_entry(prices_5m::Vector{Float64}, volumes_5m::Vector{Float64},
                         bias::DailyBias, window_start::Int, window_end::Int)
    # Look for entry within the 5-min window (one trading day = 288 bars)
    best_entry = nothing
    best_score = -Inf

    for i in window_start:min(window_end, length(prices_5m) - 1)
        if i < 20; continue; end

        price = prices_5m[i]
        recent = prices_5m[max(1,i-11):i]

        # Pullback detection: price dipped from recent high/low
        if bias.direction == :buy
            recent_high = maximum(prices_5m[max(1,i-24):i])
            pullback_pct = (recent_high - price) / recent_high * 100
            # Want 0.3-1.5% pullback from recent high
            if pullback_pct < 0.2 || pullback_pct > 2.0; continue; end

            # Momentum turning: short EMA crossing above longer EMA
            ema_fast = QuantEngine._ema(recent, 3)
            ema_slow = QuantEngine._ema(recent, 8)
            if length(ema_fast) < 2; continue; end
            if ema_fast[end] <= ema_slow[end]; continue; end  # need fast > slow
            if ema_fast[end-1] > ema_slow[end-1]; continue; end  # need fresh cross

            # Volume confirmation
            if i > 10
                recent_vol = mean(volumes_5m[max(1,i-4):i])
                avg_vol = mean(volumes_5m[max(1,i-19):i])
                vol_ratio = recent_vol / max(avg_vol, 1.0)
                if vol_ratio < 0.7; continue; end  # need decent volume
            else
                vol_ratio = 1.0
            end

            score = pullback_pct * vol_ratio * bias.confidence / 100
            method = "pullback_buy"

        elseif bias.direction == :sell
            recent_low = minimum(prices_5m[max(1,i-24):i])
            bounce_pct = (price - recent_low) / max(recent_low, 0.01) * 100
            if bounce_pct < 0.2 || bounce_pct > 2.0; continue; end

            ema_fast = QuantEngine._ema(recent, 3)
            ema_slow = QuantEngine._ema(recent, 8)
            if length(ema_fast) < 2; continue; end
            if ema_fast[end] >= ema_slow[end]; continue; end
            if ema_fast[end-1] < ema_slow[end-1]; continue; end

            if i > 10
                recent_vol = mean(volumes_5m[max(1,i-4):i])
                avg_vol = mean(volumes_5m[max(1,i-19):i])
                vol_ratio = recent_vol / max(avg_vol, 1.0)
                if vol_ratio < 0.7; continue; end
            else
                vol_ratio = 1.0
            end

            score = bounce_pct * vol_ratio * bias.confidence / 100
            method = "pullback_sell"
        else
            continue
        end

        if score > best_score
            best_score = score
            best_entry = (bar=i, price=price, score=score, method=method)
        end
    end

    return best_entry
end

function run_multitf_simulation(ticker::String; days::Int=150)
    asset_type = detect_asset_type(ticker)
    display = uppercase(ticker)

    println("\n╔══════════════════════════════════════════════════════════════╗")
    println("║   MULTI-TIMEFRAME SIMULATION (Daily Bias + 5-Min Entry)   ║")
    println("╚══════════════════════════════════════════════════════════════╝")

    # Fetch daily data (for bias computation)
    println("  Fetching daily data...")
    daily = fetch_ohlcv(display; period="2y")
    daily_prices = daily.adj
    daily_dates = daily.dates
    println("  Daily: $(length(daily_prices)) bars")

    # Fetch 5-min data (for entry timing)
    println("  Fetching 5-minute data...")
    minute = fetch_binance_klines(ticker; interval="5m",
                                   start_date=today() - Day(days), end_date=today())
    m_prices = minute.adj
    m_volumes = minute.volume
    m_dates = minute.dates
    println("  5-min: $(length(m_prices)) bars ($(m_dates[1]) → $(m_dates[end]))")

    # Cost model: limit orders on liquid pairs
    costs_limit = realistic_costs_limit(asset_type)
    costs_taker = realistic_costs(asset_type)
    cost_frac = round_trip_cost_fraction(costs_limit)

    @printf("  Costs (limit): %.0f bps RT | Costs (taker): %.0f bps RT\n",
            round_trip_cost_bps(costs_limit), round_trip_cost_bps(costs_taker))
    @printf("  Min edge: %.2f%%\n", cost_frac * 100 * 1.5)
    println()

    # State
    capital = 10000.0
    peak_capital = capital
    trades = MTFTrade[]
    equity_curve = Float64[capital]
    in_position = false
    pos_direction = :hold
    pos_entry_price = 0.0
    pos_entry_time = DateTime(0)
    pos_entry_bar = 0
    pos_daily_vol = 0.0
    pos_bias_conf = 0.0
    pos_entry_method = ""
    streak = 0
    max_streak = 0

    # Map daily dates to 5-min bar ranges
    # Each trading day ≈ 288 five-min bars (24hr crypto)
    bars_per_day = 288

    # Determine which daily bars fall within our 5-min data range
    min_date = Date(m_dates[1])
    max_date = Date(m_dates[end])

    # Need at least 40 daily bars before our 5-min window for bias computation
    daily_start = findfirst(d -> Date(d) >= min_date - Day(5), daily_dates)
    if daily_start === nothing || daily_start < 40
        daily_start = 40
    end

    println("  ── Simulation Running ──────────────────────────────────────")
    println("  Daily bias window: $(Date(daily_dates[daily_start])) → $(Date(daily_dates[end]))")
    println()

    # Walk through each day
    for d_idx in daily_start:length(daily_dates)
        current_date = Date(daily_dates[d_idx])
        if current_date < min_date || current_date > max_date
            continue
        end

        # ── Daily bias computation (once per day at open) ────
        bias = compute_daily_bias(daily_prices[1:d_idx])

        # ── Check position exit (daily level) ────────────────
        if in_position
            current_price = daily_prices[min(d_idx, length(daily_prices))]
            hold_days = (daily_dates[d_idx] - pos_entry_time).value / 86400000

            pnl_pct = if pos_direction == :buy
                (current_price / pos_entry_price - 1.0) * 100
            else
                (1.0 - current_price / pos_entry_price) * 100
            end

            # Exit conditions (daily level)
            tp_pct = pos_daily_vol * sqrt(7) * 200  # ~2× weekly vol in %
            sl_pct = pos_daily_vol * sqrt(3) * 100  # ~1× 3-day vol in %
            tp_pct = clamp(tp_pct, 2.0, 25.0)
            sl_pct = clamp(sl_pct, 1.5, 12.0)

            exit_reason = nothing
            if pnl_pct >= tp_pct
                exit_reason = :take_profit
            elseif pnl_pct <= -sl_pct
                exit_reason = :stop_loss
            elseif hold_days >= 10
                exit_reason = :time_expired
            elseif bias.direction != :hold && bias.direction != pos_direction && bias.confidence > 55
                exit_reason = :signal_reversal  # daily bias flipped
            end

            if exit_reason !== nothing
                net_pnl = pnl_pct - cost_frac * 100
                pnl_dollars = capital * 0.05 * net_pnl / 100  # 5% position
                capital += pnl_dollars
                peak_capital = max(peak_capital, capital)

                if net_pnl > 0
                    streak = streak > 0 ? streak + 1 : 1
                else
                    streak = streak < 0 ? streak - 1 : -1
                end
                max_streak = max(max_streak, streak)

                trade = MTFTrade(length(trades)+1, pos_direction,
                    pos_entry_time, daily_dates[d_idx],
                    pos_entry_price, current_price,
                    net_pnl, pnl_dollars, hold_days * 24,
                    exit_reason, pos_bias_conf, pos_entry_method)
                push!(trades, trade)

                emoji = net_pnl > 0 ? "W" : "L"
                pnl_s = pnl_dollars >= 0 ? "+\$$(round(pnl_dollars, digits=2))" : "-\$$(round(abs(pnl_dollars), digits=2))"
                sstr = streak >= 3 ? " [streak:$streak]" : ""
                ex_s = exit_reason == :take_profit ? "TP" : exit_reason == :stop_loss ? "SL" :
                       exit_reason == :signal_reversal ? "REV" : "TIME"
                println("  [$emoji] #$(trade.num) $(uppercase(string(pos_direction))) $ex_s | \$$(round(pos_entry_price, digits=0))→\$$(round(current_price, digits=0)) | $pnl_s ($(@sprintf("%+.1f", net_pnl))%) | $(round(hold_days*24, digits=0))hr $pos_entry_method | bias:$(round(pos_bias_conf, digits=0))%$sstr")

                in_position = false
            end
        end

        # ── Look for new entry (only when flat) ──────────────
        if !in_position && bias.direction in (:buy, :sell) && bias.confidence >= 50

            # Find the 5-min bars for this day
            day_bars = findall(dt -> Date(dt) == current_date, m_dates)
            if isempty(day_bars); continue; end

            entry = find_5min_entry(m_prices, m_volumes, bias,
                                     first(day_bars), last(day_bars))

            if entry !== nothing
                pos_entry_price = m_prices[min(entry.bar + 1, length(m_prices))]
                pos_entry_time = m_dates[entry.bar]
                pos_direction = bias.direction
                pos_daily_vol = bias.daily_vol
                pos_bias_conf = bias.confidence
                pos_entry_method = entry.method
                pos_entry_bar = entry.bar
                in_position = true
            end
        end

        push!(equity_curve, capital)
    end

    # Close any remaining position at last price
    if in_position
        current_price = daily_prices[end]
        pnl_pct = pos_direction == :buy ?
            (current_price / pos_entry_price - 1.0) * 100 :
            (1.0 - current_price / pos_entry_price) * 100
        net_pnl = pnl_pct - cost_frac * 100
        pnl_dollars = capital * 0.05 * net_pnl / 100
        capital += pnl_dollars
        peak_capital = max(peak_capital, capital)
        if net_pnl > 0; streak = streak > 0 ? streak + 1 : 1
        else; streak = streak < 0 ? streak - 1 : -1; end
        max_streak = max(max_streak, streak)
        push!(trades, MTFTrade(length(trades)+1, pos_direction,
            pos_entry_time, daily_dates[end], pos_entry_price, current_price,
            net_pnl, pnl_dollars, 0.0, :end_of_data, pos_bias_conf, pos_entry_method))
        emoji = net_pnl > 0 ? "W" : "L"
        pnl_s = pnl_dollars >= 0 ? "+\$$(round(pnl_dollars, digits=2))" : "-\$$(round(abs(pnl_dollars), digits=2))"
        @printf("  [%s] #%-3d %s CLOSE | \$%.0f→\$%.0f | %s (%+.1f%%)\n",
                emoji, length(trades), uppercase(string(pos_direction)),
                pos_entry_price, current_price, pnl_s, net_pnl)
        in_position = false
    end

    # ── Report ───────────────────────────────────────────────
    nt = length(trades)
    if nt == 0
        println("\n  No trades executed. Daily bias never triggered with 5-min entry confirmation.")
        return
    end

    wins = count(t -> t.pnl_pct > 0, trades)
    losses = nt - wins
    wr = wins / nt * 100
    total_pnl = capital - 10000
    total_pnl_pct = total_pnl / 100
    wp = sum(t.pnl_dollars for t in trades if t.pnl_dollars > 0; init=0.0)
    lp = abs(sum(t.pnl_dollars for t in trades if t.pnl_dollars < 0; init=0.0))
    pf = lp > 0 ? wp / lp : (wp > 0 ? 99.0 : 0.0)
    avg_win = wins > 0 ? mean(t.pnl_pct for t in trades if t.pnl_pct > 0) : 0.0
    avg_loss = losses > 0 ? mean(t.pnl_pct for t in trades if t.pnl_pct <= 0) : 0.0
    avg_hold = mean(t.hold_hours for t in trades)
    max_dd = 0.0; pk = 10000.0
    for eq in equity_curve; pk = max(pk, eq); max_dd = max(max_dd, (pk-eq)/pk*100); end

    tp_n = count(t -> t.exit_reason == :take_profit, trades)
    sl_n = count(t -> t.exit_reason == :stop_loss, trades)
    rev_n = count(t -> t.exit_reason == :signal_reversal, trades)
    time_n = count(t -> t.exit_reason == :time_expired, trades)

    pnl_s = total_pnl >= 0 ? "+\$$(round(total_pnl, digits=2)) (+$(round(total_pnl_pct, digits=1))%)" :
                              "-\$$(round(abs(total_pnl), digits=2)) ($(round(total_pnl_pct, digits=1))%)"

    println()
    println("╔══════════════════════════════════════════════════════════════════════╗")
    println("║   MULTI-TIMEFRAME REPORT — $(rpad(display, 42))║")
    println("╠══════════════════════════════════════════════════════════════════════╣")
    @printf("║  Method:       Daily MACD bias + 5-min pullback entry              ║\n")
    @printf("║  Period:       %-54s║\n", "$(Date(m_dates[1])) → $(Date(m_dates[end]))")
    @printf("║  Costs:        %-54s║\n", "$(round(round_trip_cost_bps(costs_limit), digits=0)) bps (limit orders on liquid pairs)")
    println("╠══════════════════════════════════════════════════════════════════════╣")
    @printf("║  Capital:      \$10,000 → \$%-42s║\n", "$(round(capital, digits=2))")
    @printf("║  Total PnL:    %-54s║\n", pnl_s)
    @printf("║  Max Drawdown: %-54s║\n", "$(round(max_dd, digits=1))%")
    @printf("║  Peak:         \$%-52s║\n", "$(round(peak_capital, digits=2))")
    println("╠══════════════════════════════════════════════════════════════════════╣")
    @printf("║  Trades:       %-54d║\n", nt)
    @printf("║  Wins/Losses:  %-54s║\n", "$wins / $losses")
    @printf("║  Win Rate:     %-54s║\n", "$(round(wr, digits=1))%")
    @printf("║  Profit Factor:%-54s║\n", "$(round(pf, digits=2))")
    @printf("║  Avg Win:      %-54s║\n", "+$(round(avg_win, digits=2))%")
    @printf("║  Avg Loss:     %-54s║\n", "$(round(avg_loss, digits=2))%")
    @printf("║  Avg Hold:     %-54s║\n", "$(round(avg_hold, digits=0)) hours")
    @printf("║  Max Streak:   %-54d║\n", max_streak)
    println("╠══════════════════════════════════════════════════════════════════════╣")
    @printf("║  Exits: TP=%d  SL=%d  Reversal=%d  Time=%d                         ║\n", tp_n, sl_n, rev_n, time_n)
    println("╠══════════════════════════════════════════════════════════════════════╣")
    println("║  TRADE LOG                                                          ║")
    for t in trades
        emoji = t.pnl_pct > 0 ? "W" : "L"
        ps = t.pnl_dollars >= 0 ? "+\$$(round(t.pnl_dollars, digits=2))" : "-\$$(round(abs(t.pnl_dollars), digits=2))"
        ex = t.exit_reason == :take_profit ? "TP" : t.exit_reason == :stop_loss ? "SL" :
             t.exit_reason == :signal_reversal ? "REV" : t.exit_reason == :end_of_data ? "END" : "TIME"
        @printf("║  [%s] #%-3d %s %-4s \$%.0f→\$%.0f  %8s %+5.1f%% %4.0fhr  bias:%.0f%%\n",
                emoji, t.num, uppercase(string(t.direction)), ex,
                t.entry_price, t.exit_price, ps, t.pnl_pct, t.hold_hours, t.daily_bias_conf)
    end
    println("╚══════════════════════════════════════════════════════════════════════╝")
end

function main()
    ticker = isempty(ARGS) ? "BTC-USD" : ARGS[1]
    days = 150
    for i in eachindex(ARGS)
        if ARGS[i] == "--days" && i < length(ARGS); days = parse(Int, ARGS[i+1]); end
    end
    run_multitf_simulation(ticker; days=days)
end

main()
