# ── Backtest Performance Metrics ──────────────────────────────

"""Compute all performance metrics and populate the BacktestResult."""
function compute_backtest_metrics!(result::BacktestResult, prices::Vector{Float64},
                                   dates::Vector{DateTime})
    result.n_trades = length(result.trades)

    if result.n_trades == 0
        return result
    end

    # ── Trade-level metrics ──
    pnls = [t.pnl for t in result.trades]
    wins = filter(x -> x > 0, pnls)
    losses = filter(x -> x <= 0, pnls)

    result.win_rate = length(wins) / result.n_trades * 100.0
    result.avg_hold_bars = mean(t.hold_bars for t in result.trades)

    gross_profit = isempty(wins) ? 0.0 : sum(wins)
    gross_loss = isempty(losses) ? 1e-8 : abs(sum(losses))
    result.profit_factor = gross_profit / gross_loss

    # ── Equity curve metrics ──
    if length(result.equity_curve) > 1
        eq = result.equity_curve
        result.total_return = (eq[end] / eq[1] - 1.0) * 100.0

        # Daily returns from equity curve
        result.daily_returns = diff(eq) ./ eq[1:end-1]

        if length(result.daily_returns) > 1
            μ = mean(result.daily_returns)
            σ = std(result.daily_returns)

            # Sharpe (annualized, assuming 252 trading days)
            result.sharpe = σ > 1e-10 ? μ / σ * sqrt(252) : 0.0

            # Sortino (downside deviation only)
            downside = filter(r -> r < 0, result.daily_returns)
            dd_std = isempty(downside) ? 1e-10 : std(downside)
            result.sortino = dd_std > 1e-10 ? μ / dd_std * sqrt(252) : 0.0
        end

        # Max drawdown
        result.max_drawdown, result.max_drawdown_duration = _compute_max_drawdown(eq)

        # Calmar ratio (annualized return / max drawdown)
        n_years = max(length(eq) / 252.0, 0.01)
        ann_return = (eq[end] / eq[1]) ^ (1.0 / n_years) - 1.0
        result.calmar = result.max_drawdown > 1e-10 ?
            ann_return / result.max_drawdown : 0.0
    end

    # ── Buy-and-hold benchmark ──
    if length(prices) > 1
        bh_returns = diff(prices) ./ prices[1:end-1]

        result.buy_hold_return = (prices[end] / prices[1] - 1.0) * 100.0

        if length(bh_returns) > 1
            bh_μ = mean(bh_returns)
            bh_σ = std(bh_returns)
            result.buy_hold_sharpe = bh_σ > 1e-10 ? bh_μ / bh_σ * sqrt(252) : 0.0
        end

        bh_equity = prices ./ prices[1]
        result.buy_hold_max_dd, _ = _compute_max_drawdown(bh_equity)
    end

    return result
end

"""Compute max drawdown and its duration from an equity curve."""
function _compute_max_drawdown(equity::Vector{Float64})
    peak = equity[1]
    max_dd = 0.0
    max_dd_duration = 0
    current_dd_start = 1

    for i in eachindex(equity)
        if equity[i] > peak
            peak = equity[i]
            current_dd_start = i
        end
        dd = (peak - equity[i]) / peak
        if dd > max_dd
            max_dd = dd
            max_dd_duration = i - current_dd_start
        end
    end

    return (max_dd, max_dd_duration)
end
