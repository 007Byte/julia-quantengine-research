# ── Model 9: BiLSTM (Bidirectional) ─────────────────────────
# Edge: Handles pre-/post-event shifts perfectly

function run_bilstm(Xseq_tr, yseq_tr, Xseq_te, yseq_te, n_feat; hidden=6,
                    cache::Union{WeightCache,Nothing}=nothing, ticker::String="")
    hd = hidden
    gi = hd + n_feat

    # Forward LSTM + Backward LSTM + output layer
    # 4 gates each × 2 directions + output from 2*hidden
    shapes_fwd = [(hd,gi),(hd,gi),(hd,gi),(hd,gi)]  # Wf,Wi,Wc,Wo forward
    shapes_bwd = [(hd,gi),(hd,gi),(hd,gi),(hd,gi)]  # Wf,Wi,Wc,Wo backward
    shapes_out = [(2*hd, 1), (1, 1)]                  # Wy, by
    all_shapes = vcat(shapes_fwd, shapes_bwd, shapes_out)
    np = total_params(all_shapes)
    function bilstm_forward(xseq, ws)
        # Forward pass
        h_f = zeros(hd); c_f = zeros(hd)
        for t in 1:size(xseq, 1)
            x = xseq[t, :]; combined = vcat(h_f, x)
            f = σ_nn.(ws[1]*combined); i = σ_nn.(ws[2]*combined)
            ch = tanh.(ws[3]*combined); o = σ_nn.(ws[4]*combined)
            c_f = f .* c_f .+ i .* ch; h_f = o .* tanh.(c_f)
        end
        # Backward pass
        h_b = zeros(hd); c_b = zeros(hd)
        for t in size(xseq, 1):-1:1
            x = xseq[t, :]; combined = vcat(h_b, x)
            f = σ_nn.(ws[5]*combined); i = σ_nn.(ws[6]*combined)
            ch = tanh.(ws[7]*combined); o = σ_nn.(ws[8]*combined)
            c_b = f .* c_b .+ i .* ch; h_b = o .* tanh.(c_b)
        end
        h_cat = vcat(h_f, h_b)
        return σ_nn(dot(ws[9][:,1], h_cat) + ws[10][1,1])
    end

    function train_fn()
        θ0 = randn(np) * 0.1
        function loss(θ)
            ws = unpack_weights(θ, all_shapes)
            total = 0.0
            for (xseq, y) in zip(Xseq_tr, yseq_tr)
                pred = bilstm_forward(xseq, ws)
                total += -(y*log(pred+1e-8) + (1-y)*log(1-pred+1e-8))
            end
            return total / max(1, length(Xseq_tr)) + 1e-4 * sum(θ.^2)
        end
        opt = optimize(loss, θ0, LBFGS(), Optim.Options(iterations=25, show_trace=false))
        return (Optim.minimizer(opt), all_shapes, 0.5, Optim.minimum(opt))
    end

    ws = if cache !== nothing && !isempty(ticker)
        get_cached_or_train(cache, 9, ticker, n_feat, Xseq_tr, train_fn)
    else
        θ_star, _, _, _ = train_fn()
        unpack_weights(θ_star, all_shapes)
    end

    preds = [bilstm_forward(x, ws) for x in Xseq_te]
    dir_acc = isempty(preds) ? 0.5 : mean((preds .> 0.5) .== (yseq_te .> 0.5))
    p_up = isempty(preds) ? 0.5 : preds[end]

    # Regime detection: high prob = trending, ~0.5 = mean-reverting
    regime = p_up > 0.6 ? "TRENDING UP" : p_up < 0.4 ? "TRENDING DOWN" : "MEAN-REVERTING"

    return (direction=p_up > 0.5 ? "UP" : "DOWN", probability=p_up,
            accuracy=dir_acc, regime=regime, predictions=preds,
            model="BiLSTM", n_params=np)
end
