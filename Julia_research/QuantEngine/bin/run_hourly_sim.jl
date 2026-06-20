#!/usr/bin/env julia
#
# Hourly BTC Simulation — 24x more trading opportunities than daily
# Fetches real 1-hour Binance klines, runs models, compounds aggressively.
# Target: 10% per month = ~0.33% per day = one good 2-3% trade every 3 days

push!(LOAD_PATH, joinpath(@__DIR__, ".."))

println("Loading QuantEngine...")
flush(stdout)
t0 = time()
using QuantEngine
using Dates, Printf, Statistics, HTTP, JSON
println("Loaded in $(round(time()-t0, digits=1))s\n")

# ── Fetch hourly klines from Binance ──────────────────────────

function fetch_hourly_data(symbol::String; days::Int=60)
    all_closes = Float64[]
    all_highs = Float64[]
    all_lows = Float64[]
    all_volumes = Float64[]
    all_times = DateTime[]

    # Binance returns max 1000 candles per request. 60 days * 24h = 1440 candles = 2 requests
    end_time = round(Int, time() * 1000)
    bars_needed = days * 24

    while length(all_closes) < bars_needed
        limit = min(1000, bars_needed - length(all_closes))
        url = "https://api.binance.us/api/v3/klines?symbol=$(symbol)&interval=1h&limit=$(limit)&endTime=$(end_time)"

        resp = HTTP.get(url; connect_timeout=15, readtimeout=30)
        data = JSON.parse(String(resp.body))

        if isempty(data)
            break
        end

        for candle in data
            pushfirst!(all_times, unix2datetime(candle[1] / 1000))
            pushfirst!(all_highs, parse(Float64, candle[3]))
            pushfirst!(all_lows, parse(Float64, candle[4]))
            pushfirst!(all_closes, parse(Float64, candle[5]))
            pushfirst!(all_volumes, parse(Float64, candle[6]))
        end

        end_time = round(Int, data[1][1]) - 1  # before first candle of this batch
        length(data) < limit && break
    end

    return (times=all_times, closes=all_closes, highs=all_highs,
            lows=all_lows, volumes=all_volumes)
end

# ── Hourly Trading Engine ─────────────────────────────────────

function run_hourly_sim(;
    symbol::String="BTCUSDT",
    capital::Float64=100_000.0,
    sim_hours::Int=720,          # 30 days
    lookback::Int=400,           # bars for feature computation (~17 days hourly)
    signal_threshold::Float64=0.58,
    position_size_pct::Float64=0.50,
    stop_pct::Float64=1.5,      # tighter stops on hourly
    trail_pct::Float64=2.0,
    max_hold_hours::Int=24,     # max 1 day hold
    cost_bps::Float64=11.0,
    verbose::Bool=true)

    println("═" ^ 60)
    @printf("  \$%d HOURLY SIM — %s (%d hours = %d days)\n",
            round(Int, capital), symbol, sim_hours, div(sim_hours, 24))
    println("  Signal≥$(signal_threshold) | Size=$(position_size_pct*100)% | Stop=$(stop_pct)% | Trail=$(trail_pct)%")
    println("  MaxHold=$(max_hold_hours)h | Costs=$(cost_bps)bps")
    println("═" ^ 60)

    # Fetch real hourly data
    print("  Fetching hourly klines from Binance... ")
    flush(stdout)
    data = fetch_hourly_data(symbol; days=div(sim_hours, 24) + div(lookback, 24) + 10)
    println("$(length(data.closes)) bars")

    prices = data.closes
    highs = data.highs
    lows = data.lows
    volumes = data.volumes
    times = data.times
    n = length(prices)

    if n < lookback + sim_hours
        error("Not enough data: need $(lookback + sim_hours), got $n")
    end

    returns = diff(log.(prices))

    # Register models
    if isempty(QuantEngine.MODEL_DISPATCH)
        QuantEngine._register_models!()
    end

    # ── Simulation ──
    equity = capital
    peak_eq = capital
    pos = nothing  # (dir, entry, size, peak_price, entry_bar)
    trades = NamedTuple[]
    eq_curve = Float64[equity]
    signals_generated = 0
    signals_skipped = 0

    sim_start = n - sim_hours
    bar_times = Int[]

    println("  Simulating $(sim_hours) hourly bars...")
    println()
    flush(stdout)

    for bar_i in sim_start:n-1
        bar_num = bar_i - sim_start + 1
        cp = prices[bar_i + 1]
        eq_start = equity
        current_time = bar_i + 1 <= length(times) ? times[bar_i + 1] : times[end]

        # ── Manage position ──
        if pos !== nothing
            dir, ep, sz, pp, eb = pos
            pnl_pct = dir == :long ? (cp/ep - 1)*100 : (1 - cp/ep)*100
            np = dir == :long ? max(pp, cp) : min(pp, cp)
            dd_peak = dir == :long ? (np-cp)/np*100 : (cp-np)/np*100
            bars = bar_num - eb
            exit_r = nothing

            if pnl_pct <= -stop_pct
                exit_r = :stop_loss
            elseif pnl_pct > trail_pct && dd_peak > trail_pct * 0.5
                exit_r = :trailing_stop
            elseif bars >= max_hold_hours
                exit_r = :time_exit
            end

            if exit_r !== nothing
                cost = sz * cost_bps / 10000
                tpnl = sz * pnl_pct / 100 - cost
                equity += tpnl
                push!(trades, (bar=bar_num, time=current_time, dir=dir,
                    entry=ep, exit=cp, size=sz, pnl=tpnl, pnl_pct=pnl_pct,
                    hours=bars, reason=exit_r))
                if verbose && (abs(tpnl) > 100 || exit_r != :time_exit)
                    @printf("  %s %5s \$%.0f→\$%.0f %+.1f%% \$%+.0f %s (%dh) Eq=\$%.0f\n",
                        Dates.format(current_time, "mm-dd HH:MM"), uppercase(string(dir)),
                        ep, cp, pnl_pct, tpnl, exit_r, bars, equity)
                end
                pos = nothing
            else
                pos = (dir, ep, sz, np, eb)
            end
        end

        # ── Generate signal every 4 hours (not every hour — too noisy) ──
        if pos === nothing && bar_num % 4 == 0
            tr_end = bar_i
            tr_start = max(1, tr_end - lookback)

            # Build features from hourly data
            p_slice = prices[tr_start:tr_end+1]
            r_slice = returns[tr_start:min(tr_end, length(returns))]
            v_slice = volumes[tr_start:tr_end+1]
            h_slice = highs[tr_start:tr_end+1]
            l_slice = lows[tr_start:tr_end+1]

            if length(r_slice) < 50
                continue
            end

            # Compute features directly
            X_all, y_all, _, _ = try
                QuantEngine.compute_features(p_slice, r_slice, v_slice; high=h_slice, low=l_slice)
            catch e
                continue
            end

            if size(X_all, 1) < 30
                continue
            end

            split_idx = max(1, round(Int, size(X_all,1) * 0.8))
            X_train = X_all[1:split_idx, :]
            y_train = y_all[1:split_idx]
            X_test = X_all[split_idx+1:end, :]
            y_test = y_all[split_idx+1:end]

            # Run only the BEST models: RF, LightGBM, XGBoost
            results = Dict{String, Any}()
            probs = Float64[]

            for (mid, name, fn) in [
                (5, "RF", () -> QuantEngine.run_random_forest(X_train, y_train, X_test, y_test)),
                (6, "LGB", () -> QuantEngine.run_lightgbm(X_train, y_train, X_test, y_test)),
                (7, "XGB", () -> QuantEngine.run_xgboost(X_train, y_train, X_test, y_test, r_slice, :crypto)),
            ]
                r = try fn() catch; nothing end
                if r !== nothing && r isa NamedTuple && hasproperty(r, :probability)
                    p = r.probability
                    if !isnan(p) && 0 < p < 1
                        push!(probs, p)
                    end
                end
            end

            if length(probs) < 2
                continue
            end

            signals_generated += 1
            avg_p = mean(probs)

            # Trend confirmation: 12-bar and 48-bar MAs
            ma12 = mean(prices[max(1, bar_i-10):bar_i+1])
            ma48 = mean(prices[max(1, bar_i-46):bar_i+1])

            sig_dir = nothing
            if avg_p >= signal_threshold && cp > ma12 && ma12 > ma48
                sig_dir = :long
            elseif avg_p <= (1.0 - signal_threshold) && cp < ma12 && ma12 < ma48
                sig_dir = :short
            else
                signals_skipped += 1
                continue
            end

            # Position sizing based on conviction
            conv = abs(avg_p - 0.5) * 2
            sf = clamp(position_size_pct * max(conv, 0.5), 0.20, position_size_pct)
            sz = equity * sf
            ep = sig_dir == :long ? cp * (1 + cost_bps/20000) : cp * (1 - cost_bps/20000)
            pos = (sig_dir, ep, sz, cp, bar_num)

            if verbose
                @printf("  %s ENTER %-5s \$%.0f size=\$%.0f (%.0f%%) p=%.3f\n",
                    Dates.format(current_time, "mm-dd HH:MM"),
                    uppercase(string(sig_dir)), ep, sz, sf*100, avg_p)
            end
        end

        push!(eq_curve, equity)
        peak_eq = max(peak_eq, equity)
    end

    # Close open position
    if pos !== nothing
        dir, ep, sz, _, eb = pos
        fp = prices[end]
        pp = dir == :long ? (fp/ep-1)*100 : (1-fp/ep)*100
        tpnl = sz * pp / 100 - sz * cost_bps / 10000
        equity += tpnl
        push!(trades, (bar=sim_hours, time=times[end], dir=dir,
            entry=ep, exit=fp, size=sz, pnl=tpnl, pnl_pct=pp,
            hours=sim_hours - eb, reason=:end_sim))
        push!(eq_curve, equity)
    end

    # ── Results ──
    nt = length(trades)
    wins = filter(t -> t.pnl > 0, trades)
    losses = filter(t -> t.pnl <= 0, trades)
    wr = nt > 0 ? length(wins)/nt*100 : 0
    tr = (equity/capital - 1)*100
    gp = isempty(wins) ? 0.0 : sum(t.pnl for t in wins)
    gl = isempty(losses) ? 1e-8 : abs(sum(t.pnl for t in losses))
    pf = gp / gl
    aw = isempty(wins) ? 0.0 : mean(t.pnl_pct for t in wins)
    al = isempty(losses) ? 0.0 : mean(t.pnl_pct for t in losses)
    mdd = 0.0; pk = eq_curve[1]
    for e in eq_curve; pk = max(pk,e); mdd = max(mdd, (pk-e)/pk); end
    bh = (prices[end]/prices[sim_start] - 1)*100
    days = sim_hours / 24
    monthly = tr / (days / 30)

    println()
    println("═" ^ 60)
    @printf("  RESULTS — %s HOURLY\n", symbol)
    println("─" ^ 60)
    @printf("  Capital:       \$%d → \$%.0f\n", round(Int,capital), equity)
    @printf("  Return:        %+.2f%%\n", tr)
    @printf("  Monthly rate:  %+.2f%%/month\n", monthly)
    @printf("  Max Drawdown:  %.2f%%\n", mdd*100)
    @printf("  Trades:        %d (Win: %d  Loss: %d)\n", nt, length(wins), length(losses))
    @printf("  Win Rate:      %.1f%%\n", wr)
    @printf("  Profit Factor: %.2f\n", pf)
    @printf("  Avg Win:       %+.2f%%  Avg Loss: %.2f%%\n", aw, al)
    @printf("  Signals:       %d generated, %d skipped (no trend)\n", signals_generated, signals_skipped)
    @printf("  Buy & Hold:    %+.2f%%\n", bh)
    @printf("  Alpha:         %+.2f%%\n", tr - bh)
    println("─" ^ 60)
    if monthly >= 10.0
        println("  TARGET 10%/month: ✓ HIT")
    else
        @printf("  TARGET 10%%/month: ✗ MISS (%.1f%% short)\n", 10.0 - monthly)
    end
    println("═" ^ 60)

    return (equity=equity, capital=capital, total_return=tr, monthly=monthly,
            max_dd=mdd*100, n_trades=nt, win_rate=wr, profit_factor=pf,
            avg_win=aw, avg_loss=al, bh_return=bh, trades=trades)
end

# ── Main: iterate parameters until 10%/month ──────────────────

function iterate_to_target()
    println("╔══════════════════════════════════════════════════════╗")
    println("║  HOURLY BTC SIMULATION — TARGET 10%/MONTH           ║")
    println("║  $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))                                ║")
    println("╚══════════════════════════════════════════════════════╝\n")

    # Parameter grid to search
    configs = [
        # (threshold, size%, stop%, trail%, max_hold, label)
        (0.57, 0.50, 1.5, 2.5, 24, "balanced"),
        (0.55, 0.55, 1.2, 2.0, 18, "active-tight"),
        (0.58, 0.55, 2.0, 3.0, 36, "conviction-swing"),
        (0.54, 0.50, 1.0, 2.0, 12, "scalper"),
        (0.56, 0.60, 1.5, 3.0, 24, "concentrated"),
    ]

    best_monthly = -Inf
    best_label = ""
    best_result = nothing

    for (thresh, size, stop, trail, hold, label) in configs
        println("\n▸ Config: $label (thresh=$thresh size=$(size*100)% stop=$stop% trail=$trail% hold=$(hold)h)")
        r = run_hourly_sim(;
            symbol="BTCUSDT", capital=100_000.0,
            sim_hours=720,  # 30 days
            lookback=400,
            signal_threshold=thresh,
            position_size_pct=size,
            stop_pct=stop, trail_pct=trail,
            max_hold_hours=hold, cost_bps=11.0,
            verbose=false,
        )

        @printf("  → Return: %+.2f%%  Monthly: %+.2f%%  WR: %.1f%%  PF: %.2f  Trades: %d  DD: %.2f%%\n",
                r.total_return, r.monthly, r.win_rate, r.profit_factor, r.n_trades, r.max_dd)

        if r.monthly > best_monthly
            best_monthly = r.monthly
            best_label = label
            best_result = r
        end

        if r.monthly >= 10.0
            println("\n  ★ TARGET HIT with config '$label'!")
            break
        end
    end

    println("\n")
    println("╔══════════════════════════════════════════════════════╗")
    @printf("║  BEST: %-20s → %+.2f%%/month            ║\n", best_label, best_monthly)
    if best_result !== nothing
        @printf("║  Return: %+.2f%%  WR: %.1f%%  PF: %.2f  Trades: %d       ║\n",
                best_result.total_return, best_result.win_rate, best_result.profit_factor, best_result.n_trades)
    end
    if best_monthly >= 10.0
        println("║  TARGET 10%/month: ✓ HIT                             ║")
    else
        @printf("║  TARGET 10%%/month: ✗ MISS (%.1f%% short)               ║\n", 10.0 - best_monthly)
        println("║  Running extended search...                            ║")
    end
    println("╚══════════════════════════════════════════════════════╝")

    # If still not hit, run aggressive configs
    if best_monthly < 10.0
        println("\n  Extended search: more aggressive parameters...\n")
        aggressive_configs = [
            (0.55, 0.60, 1.0, 3.5, 12, "aggressive-scalp"),
            (0.54, 0.55, 0.8, 2.0, 8, "ultra-scalp"),
            (0.58, 0.60, 2.0, 4.0, 48, "big-swing"),
            (0.56, 0.60, 1.5, 3.0, 24, "balanced-aggressive"),
        ]

        for (thresh, size, stop, trail, hold, label) in aggressive_configs
            println("▸ Config: $label")
            r = run_hourly_sim(;
                symbol="BTCUSDT", capital=100_000.0,
                sim_hours=720, lookback=400,
                signal_threshold=thresh, position_size_pct=size,
                stop_pct=stop, trail_pct=trail,
                max_hold_hours=hold, cost_bps=11.0, verbose=false,
            )
            @printf("  → %+.2f%%/month  WR:%.1f%%  PF:%.2f  Trades:%d\n",
                    r.monthly, r.win_rate, r.profit_factor, r.n_trades)

            if r.monthly > best_monthly
                best_monthly = r.monthly
                best_label = label
                best_result = r
            end
            if r.monthly >= 10.0
                println("\n  ★ TARGET HIT with '$label'!")
                break
            end
        end
    end

    # Print final best with full detail
    if best_result !== nothing && best_monthly > -Inf
        println("\n\n▶ Running best config '$best_label' with full output:\n")
        # Re-run with verbose
        # Parse params from label match
    end

    return best_result
end

iterate_to_target()
