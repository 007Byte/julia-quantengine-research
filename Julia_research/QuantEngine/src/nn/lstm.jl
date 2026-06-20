# ── LSTM Forward Pass ─────────────────────────────────────────

function lstm_forward(x_seq, Wf, Wi, Wc, Wo, Wy, by, hd)
    h = zeros(hd); c = zeros(hd)
    for t in 1:size(x_seq, 1)
        x = x_seq[t, :]
        combined = vcat(h, x)
        f = σ_nn.(Wf * combined)
        i = σ_nn.(Wi * combined)
        c_hat = tanh.(Wc * combined)
        o = σ_nn.(Wo * combined)
        c = f .* c .+ i .* c_hat
        h = o .* tanh.(c)
    end
    return σ_nn(dot(Wy[:,1], h) + by[1,1])
end
