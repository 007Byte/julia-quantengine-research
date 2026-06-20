# ── GRU Forward Pass ──────────────────────────────────────────

function gru_forward(x_seq, Wz, Wr, Wh, Wy, by, hd)
    h = zeros(hd)
    for t in 1:size(x_seq, 1)
        x = x_seq[t, :]
        combined = vcat(h, x)
        z = σ_nn.(Wz * combined)
        r = σ_nn.(Wr * combined)
        combined_r = vcat(r .* h, x)
        h_hat = tanh.(Wh * combined_r)
        h = (1.0 .- z) .* h .+ z .* h_hat
    end
    return σ_nn(dot(Wy[:,1], h) + by[1,1])
end
