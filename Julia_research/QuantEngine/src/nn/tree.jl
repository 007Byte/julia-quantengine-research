# ── Decision Tree ─────────────────────────────────────────────

struct TreeNode
    feature_idx::Int
    threshold::Float64
    left::Union{TreeNode, Float64}
    right::Union{TreeNode, Float64}
end

function fit_tree(X::Matrix{Float64}, y::Vector{Float64},
                  features::Vector{Int}, depth::Int, max_depth::Int;
                  min_samples::Int=4, λ::Float64=0.0)
    if depth >= max_depth || length(y) < min_samples
        return mean(y)
    end
    best_score = Inf
    best_split = nothing
    for fi in features
        col = @view X[:, fi]
        vals = sort(unique(col))
        step = max(1, div(length(vals), 15))
        for idx in 1:step:length(vals)-1
            v = (vals[idx] + vals[min(idx+1, length(vals))]) / 2.0
            left_mask  = col .<= v
            right_mask = .!left_mask
            nl = sum(left_mask); nr = sum(right_mask)
            if nl < 2 || nr < 2 continue end
            yl = y[left_mask]; yr = y[right_mask]
            score = var(yl) * nl + var(yr) * nr + λ * (mean(yl)^2 + mean(yr)^2)
            if score < best_score
                best_score = score
                best_split = (fi, v, left_mask, right_mask)
            end
        end
    end
    if best_split === nothing
        return mean(y)
    end
    fi, v, lm, rm = best_split
    left  = fit_tree(X[lm, :], y[lm], features, depth+1, max_depth; min_samples, λ)
    right = fit_tree(X[rm, :], y[rm], features, depth+1, max_depth; min_samples, λ)
    return TreeNode(fi, v, left, right)
end

predict_tree(node::TreeNode, x::AbstractVector) =
    x[node.feature_idx] <= node.threshold ?
        (node.left  isa TreeNode ? predict_tree(node.left,  x) : node.left) :
        (node.right isa TreeNode ? predict_tree(node.right, x) : node.right)
predict_tree(val::Float64, x::AbstractVector) = val
