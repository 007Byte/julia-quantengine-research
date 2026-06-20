#!/usr/bin/env julia
# ════════════════════════════════════════════════════════════════
#  24/7 Live Analysis Loop
#  Usage:  julia -t auto run_live.jl AAPL 300       # every 5 min
#          julia -t auto run_live.jl BTC-USD 60      # every 1 min
#          julia -t auto run_live.jl AAPL,MSFT,GOOGL  # multi-ticker
# ════════════════════════════════════════════════════════════════

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using QuantEngine
using Dates

# Parse args
tickers_str = length(ARGS) >= 1 ? ARGS[1] : "AAPL"
interval    = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 300
tickers     = split(tickers_str, ",")

println()
println("╔══════════════════════════════════════════════════════════════╗")
println("║     QUANT PRINTING DEV — 24/7 Live Mode                    ║")
println("╚══════════════════════════════════════════════════════════════╝")
println("  Tickers:  $(join(tickers, ", "))")
println("  Interval: $(interval)s ($(round(interval/60, digits=1)) min)")
println("  Threads:  $(Threads.nthreads())")
println("  Press Ctrl+C to stop")
println()

iteration = 0

while true
    iteration += 1
    ts = Dates.format(now(), "HH:MM:SS")

    println("─── Iteration $iteration [$ts] ─────────────────────────────")

    for ticker in tickers
        ticker = strip(ticker)
        try
            ctx = prepare_context(ticker; output_dir=nothing)
            # Use a temp dir that gets reused each iteration
            ctx.output_dir = joinpath(resolve_output_base(), "live_$(uppercase(ticker))")
            mkpath(ctx.output_dir)

            run_all_models(ctx; threaded=(Threads.nthreads() > 1), verbose=false)
            composite = compute_composite(ctx.results)

            n_pass = count(r -> r.success, ctx.log)
            total_ms = sum(r.time_ms for r in ctx.log)

            @printf("  %s | %s | Score: %+.3f | p(up): %.3f | %d/%d pass | %.1fs\n",
                uppercase(ticker), composite.direction, composite.score,
                composite.p_true, n_pass, length(ctx.log), total_ms/1000)

        catch e
            println("  $ticker ERROR: $(sprint(showerror, e)[1:min(80,end)])")
        end
    end

    println()
    sleep(interval)
end
