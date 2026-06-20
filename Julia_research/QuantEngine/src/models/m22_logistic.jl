# -- Model 22: Logistic Regression (Post-Trade Continuation) -----------------
# Formula: P(y=1|x) = sigma(beta_0 + beta^T x)
# Edge: Interpretable baseline -- "liquidity noise or real info?"

function run_logistic_regression(returns, prices, volumes)
    r = returns
    n = length(r)
    if n < 30
        return (direction="HOLD", probability=0.5, accuracy=NaN,
                coefficients=Float64[], feature_names=String[],
                continuation_signal=false, model="Logistic Regression (Post-Trade)")
    end

    # Features designed for post-trade continuation detection:
    #  1. Orderbook imbalance proxy (volume direction asymmetry)
    #  2. Trade direction (sign of last return)
    #  3. Trade size proxy (|return| relative to rolling vol)
    #  4. Rolling volume ratio (recent vs avg)
    #  5. Bid-ask spread proxy (high-low range / close)
    #  6. Recent volatility (5-day std)
    #  7. Time momentum (3-day cumulative return)

    feat_names = ["OB_Imbalance", "Trade_Dir", "Trade_Size",
                  "Vol_Ratio", "BA_Spread", "Recent_Vol", "Momentum_3d"]
    n_feat = length(feat_names)
    X = fill(NaN, n, n_feat)

    for i in 6:n
        # 1. Orderbook imbalance proxy: ratio of up-volume to total
        up_vol = sum(volumes[max(1,i-4):i] .* (r[max(1,i-4):i] .> 0))
        dn_vol = sum(volumes[max(1,i-4):i] .* (r[max(1,i-4):i] .<= 0))
        X[i,1] = (up_vol - dn_vol) / max(up_vol + dn_vol, 1.0)

        # 2. Trade direction (sign of last return)
        X[i,2] = sign(r[i])

        # 3. Trade size: |return| / rolling 20-day vol
        rv = std(@view r[max(1,i-19):i])
        X[i,3] = rv > 1e-8 ? abs(r[i]) / rv : 0.0

        # 4. Rolling volume ratio: 5-day avg / 20-day avg
        vol_5  = mean(@view volumes[max(1,i-4):i])
        vol_20 = mean(@view volumes[max(1,i-19):i])
        X[i,4] = vol_20 > 0 ? vol_5 / vol_20 : 1.0

        # 5. Bid-ask spread proxy: (high-low)/close range
        if i <= length(prices)
            hi = maximum(@view prices[max(1,i-4):min(i,length(prices))])
            lo = minimum(@view prices[max(1,i-4):min(i,length(prices))])
            X[i,5] = prices[i] > 0 ? (hi - lo) / prices[i] : 0.0
        else
            X[i,5] = 0.0
        end

        # 6. Recent volatility (5-day)
        X[i,6] = std(@view r[max(1,i-4):i])

        # 7. Momentum (3-day cumulative return)
        X[i,7] = sum(@view r[max(1,i-2):i])
    end

    # Labels: continuation = next return same sign as current (1=yes, 0=no)
    y = zeros(n)
    for i in 1:n-1
        y[i] = sign(r[i]) == sign(r[min(i+1, n)]) ? 1.0 : 0.0
    end

    # Filter valid rows
    valid = [!any(isnan, X[i,:]) && i < n for i in 1:n]
    X_v = X[valid, :]
    y_v = y[valid]

    if size(X_v, 1) < 20
        return (direction="HOLD", probability=0.5, accuracy=NaN,
                coefficients=zeros(n_feat), feature_names=feat_names,
                continuation_signal=false, model="Logistic Regression (Post-Trade)")
    end

    # Standardize
    mu_x = mean(X_v, dims=1); sigma_x = std(X_v, dims=1)
    sigma_x[sigma_x .== 0] .= 1.0
    X_s = (X_v .- mu_x) ./ sigma_x

    # Train/test split
    split = round(Int, size(X_s,1) * 0.8)
    Xtr, ytr = X_s[1:split, :], y_v[1:split]
    Xte, yte = X_s[split+1:end, :], y_v[split+1:end]

    # Fit logistic regression via Optim.jl (MLE)
    function log_reg_nll(beta)
        beta0 = beta[1]; w = beta[2:end]
        ll = 0.0
        for i in 1:size(Xtr, 1)
            z = beta0 + dot(w, Xtr[i, :])
            p = sigma_nn(z)
            ll += ytr[i] * log(p + 1e-10) + (1 - ytr[i]) * log(1 - p + 1e-10)
        end
        return -ll / size(Xtr, 1) + 0.01 * sum(w .^ 2)  # L2 regularization
    end

    beta0_init = zeros(n_feat + 1)
    opt = optimize(log_reg_nll, beta0_init, LBFGS(),
                   Optim.Options(iterations=100, show_trace=false))
    beta_star = Optim.minimizer(opt)
    b0 = beta_star[1]; w = beta_star[2:end]

    # Test predictions
    preds = [sigma_nn(b0 + dot(w, Xte[i,:])) for i in 1:size(Xte,1)]
    dir_acc = mean((preds .> 0.5) .== (yte .> 0.5))
    p_continuation = isempty(preds) ? 0.5 : preds[end]

    # Interpretation: positive coeff = continuation, negative = mean-reversion
    continuation_signal = p_continuation > 0.55

    # Signal for downstream: does the last trade look like real information?
    direction = continuation_signal ? "CONTINUATION (ride)" : "MEAN-REVERSION (fade)"

    return (direction=direction, probability=p_continuation,
            accuracy=dir_acc, coefficients=w, intercept=b0,
            feature_names=feat_names, continuation_signal=continuation_signal,
            top_feature=feat_names[argmax(abs.(w))],
            top_coeff=w[argmax(abs.(w))],
            model="Logistic Regression (Post-Trade)")
end
