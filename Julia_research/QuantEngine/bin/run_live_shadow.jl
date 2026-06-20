#!/usr/bin/env julia
#
# Live Shadow — real Binance/Yahoo data, real 38-model ensemble, real results.
# Uses QuantEngine's actual pipeline. No fake data. No API keys needed.

push!(LOAD_PATH, joinpath(@__DIR__, ".."))

println("Loading QuantEngine...")
flush(stdout)
t0 = time()
using QuantEngine
using Dates, Statistics
println("Loaded in $(round(time()-t0, digits=1))s\n")

function run_live(ticker::String)
    println("━" ^ 55)
    println("  $ticker — LIVE DATA")
    println("━" ^ 55)

    # 1. Fetch real data + compute features
    print("  Fetching + preparing... ")
    flush(stdout)
    ctx = try
        prepare_context(ticker; output_dir=tempdir())
    catch e
        println("FAILED: $e")
        return nothing
    end
    println("$(length(ctx.prices)) bars, price=\$$(round(ctx.S0, digits=2))")

    # 2. Register the model dispatch table
    QuantEngine._register_models!()

    # 3. Run fast models (in-process, no Distributed.jl needed)
    println("\n  Fast models:")
    flush(stdout)

    for mid in sort(collect(QuantEngine.FAST_MODELS))
        t1 = time()
        result = run_model(ctx, mid; verbose=false)
        ms = round((time() - t1) * 1000, digits=0)

        if result !== nothing && result isa NamedTuple
            p_up = get(result, :probability, get(result, :p_up, get(result, :fair_value, -1.0)))
            dir = get(result, :direction, get(result, :signal, :unknown))
            println("    $(rpad("m$(lpad(mid,2,'0'))", 5)) ✓  p=$(round(Float64(p_up), digits=3))  dir=$(rpad(string(dir),6))  ($(ms)ms)")
        else
            # Check ctx.log for the error
            log_entry = length(ctx.log) > 0 ? ctx.log[end] : nothing
            msg = log_entry !== nothing && !log_entry.success ? log_entry.message : "no result"
            println("    $(rpad("m$(lpad(mid,2,'0'))", 5)) ✗  $(msg[1:min(50,length(msg))])  ($(ms)ms)")
        end
        flush(stdout)
    end

    # 4. Run heavy NN models (top 3 only — these train neural nets)
    println("\n  Heavy models (subset — these train NNs, expect ~seconds each):")
    flush(stdout)

    for mid in sort(collect(QuantEngine.HEAVY_MODELS))[1:min(3, length(QuantEngine.HEAVY_MODELS))]
        t1 = time()
        result = run_model(ctx, mid; verbose=false)
        ms = round((time() - t1) * 1000, digits=0)

        if result !== nothing && result isa NamedTuple
            p_up = get(result, :probability, get(result, :p_up, -1.0))
            dir = get(result, :direction, get(result, :signal, :unknown))
            println("    $(rpad("m$(lpad(mid,2,'0'))", 5)) ✓  p=$(round(Float64(p_up), digits=3))  dir=$(rpad(string(dir),6))  ($(ms)ms)")
        else
            log_entry = length(ctx.log) > 0 ? ctx.log[end] : nothing
            msg = log_entry !== nothing && !log_entry.success ? log_entry.message : "no result"
            println("    $(rpad("m$(lpad(mid,2,'0'))", 5)) ✗  $(msg[1:min(50,length(msg))])  ($(ms)ms)")
        end
        flush(stdout)
    end

    # 5. Aggregate
    all_results = ctx.results
    probs = Float64[]
    directions = Symbol[]

    for (name, val) in all_results
        if val isa NamedTuple || val isa Dict
            p = get(val, :probability, get(val, :p_up, nothing))
            d = get(val, :direction, get(val, :signal, nothing))
            if p !== nothing && p isa Number
                push!(probs, Float64(p))
            end
            if d !== nothing && d isa Symbol
                push!(directions, d)
            end
        end
    end

    n_models = length(probs)
    if n_models == 0
        println("\n  No model outputs to aggregate.")
        return nothing
    end

    avg_prob = mean(probs)
    buy_count = count(d -> d in (:buy, :long, :up), directions)
    sell_count = count(d -> d in (:sell, :short, :down), directions)
    hold_count = length(directions) - buy_count - sell_count

    if avg_prob > 0.55
        signal = :BUY
    elseif avg_prob < 0.45
        signal = :SELL
    else
        signal = :HOLD
    end

    strength = abs(avg_prob - 0.5) * 2  # 0 at 50%, 1 at 0% or 100%

    println("\n  ╔════════════════════════════════════════════╗")
    println("  ║  RESULT: $(rpad(ticker, 35))║")
    println("  ╠════════════════════════════════════════════╣")
    println("  ║  Price:      \$$(rpad(round(ctx.S0, digits=2), 30))║")
    println("  ║  Signal:     $(rpad(string(signal), 31))║")
    println("  ║  Avg prob:   $(rpad("$(round(avg_prob*100, digits=1))%", 31))║")
    println("  ║  Strength:   $(rpad(round(strength, digits=3), 31))║")
    println("  ║  Models ran: $(rpad("$n_models (BUY=$buy_count SELL=$sell_count HOLD=$hold_count)", 31))║")
    println("  ║  Data:       $(rpad("$(length(ctx.prices)) bars, $(ctx.n_features) features", 31))║")
    println("  ╚════════════════════════════════════════════╝")

    return (ticker=ticker, price=ctx.S0, signal=signal, avg_prob=avg_prob,
            strength=strength, n_models=n_models,
            buy=buy_count, sell=sell_count, hold=hold_count)
end

# ── Main ──────────────────────────────────────────

println("═" ^ 55)
println("  QUANTENGINE LIVE SHADOW")
println("  Real data · Real models · No orders")
println("  $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))")
println("═" ^ 55)
println()

results = []
for ticker in ["BTC-USD", "ETH-USD"]
    r = run_live(ticker)
    r !== nothing && push!(results, r)
    println()
end

if !isempty(results)
    println("═" ^ 55)
    println("  SUMMARY — $(Dates.format(now(), "HH:MM:SS"))")
    println("─" ^ 55)
    for r in results
        println("  $(rpad(r.ticker, 8)) \$$(rpad(round(r.price, digits=2), 12))" *
                "$(rpad(string(r.signal), 5)) " *
                "prob=$(round(r.avg_prob*100, digits=1))% " *
                "($(r.n_models) models)")
    end
    println("═" ^ 55)
end
