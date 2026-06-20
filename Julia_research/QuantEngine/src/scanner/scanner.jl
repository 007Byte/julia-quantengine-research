# ── Multi-Ticker Scanner ──────────────────────────────────────
# Scans a universe of tickers using a fast subset of models,
# ranks by composite signal strength, and returns top opportunities.

"""Result of scanning a single ticker."""
struct ScanResult
    ticker::String
    asset_type::Symbol
    price::Float64
    direction::String          # BUY / LEAN BUY / HOLD / LEAN SELL / DO NOT BUY
    score::Float64             # [-1, 1] composite score
    p_true::Float64            # ensemble probability
    confidence::Int
    n_models::Int
    kelly_frac::Float64        # recommended Kelly fraction
    daily_vol::Float64         # annualized volatility
    scan_time_ms::Float64
end

"""Configuration for the scanner."""
struct ScanConfig
    model_ids::Vector{Int}     # which models to run (fast subset)
    top_n::Int                 # return top N results
    min_score::Float64         # minimum absolute score to include
    verbose::Bool
end

function ScanConfig(; fast_only::Bool=true, top_n::Int=10,
                     min_score::Float64=0.05, verbose::Bool=false)
    models = if fast_only
        # Fast models only: RF, LightGBM, XGBoost, SGD, GARCH, Kelly, EV Gap,
        # Logistic, AR(1), FracDiff, Triple-Barrier
        [5, 6, 7, 10, 14, 17, 22, 23, 29, 30]
    else
        collect(1:N_MODELS)
    end
    ScanConfig(models, top_n, min_score, verbose)
end

"""
    scan_universe(tickers; config) → Vector{ScanResult}

Scan multiple tickers and return ranked opportunities.
Uses a fast subset of models for speed (~2-5 sec per ticker).
"""
function scan_universe(tickers::Vector{String};
                       config::ScanConfig=ScanConfig())
    if isempty(MODEL_DISPATCH)
        _register_models!()
    end

    results = ScanResult[]
    n = length(tickers)

    if config.verbose
        println("═" ^ 64)
        println("  SCANNER — Scanning $n tickers")
        println("  Models: $(length(config.model_ids)) | Top: $(config.top_n)")
        println("═" ^ 64)
    end

    for (idx, ticker) in enumerate(tickers)
        t0 = time_ns()
        result = try
            _scan_single(ticker, config)
        catch e
            if config.verbose
                @printf("  [%3d/%d] %-12s FAILED: %s\n", idx, n, ticker,
                        sprint(showerror, e)[1:min(50, end)])
            end
            nothing
        end
        elapsed = (time_ns() - t0) / 1e6

        if result !== nothing
            push!(results, ScanResult(
                result.ticker, result.asset_type, result.price,
                result.direction, result.score, result.p_true,
                result.confidence, result.n_models,
                result.kelly_frac, result.daily_vol, elapsed
            ))
            if config.verbose
                @printf("  [%3d/%d] %-12s %6s  score=%+.3f  p=%.3f  (%.0fms)\n",
                        idx, n, ticker, result.direction, result.score,
                        result.p_true, elapsed)
            end
        end
    end

    # Filter by minimum score
    filtered = filter(r -> abs(r.score) >= config.min_score, results)

    # Sort by absolute score (strongest signals first)
    sort!(filtered, by=r -> -abs(r.score))

    # Return top N
    top = filtered[1:min(config.top_n, length(filtered))]

    if config.verbose
        println()
        println("  TOP $(length(top)) OPPORTUNITIES:")
        println("  " * "-" ^ 60)
        @printf("  %-12s %8s %8s %8s %8s %8s\n",
                "Ticker", "Dir", "Score", "P(up)", "Kelly%", "Vol%")
        println("  " * "-" ^ 60)
        for r in top
            @printf("  %-12s %8s %+8.3f %8.3f %7.1f%% %7.1f%%\n",
                    r.ticker, r.direction, r.score, r.p_true,
                    r.kelly_frac * 100, r.daily_vol * 100)
        end
        println("  " * "-" ^ 60)
    end

    return top
end

"""Scan a single ticker with the fast model subset."""
function _scan_single(ticker::String, config::ScanConfig)
    ticker = validate_ticker(ticker)
    asset_type = detect_asset_type(ticker)
    display_ticker = asset_type == :polymarket ? replace(ticker, "poly:" => "") : uppercase(ticker)

    # Fetch data
    if asset_type == :polymarket
        return nothing  # scanner doesn't support polymarket yet
    end

    stock = try
        fetch_ohlcv(display_ticker; period="1y")
    catch
        return nothing
    end

    prices = stock.adj
    returns = diff(log.(prices))
    volumes = stock.volume

    if length(returns) < 50
        return nothing
    end

    # Build context
    X_all, y_all, _, _ = compute_features(prices, returns, volumes)
    n_samples = size(X_all, 1)
    if n_samples < 30
        return nothing
    end

    split_idx = round(Int, n_samples * 0.8)
    X_train = X_all[1:split_idx, :]
    y_train = y_all[1:split_idx]
    X_test = X_all[split_idx+1:end, :]
    y_test = y_all[split_idx+1:end]

    seq_len = min(10, max(2, div(size(X_train, 1), 5)))
    if size(X_train, 1) > seq_len + 2
        Xseq_train, yseq_train = make_sequences(X_train, y_train, seq_len)
        Xseq_test, yseq_test = make_sequences(X_test, y_test, seq_len)
    else
        Xseq_train = [reshape(X_train[1,:], 1, :)]
        yseq_train = [y_train[1]]
        Xseq_test = Xseq_train
        yseq_test = yseq_train
    end

    out_dir = mktempdir()
    ctx = AnalysisContext(
        ticker, asset_type, display_ticker, out_dir,
        stock.dates, prices, returns, volumes, stock.high, stock.low, prices[end],
        X_train, y_train, X_test, y_test,
        Xseq_train, yseq_train, Xseq_test, yseq_test,
        size(X_all, 2), seq_len,
        nothing, Float64[],
        Dict{String,Any}(), RalphLog[], ReentrantLock(),
        nothing  # weight_cache
    )

    # Run fast models only
    phase1 = filter(m -> !(m in PHASE2_MODELS), config.model_ids)
    phase2 = filter(m -> m in PHASE2_MODELS, config.model_ids)

    for m in phase1
        run_model(ctx, m; verbose=false)
    end
    for m in phase2
        run_model(ctx, m; verbose=false)
    end

    # Composite signal
    comp = compute_composite(ctx.results)

    # Extract Kelly and vol
    kelly_r = get(ctx.results, "17. Kelly Criterion", nothing)
    kelly_frac = if kelly_r isa NamedTuple && hasproperty(kelly_r, :kelly_quarter)
        clamp(kelly_r.kelly_quarter, 0.0, 0.5)
    else
        0.0
    end

    garch_r = get(ctx.results, "14. EGARCH/GARCH Family", nothing)
    daily_vol = if garch_r isa NamedTuple && hasproperty(garch_r, :σ_annual_forecast)
        garch_r.σ_annual_forecast / sqrt(252)
    else
        std(returns)
    end

    return (ticker=display_ticker, asset_type=asset_type, price=prices[end],
            direction=comp.direction, score=comp.score, p_true=comp.p_true,
            confidence=comp.confidence, n_models=comp.n_directional,
            kelly_frac=kelly_frac, daily_vol=daily_vol)
end

"""Load tickers from a text file (one per line)."""
function load_watchlist(filepath::String)::Vector{String}
    lines = readlines(filepath)
    return filter(!isempty, strip.(lines))
end
