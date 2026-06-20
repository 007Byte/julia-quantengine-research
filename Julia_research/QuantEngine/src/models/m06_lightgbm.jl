# ── Model 6: LightGBM (Gradient Boosting - leaf-wise) ───────
# Edge: Fast ensembles for stock/crypto signals

function run_lightgbm(X_tr, y_tr, X_te, y_te; n_trees=60, lr=0.1, max_depth=3)
    n = size(X_tr, 1)
    p = size(X_tr, 2)
    pred_train = fill(mean(y_tr), n)
    trees = []

    for t in 1:n_trees
        residuals = y_tr .- pred_train
        # Histogram-based: bin features into 32 bins
        tree = fit_tree(X_tr, residuals, collect(1:p), 0, max_depth; min_samples=6)
        push!(trees, tree)
        for i in 1:n
            pred_train[i] += lr * predict_tree(tree, X_tr[i, :])
        end
    end

    function gb_predict(x)
        base = mean(y_tr)
        for tree in trees
            base += lr * predict_tree(tree, x)
        end
        return σ_nn(base)  # squash to probability
    end

    preds_test = [gb_predict(X_te[i, :]) for i in 1:size(X_te, 1)]
    dir_acc = mean((preds_test .> 0.5) .== (y_te .> 0.5))
    p_up = isempty(preds_test) ? 0.5 : preds_test[end]

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
                    local gb_trees = []
                    for _ in 1:min(n_trees, 40)
                        res = ytr .- pred_tr
                        t = fit_tree(Xtr, res, collect(1:p_s), 0, max_depth; min_samples=6)
                        push!(gb_trees, t)
                        for i in 1:n_s
                            pred_tr[i] += lr * predict_tree(t, Xtr[i, :])
                        end
                    end
                    [σ_nn(mean(ytr) + sum(lr * predict_tree(t, Xte[i, :]) for t in gb_trees))
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
            n_trees=n_trees, learning_rate=lr,
            predictions=preds_test, model="LightGBM")
end
