# ── Model 28: Meta-Labeling (Lopez de Prado Ch. 3) ─────────────
# Edge: Instead of "predict direction", predict "will our direction call be right?"
# Primary model → direction; Meta-model → bet size (0 = skip, 1 = full size)
# Phase 2: depends on ensemble/model results for the primary signal.

function run_meta_labeling(X_train, y_train, X_test, y_test,
                           model_results::Dict, returns, volumes)
    n_tr = size(X_train, 1)
    n_te = size(X_test, 1)
    n_total = n_tr + n_te

    if n_tr < 30 || n_te < 5
        return (direction="NO BET", probability=0.5, accuracy=NaN,
                primary_direction="HOLD", primary_probability=0.5,
                bet_size=0.0, meta_accuracy=NaN,
                model="Meta-Labeling (Lopez de Prado)")
    end

    # ── Step 1: Extract primary signal from model results ──────
    primary_prob = 0.5
    primary_dir = "HOLD"

    # Prefer ensemble if available
    for (name, res) in model_results
        if res isa NamedTuple && occursin("Ensemble", name) && hasproperty(res, :probability)
            primary_prob = res.probability
            primary_dir = hasproperty(res, :direction) ? res.direction : "HOLD"
            break
        end
    end

    # Fallback: weighted average of all model probabilities
    if primary_dir == "HOLD"
        probs = Float64[]
        for (_, res) in model_results
            if res isa NamedTuple && hasproperty(res, :probability)
                p = res.probability
                if !isnan(p) && 0 < p < 1
                    push!(probs, p)
                end
            end
        end
        if !isempty(probs)
            primary_prob = mean(probs)
            primary_dir = primary_prob > 0.55 ? "UP" : primary_prob < 0.45 ? "DOWN" : "HOLD"
        end
    end

    # ── Step 2: Build triple-barrier meta-labels ───────────────
    # Align returns to the full feature matrix range
    n_ret = length(returns)
    if n_ret < n_total
        return (direction="NO BET", probability=0.5, accuracy=NaN,
                primary_direction=primary_dir, primary_probability=primary_prob,
                bet_size=0.0, meta_accuracy=NaN,
                model="Meta-Labeling (Lopez de Prado)")
    end

    r_aligned = returns[end-n_total+1:end]
    vol = daily_volatility(r_aligned; window=20)
    tb_labels = triple_barrier_label(r_aligned, vol; pt_mult=2.0, sl_mult=1.0, max_holding=10)

    # Meta-label: did the primary direction agree with triple-barrier outcome?
    # Primary direction sign: >0.5 → long (+1), <0.5 → short (-1)
    primary_sign = primary_prob > 0.5 ? 1.0 : -1.0

    meta_y_all = Float64[]
    for i in 1:n_total
        if tb_labels[i] == 0.0
            push!(meta_y_all, 0.0)  # no signal → bet was neutral
        else
            # Did primary direction match the barrier outcome?
            push!(meta_y_all, (primary_sign * tb_labels[i] > 0) ? 1.0 : 0.0)
        end
    end

    meta_y_train = meta_y_all[1:n_tr]
    meta_y_test = meta_y_all[n_tr+1:end]

    # ── Step 3: Augment features with primary confidence ───────
    primary_conf = abs(primary_prob - 0.5) * 2.0  # 0 = uncertain, 1 = very confident
    X_meta_train = hcat(X_train, fill(primary_conf, n_tr))
    X_meta_test = hcat(X_test, fill(primary_conf, n_te))

    # ── Step 4: Train meta-model ────────────────────────────────
    n_feat_meta = size(X_meta_train, 2)

    # For small datasets, use a simple threshold model instead of gradient boosting
    # to avoid overfitting (primary cause of the ~23% accuracy issue)
    if n_tr < 100
        # Simple model: bet when primary confidence is high
        meta_preds = zeros(n_te)
        for i in 1:n_te
            conf = abs(X_meta_test[i, end])  # last column is primary_conf
            meta_preds[i] = conf > 0.2 ? clamp(0.3 + conf * 0.5, 0.3, 0.8) : 0.2
        end
    else
        # Gradient boosted trees — reduced complexity to prevent overfitting
        # Previously: 40 trees, depth 3, min_samples 4, λ 0.5
        # Now:        15 trees, depth 2, min_samples 8, λ 1.0
        n_trees = 15
        lr = 0.1
        residuals = copy(meta_y_train)
        trees = []

        for t in 1:n_trees
            feat_subset = sort(shuffle(1:n_feat_meta)[1:max(2, div(n_feat_meta, 2))])
            tree = fit_tree(X_meta_train, residuals, feat_subset, 0, 2;
                            min_samples=8, λ=1.0)
            push!(trees, tree)
            for i in 1:n_tr
                pred = predict_tree(tree, @view X_meta_train[i, :])
                residuals[i] -= lr * pred
            end
        end

        # Predict on test set
        meta_preds = zeros(n_te)
        for i in 1:n_te
            raw = sum(lr * predict_tree(tree, @view X_meta_test[i, :]) for tree in trees)
            meta_preds[i] = sigma_nn(raw)
        end
    end

    # ── Step 5: Output bet size ────────────────────────────────
    bet_size = isempty(meta_preds) ? 0.0 : clamp(meta_preds[end], 0.0, 1.0)
    meta_acc = n_te > 0 ? mean((meta_preds .> 0.5) .== (meta_y_test .> 0.5)) : NaN

    direction = bet_size > 0.5 ? "BET" : "NO BET"

    return (direction=direction, probability=bet_size,
            accuracy=meta_acc, primary_direction=primary_dir,
            primary_probability=primary_prob,
            bet_size=bet_size, meta_accuracy=meta_acc,
            model="Meta-Labeling (Lopez de Prado)")
end
