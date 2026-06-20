# ── MLP Forward Pass ──────────────────────────────────────────

function mlp_forward(x, W1, b1, W2, b2, W3, b3)
    h1 = max.(0.0, W1 * x .+ b1[:,1])   # ReLU
    h2 = max.(0.0, W2 * h1 .+ b2[:,1])  # ReLU
    return σ_nn(dot(W3[1,:], h2) + b3[1,1])
end
