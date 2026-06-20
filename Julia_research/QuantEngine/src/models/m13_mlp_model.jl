# ── Model 13: MLP (Multi-Layer Perceptron) ──────────────────
# Edge: Fast baseline in hybrids

function run_mlp(X_tr, y_tr, X_te, y_te, n_feat;
                 h1=16, h2=8, cache::Union{WeightCache,Nothing}=nothing, ticker::String="")
    shapes = [(h1, n_feat), (h1, 1),    # W1, b1
              (h2, h1), (h2, 1),          # W2, b2
              (1, h2), (1, 1)]            # W3, b3
    np = total_params(shapes)

    function train_fn()
        θ0 = randn(np) * 0.1
        function loss(θ)
            ws = unpack_weights(θ, shapes)
            W1,b1,W2,b2,W3,b3 = ws[1],ws[2],ws[3],ws[4],ws[5],ws[6]
            total = 0.0
            for i in 1:size(X_tr, 1)
                pred = mlp_forward(X_tr[i,:], W1, b1, W2, b2, W3, b3)
                total += -(y_tr[i]*log(pred+1e-8) + (1-y_tr[i])*log(1-pred+1e-8))
            end
            return total / size(X_tr, 1) + 1e-4 * sum(θ.^2)
        end
        opt = optimize(loss, θ0, LBFGS(), Optim.Options(iterations=40, show_trace=false))
        return (Optim.minimizer(opt), shapes, 0.5, Optim.minimum(opt))
    end

    ws = if cache !== nothing && !isempty(ticker)
        get_cached_or_train(cache, 13, ticker, n_feat, X_tr, train_fn)
    else
        θ_star, _, _, _ = train_fn()
        unpack_weights(θ_star, shapes)
    end
    W1,b1,W2,b2,W3,b3 = ws[1],ws[2],ws[3],ws[4],ws[5],ws[6]

    preds = [mlp_forward(X_te[i,:], W1, b1, W2, b2, W3, b3) for i in 1:size(X_te,1)]
    dir_acc = mean((preds .> 0.5) .== (y_te .> 0.5))
    p_up = isempty(preds) ? 0.5 : preds[end]

    return (direction=p_up > 0.5 ? "UP" : "DOWN", probability=p_up,
            accuracy=dir_acc, predictions=preds, model="MLP", n_params=np)
end
