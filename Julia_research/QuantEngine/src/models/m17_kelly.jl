# -- Model 17: Kelly Criterion (Fractional) ----------------------------------
# Formula: f* = (p*b - (1-p)) / b
# Edge: Compounding without ruin ($1k -> $150k+)

function run_kelly(returns; rf=RF_DAILY, regime::Symbol=:neutral,
                   slippage_bps::Float64=5.0, cost_bps::Float64=10.0)
    r = returns
    n = length(r)

    # Adjust returns for transaction costs and slippage
    cost_per_trade = (slippage_bps + cost_bps) / 10000.0
    r_adj = r .- cost_per_trade  # conservative: subtract costs from every return

    # Win rate and avg win/loss (cost-adjusted)
    wins  = r_adj[r_adj .> 0]
    losses = r_adj[r_adj .< 0]
    p_win = length(wins) / n
    avg_win  = isempty(wins) ? 0.0 : mean(wins)
    avg_loss = isempty(losses) ? 1e-6 : abs(mean(losses))

    # Kelly fraction: f* = p - (1-p)/b where b = avg_win/avg_loss
    b_ratio = avg_win / max(avg_loss, 1e-8)
    kelly_full = p_win - (1 - p_win) / max(b_ratio, 1e-8)
    kelly_full = clamp(kelly_full, -1.0, 2.0)

    # Regime-aware Kelly scaling
    # Volatile regime → reduce sizing; trending → slightly increase
    regime_scale = if regime == :volatile
        0.5   # halve in volatile regime (protect capital)
    elseif regime == :trending
        1.2   # slight boost in trending (momentum works)
    elseif regime == :mean_reverting
        0.7   # reduce in mean-reverting (signals less reliable)
    else
        1.0   # neutral
    end
    kelly_full *= regime_scale

    kelly_three_quarter = 0.75 * kelly_full
    kelly_half = 0.50 * kelly_full
    kelly_quarter = 0.25 * kelly_full

    # Empirical Kelly (adjust for estimation error)
    kelly_empirical = kelly_half * (1 - 1/sqrt(n))

    # Monte Carlo optimal Kelly search
    best_mc_kelly = 0.0; best_mc_growth = -Inf
    for f_test in 0.0:0.02:1.5
        growth = 0.0
        for i in 1:min(n, 500)
            growth += log(max(1e-10, 1.0 + f_test * r[rand(1:n)]))
        end
        if growth > best_mc_growth
            best_mc_growth = growth; best_mc_kelly = f_test
        end
    end

    # Edge quality metrics
    quarterly_n = div(n, 63)
    edge_consistency = 0.0
    if quarterly_n >= 2
        q_returns = [mean(r[max(1,(i-1)*63+1):min(n,i*63)]) for i in 1:quarterly_n]
        edge_consistency = count(x -> x > rf, q_returns) / quarterly_n * 100
    end

    excess = r .- rf
    edge_sharpe = std(excess) > 0 ? mean(excess) / std(excess) * sqrt(252) : 0.0
    cv_edge = std(excess) > 0 ? std(excess) / abs(mean(excess) + 1e-10) : 99.0

    # MC simulation: probability of profit at different Kelly levels
    function mc_sim(f, n_paths=1000, horizon=252)
        profits = 0
        ruins = 0
        final_vals = Float64[]
        for _ in 1:n_paths
            val = 1.0
            for _ in 1:horizon
                val *= (1.0 + f * r[rand(1:n)])
                if val < 0.01  ruins += 1; break end
            end
            push!(final_vals, val)
            if val > 1.0 profits += 1 end
        end
        return (prob_profit=profits/n_paths*100, prob_ruin=ruins/n_paths*100,
                median_return=(median(final_vals)-1)*100)
    end

    sim_full = mc_sim(max(0, kelly_full))
    sim_half = mc_sim(max(0, kelly_half))
    sim_quarter = mc_sim(max(0, kelly_quarter))

    return (kelly_full=kelly_full, kelly_three_quarter=kelly_three_quarter,
            kelly_half=kelly_half, kelly_quarter=kelly_quarter,
            kelly_empirical=kelly_empirical, kelly_mc=best_mc_kelly,
            win_rate=p_win*100, avg_win=avg_win*100, avg_loss=avg_loss*100,
            edge_consistency=edge_consistency, edge_sharpe=edge_sharpe, cv_edge=cv_edge,
            prob_profit_full=sim_full.prob_profit, prob_ruin_full=sim_full.prob_ruin,
            prob_profit_half=sim_half.prob_profit, prob_ruin_half=sim_half.prob_ruin,
            prob_profit_quarter=sim_quarter.prob_profit,
            median_return_half=sim_half.median_return, model="Kelly Criterion")
end
