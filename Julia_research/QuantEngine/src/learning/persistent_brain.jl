# ── Persistent Learning Brain ─────────────────────────────────
# Stores all learnings to disk (JLD2). Survives between runs.
# The system gets smarter every time it trades.
#
# What it learns:
#   - Which strategies work on which asset types (stock vs crypto)
#   - Optimal TP/SL/hold parameters per volatility regime
#   - Which signals are accurate vs false (signal quality scores)
#   - Win rate by day of week, direction, signal strength
#   - Asset-specific performance history
#   - Regime-specific model accuracy

using JLD2

"""Complete learning state persisted to disk."""
mutable struct QuantBrain
    # ── Strategy Performance ──────────────────────────────────
    # strategy_name → (wins, losses, total_pnl, avg_win, avg_loss)
    strategy_scores::Dict{String, NamedTuple{(:wins,:losses,:total_pnl,:avg_win,:avg_loss), Tuple{Int,Int,Float64,Float64,Float64}}}

    # ── Asset-Specific Learnings ──────────────────────────────
    # asset → (best_strategy, win_rate, avg_pnl, n_trades, last_updated)
    asset_memory::Dict{String, NamedTuple{(:best_strategy,:win_rate,:avg_pnl,:n_trades,:volatility_class,:trend_bias), Tuple{String,Float64,Float64,Int,Symbol,Symbol}}}

    # ── Signal Quality Tracking ───────────────────────────────
    # signal_name → (times_fired, times_correct, accuracy)
    signal_accuracy::Dict{String, NamedTuple{(:fired,:correct,:accuracy), Tuple{Int,Int,Float64}}}

    # ── Optimal Parameters (learned from experience) ──────────
    # asset_class → (best_tp, best_sl, best_hold, best_sizing)
    optimal_params::Dict{Symbol, NamedTuple{(:tp,:sl,:hold,:sizing,:min_strength), Tuple{Float64,Float64,Int,Float64,Float64}}}

    # ── Direction Bias ────────────────────────────────────────
    # "BUY" or "SELL" → win rate (learn if the system is better at buying or selling)
    direction_stats::Dict{Symbol, NamedTuple{(:wins,:losses,:avg_pnl), Tuple{Int,Int,Float64}}}

    # ── Regime Memory ─────────────────────────────────────────
    # volatility_regime → best approach
    regime_learnings::Dict{Symbol, NamedTuple{(:best_layer,:win_rate,:n_trades,:avoid), Tuple{String,Float64,Int,String}}}

    # ── Trade History (last 500 trades for rolling analysis) ──
    trade_log::Vector{NamedTuple{(:ticker,:dir,:pnl,:pnl_pct,:strategy,:signal,:bars,:date,:asset_type), Tuple{String,Symbol,Float64,Float64,String,String,Int,String,Symbol}}}

    # ── Meta ──────────────────────────────────────────────────
    version::Int
    total_trades::Int
    total_pnl::Float64
    lifetime_win_rate::Float64
    created::DateTime
    last_updated::DateTime
    brain_file::String
end

const DEFAULT_BRAIN_PATH = expanduser("~/.quantengine/brain.jld2")

"""Create a new empty brain."""
function QuantBrain(; brain_file::String=DEFAULT_BRAIN_PATH)
    QuantBrain(
        Dict{String, NamedTuple}(),
        Dict{String, NamedTuple}(),
        Dict{String, NamedTuple}(),
        Dict{Symbol, NamedTuple}(
            :stock => (tp=4.0, sl=3.0, hold=8, sizing=0.12, min_strength=65.0),
            :crypto => (tp=5.0, sl=3.0, hold=10, sizing=0.10, min_strength=70.0),
        ),
        Dict{Symbol, NamedTuple}(
            :buy => (wins=0, losses=0, avg_pnl=0.0),
            :sell => (wins=0, losses=0, avg_pnl=0.0),
        ),
        Dict{Symbol, NamedTuple}(),
        NamedTuple[],
        1, 0, 0.0, 0.0, now(), now(), brain_file
    )
end

"""Save brain to disk."""
function save_brain!(brain::QuantBrain)
    mkpath(dirname(brain.brain_file))
    brain.last_updated = now()
    JLD2.save(brain.brain_file, "brain", brain)
end

"""Load brain from disk, or create new if not found."""
function load_brain(; brain_file::String=DEFAULT_BRAIN_PATH)::QuantBrain
    if isfile(brain_file)
        try
            brain = JLD2.load(brain_file, "brain")
            return brain
        catch e
            @warn "Failed to load brain: $(sprint(showerror, e)[1:min(60,end)]). Creating new."
        end
    end
    return QuantBrain(; brain_file=brain_file)
end

"""Record a completed trade and update all learning systems."""
function learn_from_trade!(brain::QuantBrain, ticker::String, dir::Symbol,
                           pnl::Float64, pnl_pct::Float64, strategy::String,
                           signal::String, bars_held::Int, date::String,
                           asset_type::Symbol)
    won = pnl > 0
    brain.total_trades += 1
    brain.total_pnl += pnl

    # ── Update trade log (rolling 500) ────────────────────────
    push!(brain.trade_log, (ticker=ticker, dir=dir, pnl=pnl, pnl_pct=pnl_pct,
        strategy=strategy, signal=signal, bars=bars_held, date=date, asset_type=asset_type))
    if length(brain.trade_log) > 500
        brain.trade_log = brain.trade_log[end-499:end]
    end

    # ── Update lifetime win rate ──────────────────────────────
    total_wins = count(t -> t.pnl > 0, brain.trade_log)
    brain.lifetime_win_rate = length(brain.trade_log) > 0 ? total_wins / length(brain.trade_log) * 100 : 0.0

    # ── Update strategy scores ────────────────────────────────
    if haskey(brain.strategy_scores, strategy)
        s = brain.strategy_scores[strategy]
        new_wins = s.wins + (won ? 1 : 0)
        new_losses = s.losses + (won ? 0 : 1)
        new_pnl = s.total_pnl + pnl
        n = new_wins + new_losses
        new_avg_win = won ? (s.avg_win * s.wins + pnl_pct) / max(new_wins, 1) : s.avg_win
        new_avg_loss = !won ? (s.avg_loss * s.losses + pnl_pct) / max(new_losses, 1) : s.avg_loss
        brain.strategy_scores[strategy] = (wins=new_wins, losses=new_losses, total_pnl=new_pnl,
            avg_win=new_avg_win, avg_loss=new_avg_loss)
    else
        brain.strategy_scores[strategy] = (wins=won ? 1 : 0, losses=won ? 0 : 1,
            total_pnl=pnl, avg_win=won ? pnl_pct : 0.0, avg_loss=won ? 0.0 : pnl_pct)
    end

    # ── Update signal accuracy ────────────────────────────────
    for sig in split(signal, "+")
        sig = strip(sig)
        isempty(sig) && continue
        if haskey(brain.signal_accuracy, sig)
            sa = brain.signal_accuracy[sig]
            new_fired = sa.fired + 1
            new_correct = sa.correct + (won ? 1 : 0)
            brain.signal_accuracy[sig] = (fired=new_fired, correct=new_correct,
                accuracy=new_correct / new_fired * 100)
        else
            brain.signal_accuracy[sig] = (fired=1, correct=won ? 1 : 0,
                accuracy=won ? 100.0 : 0.0)
        end
    end

    # ── Update direction stats ────────────────────────────────
    ds = brain.direction_stats[dir]
    new_w = ds.wins + (won ? 1 : 0)
    new_l = ds.losses + (won ? 0 : 1)
    n = new_w + new_l
    new_avg = (ds.avg_pnl * (n - 1) + pnl_pct) / n
    brain.direction_stats[dir] = (wins=new_w, losses=new_l, avg_pnl=new_avg)

    # ── Update asset memory ───────────────────────────────────
    asset_trades = filter(t -> t.ticker == ticker, brain.trade_log)
    if length(asset_trades) >= 3
        a_wins = count(t -> t.pnl > 0, asset_trades)
        a_wr = a_wins / length(asset_trades) * 100
        a_avg = mean(t.pnl_pct for t in asset_trades)
        # Find best strategy for this asset
        strat_perf = Dict{String,Float64}()
        for t in asset_trades
            strat_perf[t.strategy] = get(strat_perf, t.strategy, 0.0) + t.pnl
        end
        best = isempty(strat_perf) ? "unknown" : first(sort(collect(strat_perf), by=x->x[2], rev=true))[1]
        # Determine if asset trends or mean-reverts
        buy_pnl = sum(t.pnl for t in asset_trades if t.dir == :buy; init=0.0)
        sell_pnl = sum(t.pnl for t in asset_trades if t.dir == :sell; init=0.0)
        trend_bias = buy_pnl > sell_pnl * 1.5 ? :bullish : sell_pnl > buy_pnl * 1.5 ? :bearish : :neutral
        # Volatility class from trade returns
        vol = std(t.pnl_pct for t in asset_trades)
        vol_class = vol > 10 ? :high_vol : vol > 5 ? :medium_vol : :low_vol

        brain.asset_memory[ticker] = (best_strategy=best, win_rate=a_wr, avg_pnl=a_avg,
            n_trades=length(asset_trades), volatility_class=vol_class, trend_bias=trend_bias)
    end

    # ── Update optimal parameters (learn from winners) ────────
    if won && bars_held > 0
        params = get(brain.optimal_params, asset_type,
            (tp=4.0, sl=3.0, hold=8, sizing=0.12, min_strength=55.0))
        # Exponential moving average toward winning trade's parameters
        alpha = 0.3  # learning rate (aggressive — adapt fast)
        new_tp = params.tp * (1 - alpha) + abs(pnl_pct) * alpha
        new_hold = round(Int, params.hold * (1 - alpha) + bars_held * alpha)
        brain.optimal_params[asset_type] = (tp=new_tp, sl=params.sl, hold=new_hold,
            sizing=params.sizing, min_strength=params.min_strength)
    end
end

"""Get the brain's recommendation for a trade decision."""
function brain_filter(brain::QuantBrain, ticker::String, dir::Symbol,
                      strategy::String, signal::String, strength::Float64,
                      asset_type::Symbol)::NamedTuple
    score = 1.0  # multiplier: >1 = boost, <1 = reduce, 0 = reject
    reasons = String[]

    # ── Check signal accuracy (reject signals with <25% historical accuracy) ──
    for sig in split(signal, "+")
        sig = strip(sig)
        if haskey(brain.signal_accuracy, sig) && brain.signal_accuracy[sig].fired >= 15
            acc = brain.signal_accuracy[sig].accuracy
            if acc < 25
                score *= 0.3
                push!(reasons, "$sig accuracy $(round(acc, digits=0))% < 25% → reduce")
            elseif acc > 60
                score *= 1.3
                push!(reasons, "$sig accuracy $(round(acc, digits=0))% > 60% → boost")
            end
        end
    end

    # ── Check strategy track record ───────────────────────────
    if haskey(brain.strategy_scores, strategy)
        ss = brain.strategy_scores[strategy]
        n = ss.wins + ss.losses
        if n >= 15
            strat_wr = ss.wins / n * 100
            if strat_wr < 35
                score *= 0.5
                push!(reasons, "$strategy WR $(round(strat_wr, digits=0))% → reduce")
            elseif strat_wr > 55
                score *= 1.2
                push!(reasons, "$strategy WR $(round(strat_wr, digits=0))% → boost")
            end
        end
    end

    # ── Check asset-specific history ──────────────────────────
    if haskey(brain.asset_memory, ticker)
        am = brain.asset_memory[ticker]
        if am.n_trades >= 5
            if am.win_rate < 35
                score *= 0.5
                push!(reasons, "$ticker historical WR $(round(am.win_rate, digits=0))% → reduce")
            end
            # Check direction bias
            if am.trend_bias == :bullish && dir == :sell
                score *= 0.7
                push!(reasons, "$ticker tends bullish but signal is SELL → reduce")
            elseif am.trend_bias == :bearish && dir == :buy
                score *= 0.7
                push!(reasons, "$ticker tends bearish but signal is BUY → reduce")
            end
        end
    end

    # ── Check direction performance ───────────────────────────
    ds = brain.direction_stats[dir]
    if ds.wins + ds.losses >= 20
        dir_wr = ds.wins / (ds.wins + ds.losses) * 100
        if dir_wr < 40
            score *= 0.8
            push!(reasons, "$(uppercase(string(dir))) overall WR $(round(dir_wr, digits=0))% → reduce")
        end
    end

    # ── Apply minimum strength from learned optimal params ────
    if haskey(brain.optimal_params, asset_type)
        if strength < brain.optimal_params[asset_type].min_strength
            score *= 0.5
            push!(reasons, "strength $strength < learned min $(brain.optimal_params[asset_type].min_strength)")
        end
    end

    # Final decision
    action = score >= 0.7 ? :take : score >= 0.4 ? :reduce : :skip
    sizing_mult = clamp(score, 0.3, 1.5)

    return (action=action, score=score, sizing_multiplier=sizing_mult, reasons=reasons)
end

"""Get learned optimal parameters for an asset type."""
function get_learned_params(brain::QuantBrain, asset_type::Symbol)
    return get(brain.optimal_params, asset_type,
        (tp=4.0, sl=3.0, hold=8, sizing=0.12, min_strength=65.0))
end

"""Print a summary of what the brain has learned."""
function print_brain_summary(brain::QuantBrain)
    println("\n  ╔══════════════════════════════════════════════════════════╗")
    println("  ║  QUANTENGINE BRAIN — Persistent Learnings              ║")
    println("  ╠══════════════════════════════════════════════════════════╣")
    @printf("  ║  Total trades learned from: %-28d║\n", brain.total_trades)
    @printf("  ║  Lifetime win rate:         %-28s║\n", "$(round(brain.lifetime_win_rate, digits=1))%")
    @printf("  ║  Lifetime P&L:              %-28s║\n",
        brain.total_pnl >= 0 ? "+\$$(round(brain.total_pnl, digits=2))" : "-\$$(round(abs(brain.total_pnl), digits=2))")
    @printf("  ║  Brain file:                %-28s║\n", basename(brain.brain_file))
    @printf("  ║  Last updated:              %-28s║\n", Dates.format(brain.last_updated, "yyyy-mm-dd HH:MM"))

    if !isempty(brain.signal_accuracy)
        println("  ╠══════════════════════════════════════════════════════════╣")
        println("  ║  SIGNAL ACCURACY (learned)                              ║")
        sorted = sort(collect(brain.signal_accuracy), by=x -> x[2].fired, rev=true)
        for (name, sa) in sorted[1:min(8, length(sorted))]
            emoji = sa.accuracy >= 55 ? "✓" : sa.accuracy >= 45 ? "~" : "✗"
            @printf("  ║  %s %-25s %3d fired  %.0f%% acc      ║\n",
                emoji, first(name, 25), sa.fired, sa.accuracy)
        end
    end

    if !isempty(brain.asset_memory)
        println("  ╠══════════════════════════════════════════════════════════╣")
        println("  ║  ASSET MEMORY                                           ║")
        for (ticker, am) in brain.asset_memory
            @printf("  ║  %-6s %2d trades  %.0f%% WR  bias:%-8s best:%s  ║\n",
                ticker, am.n_trades, am.win_rate, am.trend_bias,
                first(am.best_strategy, 12))
        end
    end

    if !isempty(brain.optimal_params)
        println("  ╠══════════════════════════════════════════════════════════╣")
        println("  ║  LEARNED OPTIMAL PARAMETERS                             ║")
        for (atype, p) in brain.optimal_params
            @printf("  ║  %-8s TP:%.1f%% SL:%.1f%% Hold:%dd Size:%.0f%%        ║\n",
                atype, p.tp, p.sl, p.hold, p.sizing * 100)
        end
    end

    println("  ╚══════════════════════════════════════════════════════════╝")
end
