# ================================================================
#  Quantitative Finance — Portfolio Optimization with JuMP
#
#  1. Pulls LIVE 1-year historical prices from Yahoo Finance
#  2. Computes log returns & covariance matrix
#  3. Solves Markowitz Mean-Variance Optimization via JuMP + Ipopt
#  4. Traces the full Efficient Frontier
#  5. Finds Max Sharpe Ratio & Minimum Variance portfolios
#  6. Produces correlation heatmap & weight allocation charts
# ================================================================

using HTTP, JSON, Dates
using Statistics, LinearAlgebra
using JuMP, Ipopt
using DataFrames
using Plots
using Printf

# ── 1. LIVE DATA: Fetch prices from Yahoo Finance ─────────────

function fetch_yahoo(ticker::String, period="1y")
    url = "https://query1.finance.yahoo.com/v8/finance/chart/$ticker" *
          "?interval=1d&range=$period"
    headers = ["User-Agent" => "Mozilla/5.0"]
    try
        resp = HTTP.get(url, headers; redirect=true, connect_timeout=10, readtimeout=15)
        data = JSON.parse(String(resp.body))
        result = data["chart"]["result"][1]
        timestamps = result["timestamp"]
        closes     = result["indicators"]["adjclose"][1]["adjclose"]
        dates_vec  = [unix2datetime(t) for t in timestamps]
        prices_vec = Float64[p === nothing ? NaN : p for p in closes]
        return dates_vec, prices_vec
    catch e
        println("  ⚠ Could not fetch $ticker: $e")
        return nothing, nothing
    end
end

# Portfolio of 8 diverse stocks across sectors
tickers = ["AAPL", "MSFT", "GOOGL", "JPM", "JNJ", "XOM", "TSLA", "GLD"]
names   = ["Apple", "Microsoft", "Alphabet", "JPMorgan", "J&J", "ExxonMobil", "Tesla", "Gold ETF"]
RISK_FREE_RATE = 0.053  # Current ~5.3% (US 10-yr Treasury)

println("=" ^ 60)
println("  Portfolio Optimization — Live Market Data")
println("=" ^ 60)
println("\n  Fetching 1-year historical prices...")

price_matrix = Dict{String, Vector{Float64}}()
date_ref     = nothing

for (i, ticker) in enumerate(tickers)
    dates, prices = fetch_yahoo(ticker)
    if prices !== nothing
        # Remove NaN
        valid = .!isnan.(prices)
        prices = prices[valid]
        dates  = dates[valid]
        price_matrix[ticker] = prices
        if date_ref === nothing
            global date_ref = dates
        end
        println("  ✓ $ticker ($(names[i])): $(length(prices)) days, " *
                "latest = \$$(round(prices[end], digits=2))")
    end
end

# Align all series to the shortest length
min_len = minimum(length(v) for v in values(price_matrix))
for k in keys(price_matrix)
    price_matrix[k] = price_matrix[k][end-min_len+1:end]
end

# ── 2. LOG RETURNS & STATISTICS ───────────────────────────────

n_assets = length(tickers)
n_days   = min_len - 1

# Build returns matrix: rows = days, cols = assets
returns = zeros(n_days, n_assets)
for (j, ticker) in enumerate(tickers)
    p = price_matrix[ticker]
    returns[:, j] = diff(log.(p))          # log return: ln(P_t / P_{t-1})
end

μ = vec(mean(returns, dims=1)) .* 252      # Annualized mean returns
Σ = cov(returns) .* 252                    # Annualized covariance matrix
σ = sqrt.(diag(Σ))                         # Individual volatilities
corr_matrix = Σ ./ (σ * σ')               # Correlation matrix

println("\n" * "─" ^ 60)
println("  Asset Statistics (Annualized)")
println("─" ^ 60)
println("  $(rpad("Ticker",8)) $(rpad("Name",12)) $(rpad("Return",10)) $(rpad("Volatility",12)) Sharpe")
println("  " * "─" ^ 56)
for j in 1:n_assets
    sharpe = (μ[j] - RISK_FREE_RATE) / σ[j]
    println("  $(rpad(tickers[j],8)) $(rpad(names[j],12)) " *
            "$(rpad(string(round(μ[j]*100,digits=1))*"%", 10)) " *
            "$(rpad(string(round(σ[j]*100,digits=1))*"%", 12)) " *
            "$(round(sharpe, digits=2))")
end

# ── 3. PORTFOLIO OPTIMIZATION WITH JuMP ───────────────────────
# Minimize portfolio variance  w' Σ w
# Subject to:
#   Σ wᵢ = 1         (fully invested)
#   wᵢ ≥ 0           (long-only, no short selling)
#   μ' w ≥ r_target  (minimum return constraint)

function optimize_portfolio(μ, Σ, target_return; allow_short=false)
    n = length(μ)
    model = Model(Ipopt.Optimizer)
    set_silent(model)

    lb = allow_short ? -0.3 : 0.0
    @variable(model, lb <= w[1:n] <= 1.0)
    @objective(model, Min, w' * Σ * w)                     # Minimize variance
    @constraint(model, sum(w) == 1.0)                      # Fully invested
    @constraint(model, dot(μ, w) >= target_return)         # Return target

    optimize!(model)

    if termination_status(model) == MOI.LOCALLY_SOLVED ||
       termination_status(model) == MOI.OPTIMAL
        weights = value.(w)
        port_return = dot(μ, weights)
        port_vol    = sqrt(weights' * Σ * weights)
        port_sharpe = (port_return - RISK_FREE_RATE) / port_vol
        return weights, port_return, port_vol, port_sharpe
    else
        return nothing, nothing, nothing, nothing
    end
end

# ── 4. TRACE THE EFFICIENT FRONTIER ───────────────────────────
println("\n  Solving Efficient Frontier (50 portfolios)...")

r_min = minimum(μ) * 0.8
r_max = maximum(μ) * 0.95
targets = range(r_min, r_max, length=50)

frontier_returns = Float64[]
frontier_vols    = Float64[]
frontier_sharpes = Float64[]

for r in targets
    w, ret, vol, sharpe = optimize_portfolio(μ, Σ, r)
    if w !== nothing
        push!(frontier_returns, ret)
        push!(frontier_vols,    vol)
        push!(frontier_sharpes, sharpe)
    end
end

# ── 5. SPECIAL PORTFOLIOS ─────────────────────────────────────

# Minimum Variance Portfolio
min_idx = argmin(frontier_vols)
mv_return = frontier_returns[min_idx]
mv_vol    = frontier_vols[min_idx]
mv_w, _, _, _ = optimize_portfolio(μ, Σ, mv_return)

# Maximum Sharpe Ratio Portfolio (Tangency Portfolio)
max_sharpe_idx = argmax(frontier_sharpes)
ms_return = frontier_returns[max_sharpe_idx]
ms_vol    = frontier_vols[max_sharpe_idx]
ms_w, _, _, _ = optimize_portfolio(μ, Σ, ms_return)

# Equal-Weight (naive) benchmark
ew_w      = fill(1.0/n_assets, n_assets)
ew_return = dot(μ, ew_w)
ew_vol    = sqrt(ew_w' * Σ * ew_w)
ew_sharpe = (ew_return - RISK_FREE_RATE) / ew_vol

println("\n" * "=" ^ 60)
println("  Portfolio Comparison")
println("=" ^ 60)
@printf(stdout, "  %-28s %8s %10s %8s\n", "Portfolio", "Return", "Volatility", "Sharpe")
println("  " * "─" ^ 56)
@printf(stdout, "  %-28s %7.1f%%  %9.1f%%  %7.2f\n",
    "Min Variance",    mv_return*100, mv_vol*100,    (mv_return-RISK_FREE_RATE)/mv_vol)
@printf(stdout, "  %-28s %7.1f%%  %9.1f%%  %7.2f\n",
    "Max Sharpe (Tangency)",ms_return*100, ms_vol*100, (ms_return-RISK_FREE_RATE)/ms_vol)
@printf(stdout, "  %-28s %7.1f%%  %9.1f%%  %7.2f\n",
    "Equal Weight (naive)", ew_return*100, ew_vol*100, ew_sharpe)
println("=" ^ 60)

# Max Sharpe weights breakdown
println("\n  Max Sharpe Portfolio — Weights:")
for j in 1:n_assets
    bar = "█" ^ Int(round(ms_w[j] * 40))
    @printf(stdout, "  %-10s %5.1f%%  %s\n", tickers[j], ms_w[j]*100, bar)
end

# ── 6. PLOTS ──────────────────────────────────────────────────

# Plot 1: Efficient Frontier
sharpe_colors = cgrad(:RdYlGn, frontier_sharpes, rev=false)
p1 = scatter(frontier_vols .* 100, frontier_returns .* 100,
    marker_z  = frontier_sharpes,
    color     = :RdYlGn,
    markersize = 5,
    colorbar_title = "Sharpe Ratio",
    xlabel    = "Volatility (% ann.)",
    ylabel    = "Expected Return (% ann.)",
    title     = "Efficient Frontier",
    legend    = :topleft,
    label     = "Portfolios")

# Individual assets
scatter!(p1, σ.*100, μ.*100,
    color=:white, markerstrokecolor=:black, markersize=7, label="Assets")
for j in 1:n_assets
    annotate!(p1, σ[j]*100 + 0.3, μ[j]*100, text(tickers[j], 7, :gray))
end

# Special portfolios
scatter!(p1, [mv_vol*100], [mv_return*100],
    color=:blue, markersize=10, markershape=:star5, label="Min Variance")
scatter!(p1, [ms_vol*100], [ms_return*100],
    color=:gold, markersize=10, markershape=:star5, label="Max Sharpe")
scatter!(p1, [ew_vol*100], [ew_return*100],
    color=:red, markersize=8, markershape=:diamond, label="Equal Weight")

# Plot 2: Max Sharpe portfolio weights (pie-style bar)
colors2 = palette(:tab10, n_assets)
p2 = bar(tickers, ms_w .* 100,
    color     = colors2,
    xlabel    = "Asset",
    ylabel    = "Weight (%)",
    title     = "Max Sharpe Portfolio Weights",
    legend    = false,
    ylims     = (0, max(ms_w...) * 120))

# Plot 3: Correlation heatmap
p3 = heatmap(tickers, tickers, corr_matrix,
    color  = :RdBu,
    clims  = (-1, 1),
    title  = "Asset Correlation Matrix",
    aspect_ratio = 1,
    xrotation = 45)

# Plot 4: Cumulative returns over the past year
p4 = plot(title="Cumulative Returns (1 Year)", xlabel="Day", ylabel="Growth of \$1",
    legend=:topleft, size=(500,350))
for (j, ticker) in enumerate(tickers)
    cum_ret = cumprod(1 .+ returns[:, j])
    plot!(p4, cum_ret, label=ticker, linewidth=1.5)
end
hline!(p4, [1.0], color=:black, linestyle=:dash, linewidth=1, label="")

combined = plot(p1, p2, p3, p4, layout=(2,2), size=(1200, 900))
savefig(combined, "C:/Users/yturb/portfolio_optimization.png")
println("\n  Chart saved → C:/Users/yturb/portfolio_optimization.png")
println("\n  Done.")
