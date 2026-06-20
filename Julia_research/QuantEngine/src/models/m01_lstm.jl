# ── Model 1: LSTM (BD-LSTM/ED-LSTM) ─────────────────────────
# Edge: Lowest RMSE in crypto price forecasting

function run_lstm(Xseq_tr, yseq_tr, Xseq_te, yseq_te, n_feat;
                  hidden=8, cache::Union{WeightCache,Nothing}=nothing, ticker::String="")
    hd = hidden
    gi = hd + n_feat  # gate input dimension
    shapes = [(hd, gi), (hd, gi), (hd, gi), (hd, gi),  # Wf, Wi, Wc, Wo
              (hd, 1), (1, 1)]                           # Wy, by
    np = total_params(shapes)

    function train_fn()
        θ0 = randn(np) * 0.1
        function loss(θ)
            ws = unpack_weights(θ, shapes)
            Wf, Wi, Wc, Wo, Wy, by = ws[1], ws[2], ws[3], ws[4], ws[5], ws[6]
            total = 0.0
            for (xseq, y) in zip(Xseq_tr, yseq_tr)
                pred = lstm_forward(xseq, Wf, Wi, Wc, Wo, Wy, by, hd)
                total += -(y * log(pred + 1e-8) + (1-y) * log(1-pred + 1e-8))
            end
            return total / length(Xseq_tr) + 1e-4 * sum(θ .^ 2)
        end
        opt = optimize(loss, θ0, LBFGS(),
                       Optim.Options(iterations=30, g_tol=1e-4, show_trace=false))
        return (Optim.minimizer(opt), shapes, 0.5, Optim.minimum(opt))
    end

    ws = if cache !== nothing && !isempty(ticker)
        get_cached_or_train(cache, 1, ticker, n_feat, Xseq_tr, train_fn)
    else
        θ_star, _, _, _ = train_fn()
        unpack_weights(θ_star, shapes)
    end
    Wf, Wi, Wc, Wo, Wy, by = ws[1], ws[2], ws[3], ws[4], ws[5], ws[6]

    # Predictions
    preds_test = [lstm_forward(x, Wf, Wi, Wc, Wo, Wy, by, hd) for x in Xseq_te]
    dir_acc = isempty(preds_test) ? 0.5 :
        mean((preds_test .> 0.5) .== (yseq_te .> 0.5))
    rmse = isempty(preds_test) ? NaN :
        sqrt(mean((preds_test .- yseq_te) .^ 2))
    p_up = isempty(preds_test) ? 0.5 : preds_test[end]

    return (direction=p_up > 0.5 ? "UP" : "DOWN", probability=p_up,
            accuracy=dir_acc, rmse=rmse, predictions=preds_test,
            model="LSTM (BD/ED)", n_params=np)
end
