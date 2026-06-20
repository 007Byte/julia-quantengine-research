# ── Portfolio Optimizer ───────────────────────────────────────
# Given a set of candidate trades from the scanner, optimize allocation
# using correlation analysis and mean-variance optimization.

"""Portfolio allocation for a single asset."""
struct PortfolioAllocation
    ticker::String
    direction::Symbol          # :long or :short
    weight::Float64            # fraction of portfolio (0 to 1)
    size_dollars::Float64      # dollar amount
    expected_return::Float64   # from scan score
    risk::Float64              # from daily vol
end

"""Result of portfolio optimization."""
struct PortfolioOptResult
    allocations::Vector{PortfolioAllocation}
    total_weight::Float64      # should be <= 1.0
    expected_portfolio_return::Float64
    portfolio_risk::Float64
    diversification_ratio::Float64  # ratio of weighted avg vol to portfolio vol
    n_assets::Int
end

"""
    optimize_portfolio(scan_results, capital; max_positions, max_weight_per_asset,
                       max_sector_weight, correlation_penalty)

Optimize portfolio allocation from scanner results.
Uses a simplified mean-variance approach with correlation penalty.
"""
function optimize_portfolio(scan_results::Vector{ScanResult}, capital::Float64;
                            max_positions::Int=10,
                            max_weight_per_asset::Float64=0.15,
                            max_total_weight::Float64=0.80,
                            correlation_penalty::Float64=0.3)
    if isempty(scan_results)
        return PortfolioOptResult(PortfolioAllocation[], 0.0, 0.0, 0.0, 0.0, 0)
    end

    # Take top candidates
    candidates = scan_results[1:min(max_positions * 2, length(scan_results))]

    # Score each candidate: higher score = better risk-adjusted opportunity
    scored = [(
        ticker=c.ticker,
        direction=c.score > 0 ? :long : :short,
        score=abs(c.score),
        kelly=c.kelly_frac,
        vol=max(c.daily_vol, 0.001),
        asset_type=c.asset_type
    ) for c in candidates]

    # Sort by score/vol ratio (risk-adjusted attractiveness)
    sort!(scored, by=s -> -s.score / s.vol)

    # Allocate weights using Kelly-informed sizing with diversification
    allocations = PortfolioAllocation[]
    total_weight = 0.0
    used_types = Dict{Symbol, Float64}()  # track sector/type exposure

    for s in scored
        if length(allocations) >= max_positions
            break
        end
        if total_weight >= max_total_weight
            break
        end

        # Base weight from Kelly fraction, clamped
        base_weight = clamp(s.kelly, 0.01, max_weight_per_asset)

        # Reduce weight if same asset type is overrepresented
        type_exposure = get(used_types, s.asset_type, 0.0)
        type_limit = 0.40  # max 40% in any single asset type
        if type_exposure + base_weight > type_limit
            base_weight = max(0.0, type_limit - type_exposure)
        end

        # Apply correlation penalty for similar assets
        # (simplified: penalize if same asset type already in portfolio)
        if type_exposure > 0
            base_weight *= (1.0 - correlation_penalty)
        end

        # Ensure we don't exceed total weight limit
        base_weight = min(base_weight, max_total_weight - total_weight)

        if base_weight < 0.005  # minimum 0.5% allocation
            continue
        end

        size_dollars = capital * base_weight
        expected_ret = s.score * base_weight  # weighted expected return

        push!(allocations, PortfolioAllocation(
            s.ticker, s.direction, base_weight, size_dollars,
            expected_ret, s.vol
        ))

        total_weight += base_weight
        used_types[s.asset_type] = type_exposure + base_weight
    end

    # Portfolio-level metrics
    if isempty(allocations)
        return PortfolioOptResult(allocations, 0.0, 0.0, 0.0, 0.0, 0)
    end

    exp_return = sum(a.expected_return for a in allocations)
    weighted_avg_vol = sum(a.weight * a.risk for a in allocations)
    # Simplified portfolio vol (assumes low correlation → diversification benefit)
    portfolio_vol = weighted_avg_vol * sqrt(1.0 / max(length(allocations), 1))
    div_ratio = portfolio_vol > 0 ? weighted_avg_vol / portfolio_vol : 1.0

    return PortfolioOptResult(
        allocations, total_weight, exp_return,
        portfolio_vol, div_ratio, length(allocations)
    )
end

"""Print portfolio optimization results."""
function print_portfolio(result::PortfolioOptResult, capital::Float64)
    println()
    println("╔" * "═"^62 * "╗")
    println("║  PORTFOLIO OPTIMIZATION                                      ║")
    println("╠" * "═"^62 * "╣")
    @printf("║  Capital:          \$%10.2f                               ║\n", capital)
    @printf("║  Positions:        %10d                                 ║\n", result.n_assets)
    @printf("║  Total Weight:     %9.1f%%                                ║\n", result.total_weight * 100)
    @printf("║  Expected Return:  %+9.2f%%                               ║\n", result.expected_portfolio_return * 100)
    @printf("║  Portfolio Risk:   %9.2f%%                                ║\n", result.portfolio_risk * 100)
    @printf("║  Diversification:  %9.2fx                                ║\n", result.diversification_ratio)
    println("╠" * "═"^62 * "╣")
    @printf("║  %-10s %6s %8s %10s %8s %8s      ║\n",
            "Ticker", "Dir", "Weight", "Size", "E[R]", "Vol")
    println("║  " * "-"^58 * "  ║")
    for a in result.allocations
        @printf("║  %-10s %6s %7.1f%% %10.2f %+7.2f%% %7.1f%%      ║\n",
                a.ticker, a.direction, a.weight * 100, a.size_dollars,
                a.expected_return * 100, a.risk * 100)
    end
    println("╚" * "═"^62 * "╝")
end
