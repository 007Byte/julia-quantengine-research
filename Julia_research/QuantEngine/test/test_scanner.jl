# ── Scanner & Portfolio Optimizer Tests ────────────────────────

using QuantEngine: ScanResult, ScanConfig, PortfolioAllocation, PortfolioOptResult

@testset "ScanConfig defaults" begin
    config = ScanConfig()
    @test config.top_n == 10
    @test config.min_score == 0.05
    @test config.verbose == false
    @test length(config.model_ids) > 5  # fast subset
    @test length(config.model_ids) < N_MODELS  # not all models
end

@testset "ScanConfig all models" begin
    config = ScanConfig(fast_only=false)
    @test length(config.model_ids) == N_MODELS
end

@testset "load_watchlist" begin
    dir = mktempdir()
    filepath = joinpath(dir, "watchlist.txt")
    write(filepath, "AAPL\nMSFT\n\nGOOGL\nBTC-USD\n")

    tickers = load_watchlist(filepath)
    @test length(tickers) == 4
    @test "AAPL" in tickers
    @test "BTC-USD" in tickers
end

@testset "optimize_portfolio empty" begin
    result = optimize_portfolio(ScanResult[], 10000.0)
    @test result.n_assets == 0
    @test result.total_weight == 0.0
    @test isempty(result.allocations)
end

@testset "optimize_portfolio basic" begin
    # Create synthetic scan results
    results = [
        ScanResult("AAPL", :stock, 150.0, "BUY", 0.3, 0.65, 70, 8, 0.10, 0.015, 500.0),
        ScanResult("MSFT", :stock, 380.0, "LEAN BUY", 0.15, 0.58, 55, 8, 0.06, 0.012, 400.0),
        ScanResult("BTC-USD", :crypto, 45000.0, "BUY", 0.25, 0.63, 65, 7, 0.08, 0.035, 600.0),
        ScanResult("ETH-USD", :crypto, 3000.0, "LEAN BUY", 0.12, 0.56, 50, 6, 0.04, 0.040, 550.0),
    ]

    portfolio = optimize_portfolio(results, 10000.0)

    @test portfolio.n_assets > 0
    @test portfolio.n_assets <= 10
    @test portfolio.total_weight > 0.0
    @test portfolio.total_weight <= 0.80  # max_total_weight default

    # Each allocation should have valid fields
    for a in portfolio.allocations
        @test a.weight > 0.0
        @test a.weight <= 0.15  # max per asset
        @test a.size_dollars > 0.0
        @test a.size_dollars <= 10000.0 * 0.15
        @test a.direction in (:long, :short)
    end

    # Portfolio metrics
    @test isfinite(portfolio.expected_portfolio_return)
    @test portfolio.portfolio_risk >= 0.0
    @test portfolio.diversification_ratio >= 1.0  # diversification always >= 1
end

@testset "optimize_portfolio respects max_positions" begin
    results = [
        ScanResult("T$i", :stock, 100.0, "BUY", 0.2, 0.6, 60, 8, 0.08, 0.02, 100.0)
        for i in 1:20
    ]

    portfolio = optimize_portfolio(results, 50000.0; max_positions=3)
    @test portfolio.n_assets <= 3
end

@testset "optimize_portfolio type diversification" begin
    # All same type — should apply correlation penalty
    results = [
        ScanResult("AAPL", :stock, 150.0, "BUY", 0.3, 0.65, 70, 8, 0.10, 0.015, 100.0),
        ScanResult("MSFT", :stock, 380.0, "BUY", 0.28, 0.64, 68, 8, 0.10, 0.012, 100.0),
        ScanResult("GOOGL", :stock, 140.0, "BUY", 0.25, 0.62, 65, 8, 0.10, 0.014, 100.0),
    ]

    portfolio = optimize_portfolio(results, 10000.0)

    # Second and third stock should have reduced weight due to correlation penalty
    if portfolio.n_assets >= 2
        @test portfolio.allocations[2].weight < portfolio.allocations[1].weight
    end
end

@testset "optimize_portfolio short positions" begin
    results = [
        ScanResult("AAPL", :stock, 150.0, "DO NOT BUY", -0.3, 0.35, 70, 8, 0.10, 0.015, 100.0),
    ]

    portfolio = optimize_portfolio(results, 10000.0)
    if portfolio.n_assets > 0
        @test portfolio.allocations[1].direction == :short
    end
end

@testset "PortfolioAllocation fields" begin
    a = PortfolioAllocation("AAPL", :long, 0.10, 1000.0, 0.03, 0.015)
    @test a.ticker == "AAPL"
    @test a.direction == :long
    @test a.weight == 0.10
    @test a.size_dollars == 1000.0
end
