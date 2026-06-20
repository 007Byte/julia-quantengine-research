# -- Supporting Technique S1: Event Study -------------------------------------
# Measures post-event price behavior (continuation vs reversal)
# Edge: Feeds directly into EV Gap + Kelly pipeline

function run_event_study(returns, prices)
    r = returns
    n = length(r)
    if n < 30
        return (mean_reaction=NaN, fade_rate=NaN, hold_rate=NaN,
                reversal_rate=NaN, n_events=0, model="Event Study")
    end

    sigma_r = std(r)
    events = findall(abs.(r) .> 1.5 * sigma_r)  # significant moves

    reactions = Float64[]     # immediate next return in same direction
    hold_count = 0; fade_count = 0; reversal_count = 0

    for idx in events
        if idx + 3 <= n
            # Immediate reaction (t+1)
            same_dir = r[idx+1] * sign(r[idx])
            push!(reactions, same_dir)

            # 3-day follow-through
            cumul_3d = sum(r[idx+1:idx+3]) * sign(r[idx])
            if cumul_3d > 0.5 * abs(r[idx])
                hold_count += 1       # move held
            elseif cumul_3d < -0.5 * abs(r[idx])
                reversal_count += 1   # full reversal
            else
                fade_count += 1       # partial fade
            end
        end
    end

    n_events = length(reactions)
    mean_reaction = isempty(reactions) ? NaN : mean(reactions)
    total = hold_count + fade_count + reversal_count
    hold_rate = total > 0 ? hold_count / total : NaN
    fade_rate = total > 0 ? fade_count / total : NaN
    reversal_rate = total > 0 ? reversal_count / total : NaN

    return (mean_reaction=mean_reaction, fade_rate=fade_rate,
            hold_rate=hold_rate, reversal_rate=reversal_rate,
            n_events=n_events, model="Event Study")
end
