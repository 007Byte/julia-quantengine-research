# ── Feature Engineering ───────────────────────────────────────

function compute_features(prices, returns, volumes; high=nothing, low=nothing,
                          book_features::Union{NamedTuple, Nothing}=nothing)
    n = length(returns)
    lookback = 20
    n_feat = 18  # 9 base + 2 fracdiff + 3 microstructure + 3 orderbook + 1 CVD
    X = fill(NaN, n, n_feat)
    for i in lookback:n
        X[i,1] = returns[i]
        X[i,2] = i >= 2 ? returns[i-1] : 0.0
        X[i,3] = i >= 3 ? returns[i-2] : 0.0
        X[i,4] = i >= 4 ? returns[i-3] : 0.0
        X[i,5] = i >= 5 ? returns[i-4] : 0.0
        X[i,6] = std(@view returns[max(1,i-19):i])
        if length(volumes) >= i+1 && volumes[i] > 0
            X[i,7] = (volumes[min(i+1,length(volumes))] - volumes[i]) / volumes[i]
        else
            X[i,7] = 0.0
        end
        if i >= 14
            gains = max.(returns[i-13:i], 0.0)
            losses = max.(-returns[i-13:i], 0.0)
            avg_gain = mean(gains); avg_loss = mean(losses)
            X[i,8] = avg_loss ≈ 0.0 ? 100.0 : 100.0 - 100.0/(1.0 + avg_gain/avg_loss)
        else
            X[i,8] = 50.0
        end
        X[i,9] = i >= 10 ? sum(@view returns[i-9:i]) : 0.0
    end

    # Columns 10-11: Fractional differentiation features
    if length(prices) > 50
        fd = try
            compute_fracdiff_features(Float64.(prices), Float64.(returns))
        catch
            nothing
        end
        if fd !== nothing
            # Align fracdiff output (length = length(prices)) to returns (length = length(prices)-1)
            # prices[2:end] corresponds to returns[1:end]
            fd_price_aligned = fd.fd_price[2:end]  # drop first to align with returns
            fd_logprice_aligned = fd.fd_logprice[2:end]
            for i in lookback:n
                X[i, 10] = isnan(fd_price_aligned[i]) ? 0.0 : fd_price_aligned[i]
                X[i, 11] = isnan(fd_logprice_aligned[i]) ? 0.0 : fd_logprice_aligned[i]
            end
        else
            X[:, 10] .= 0.0
            X[:, 11] .= 0.0
        end
    else
        X[:, 10] .= 0.0
        X[:, 11] .= 0.0
    end

    # Columns 12-14: Microstructure / Order-Flow Features
    for i in lookback:n
        # Feature 12: Bid-Ask Spread Proxy (high-low range / price)
        if high !== nothing && low !== nothing && i < length(high) && i < length(low)
            spread = (high[min(i+1, length(high))] - low[min(i+1, length(low))]) /
                     max(prices[min(i+1, length(prices))], 0.01)
            X[i, 12] = clamp(spread, 0.0, 0.5)
        else
            X[i, 12] = abs(returns[i]) * 2  # fallback: return-based spread estimate
        end

        # Feature 13: Order-Book Imbalance Proxy (volume-weighted price momentum)
        if i >= 5 && length(volumes) >= i
            recent_r = returns[max(1,i-4):i]
            recent_v = volumes[max(1,i-4):min(i, length(volumes))]
            if length(recent_r) == length(recent_v) && sum(recent_v) > 0
                X[i, 13] = dot(recent_r, recent_v) / sum(recent_v)
            else
                X[i, 13] = 0.0
            end
        else
            X[i, 13] = 0.0
        end

        # Feature 14: Trade Velocity (volume acceleration)
        if i >= 5 && length(volumes) > i
            vol_now = mean(volumes[max(1,i-2):min(i, length(volumes))])
            vol_prev = mean(volumes[max(1,i-4):max(1,i-2)])
            X[i, 14] = vol_prev > 0 ? (vol_now - vol_prev) / vol_prev : 0.0
            X[i, 14] = clamp(X[i, 14], -5.0, 5.0)
        else
            X[i, 14] = 0.0
        end
    end

    # Columns 15-17: L2 Order Book Features (when available)
    if book_features !== nothing
        for i in lookback:n
            X[i, 15] = hasproperty(book_features, :depth_imbalance) ? book_features.depth_imbalance : 0.0
            X[i, 16] = hasproperty(book_features, :book_pressure) ? book_features.book_pressure : 0.0
            X[i, 17] = hasproperty(book_features, :spread_bps) && !isnan(book_features.spread_bps) ?
                book_features.spread_bps / 100.0 : 0.0  # normalize to reasonable range
        end
    else
        X[:, 15] .= 0.0
        X[:, 16] .= 0.0
        X[:, 17] .= 0.0
    end

    # Column 18: CVD (Cumulative Volume Delta) divergence score
    if length(prices) > 20 && length(volumes) >= length(prices)
        cvd_result = try
            compute_cvd(Float64.(prices), Float64.(volumes); high=high, low=low)
        catch
            nothing
        end
        if cvd_result !== nothing
            cvd_feats = cvd_to_features(cvd_result, length(prices))
            for i in lookback:n
                # Use divergence score: +1 bullish div, -1 bearish div, ±0.5 confirmation
                X[i, 18] = cvd_feats.divergence_score
            end
        else
            X[:, 18] .= 0.0
        end
    else
        X[:, 18] .= 0.0
    end

    y = zeros(n)
    for i in 1:n-1
        y[i] = returns[min(i+1, n)] > 0 ? 1.0 : 0.0
    end

    valid = [!any(isnan, X[i,:]) for i in 1:size(X,1)]
    X_valid = X[valid, :]
    y_valid = y[valid]

    μ = mean(X_valid, dims=1)
    σ_feat = std(X_valid, dims=1)
    σ_feat[σ_feat .== 0] .= 1.0
    X_std = (X_valid .- μ) ./ σ_feat

    return X_std, y_valid, μ, σ_feat
end

function make_sequences(X, y, seq_len=10)
    n = size(X, 1)
    seqs_X = [X[i:i+seq_len-1, :] for i in 1:n-seq_len]
    seqs_y = [y[i+seq_len] for i in 1:n-seq_len]
    return seqs_X, seqs_y
end

"""Build the full prepared data pipeline and return an AnalysisContext."""
function prepare_context(ticker::AbstractString; output_dir::Union{AbstractString,Nothing}=nothing)
    asset_type = detect_asset_type(ticker)
    display_ticker = asset_type == :polymarket ? replace(ticker, "poly:" => "") : uppercase(ticker)
    out_dir = output_dir === nothing ? make_output_dir(display_ticker) : output_dir

    poly_data = nothing
    if asset_type == :polymarket
        poly_slug = replace(ticker, "poly:" => "")
        poly_data = fetch_polymarket_data(poly_slug)
        market_price = poly_data.prices[1]
        dates   = [Dates.now()]
        prices  = [market_price]
        returns = [0.0]
        volumes = [0.0]
        high    = [market_price]
        low     = [market_price]
    else
        stock = fetch_ohlcv(display_ticker)
        dates   = stock.dates
        prices  = stock.adj
        returns = diff(log.(prices))
        volumes = stock.volume
        high    = stock.high
        low     = stock.low
    end

    S0 = prices[end]
    r_spy = Float64[]
    if asset_type != :polymarket
        spy = try fetch_ohlcv(BENCHMARK) catch; nothing end
        if spy !== nothing
            r_spy = diff(log.(spy.adj))
            common_n = min(length(returns), length(r_spy))
            r_spy = r_spy[end-common_n+1:end]
        end
    end

    # Features
    if asset_type != :polymarket && length(returns) > 30
        X_all, y_all, _, _ = compute_features(prices, returns, volumes; high=high, low=low)
        n_samples = size(X_all, 1)
        split_idx = round(Int, n_samples * 0.8)
        X_train = X_all[1:split_idx, :]
        y_train = y_all[1:split_idx]
        X_test  = X_all[split_idx+1:end, :]
        y_test  = y_all[split_idx+1:end]
        n_features = size(X_all, 2)
    else
        X_train = zeros(1, 18); y_train = [0.5]
        X_test  = zeros(1, 18); y_test  = [0.5]
        n_features = 18
    end

    seq_len = min(10, max(2, div(size(X_train, 1), 5)))
    if size(X_train, 1) > seq_len + 2
        Xseq_train, yseq_train = make_sequences(X_train, y_train, seq_len)
        Xseq_test,  yseq_test  = make_sequences(X_test,  y_test,  seq_len)
    else
        Xseq_train = [reshape(X_train[1,:], 1, :)]
        yseq_train = [y_train[1]]
        Xseq_test  = Xseq_train
        yseq_test  = yseq_train
    end

    ctx = AnalysisContext(
        ticker, asset_type, display_ticker, out_dir,
        dates, prices, returns, volumes, high, low, S0,
        X_train, y_train, X_test, y_test,
        Xseq_train, yseq_train, Xseq_test, yseq_test,
        n_features, seq_len,
        poly_data, r_spy,
        Dict{String, Any}(), RalphLog[], ReentrantLock(),
        nothing  # weight_cache
    )

    # Initialize weight cache for NN model acceleration
    try
        cache_dir = joinpath(homedir(), ".quantengine", "weights")
        mkpath(cache_dir)
        ctx.weight_cache = WeightCache(cache_dir)
        load_cache!(ctx.weight_cache)
    catch; end

    return ctx
end
