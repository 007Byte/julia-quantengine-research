# ── Model 7: XGBoost (Regularized Gradient Boosting) ────────
# Edge: Best risk-adjusted returns (Sortino/Sharpe edge)

function run_xgboost(X_tr, y_tr, X_te, y_te, returns, asset_type; n_trees=60, lr=0.08, max_depth=3, λ_reg=1.0)
    n = size(X_tr, 1)
    p = size(X_tr, 2)
    pred_train = fill(mean(y_tr), n)
    trees = []

    for t in 1:n_trees
        residuals = y_tr .- pred_train
        # XGBoost uses L2 regularization in the splits
        tree = fit_tree(X_tr, residuals, collect(1:p), 0, max_depth; min_samples=5, λ=λ_reg)
        push!(trees, tree)
        for i in 1:n
            pred_train[i] += lr * predict_tree(tree, X_tr[i, :])
        end
    end

    function xgb_predict(x)
        base = mean(y_tr)
        for tree in trees
            base += lr * predict_tree(tree, x)
        end
        return σ_nn(base)
    end

    preds_test = [xgb_predict(X_te[i, :]) for i in 1:size(X_te, 1)]
    dir_acc = mean((preds_test .> 0.5) .== (y_te .> 0.5))
    p_up = isempty(preds_test) ? 0.5 : preds_test[end]

    # Compute Sortino on predicted signals
    if length(preds_test) > 5 && asset_type != :polymarket
        test_returns = returns[end-length(preds_test)+1:end]
        signal_returns = [(p > 0.5 ? 1.0 : -1.0) * r for (p, r) in zip(preds_test, test_returns)]
        down = signal_returns[signal_returns .< 0]
        sortino = isempty(down) ? 99.0 : mean(signal_returns) / std(down) * sqrt(252)
    else
        sortino = NaN
    end

    # CPCV accuracy
    cpcv_acc = NaN
    cpcv_std = NaN
    X_full = vcat(X_tr, X_te)
    y_full = vcat(y_tr, y_te)
    if size(X_full, 1) >= 60
        cpcv_result = try
            cpcv_evaluate(
                (Xtr, ytr, Xte) -> begin
                    local n_s = size(Xtr, 1)
                    local p_s = size(Xtr, 2)
                    local pred_tr = fill(mean(ytr), n_s)
                    local xgb_trees = []
                    for _ in 1:min(n_trees, 40)
                        res = ytr .- pred_tr
                        t = fit_tree(Xtr, res, collect(1:p_s), 0, max_depth; min_samples=5, λ=λ_reg)
                        push!(xgb_trees, t)
                        for i in 1:n_s
                            pred_tr[i] += lr * predict_tree(t, Xtr[i, :])
                        end
                    end
                    [σ_nn(mean(ytr) + sum(lr * predict_tree(t, Xte[i, :]) for t in xgb_trees))
                     for i in 1:size(Xte, 1)]
                end,
                X_full, y_full; n_groups=5, n_test_groups=2, purge=3, embargo=2
            )
        catch
            nothing
        end
        if cpcv_result !== nothing
            cpcv_acc = cpcv_result.mean_accuracy
            cpcv_std = cpcv_result.std_accuracy
        end
    end

    return (direction=p_up > 0.5 ? "UP" : "DOWN", probability=p_up,
            accuracy=dir_acc, cpcv_accuracy=cpcv_acc, cpcv_std=cpcv_std,
            sortino=sortino, n_trees=n_trees,
            predictions=preds_test, model="XGBoost", λ=λ_reg)
end
