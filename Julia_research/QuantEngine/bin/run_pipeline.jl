#!/usr/bin/env julia
# ════════════════════════════════════════════════════════════════
#  MONEY PRINTING MACHINE — 24/7 Pipeline
#  Usage:  julia -t auto bin/run_pipeline.jl BTC-USD,AAPL
#          julia -t auto bin/run_pipeline.jl poly:market-slug
#          QE_FORCE_CONSERVATIVE=true julia bin/run_pipeline.jl ETH-USD
# ════════════════════════════════════════════════════════════════

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using QuantEngine

# Parse assets from command line
assets = if !isempty(ARGS)
    String[strip(a) for a in split(ARGS[1], ",")]
else
    String["BTC-USD", "AAPL"]
end

# Load config from environment
config = load_pipeline_config()

# Run forever
run_money_printer(assets; config)
