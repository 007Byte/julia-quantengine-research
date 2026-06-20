# ── Backtest Report ───────────────────────────────────────────

"""Print a formatted backtest summary to console."""
function print_backtest_report(result::BacktestResult)
    println()
    println("╔" * "═"^62 * "╗")
    println("║  BACKTEST REPORT — $(rpad(result.ticker, 42))║")
    println("╠" * "═"^62 * "╣")
    @printf("║  Total Return:      %+8.1f%%                              ║\n", result.total_return)
    @printf("║  Sharpe Ratio:      %8.2f                               ║\n", result.sharpe)
    @printf("║  Sortino Ratio:     %8.2f                               ║\n", result.sortino)
    @printf("║  Max Drawdown:      %8.1f%%                              ║\n", result.max_drawdown * 100)
    @printf("║  Calmar Ratio:      %8.2f                               ║\n", result.calmar)
    @printf("║  Win Rate:          %7.1f%%  (%d trades)                  ║\n", result.win_rate, result.n_trades)
    @printf("║  Profit Factor:     %8.2f                               ║\n", result.profit_factor)
    @printf("║  Avg Hold:          %7.1f bars                           ║\n", result.avg_hold_bars)
    println("╠" * "═"^62 * "╣")
    println("║  BENCHMARK (Buy & Hold)                                     ║")
    @printf("║  Return:            %+8.1f%%                              ║\n", result.buy_hold_return)
    @printf("║  Sharpe:            %8.2f                               ║\n", result.buy_hold_sharpe)
    @printf("║  Max Drawdown:      %8.1f%%                              ║\n", result.buy_hold_max_dd * 100)
    println("╠" * "═"^62 * "╣")

    alpha = result.total_return - result.buy_hold_return
    @printf("║  ALPHA:             %+8.1f%%                              ║\n", alpha)
    println("╚" * "═"^62 * "╝")

    # Trade log
    if !isempty(result.trades)
        println("\n  Trade Log:")
        println("  " * "-"^70)
        @printf("  %-5s %-6s %10s %10s %10s %8s %12s\n",
                "Fold", "Dir", "Entry", "Exit", "PnL", "PnL%", "Exit Reason")
        println("  " * "-"^70)
        for t in result.trades
            @printf("  %-5d %-6s %10.2f %10.2f %+10.2f %+7.1f%% %12s\n",
                    t.fold, t.direction, t.entry_price, t.exit_price,
                    t.pnl, t.pnl_pct, t.exit_reason)
        end
        println("  " * "-"^70)
    end
    println()
end

"""Generate a backtest equity curve chart (if Plots is loaded)."""
function save_backtest_chart(result::BacktestResult, output_dir::String)
    if isempty(result.equity_curve) || length(result.equity_curve) < 2
        @warn "No equity curve data to plot"
        return nothing
    end

    try
        mkpath(output_dir)

        # Equity curve
        p1 = Plots.plot(result.equity_curve,
            title="Equity Curve — $(result.ticker)",
            xlabel="Bar", ylabel="Portfolio Value (\$)",
            legend=false, linewidth=2, color=:blue,
            size=(900, 400))
        Plots.hline!([result.config.initial_capital], linestyle=:dash, color=:gray, alpha=0.5)

        # Drawdown
        peak = accumulate(max, result.equity_curve)
        dd = (peak .- result.equity_curve) ./ peak .* 100
        p2 = Plots.plot(dd,
            title="Drawdown",
            xlabel="Bar", ylabel="Drawdown (%)",
            legend=false, linewidth=1.5, color=:red, fill=(0, 0.3, :red),
            size=(900, 300))

        # Combined
        p = Plots.plot(p1, p2, layout=(2,1), size=(900, 700))
        filepath = joinpath(output_dir, "$(result.ticker)_backtest.png")
        Plots.savefig(p, filepath)

        return filepath
    catch e
        @warn "Failed to generate backtest chart: $(sprint(showerror, e)[1:min(80,end)])"
        return nothing
    end
end
