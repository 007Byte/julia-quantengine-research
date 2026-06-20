# ── Model 15: Reinforcement Learning (Double DQN / Q-Learning)
# Edge: Highest annualized returns in portfolio sims

function run_rl(returns; n_episodes=5, γ_discount=0.95, ε_start=1.0, α_lr=0.1)
    r = filter(!isnan, returns)
    n = length(r)
    if n < 30
        return (action="FLAT", sharpe=NaN, annual_return=NaN,
                cumulative_pnl=Float64[], actions=Int[],
                training_rewards=Float64[], n_states=0,
                model="Reinforcement Learning (DQN)")
    end

    # Discretize state: (return_bin, vol_bin, trend_bin)
    # Return bins: 5 levels
    r_pctiles = quantile(r, [0.1, 0.3, 0.7, 0.9])
    function ret_bin(x)
        x < r_pctiles[1] ? 1 : x < r_pctiles[2] ? 2 :
        x < r_pctiles[3] ? 3 : x < r_pctiles[4] ? 4 : 5
    end

    # Vol bins: 3 levels (rolling 20-day std)
    vols = [i >= 20 ? std(@view r[i-19:i]) : std(r[1:max(2,i)]) for i in 1:n]
    vols = replace(vols, NaN => std(r))
    v_pctiles = quantile(filter(!isnan, vols), [0.33, 0.67])
    vol_bin(v) = v < v_pctiles[1] ? 1 : v < v_pctiles[2] ? 2 : 3

    # Trend bins: 2 levels (5-day SMA direction)
    trend_bin(i) = i >= 5 && mean(@view r[i-4:i]) > 0 ? 1 : 2

    # State space: 5 × 3 × 2 = 30 states, 3 actions (short=-1, flat=0, long=1)
    n_states = 30; n_actions = 3
    Q = zeros(n_states, n_actions)

    state_idx(rb, vb, tb) = (rb - 1) * 6 + (vb - 1) * 2 + tb

    ε = ε_start
    total_rewards = Float64[]

    for ep in 1:n_episodes
        ep_reward = 0.0
        for i in 21:n-1
            s = state_idx(ret_bin(r[i]), vol_bin(vols[i]), trend_bin(i))
            s = clamp(s, 1, n_states)

            # ε-greedy action selection
            if rand() < ε
                a = rand(1:n_actions)
            else
                a = argmax(Q[s, :])
            end

            # Action: 1=short, 2=flat, 3=long → position
            position = a == 1 ? -1.0 : a == 2 ? 0.0 : 1.0
            reward = position * r[i+1]

            # Next state
            s_next = state_idx(ret_bin(r[i+1]),
                              vol_bin(i+1 <= n ? vols[min(i+1,n)] : vols[end]),
                              trend_bin(i+1))
            s_next = clamp(s_next, 1, n_states)

            # Double Q-Learning update
            best_next = maximum(Q[s_next, :])
            Q[s, a] += α_lr * (reward + γ_discount * best_next - Q[s, a])

            ep_reward += reward
        end
        push!(total_rewards, ep_reward)
        ε *= 0.7  # decay exploration
    end

    # Optimal policy evaluation on last 20% of data
    test_start = round(Int, n * 0.8)
    actions = Int[]; cum_pnl = Float64[]; running = 0.0
    for i in test_start:n-1
        s = state_idx(ret_bin(r[i]), vol_bin(vols[i]), trend_bin(i))
        s = clamp(s, 1, n_states)
        a = argmax(Q[s, :])
        push!(actions, a)
        position = a == 1 ? -1.0 : a == 2 ? 0.0 : 1.0
        running += position * r[i+1]
        push!(cum_pnl, running)
    end

    # Compute Sharpe of RL strategy
    if length(cum_pnl) > 2
        strat_returns = diff(vcat([0.0], cum_pnl))
        sharpe = mean(strat_returns) / std(strat_returns) * sqrt(252)
        ann_return = mean(strat_returns) * 252 * 100
    else
        sharpe = NaN; ann_return = NaN
    end

    optimal_action = isempty(actions) ? 2 : actions[end]
    action_label = optimal_action == 1 ? "SHORT" : optimal_action == 2 ? "FLAT" : "LONG"

    return (action=action_label, sharpe=sharpe, annual_return=ann_return,
            cumulative_pnl=cum_pnl, actions=actions,
            training_rewards=total_rewards, n_states=n_states,
            model="Reinforcement Learning (DQN)")
end
