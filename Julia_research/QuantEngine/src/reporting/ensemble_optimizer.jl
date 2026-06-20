# ── Learned Ensemble Weights ──────────────────────────────────
# Optimizes model weights using historical prediction accuracy
# instead of static accuracy-based formula.

"""
    learn_ensemble_weights(predictions, actuals; n_iter) → Vector{Float64}

Learn optimal ensemble weights from historical model predictions.
predictions: matrix (n_samples × n_models) of model probabilities
actuals: vector of actual outcomes (0.0 or 1.0)

Returns normalized weight vector that minimizes ensemble prediction error.
Uses softmax parameterization to ensure weights are positive and sum to 1.
"""
function learn_ensemble_weights(predictions::Matrix{Float64},
                                 actuals::Vector{Float64};
                                 n_iter::Int=200, λ::Float64=0.01)
    n_samples, n_models = size(predictions)
    if n_samples < 10 || n_models < 2
        return fill(1.0 / max(n_models, 1), max(n_models, 1))
    end

    # Initial weights: uniform in log-space (softmax parameterization)
    w0 = zeros(n_models)

    function loss(w)
        # Softmax to ensure positive weights summing to 1
        w_exp = exp.(w .- maximum(w))  # numerical stability
        w_norm = w_exp ./ sum(w_exp)

        # Ensemble prediction: weighted average
        ensemble_pred = predictions * w_norm

        # Binary cross-entropy loss
        bce = 0.0
        for i in 1:n_samples
            p = clamp(ensemble_pred[i], 1e-8, 1 - 1e-8)
            bce += -(actuals[i] * log(p) + (1 - actuals[i]) * log(1 - p))
        end

        # L2 regularization to prevent extreme weights
        return bce / n_samples + λ * sum(w .^ 2)
    end

    opt = try
        optimize(loss, w0, LBFGS(), Optim.Options(iterations=n_iter, show_trace=false))
    catch
        return fill(1.0 / n_models, n_models)
    end

    w_star = Optim.minimizer(opt)
    w_exp = exp.(w_star .- maximum(w_star))
    w_norm = w_exp ./ sum(w_exp)

    return w_norm
end

"""
    build_prediction_matrix(results_history) → (predictions, actuals, model_names)

Build a prediction matrix from a list of historical model results.
Each element of results_history is a Dict of model results for one time step.
"""
function build_prediction_matrix(results_history::Vector{Dict{String,Any}},
                                  actuals::Vector{Float64})
    if isempty(results_history)
        return (zeros(0, 0), Float64[], String[])
    end

    # Find models that appear in every time step with valid probability
    model_names = String[]
    for (name, r) in results_history[1]
        if r isa NamedTuple && hasproperty(r, :probability)
            p = r.probability
            if !isnan(p) && 0 < p < 1
                push!(model_names, name)
            end
        end
    end

    n_samples = min(length(results_history), length(actuals))
    n_models = length(model_names)

    if n_samples < 5 || n_models < 2
        return (zeros(0, 0), Float64[], String[])
    end

    predictions = zeros(n_samples, n_models)
    for (t, results) in enumerate(results_history[1:n_samples])
        for (j, name) in enumerate(model_names)
            r = get(results, name, nothing)
            if r isa NamedTuple && hasproperty(r, :probability)
                p = r.probability
                predictions[t, j] = isnan(p) ? 0.5 : clamp(p, 0.01, 0.99)
            else
                predictions[t, j] = 0.5
            end
        end
    end

    return (predictions, actuals[1:n_samples], model_names)
end
