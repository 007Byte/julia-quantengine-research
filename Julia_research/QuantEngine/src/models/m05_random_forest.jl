# ── Model 5: Random Forest ──────────────────────────────────
# Edge: Highest raw PNL (up to 104%)

function run_random_forest(X_tr, y_tr, X_te, y_te; n_trees=100, max_depth=4)
    n, p = size(X_tr)
    max_feat = max(1, round(Int, sqrt(p)))

    trees = []
    for _ in 1:n_trees
        idx = rand(1:n, n)  # bootstrap
        feats = sort(shuffle(1:p)[1:max_feat])
        tree = fit_tree(X_tr[idx, :], y_tr[idx], feats, 0, max_depth)
        push!(trees, tree)
    end

    # Predict
    function rf_predict(x)
        preds = [predict_tree(t, x) for t in trees]
        return mean(preds)
    end

    preds_test = [rf_predict(X_te[i, :]) for i in 1:size(X_te, 1)]
    dir_acc = mean((preds_test .> 0.5) .== (y_te .> 0.5))

    # Feature importance (permutation)
    base_acc = dir_acc
    importance = zeros(p)
    for fi in 1:p
        X_perm = copy(X_te)
        X_perm[:, fi] = shuffle(X_perm[:, fi])
        preds_perm = [rf_predict(X_perm[i, :]) for i in 1:size(X_perm, 1)]
        perm_acc = mean((preds_perm .> 0.5) .== (y_te .> 0.5))
        importance[fi] = max(0.0, base_acc - perm_acc)
    end
    if sum(importance) > 0
        importance ./= sum(importance)
    end

    p_up = isempty(preds_test) ? 0.5 : preds_test[end]

    # CPCV accuracy (honest out-of-sample estimate)
    cpcv_acc = NaN
    cpcv_std = NaN
    X_full = vcat(X_tr, X_te)
    y_full = vcat(y_tr, y_te)
    if size(X_full, 1) >= 60
        cpcv_result = try
            cpcv_evaluate(
                (Xtr, ytr, Xte) -> begin
                    local rf_trees = []
                    local n_s = size(Xtr, 1)
                    local mf = max(1, round(Int, sqrt(size(Xtr, 2))))
                    for _ in 1:min(n_trees, 50)  # fewer trees for speed
                        idx = rand(1:n_s, n_s)
                        feats = sort(shuffle(1:size(Xtr, 2))[1:mf])
                        t = fit_tree(Xtr[idx, :], ytr[idx], feats, 0, max_depth)
                        push!(rf_trees, t)
                    end
                    [mean(predict_tree(t, Xte[i, :]) for t in rf_trees) for i in 1:size(Xte, 1)]
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
            feature_importance=importance,
            n_trees=n_trees, predictions=preds_test, model="Random Forest")
end
