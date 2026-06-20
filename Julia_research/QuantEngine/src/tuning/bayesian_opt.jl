# ── Bayesian Optimization for Hyperparameter Tuning ──────────
# Uses a simple surrogate model (RBF interpolation) to guide the search
# for optimal hyperparameters. Objective: maximize CPCV accuracy.

"""Result of a single evaluation during tuning."""
struct TuningTrial
    params::Dict{String, Float64}
    objective::Float64         # CPCV accuracy (higher is better)
    elapsed_ms::Float64
end

"""Result of a complete tuning run."""
struct TuningResult
    model_name::String
    model_id::Int
    best_params::Dict{String, Float64}
    best_objective::Float64
    trials::Vector{TuningTrial}
    n_evaluations::Int
end

"""
    tune_model(model_id, ticker; n_evaluations, n_initial)

Run Bayesian optimization to find the best hyperparameters for a model.
Uses random search for initial points, then RBF surrogate-guided search.

The objective function trains the model with given hyperparameters on
historical data and returns the CPCV accuracy.
"""
function tune_model(model_id::Int, ticker::String;
                    n_evaluations::Int=30, n_initial::Int=10,
                    verbose::Bool=true)
    space = get_search_space(model_id)
    ticker = validate_ticker(ticker)

    verbose && println("═" ^ 64)
    verbose && println("  TUNING — $(space.model_name) (Model $model_id) on $ticker")
    verbose && println("  Evaluations: $n_evaluations | Initial random: $n_initial")
    verbose && println("  Parameters: $(join([hp.name for hp in space.params], ", "))")
    verbose && println("═" ^ 64)

    # Fetch data once
    display_ticker = uppercase(replace(ticker, "-USD" => "-USD", "poly:" => ""))
    stock = fetch_ohlcv(display_ticker; period="3y")
    prices = stock.adj
    returns = diff(log.(prices))
    volumes = stock.volume

    X_all, y_all, _, _ = compute_features(prices, returns, volumes)
    if size(X_all, 1) < 100
        error("Need at least 100 samples for tuning, got $(size(X_all, 1))")
    end

    trials = TuningTrial[]
    best_obj = -Inf
    best_params = Dict{String, Float64}()

    # Phase 1: Random exploration
    for i in 1:min(n_initial, n_evaluations)
        params = sample_point(space)
        t0 = time_ns()
        obj = _evaluate_params(model_id, params, X_all, y_all, returns, volumes, space)
        elapsed = (time_ns() - t0) / 1e6

        trial = TuningTrial(params, obj, elapsed)
        push!(trials, trial)

        if obj > best_obj
            best_obj = obj
            best_params = params
        end

        if verbose
            marker = obj >= best_obj ? " ★" : ""
            @printf("  [%3d/%d] acc=%.4f%s  |", i, n_evaluations, obj, marker)
            for hp in space.params
                @printf(" %s=%.3g", hp.name, params[hp.name])
            end
            println()
        end
    end

    # Phase 2: Surrogate-guided search
    for i in (n_initial + 1):n_evaluations
        # Build surrogate from existing trials
        params = _suggest_next(space, trials)
        t0 = time_ns()
        obj = _evaluate_params(model_id, params, X_all, y_all, returns, volumes, space)
        elapsed = (time_ns() - t0) / 1e6

        trial = TuningTrial(params, obj, elapsed)
        push!(trials, trial)

        if obj > best_obj
            best_obj = obj
            best_params = params
        end

        if verbose
            marker = obj >= best_obj ? " ★" : ""
            @printf("  [%3d/%d] acc=%.4f%s  |", i, n_evaluations, obj, marker)
            for hp in space.params
                @printf(" %s=%.3g", hp.name, params[hp.name])
            end
            println()
        end
    end

    if verbose
        println()
        println("  BEST: accuracy=%.4f" |> s -> @sprintf("%s", best_obj))
        for (k, v) in best_params
            @printf("    %s = %.4g\n", k, v)
        end
        println("═" ^ 64)
    end

    return TuningResult(space.model_name, model_id, best_params, best_obj,
                        trials, length(trials))
end

"""Evaluate a set of hyperparameters using CPCV accuracy."""
function _evaluate_params(model_id::Int, params::Dict{String, Float64},
                           X_all::Matrix{Float64}, y_all::Vector{Float64},
                           returns::Vector{Float64}, volumes::Vector{Float64},
                           space::SearchSpace)::Float64
    n = size(X_all, 1)

    # Build CPCV evaluation function based on model_id
    model_fn = if model_id == 5  # Random Forest
        (Xtr, ytr, Xte) -> begin
            nt = round(Int, get(params, "n_trees", 100))
            md = round(Int, get(params, "max_depth", 4))
            r = run_random_forest(Xtr, ytr, Xte, ytr[1:min(size(Xte,1),end)];
                                  n_trees=nt, max_depth=md)
            r.predictions
        end
    elseif model_id == 6  # LightGBM
        (Xtr, ytr, Xte) -> begin
            nt = round(Int, get(params, "n_trees", 60))
            lr = get(params, "lr", 0.1)
            md = round(Int, get(params, "max_depth", 3))
            r = run_lightgbm(Xtr, ytr, Xte, ytr[1:min(size(Xte,1),end)];
                             n_trees=nt, lr=lr, max_depth=md)
            r.predictions
        end
    elseif model_id == 7  # XGBoost
        (Xtr, ytr, Xte) -> begin
            nt = round(Int, get(params, "n_trees", 60))
            lr = get(params, "lr", 0.08)
            md = round(Int, get(params, "max_depth", 3))
            lam = get(params, "lambda", 1.0)
            r = run_xgboost(Xtr, ytr, Xte, ytr[1:min(size(Xte,1),end)],
                           returns, :stock; n_trees=nt, lr=lr, max_depth=md, λ_reg=lam)
            r.predictions
        end
    else
        # Generic: return random predictions (placeholder for NN models)
        (Xtr, ytr, Xte) -> fill(0.5, size(Xte, 1))
    end

    # Run CPCV
    result = try
        cpcv_evaluate(model_fn, X_all, y_all;
                      n_groups=5, n_test_groups=2, purge=3, embargo=2)
    catch
        return 0.0
    end

    return isnan(result.mean_accuracy) ? 0.0 : result.mean_accuracy
end

"""Suggest next point using RBF surrogate + exploration bonus."""
function _suggest_next(space::SearchSpace, trials::Vector{TuningTrial})::Dict{String, Float64}
    n_dims = length(space.params)
    n_trials = length(trials)

    # Extract training data for surrogate
    X_obs = zeros(n_trials, n_dims)
    y_obs = zeros(n_trials)
    for (i, trial) in enumerate(trials)
        X_obs[i, :] = normalize_point(space, trial.params)
        y_obs[i] = trial.objective
    end

    y_best = maximum(y_obs)

    # Generate candidates and score with acquisition function
    n_candidates = 100
    best_acq = -Inf
    best_point = sample_point(space)

    for _ in 1:n_candidates
        candidate = sample_point(space)
        x_norm = normalize_point(space, candidate)

        # RBF surrogate prediction: weighted average of observed values
        # with Gaussian kernel weights
        dists = [sum((x_norm .- X_obs[i, :]).^2) for i in 1:n_trials]
        length_scale = 0.3
        weights = exp.(-dists ./ (2 * length_scale^2))
        w_sum = sum(weights)

        if w_sum < 1e-10
            # Far from all observations → high exploration value
            pred_mean = mean(y_obs)
            pred_std = std(y_obs)
        else
            weights ./= w_sum
            pred_mean = dot(weights, y_obs)
            # Uncertainty: lower where we have more nearby observations
            pred_std = sqrt(max(0.0, dot(weights, (y_obs .- pred_mean).^2)))
            # Add exploration bonus for distant points
            pred_std += 0.1 * (1.0 - maximum(weights))
        end

        # Expected Improvement acquisition function
        if pred_std < 1e-10
            acq = 0.0
        else
            z = (pred_mean - y_best) / pred_std
            # Simplified EI: z * Φ(z) + φ(z)
            acq = pred_std * (z * _normal_cdf(z) + _normal_pdf(z))
        end

        if acq > best_acq
            best_acq = acq
            best_point = candidate
        end
    end

    return best_point
end

_normal_pdf(x) = exp(-x^2 / 2) / sqrt(2π)
_normal_cdf(x) = 0.5 * (1.0 + erf(x / sqrt(2.0)))

"""Save tuning results to a JSON file."""
function save_tuning_result(result::TuningResult, filepath::String)
    data = Dict(
        "model_name" => result.model_name,
        "model_id" => result.model_id,
        "best_params" => result.best_params,
        "best_objective" => result.best_objective,
        "n_evaluations" => result.n_evaluations,
        "trials" => [Dict("params" => t.params, "objective" => t.objective,
                          "elapsed_ms" => t.elapsed_ms) for t in result.trials]
    )
    open(filepath, "w") do io
        JSON.print(io, data, 2)
    end
end

"""Load tuning results from a JSON file."""
function load_tuning_result(filepath::String)::Dict
    return JSON.parsefile(filepath)
end
