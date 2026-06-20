# ── Combinatorial Purged Cross-Validation (Lopez de Prado Ch. 7) ──
# Prevents information leakage in time-series CV by:
#   1. Purging: removing samples near train/test boundary
#   2. Embargo: additional forward-looking buffer after purge
#   3. Combinatorial: generating C(n_groups, n_test_groups) train/test combos

"""
    combinations_indices(n, k) → Vector{Vector{Int}}

Generate all C(n,k) combinations of indices 1:n taken k at a time.
"""
function combinations_indices(n::Int, k::Int)
    results = Vector{Int}[]
    if k > n || k <= 0
        return results
    end
    combo = collect(1:k)
    while true
        push!(results, copy(combo))
        # Find rightmost element that can be incremented
        i = k
        while i >= 1 && combo[i] == n - k + i
            i -= 1
        end
        if i < 1
            break
        end
        combo[i] += 1
        for j in (i+1):k
            combo[j] = combo[j-1] + 1
        end
    end
    return results
end

"""
    purged_splits(n, n_splits; purge=5, embargo=3) → Vector{Tuple{Vector{Int}, Vector{Int}}}

Generate purged k-fold splits for time series data of length n.
Purge removes `purge` samples on either side of test boundary.
Embargo removes additional samples after the purge zone (forward direction only).
"""
function purged_splits(n::Int, n_splits::Int; purge::Int=5, embargo::Int=3)
    fold_size = div(n, n_splits)
    splits = Tuple{Vector{Int}, Vector{Int}}[]

    for k in 1:n_splits
        test_start = (k - 1) * fold_size + 1
        test_end = k == n_splits ? n : k * fold_size
        test_idx = collect(test_start:test_end)

        purge_start = max(1, test_start - purge)
        purge_end = min(n, test_end + purge + embargo)

        train_idx = [i for i in 1:n if i < purge_start || i > purge_end]

        if !isempty(train_idx) && !isempty(test_idx)
            push!(splits, (train_idx, test_idx))
        end
    end
    return splits
end

"""
    cpcv_splits(n, n_groups, n_test_groups; purge=5, embargo=3)
        → Vector{Tuple{Vector{Int}, Vector{Int}}}

Combinatorial Purged Cross-Validation (CPCV).
Partitions n observations into n_groups contiguous segments.
Generates all C(n_groups, n_test_groups) combinations.
"""
function cpcv_splits(n::Int, n_groups::Int, n_test_groups::Int;
                     purge::Int=5, embargo::Int=3)
    group_size = div(n, n_groups)
    groups = [((g-1)*group_size+1):(g == n_groups ? n : g*group_size)
              for g in 1:n_groups]

    combos = combinations_indices(n_groups, n_test_groups)
    splits = Tuple{Vector{Int}, Vector{Int}}[]

    for test_group_ids in combos
        test_idx = vcat([collect(groups[g]) for g in test_group_ids]...)

        train_idx = Int[]
        for g in 1:n_groups
            g in test_group_ids && continue
            for i in groups[g]
                too_close = false
                for tg in test_group_ids
                    t_start = first(groups[tg])
                    t_end = last(groups[tg])
                    if (t_start - purge <= i <= t_start - 1) ||
                       (t_end + 1 <= i <= t_end + purge + embargo)
                        too_close = true; break
                    end
                end
                if !too_close
                    push!(train_idx, i)
                end
            end
        end

        if !isempty(train_idx) && !isempty(test_idx)
            push!(splits, (sort(train_idx), sort(test_idx)))
        end
    end
    return splits
end

"""
    cpcv_evaluate(model_fn, X, y; n_groups=6, n_test_groups=2, purge=5, embargo=3) → NamedTuple

Run CPCV evaluation of any model.
model_fn(X_train, y_train, X_test) must return a Vector{Float64} of predictions.
Returns aggregate accuracy, per-fold accuracies, and out-of-sample predictions.
"""
function cpcv_evaluate(model_fn::Function, X::Matrix{Float64}, y::Vector{Float64};
                       n_groups::Int=6, n_test_groups::Int=2,
                       purge::Int=5, embargo::Int=3)
    n = size(X, 1)
    if n < n_groups * 5
        return (mean_accuracy=NaN, std_accuracy=NaN, fold_accuracies=Float64[],
                n_folds=0, oos_predictions=fill(NaN, n))
    end

    splits = cpcv_splits(n, n_groups, n_test_groups; purge, embargo)

    accuracies = Float64[]
    all_preds = fill(NaN, n)
    pred_counts = zeros(Int, n)

    for (train_idx, test_idx) in splits
        if length(train_idx) < 10 || isempty(test_idx)
            continue
        end
        X_tr, y_tr = X[train_idx, :], y[train_idx]
        X_te = X[test_idx, :]

        preds = try
            model_fn(X_tr, y_tr, X_te)
        catch
            continue
        end

        if length(preds) != length(test_idx)
            continue
        end

        acc = mean((preds .> 0.5) .== (y[test_idx] .> 0.5))
        push!(accuracies, acc)

        for (j, idx) in enumerate(test_idx)
            if isnan(all_preds[idx])
                all_preds[idx] = 0.0
            end
            all_preds[idx] += preds[j]
            pred_counts[idx] += 1
        end
    end

    # Average predictions across folds
    for i in eachindex(all_preds)
        if pred_counts[i] > 0
            all_preds[i] /= pred_counts[i]
        end
    end

    mean_acc = isempty(accuracies) ? NaN : mean(accuracies)
    std_acc = length(accuracies) > 1 ? std(accuracies) : NaN

    return (mean_accuracy=mean_acc, std_accuracy=std_acc,
            fold_accuracies=accuracies, n_folds=length(splits),
            oos_predictions=all_preds)
end
