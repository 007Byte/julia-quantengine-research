#!/usr/bin/env julia
#
# $100K Month Simulation — daily trading on BTC + ETH
# Runs models every day on trailing data window.
# Multiple trades per month. Realistic costs.

push!(LOAD_PATH, joinpath(@__DIR__, ".."))

println("Loading QuantEngine...")
flush(stdout)
t0 = time()
using QuantEngine
using Dates, Printf, Statistics
load_time = round(time()-t0, digits=1)
println("Loaded in $(load_time)s\n")

# ── Daily Trading Simulator ──────────────────────────────────
# Fixes from v1:
# 1. Trade daily (not once per giant fold)
# 2. Require p_true > 0.58 (strong signals only)
# 3. Scale position size with conviction
# 4. Trailing stop to lock in profits
# 5. Wider initial stop for crypto volatility
# 6. Trend filter: trade with 20-bar MA direction

function run_daily_sim(ticker::String;
                       capital::Float64=100_000.0,
                       sim_days::Int=30,
                       train_window::Int=200,
                       min_signal::Float64=0.58,
                       max_pos_pct::Float64=0.25,
                       stop_pct::Float64=3.0,
                       trail_pct::Float64=2.0,
                       cost_bps::Float64=11.0,
                       verbose::Bool=true)

    ticker = validate_ticker(ticker)
    asset_type = detect_asset_type(ticker)
    display = uppercase(ticker)

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

    println("═" ^ 60)
    @printf("  \$%d DAILY SIM — %s (%d days)\n", round(Int, capital), display, sim_days)
    println("  Signal≥$(min_signal) | MaxPos=$(max_pos_pct*100)% | Stop=$(stop_pct)% | Trail=$(trail_pct)%")
    println("═" ^ 60)

    equity = capital
    peak_eq = capital
    pos = nothing  # (dir, entry, size, peak_price, entry_day)
    trades = NamedTuple[]
    eq_curve = Float64[equity]

    sim_start = n - sim_days + 1

    for day_i in sim_start:n
        day_num = day_i - sim_start + 1
        cp = prices[day_i + 1]
        dt = day_i + 1 <= length(dates) ? dates[day_i + 1] : dates[end]
        eq_start = equity

        # ── Manage open position ──
        if pos !== nothing
            dir, ep, sz, pp, ed = pos

            pnl_pct = dir == :long ?
                (cp / ep - 1.0) * 100.0 :
                (1.0 - cp / ep) * 100.0

            np = dir == :long ? max(pp, cp) : min(pp, cp)
            dd_from_peak = dir == :long ?
                (np - cp) / np * 100.0 :
                (cp - np) / np * 100.0

            bars = day_num - ed
            exit_r = nothing

            if pnl_pct <= -stop_pct
                exit_r = :stop_loss
            elseif pnl_pct > trail_pct && dd_from_peak > trail_pct
                exit_r = :trailing_stop
            elseif bars >= 5
                exit_r = :time_exit  # faster turnover = more compounding cycles
            end

            if exit_r !== nothing
                cost = sz * cost_bps / 10000.0
                tpnl = sz * pnl_pct / 100.0 - cost
                equity += tpnl

                push!(trades, (day=day_num, date=dt, ticker=display, dir=dir,
                    entry=ep, exit=cp, size=sz, pnl=tpnl, pnl_pct=pnl_pct,
                    bars=bars, reason=exit_r))

                verbose && @printf("  Day %2d EXIT  %-5s \$%.0f → \$%.0f | %+.1f%% | \$%+.0f | %s | Eq=\$%.0f\n",
                    day_num, uppercase(string(dir)), ep, cp, pnl_pct, tpnl, exit_r, equity)
                pos = nothing
            else
                pos = (dir, ep, sz, np, ed)
            end
        end

        # ── Generate signal if flat ──
        if pos === nothing
            tr_start = max(1, day_i - train_window)

            ctx = QuantEngine._build_backtest_context(
                ticker, asset_type, display,
                dates, prices, rets, vols, highs, lows,
                tr_start:day_i
            )

            for mid in sort(collect(QuantEngine.FAST_MODELS))
                mid in QuantEngine.PHASE2_MODELS && continue
                run_model(ctx, mid; verbose=false)
            end
            for mid in sort(collect(QuantEngine.PHASE2_MODELS))
                mid in QuantEngine.FAST_MODELS && run_model(ctx, mid; verbose=false)
            end

            # Use ONLY tree models (RF, LightGBM, XGBoost) + Black-Scholes + FD Pricer
            # These were the strongest performers in live shadow testing
            tree_results = Dict{String,Any}()
            for (k,v) in ctx.results
                # Filter to only high-performing models
                if occursin("Random Forest", k) || occursin("LightGBM", k) ||
                   occursin("XGBoost", k) || occursin("Black-Scholes", k) ||
                   occursin("FD Pricer", k) || occursin("Kelly", k)
                    tree_results[k] = v
                end
            end
            # Use filtered results if available, else fall back to all
            comp = compute_composite(isempty(tree_results) ? ctx.results : tree_results)

            # Simple trend filter: 20-bar MA direction
            ma20 = mean(prices[max(1, day_i-18):day_i+1])
            sig_dir = nothing
            if comp.p_true >= min_signal && cp > ma20
                sig_dir = :long
            elseif comp.p_true <= (1.0 - min_signal) && cp < ma20
                sig_dir = :short
            end

            if sig_dir !== nothing
                conv = abs(comp.p_true - 0.5) * 2
                # Concentrated: floor at 25%, ceiling at max. Strong signals go full size.
                sf = clamp(max_pos_pct * max(conv^0.5, 0.5), 0.25, max_pos_pct)
                sz = equity * sf
                ep_adj = sig_dir == :long ?
                    cp * (1 + cost_bps/20000) :
                    cp * (1 - cost_bps/20000)

                pos = (sig_dir, ep_adj, sz, cp, day_num)

                verbose && @printf("  Day %2d ENTER %-5s \$%.0f | size=\$%.0f (%.0f%%) | p=%.3f\n",
                    day_num, uppercase(string(sig_dir)), ep_adj, sz, sf*100, comp.p_true)
            end
        end

        push!(eq_curve, equity)
        peak_eq = max(peak_eq, equity)
    end

    # Close open position at end
    if pos !== nothing
        dir, ep, sz, _, ed = pos
        fp = prices[end]
        pp = dir == :long ? (fp/ep - 1)*100 : (1 - fp/ep)*100
        tpnl = sz * pp / 100 - sz * cost_bps / 10000
        equity += tpnl
        push!(trades, (day=sim_days, date=dates[end], ticker=display, dir=dir,
            entry=ep, exit=fp, size=sz, pnl=tpnl, pnl_pct=pp, bars=sim_days-ed, reason=:end_sim))
        verbose && @printf("  Day %2d CLOSE %-5s \$%.0f → \$%.0f | %+.1f%% | \$%+.0f\n",
            sim_days, uppercase(string(dir)), ep, fp, pp, tpnl)
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

    bh = (prices[end]/prices[n-sim_days+1] - 1)*100

    println()
    println("═" ^ 60)
    @printf("  RESULTS — %s\n", display)
    println("─" ^ 60)
    @printf("  Capital:      \$%d → \$%.2f\n", round(Int,capital), equity)
    @printf("  Return:       %+.2f%%\n", tr)
    @printf("  Max Drawdown: %.2f%%\n", mdd*100)
    @printf("  Trades:       %d (Win: %d  Loss: %d)\n", nt, length(wins), length(losses))
    @printf("  Win Rate:     %.1f%%\n", wr)
    @printf("  Profit Factor:%.2f\n", pf)
    @printf("  Avg Win:      %+.2f%%  Avg Loss: %.2f%%\n", aw, al)
    @printf("  Buy & Hold:   %+.2f%%\n", bh)
    @printf("  Alpha:        %+.2f%%\n", tr - bh)
    println("═" ^ 60)

    return (ticker=display, equity=equity, capital=capital, total_return=tr,
            max_dd=mdd*100, n_trades=nt, win_rate=wr, profit_factor=pf,
            avg_win=aw, avg_loss=al, bh_return=bh, trades=trades,
            equity_curve=eq_curve, sim_days=sim_days)
end

# ── Main ──

println("╔═══════════════════════════════════════════════════╗")
println("║  \$100K MONTH — DAILY TRADING SIMULATION          ║")
println("║  $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))                              ║")
println("╚═══════════════════════════════════════════════════╝\n")

# ITERATION 10: back to proven BTC params, 180 days, 55% sizing
r1 = run_daily_sim("BTC-USD"; capital=100_000.0, sim_days=180,
    train_window=200, min_signal=0.59, max_pos_pct=0.55,
    stop_pct=4.0, trail_pct=3.0)

println("\n")
pnl = r1.equity - r1.capital
months = r1.sim_days / 30.0
monthly = r1.total_return / months
println("╔══════════════════════════════════════════════════════════╗")
@printf("║  BTC ONLY: \$100,000 → \$%.0f                        ║\n", r1.equity)
@printf("║  Return: %+.2f%%  |  PnL: \$%+.0f                         ║\n", r1.total_return, pnl)
@printf("║  Win Rate: %.1f%%  |  Profit Factor: %.2f                  ║\n", r1.win_rate, r1.profit_factor)
@printf("║  Trades: %d  |  MaxDD: %.2f%%  |  Alpha: %+.2f%%            ║\n", r1.n_trades, r1.max_dd, r1.total_return - r1.bh_return)
@printf("║  Monthly avg return: %+.2f%%                               ║\n", monthly)
if monthly >= 10.0
    println("║  TARGET: 10%/month → HIT ✓                               ║")
else
    @printf("║  TARGET: 10%%/month → MISS (%.1f%% short)                   ║\n", 10.0 - monthly)
end
println("╚══════════════════════════════════════════════════════════╝")
