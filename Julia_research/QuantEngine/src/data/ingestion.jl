# ── Data Ingestion — Multi-Platform ───────────────────────────

"""Validate ticker symbol against allowlist pattern. Prevents injection via API URLs."""
function validate_ticker(ticker::String)::String
    stripped = strip(ticker)
    if isempty(stripped)
        error("Ticker symbol cannot be empty")
    end
    if length(stripped) > 50
        error("Ticker symbol too long (max 50 chars): '$(stripped[1:20])...'")
    end
    if !occursin(r"^[A-Za-z0-9\.\-:]{1,50}$", stripped)
        error("Invalid ticker symbol — only alphanumeric, '.', '-', ':' allowed: '$(stripped)'")
    end
    return stripped
end

function fetch_ohlcv(ticker::String; period="2y")
    ticker = validate_ticker(ticker)
    url = "https://query1.finance.yahoo.com/v8/finance/chart/$ticker" *
          "?interval=1d&range=$period"
    # HTTP.jl verifies TLS certificates by default (MbedTLS/OpenSSL backend)
    resp = HTTP.get(url, ["User-Agent" => "Mozilla/5.0"];
                    connect_timeout=15, readtimeout=30)
    data = JSON.parse(String(resp.body))
    res  = data["chart"]["result"][1]

    ts  = res["timestamp"]
    q   = res["indicators"]["quote"][1]
    adj = res["indicators"]["adjclose"][1]["adjclose"]
    n   = length(ts)

    get_f(arr, i) = arr[i] === nothing ? NaN : Float64(arr[i])

    dates   = [unix2datetime(ts[i]) for i in 1:n]
    high    = [get_f(q["high"],   i) for i in 1:n]
    low     = [get_f(q["low"],    i) for i in 1:n]
    close_  = [get_f(q["close"],  i) for i in 1:n]
    volume  = [get_f(q["volume"], i) for i in 1:n]
    adj_cls = [get_f(adj,         i) for i in 1:n]

    valid = .!isnan.(adj_cls) .& .!isnan.(close_)
    return (dates=dates[valid], high=high[valid], low=low[valid],
            close=close_[valid], volume=volume[valid], adj=adj_cls[valid])
end

function fetch_polymarket_data(slug::String)
    slug = validate_ticker(slug)
    url = "https://gamma-api.polymarket.com/markets?slug=$slug"
    resp = HTTP.get(url, ["User-Agent" => "Mozilla/5.0"];
                    connect_timeout=15, readtimeout=30)
    data = JSON.parse(String(resp.body))
    if isempty(data)
        error("Polymarket market not found: $slug")
    end
    market = data[1]
    outcomes   = get(market, "outcomes", ["Yes", "No"])
    out_prices = get(market, "outcomePrices", "[0.5,0.5]")
    prices     = JSON.parse(out_prices isa String ? out_prices : string(out_prices))
    return (outcomes=outcomes, prices=Float64.(prices),
            question=get(market, "question", slug),
            volume=get(market, "volume", "0"),
            end_date=get(market, "endDate", ""),
            active=get(market, "active", true))
end
