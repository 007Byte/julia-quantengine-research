# ── Neural Network Primitives ─────────────────────────────────

σ_nn(x) = 1.0 / (1.0 + exp(-clamp(x, -500.0, 500.0)))
const sigma_nn = σ_nn  # alias for model files that use ASCII name
xavier(rows, cols) = randn(rows, cols) * sqrt(2.0 / (rows + cols))

function pack_weights(ws...)
    vcat([vec(w) for w in ws]...)
end

function unpack_weights(θ::Vector{Float64}, shapes::Vector{Tuple{Int,Int}})
    result = Matrix{Float64}[]
    idx = 1
    for (r, c) in shapes
        n = r * c
        push!(result, reshape(θ[idx:idx+n-1], r, c))
        idx += n
    end
    return result
end

function total_params(shapes)
    sum(r * c for (r, c) in shapes)
end
