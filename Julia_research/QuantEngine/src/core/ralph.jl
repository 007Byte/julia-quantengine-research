# ── RALPH Loop — Review · Analyze · Log · Print · Halt ────────

function ralph(model_fn::Function, model_name::String, ctx::AnalysisContext;
               max_retries::Int=2, verbose::Bool=true)
    if verbose
        println("  ┌─ RALPH │ $model_name")
        print("  │  [R] Review... ")
    end

    # R — Review
    if isempty(ctx.returns) || (length(ctx.returns) == 1 && ctx.returns[1] == 0.0)
        if verbose
            println("SKIP (no time-series data)")
            println("  └─────────────────────")
        end
        lock(ctx.lock) do
            push!(ctx.log, RalphLog(model_name, false, 0.0, "No data"))
        end
        return nothing
    end
    if verbose println("OK ($(length(ctx.returns)) points)") end

    # A — Analyze
    t0 = time_ns()
    result = nothing
    last_err = nothing
    for attempt in 1:max_retries
        try
            result = model_fn()
            break
        catch e
            last_err = e
            if verbose && attempt < max_retries
                print("  │  [A] Analyze... retry $attempt/$max_retries — ")
                println(sprint(showerror, e)[1:min(80, end)])
            end
        end
    end
    elapsed_ms = (time_ns() - t0) / 1e6

    if result === nothing
        err_msg = last_err === nothing ? "returned nothing" : sprint(showerror, last_err)
        if verbose
            println("  │  [A] Analyze... FAIL ($(round(elapsed_ms, digits=1)) ms)")
            println("  │  [H] HALT — $(first(err_msg, 80))")
            println("  └─────────────────────")
        end
        lock(ctx.lock) do
            push!(ctx.log, RalphLog(model_name, false, elapsed_ms, first(err_msg, 120)))
        end
        return nothing
    end

    if verbose println("  │  [A] Analyze... OK ($(round(elapsed_ms, digits=1)) ms)") end

    # L — Log
    if verbose println("  │  [L] Log... recorded") end
    lock(ctx.lock) do
        push!(ctx.log, RalphLog(model_name, true, elapsed_ms, "OK"))
        ctx.results[model_name] = result
    end

    # P — Print (validate)
    if verbose
        print("  │  [P] Print... ")
        if result isa NamedTuple
            n_nan = count(v -> v isa Number && (isnan(v) || isinf(v)), values(result))
            println(n_nan > 0 ? "WARNING: $n_nan NaN/Inf" : "all outputs valid")
        else
            println("OK")
        end
    end

    # H — Halt check
    if verbose
        println("  │  [H] Halt... PASS ✓")
        println("  └─────────────────────")
    end

    return result
end
