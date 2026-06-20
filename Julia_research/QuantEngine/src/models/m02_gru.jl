# ── Model 2: GRU ────────────────────────────────────────────
# Edge: Highest directional accuracy in high-frequency data

function run_gru(Xseq_tr, yseq_tr, Xseq_te, yseq_te, n_feat;
                 hidden=8, cache::Union{WeightCache,Nothing}=nothing, ticker::String="")
    hd = hidden
    gi = hd + n_feat
    shapes = [(hd, gi), (hd, gi), (hd, gi),   # Wz, Wr, Wh
              (hd, 1), (1, 1)]                  # Wy, by
    np = total_params(shapes)

    function train_fn()
        θ0 = randn(np) * 0.1
        function loss(θ)
            ws = unpack_weights(θ, shapes)
            Wz, Wr, Wh, Wy, by = ws[1], ws[2], ws[3], ws[4], ws[5]
            total = 0.0
            for (xseq, y) in zip(Xseq_tr, yseq_tr)
                pred = gru_forward(xseq, Wz, Wr, Wh, Wy, by, hd)
                total += -(y * log(pred + 1e-8) + (1-y) * log(1-pred + 1e-8))
            end
            return total / length(Xseq_tr) + 1e-4 * sum(θ .^ 2)
        end
        opt = optimize(loss, θ0, LBFGS(),
                       Optim.Options(iterations=30, g_tol=1e-4, show_trace=false))
        return (Optim.minimizer(opt), shapes, 0.5, Optim.minimum(opt))
    end

    ws = if cache !== nothing && !isempty(ticker)
        get_cached_or_train(cache, 2, ticker, n_feat, Xseq_tr, train_fn)
    else
        θ_star, _, _, _ = train_fn()
        unpack_weights(θ_star, shapes)
    end
    Wz, Wr, Wh, Wy, by = ws[1], ws[2], ws[3], ws[4], ws[5]

    preds_test = [gru_forward(x, Wz, Wr, Wh, Wy, by, hd) for x in Xseq_te]
    dir_acc = isempty(preds_test) ? 0.5 :
        mean((preds_test .> 0.5) .== (yseq_te .> 0.5))
    p_up = isempty(preds_test) ? 0.5 : preds_test[end]

    return (direction=p_up > 0.5 ? "UP" : "DOWN", probability=p_up,
            accuracy=dir_acc, model="GRU", n_params=np,
            predictions=preds_test)
end
