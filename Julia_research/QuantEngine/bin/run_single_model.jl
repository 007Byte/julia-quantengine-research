#!/usr/bin/env julia
# ════════════════════════════════════════════════════════════════
#  Run a Single Model — Fast Prototyping & Testing
#  Usage:  julia run_single_model.jl 5 AAPL        # Random Forest on AAPL
#          julia run_single_model.jl 17 BTC-USD     # Kelly on BTC
#          julia run_single_model.jl 22             # Logistic on default AAPL
# ════════════════════════════════════════════════════════════════

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using QuantEngine

# Parse args
model_id = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 1
ticker   = length(ARGS) >= 2 ? strip(ARGS[2]) : "AAPL"

model_name = get(QuantEngine.MODEL_NAMES, model_id, "Unknown")
println()
println("═" ^ 50)
println("  Single Model: #$model_id — $model_name")
println("  Ticker: $ticker")
println("═" ^ 50)
println()

t0 = time_ns()
ctx = prepare_context(ticker)
println("  Data ready: $(length(ctx.returns)) returns | Price: \$$(round(ctx.S0, digits=2))")
println()

# For Phase 2 models that need other results, run dependencies first
if model_id in QuantEngine.PHASE2_MODELS
    println("  Running dependencies first...")
    phase1_deps = if model_id == 4
        [1]  # LSTM-GARCH needs LSTM
    elseif model_id == 12
        [1, 2, 5, 6, 7, 9, 10, 11]  # Ensemble needs base models
    else
        collect(1:11)  # EV Gap, KL, Bregman, Bayesian need all probs
    end
    for dep in phase1_deps
        run_model(ctx, dep; verbose=false)
    end
    println("  Dependencies complete.")
    println()
end

result = run_model(ctx, model_id)

if result !== nothing
    println()
    println("  ── RESULT ──────────────────────────────────────")
    for (k, v) in pairs(result)
        if v isa Vector
            println("    $k: [$(length(v)) elements]")
        elseif v isa Dict
            println("    $k: Dict($(length(v)) entries)")
        else
            println("    $k: $v")
        end
    end
end

elapsed = (time_ns() - t0) / 1e9
println()
println("  Runtime: $(round(elapsed, digits=2))s")
