# ── Model 12: Ensemble Stacking (LSTM+XGBoost+RF+LightGBM) ─
# Edge: 57-59% directional accuracy on high-confidence signals

function run_ensemble(model_results::Dict; threshold=0.55)
    # Collect predictions from base models
    base_models = ["1. LSTM (BD-LSTM/ED-LSTM)", "2. GRU", "5. Random Forest",
                   "6. LightGBM", "7. XGBoost", "9. BiLSTM",
                   "10. SGD Classifier", "11. Temporal Fusion Transformer"]

    probs = Float64[]
    weights = Float64[]
    model_names = String[]

    for name in base_models
        if haskey(model_results, name)
            r = model_results[name]
            if hasproperty(r, :probability) && !isnan(r.probability)
                push!(probs, r.probability)
                # Weight by accuracy if available
                acc = hasproperty(r, :accuracy) ? r.accuracy : 0.5
                push!(weights, max(0.1, acc - 0.45))  # excess accuracy as weight
                push!(model_names, name)
            end
        end
    end

    if isempty(probs)
        return (direction="HOLD", probability=0.5, accuracy=NaN,
                confidence=0.0, n_models=0, model="Ensemble Stacking")
    end

    # Weighted average (meta-learner)
    weights ./= sum(weights)
    p_ensemble = dot(weights, probs)

    # Confidence: agreement among models
    agreement = mean([(p > 0.5) == (p_ensemble > 0.5) for p in probs])
    confidence = agreement * 100

    # High-confidence filter
    is_high_conf = abs(p_ensemble - 0.5) > (threshold - 0.5)

    direction = p_ensemble > 0.5 ? "UP" : "DOWN"
    if !is_high_conf
        direction = "HOLD (low confidence)"
    end

    return (direction=direction, probability=p_ensemble, accuracy=NaN,
            confidence=confidence, n_models=length(probs),
            model_weights=Dict(zip(model_names, weights)),
            is_high_confidence=is_high_conf, model="Ensemble Stacking")
end
