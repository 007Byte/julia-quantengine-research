#!/usr/bin/env julia
# ── QuantEngine Multi-Ticker Scanner ──────────────────────────
# Usage:
#   julia --project=. bin/run_scanner.jl watchlist.txt
#   julia --project=. bin/run_scanner.jl AAPL,MSFT,GOOGL,BTC-USD --top 5
#   julia --project=. bin/run_scanner.jl watchlist.txt --portfolio --capital 25000
#
# Options:
#   --top N          Return top N results (default: 10)
#   --portfolio      Run portfolio optimization on results
#   --capital N      Capital for portfolio optimization (default: 10000)
#   --all-models     Use all 30 models (slow, default: fast only)

using QuantEngine

function main()
    if isempty(ARGS)
        println("Usage: julia --project=. bin/run_scanner.jl TICKERS_OR_FILE [options]")
        println("  TICKERS_OR_FILE: comma-separated tickers or path to watchlist file")
        println("Options: --top N, --portfolio, --capital N, --all-models")
        return
    end

    # Parse tickers from first argument
    input = ARGS[1]
    tickers = if isfile(input)
        load_watchlist(input)
    else
        split(input, ",") |> collect .|> strip .|> String
    end

    # Parse options
    top_n = 10
    do_portfolio = "--portfolio" in ARGS
    capital = 10000.0
    fast_only = !("--all-models" in ARGS)

    for i in eachindex(ARGS)
        if ARGS[i] == "--top" && i < length(ARGS)
            top_n = parse(Int, ARGS[i+1])
        elseif ARGS[i] == "--capital" && i < length(ARGS)
            capital = parse(Float64, ARGS[i+1])
        end
    end

    config = ScanConfig(fast_only=fast_only, top_n=top_n, verbose=true)
    results = scan_universe(tickers; config)

    if do_portfolio && !isempty(results)
        portfolio = optimize_portfolio(results, capital)
        print_portfolio(portfolio, capital)
    end
end

main()
