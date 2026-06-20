# ── Binance Historical Klines (Free Minute Data) ─────────────
# Fetches historical candles from Binance REST API.
# No API key required for public endpoints.
# Rate limit: 1200 requests/min (we use conservative 500ms between requests).
#
# Supported intervals: 1m, 3m, 5m, 15m, 30m, 1h, 2h, 4h, 6h, 8h, 12h, 1d
# Max 1000 candles per request — paginate for longer periods.

"""
    fetch_binance_klines(ticker; interval, start_date, end_date, cache_dir)

Fetch historical OHLCV candles from Binance REST API.
Returns a NamedTuple matching `fetch_ohlcv()` format: (dates, high, low, close, volume, adj).

Only works for crypto tickers (BTC-USD, ETH-USD, SOL-USD, etc.).
Automatically converts to Binance format (BTCUSDT).
"""
function fetch_binance_klines(ticker::String;
                               interval::String="1m",
                               start_date::Date=today() - Day(30),
                               end_date::Date=today(),
                               cache_dir::String="")
    # Convert ticker format: BTC-USD → BTCUSDT
    symbol = _ticker_to_binance_symbol(ticker)

    # Check JLD2 cache first
    if !isempty(cache_dir)
        cache_file = joinpath(cache_dir, "binance_$(symbol)_$(interval)_$(start_date)_$(end_date).jld2")
        if isfile(cache_file)
            try
                data = JLD2.load(cache_file, "data")
                return data
            catch
                rm(cache_file; force=true)
            end
        end
    end

    # Fetch from Binance API with pagination
    all_candles = Vector{Vector{Any}}()
    start_ms = Int64(datetime2unix(DateTime(start_date))) * 1000
    end_ms = Int64(datetime2unix(DateTime(end_date, Time(23, 59, 59)))) * 1000

    # Try binance.us first (for US users), fall back to binance.com
    base_urls = ["https://api.binance.us", "https://api.binance.com"]
    active_base = base_urls[1]

    while start_ms < end_ms
        url = "$active_base/api/v3/klines?" *
              "symbol=$symbol&interval=$interval&startTime=$start_ms&endTime=$end_ms&limit=1000"

        resp = try
            HTTP.get(url; headers=["User-Agent" => "QuantEngine/8.0"],
                     connect_timeout=10, readtimeout=30)
        catch e
            # If first URL fails with 451 (geo-block), try alternative
            if active_base == base_urls[1] && length(base_urls) > 1
                active_base = base_urls[2]
                @warn "Binance US failed, trying binance.com..."
                try
                    url2 = "$active_base/api/v3/klines?" *
                            "symbol=$symbol&interval=$interval&startTime=$start_ms&endTime=$end_ms&limit=1000"
                    HTTP.get(url2; headers=["User-Agent" => "QuantEngine/8.0"],
                             connect_timeout=10, readtimeout=30)
                catch e2
                    @warn "Binance API request failed: $(sprint(showerror, e2)[1:min(60,end)])"
                    break
                end
            else
                @warn "Binance API request failed: $(sprint(showerror, e)[1:min(60,end)])"
                break
            end
        end

        if resp.status != 200
            @warn "Binance API returned status $(resp.status)"
            break
        end

        candles = JSON.parse(String(resp.body))
        if isempty(candles)
            break
        end

        append!(all_candles, candles)

        # Move start time past the last candle's close time
        last_close_time = candles[end][7]  # close time in ms (index 7)
        start_ms = last_close_time + 1

        # Rate limiting: 500ms between requests
        sleep(0.5)
    end

    if isempty(all_candles)
        error("No data returned from Binance for $symbol ($interval, $start_date → $end_date)")
    end

    # Parse candles into named tuple format matching fetch_ohlcv()
    # Binance kline format: [open_time, open, high, low, close, volume, close_time, ...]
    n = length(all_candles)
    dates  = Vector{DateTime}(undef, n)
    high   = Vector{Float64}(undef, n)
    low    = Vector{Float64}(undef, n)
    close_ = Vector{Float64}(undef, n)
    volume = Vector{Float64}(undef, n)

    for (i, c) in enumerate(all_candles)
        dates[i]  = unix2datetime(c[1] / 1000.0)
        high[i]   = parse(Float64, string(c[3]))
        low[i]    = parse(Float64, string(c[4]))
        close_[i] = parse(Float64, string(c[5]))
        volume[i] = parse(Float64, string(c[6]))
    end

    result = (dates=dates, high=high, low=low, close=close_, volume=volume, adj=close_)

    # Save to cache
    if !isempty(cache_dir)
        mkpath(cache_dir)
        cache_file = joinpath(cache_dir, "binance_$(symbol)_$(interval)_$(start_date)_$(end_date).jld2")
        try
            JLD2.save(cache_file, "data", result)
        catch e
            @warn "Failed to cache Binance data: $(sprint(showerror, e)[1:min(60,end)])"
        end
    end

    return result
end

"""Convert QuantEngine ticker format to Binance symbol (BTC-USD → BTCUSDT)."""
function _ticker_to_binance_symbol(ticker::String)::String
    t = uppercase(strip(ticker))
    # Handle common formats
    t = replace(t, "-USD" => "USDT")
    t = replace(t, "/" => "")
    t = replace(t, "-" => "")
    return t
end
