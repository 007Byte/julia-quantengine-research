#!/usr/bin/env julia
#
# Shadow Mode — real Binance data, no orders, signal comparison.
#
# Usage:
#   julia --project=. bin/run_shadow.jl
#   julia --project=. bin/run_shadow.jl --symbols BTCUSDT,ETHUSDT --hours 24
#
# What it does:
#   1. Connects to real Binance market data
#   2. Runs the full Julia signal pipeline (features → models → ensemble)
#   3. Records what the system WOULD have done
#   4. After 1m/5m/15m/1h, records what the market actually did
#   5. Logs per-model contribution to final ensemble score
#   6. Prints hit rate, directional accuracy, dead-weight model report
#
# No fills. No orders. No capital at risk.

push!(LOAD_PATH, joinpath(@__DIR__, ".."))
using QuantEngine
using Dates

function parse_shadow_args()
    symbols = ["BTCUSDT", "ETHUSDT"]
    hours = 0  # 0 = run until Ctrl+C

    for (i, arg) in enumerate(ARGS)
        if arg == "--symbols" && i < length(ARGS)
            symbols = split(ARGS[i+1], ",")
        elseif arg == "--hours" && i < length(ARGS)
            hours = parse(Int, ARGS[i+1])
        end
    end

    return (symbols=symbols, hours=hours)
end

function main()
    args = parse_shadow_args()

    println("=" ^ 60)
    println("QUANTENGINE SHADOW MODE")
    println("=" ^ 60)
    println("Instruments: $(join(args.symbols, ", "))")
    println("Duration:    $(args.hours > 0 ? "$(args.hours) hours" : "until Ctrl+C")")
    println("Mode:        OBSERVE ONLY — no orders submitted")
    println("=" ^ 60)
    println()

    # Check production modules are available
    if !isdefined(QuantEngine, :ShadowSession)
        println("ERROR: Production modules not loaded.")
        println("Install LibPQ: julia --project=. -e 'import Pkg; Pkg.add(\"LibPQ\")'")
        return
    end

    session = ShadowSession(
        team_id="crypto",
        venue="binance",
        instruments=collect(String, args.symbols),
    )

    println("Session $(session.session_id) started at $(Dates.now(Dates.UTC))")
    println("Collecting market data and generating signals...")
    println("Press Ctrl+C to stop and see the report.\n")

    start_time = time()
    deadline = args.hours > 0 ? start_time + args.hours * 3600 : Inf
    iteration = 0

    try
        # Main shadow loop
        while time() < deadline
            iteration += 1

            for symbol in args.symbols
                try
                    # Fetch real price from Binance
                    price_data = HTTP.get(
                        "https://api.binance.us/api/v3/ticker/price?symbol=$symbol";
                        connect_timeout=5, readtimeout=5,
                    )
                    price_json = JSON.parse(String(price_data.body))
                    price = parse(Float64, get(price_json, "price", "0"))

                    if price > 0
                        record_price!(session, symbol, price)
                    end
                catch e
                    # Non-fatal — data fetch failure doesn't stop shadow mode
                    if iteration % 100 == 0
                        @warn "Price fetch failed for $symbol: $(sprint(showerror, e))"
                    end
                end
            end

            # Update outcomes for pending signals
            update_outcomes!(session)

            # Status update every 60 iterations (~5 min at 5s interval)
            if iteration % 60 == 0
                stats = shadow_stats(session)
                elapsed_min = (time() - start_time) / 60
                println("[$(Dates.format(now(), "HH:MM:SS"))] " *
                        "$(elapsed_min |> x -> round(x, digits=0))min | " *
                        "signals=$(stats["total_signals"]) " *
                        "completed=$(stats["completed"]) " *
                        "pending=$(stats["pending"])")

                if stats["completed"] > 0
                    println("  hit_rate_5m=$(round(get(stats, "hit_rate_5m", 0.0) * 100, digits=1))%")
                end
            end

            sleep(5)  # 5-second tick
        end
    catch e
        if e isa InterruptException
            println("\nShutting down shadow session...")
        else
            @error "Shadow mode error" exception=(e, catch_backtrace())
        end
    end

    # Final report
    println()
    print_shadow_report(session)

    # Per-model contribution analysis
    model_stats = model_contribution_stats(session)
    if !isempty(model_stats)
        dead_weight = count(kv -> kv[2]["is_dead_weight"], model_stats)
        total_models = length(model_stats)
        println("\nENSEMBLE PRUNING RECOMMENDATION:")
        println("  Dead weight models: $dead_weight / $total_models")
        if dead_weight > 0
            println("  Consider removing these models to reduce complexity:")
            for (mid, ms) in model_stats
                if ms["is_dead_weight"]
                    println("    - $mid (hit=$(round(ms["hit_rate"]*100))%, contrib=$(round(ms["avg_contribution"], digits=3)))")
                end
            end
        end
    end

    # Save to Postgres if available
    if isdefined(QuantEngine, :PgPool)
        try
            pool = PgPool()
            pg_connect!(pool)
            # Could persist shadow signals here
            pg_close!(pool)
        catch
            @info "Postgres not available — shadow results in console only"
        end
    end

    println("\nShadow session complete.")
end

main()
