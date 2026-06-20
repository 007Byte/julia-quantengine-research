# ── Composite Signal ──────────────────────────────────────────

function compute_composite(results::Dict; learned_weights::Union{Dict{String,Float64}, Nothing}=nothing)
    probs = Float64[]
    accs  = Float64[]
    names_collected = String[]

    for (name, r) in results
        if r isa NamedTuple && hasproperty(r, :probability)
            p = r.probability
            if !isnan(p) && 0 < p < 1
                push!(probs, p)
                # Prefer CPCV accuracy (honest OOS estimate) over standard accuracy
                a = if hasproperty(r, :cpcv_accuracy) && !isnan(r.cpcv_accuracy)
                    r.cpcv_accuracy
                elseif hasproperty(r, :accuracy) && !isnan(r.accuracy)
                    r.accuracy
                else
                    0.5
                end
                push!(accs, a)
                push!(names_collected, name)
            end
        end
    end

    if isempty(probs)
        return (direction="HOLD", score=0.0, confidence=0, p_true=0.5,
                bull_pct=50.0, n_models=0)
    end

    # Use learned weights when available, fall back to accuracy-based
    if learned_weights !== nothing
        w = Float64[get(learned_weights, n, max(accs[i] - 0.45, 0.05))
                     for (i, n) in enumerate(names_collected)]
    else
        w = max.(accs .- 0.45, 0.05)
    end
    w ./= sum(w)
    p_true = dot(w, probs)

    score = (p_true - 0.5) * 2
    bull_pct = count(p -> p > 0.5, probs) / length(probs) * 100

    direction = if score > 0.15
        "BUY"
    elseif score > 0.05
        "LEAN BUY"
    elseif score < -0.15
        "DO NOT BUY"
    elseif score < -0.05
        "LEAN SELL"
    else
        "HOLD"
    end

    confidence = round(Int, clamp((1 - 2*abs(p_true - mean(probs))) * 100, 0, 100))

    n_total = count(r -> r isa NamedTuple, values(results))

    return (direction=direction, score=score, confidence=confidence,
            p_true=p_true, bull_pct=bull_pct,
            n_directional=length(probs),  # models that vote on direction
            n_total=n_total,               # total models that ran
            n_models=n_total)              # backward compat — shows total
end
