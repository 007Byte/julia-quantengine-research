# ── Polymarket Historical Data ────────────────────────────────
# Fetches historical price data from Polymarket's CLOB API
# for backtesting prediction market strategies.

"""
    fetch_polymarket_history(token_id; resolution, limit)

Fetch historical price timeseries from Polymarket CLOB API.
Resolution: "1m", "5m", "1h", "4h", "1d"
Returns NamedTuple compatible with backtest engine.
"""
function fetch_polymarket_history(token_id::String;
                                   resolution::String="1d",
                                   limit::Int=365)
    # Polymarket CLOB timeseries endpoint
    url = "https://clob.polymarket.com/prices-history?" *
          "market=$(token_id)&interval=$(resolution)&fidelity=$(limit)"

    try
        resp = HTTP.get(url, ["Accept" => "application/json"];
                        connect_timeout=15, readtimeout=30)
        data = JSON.parse(String(resp.body))

        history = get(data, "history", [])
        if isempty(history)
            @warn "No historical data for token $token_id"
            return nothing
        end

        dates = DateTime[]
        prices = Float64[]

        for point in history
            ts = get(point, "t", 0)
            price = get(point, "p", nothing)
            if price !== nothing
                push!(dates, unix2datetime(ts))
                push!(prices, Float64(price))
            end
        end

        if length(prices) < 5
            @warn "Insufficient history for $token_id: $(length(prices)) points"
            return nothing
        end

        prices = clamp.(prices, 0.01, 0.99)
        returns = diff(prices)
        volumes = fill(10000.0, length(prices))  # volume not in timeseries
        high = prices .+ abs.(diff(vcat([prices[1]], prices))) .* 0.5
        low = prices .- abs.(diff(vcat([prices[1]], prices))) .* 0.5
        high = clamp.(high, 0.01, 0.99)
        low = clamp.(low, 0.01, 0.99)

        return (dates=dates, prices=prices, returns=returns,
                volumes=volumes, high=high, low=low,
                token_id=token_id, n_days=length(prices))
    catch e
        @warn "Polymarket history fetch failed: $(sprint(showerror, e)[1:min(80,end)])"
        return nothing
    end
end

"""
    fetch_polymarket_markets(; limit, active_only)

Fetch list of available Polymarket markets for scanning.
Returns market metadata: slug, question, volume, end_date.
"""
function fetch_polymarket_markets(; limit::Int=50, active_only::Bool=true)
    url = "https://gamma-api.polymarket.com/markets?" *
          "limit=$limit&active=$(active_only)"

    try
        resp = HTTP.get(url, ["Accept" => "application/json"];
                        connect_timeout=15, readtimeout=30)
        markets = JSON.parse(String(resp.body))

        results = NamedTuple[]
        for m in markets
            slug = get(m, "slug", "")
            question = get(m, "question", "")
            volume = tryparse(Float64, string(get(m, "volume", "0")))
            end_date = get(m, "endDate", "")
            outcomes = get(m, "outcomes", ["Yes", "No"])
            prices_str = get(m, "outcomePrices", "[0.5,0.5]")
            prices = try
                JSON.parse(prices_str isa String ? prices_str : string(prices_str))
            catch
                [0.5, 0.5]
            end

            push!(results, (slug=slug, question=question,
                           volume=volume !== nothing ? volume : 0.0,
                           end_date=end_date, outcomes=outcomes,
                           yes_price=Float64(prices[1]),
                           no_price=length(prices) > 1 ? Float64(prices[2]) : 1.0 - Float64(prices[1])))
        end

        # Sort by volume (most liquid first)
        sort!(results, by=r -> -r.volume)
        return results
    catch e
        @warn "Polymarket markets fetch failed: $(sprint(showerror, e)[1:min(80,end)])"
        return NamedTuple[]
    end
end

"""
    backtest_polymarket_contract(token_id; initial_capital, verbose)

Full backtest pipeline for a specific Polymarket contract.
Fetches historical data, runs the quant layer, and simulates trading.
"""
function backtest_polymarket_contract(token_id::String;
                                       initial_capital::Float64=5000.0,
                                       verbose::Bool=true)
    # Try to fetch real historical data
    data = fetch_polymarket_history(token_id)

    if data === nothing
        verbose && println("  No historical data available — using synthetic simulation")
        data = generate_synthetic_polymarket_data(n_days=120, true_prob=0.6)
    end

    verbose && println("  Data: $(length(data.prices)) bars for $(token_id)")

    return run_polymarket_backtest(data; initial_capital=initial_capital,
                                    verbose=verbose)
end
