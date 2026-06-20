#!/usr/bin/env julia
# ── QuantEngine Hyperparameter Tuning ─────────────────────────
# Usage:
#   julia --project=. bin/run_tuning.jl 7 AAPL              # Tune XGBoost on AAPL
#   julia --project=. bin/run_tuning.jl 5 BTC-USD --evals 50 # Tune RF with 50 evals
#   julia --project=. bin/run_tuning.jl list                  # List tunable models

using QuantEngine

function main()
    if isempty(ARGS)
        println("Usage: julia --project=. bin/run_tuning.jl MODEL_ID TICKER [options]")
        println("       julia --project=. bin/run_tuning.jl list")
        println("Options: --evals N (default: 30)")
        return
    end

    if ARGS[1] == "list"
        println("Tunable models:")
        for mid in tunable_models()
            space = get_search_space(mid)
            params = join([hp.name for hp in space.params], ", ")
            println("  Model $mid: $(space.model_name) → ($params)")
        end
        return
    end

    model_id = parse(Int, ARGS[1])
    ticker = length(ARGS) >= 2 ? ARGS[2] : "AAPL"

    n_evals = 30
    for i in eachindex(ARGS)
        if ARGS[i] == "--evals" && i < length(ARGS)
            n_evals = parse(Int, ARGS[i+1])
        end
    end

    result = tune_model(model_id, ticker; n_evaluations=n_evals, verbose=true)

    # Save results
    output_dir = resolve_output_base()
    mkpath(output_dir)
    filepath = joinpath(output_dir, "tuning_$(result.model_name)_$(ticker)_$(Dates.format(now(), "yyyymmdd")).json")
    save_tuning_result(result, filepath)
    println("\n  Results saved: $filepath")
end

main()
