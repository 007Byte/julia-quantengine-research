# ── Model 8: Conv-LSTM / CNN-LSTM ───────────────────────────
# Edge: Superior multivariate crypto forecasts

function run_conv_lstm(Xseq_tr, yseq_tr, Xseq_te, yseq_te, n_feat; hidden=8, n_filters=4, kernel=3,
                       cache::Union{WeightCache,Nothing}=nothing, ticker::String="")
    # 1D convolution on feature matrix, then LSTM on conv output
    hd = hidden
    conv_out = n_filters
    gi = hd + conv_out

    # Conv1D weights: n_filters kernels of size (kernel x n_feat)
    shapes_conv = [(n_filters, kernel * n_feat)]  # W_conv (flattened kernel)
    shapes_lstm = [(hd, gi), (hd, gi), (hd, gi), (hd, gi)]  # Wf, Wi, Wc, Wo
    shapes_out  = [(hd, 1), (1, 1)]  # Wy, by
    all_shapes  = vcat(shapes_conv, shapes_lstm, shapes_out)
    np = total_params(all_shapes)
    function conv1d_forward(x_seq, W_conv)
        # x_seq: (seq_len, n_feat) -> apply conv across time
        sl = size(x_seq, 1)
        out_len = max(1, sl - kernel + 1)
        conv_result = zeros(out_len, n_filters)
        for t in 1:out_len
            patch = vec(x_seq[t:t+kernel-1, :])  # (kernel * n_feat,)
            conv_result[t, :] = W_conv * patch
        end
        return max.(conv_result, 0.0)  # ReLU
    end

    function train_fn()
        θ0 = randn(np) * 0.1
        function loss(θ)
            ws = unpack_weights(θ, all_shapes)
            W_conv = ws[1]
            Wf, Wi, Wc, Wo = ws[2], ws[3], ws[4], ws[5]
            Wy, by = ws[6], ws[7]
            total = 0.0
            for (xseq, y) in zip(Xseq_tr, yseq_tr)
                conv_out_seq = conv1d_forward(xseq, W_conv)
                if size(conv_out_seq, 1) < 1 continue end
                # Run LSTM on conv output
                h = zeros(hd); c = zeros(hd)
                for t in 1:size(conv_out_seq, 1)
                    x = conv_out_seq[t, :]
                    combined = vcat(h, x)
                    f = σ_nn.(Wf * combined); i = σ_nn.(Wi * combined)
                    c_hat = tanh.(Wc * combined); o = σ_nn.(Wo * combined)
                    c = f .* c .+ i .* c_hat
                    h = o .* tanh.(c)
                end
                pred = σ_nn(dot(Wy[:,1], h) + by[1,1])
                total += -(y * log(pred + 1e-8) + (1-y) * log(1-pred + 1e-8))
            end
            return total / max(1, length(Xseq_tr)) + 1e-4 * sum(θ .^ 2)
        end
        opt = optimize(loss, θ0, LBFGS(), Optim.Options(iterations=25, show_trace=false))
        return (Optim.minimizer(opt), all_shapes, 0.5, Optim.minimum(opt))
    end

    ws = if cache !== nothing && !isempty(ticker)
        get_cached_or_train(cache, 8, ticker, n_feat, Xseq_tr, train_fn)
    else
        θ_star, _, _, _ = train_fn()
        unpack_weights(θ_star, all_shapes)
    end

    # Test predictions -- reuse conv1d_forward for consistency
    function predict_conv_lstm(xseq)
        conv_out_seq = conv1d_forward(xseq, ws[1])
        h = zeros(hd); c = zeros(hd)
        for t in 1:size(conv_out_seq, 1)
            x = conv_out_seq[t, :]
            combined = vcat(h, x)
            f = σ_nn.(ws[2] * combined); i = σ_nn.(ws[3] * combined)
            c_hat = tanh.(ws[4] * combined); o = σ_nn.(ws[5] * combined)
            c = f .* c .+ i .* c_hat; h = o .* tanh.(c)
        end
        return σ_nn(dot(ws[6][:,1], h) + ws[7][1,1])
    end

    preds_test = [predict_conv_lstm(x) for x in Xseq_te]
    dir_acc = isempty(preds_test) ? 0.5 : mean((preds_test .> 0.5) .== (yseq_te .> 0.5))
    p_up = isempty(preds_test) ? 0.5 : preds_test[end]

    return (direction=p_up > 0.5 ? "UP" : "DOWN", probability=p_up,
            accuracy=dir_acc, n_filters=n_filters, kernel_size=kernel,
            predictions=preds_test, model="Conv-LSTM", n_params=np)
end
