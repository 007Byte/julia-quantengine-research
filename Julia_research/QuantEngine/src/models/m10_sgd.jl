# ── Model 10: SGD Classifier (Online Learning) ─────────────
# Edge: Highest forward-test PNL in some studies

function run_sgd(X_tr, y_tr, X_te, y_te, returns, asset_type; lr=0.01, epochs=5)
    n, p = size(X_tr)
    w = zeros(p)
    b = 0.0

    # Online SGD with logistic loss
    for epoch in 1:epochs
        order = shuffle(1:n)
        for i in order
            x = X_tr[i, :]
            pred = σ_nn(dot(w, x) + b)
            err = pred - y_tr[i]
            w .-= lr * err .* x
            b -= lr * err
        end
        lr *= 0.95  # decay
    end

    preds_test = [σ_nn(dot(w, X_te[i,:]) + b) for i in 1:size(X_te,1)]
    dir_acc = mean((preds_test .> 0.5) .== (y_te .> 0.5))
    p_up = isempty(preds_test) ? 0.5 : preds_test[end]

    # Online PNL simulation
    if asset_type != :polymarket && length(returns) > size(X_te,1)
        test_r = returns[end-length(preds_test)+1:end]
        positions = [p > 0.5 ? 1.0 : -1.0 for p in preds_test]
        pnl = cumsum(positions .* test_r)
        total_pnl = isempty(pnl) ? 0.0 : pnl[end]
    else
        pnl = Float64[]; total_pnl = 0.0
    end

    return (direction=p_up > 0.5 ? "UP" : "DOWN", probability=p_up,
            accuracy=dir_acc, total_pnl=total_pnl * 100,
            predictions=preds_test, cumulative_pnl=pnl, model="SGD Online")
end
