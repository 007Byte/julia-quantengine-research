#!/usr/bin/env julia
#
# Production Pipeline — full QuantEngine with production infrastructure.
#
# Usage:
#   julia --project=. bin/run_production.jl
#   julia --project=. bin/run_production.jl --team crypto --venue binance
#
# What it does:
#   1. NTP check (blocks on >150ms skew)
#   2. Connect Postgres, run migrations
#   3. Initialize risk budgets
#   4. Build OMS (starts FROZEN)
#   5. Startup reconciliation — OMS stays frozen until clean
#   6. Start outbox worker
#   7. Run validation pack (plumbing level)
#   8. Start the normal pipeline loop with production tick
#
# Scope enforcement: crypto/binance/BTC+ETH only.

push!(LOAD_PATH, joinpath(@__DIR__, ".."))
using QuantEngine
using Dates

function main()
    team = "crypto"
    venue = "binance"

    for (i, arg) in enumerate(ARGS)
        if arg == "--team" && i < length(ARGS)
            team = ARGS[i+1]
        elseif arg == "--venue" && i < length(ARGS)
            venue = ARGS[i+1]
        end
    end

    # Check production modules are loaded
    if !isdefined(QuantEngine, :ProductionPipeline)
        println("ERROR: Production modules not loaded.")
        println("Install LibPQ: julia --project=. -e 'import Pkg; Pkg.add(\"LibPQ\")'")
        println("Then ensure Postgres is running: docker compose up -d")
        return
    end

    # Start production pipeline
    pipeline = ProductionPipeline(team_id=team, venue=venue)

    try
        start_production!(pipeline)

        if pipeline.oms !== nothing && pipeline.oms.frozen
            println("\n⚠ OMS is FROZEN — reconciliation issues detected.")
            println("  Resolve incidents in reconciliation_incidents table,")
            println("  then restart the pipeline.\n")
        end

        println("\nProduction pipeline running. Press Ctrl+C to stop.\n")

        # Main loop — integrates with existing QuantEngine pipeline
        config = load_pipeline_config()
        iteration = 0

        while true
            iteration += 1

            # Production infrastructure tick
            production_tick!(pipeline, iteration)

            # Normal pipeline would run here
            # For now, just heartbeat
            if iteration % 60 == 0
                elapsed_min = round(iteration * 5 / 60, digits=0)
                @info "Heartbeat: $(elapsed_min)min | OMS frozen=$(pipeline.oms.frozen)"
            end

            sleep(config.poll_interval_ms / 1000.0)
        end
    catch e
        if e isa InterruptException
            println("\nShutting down...")
        else
            @error "Pipeline error" exception=(e, catch_backtrace())
        end
    finally
        stop_production!(pipeline)
    end
end

main()
