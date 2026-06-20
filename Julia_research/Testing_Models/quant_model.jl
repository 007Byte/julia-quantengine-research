# ============================================================
#  Quantitative Finance Model — Monte Carlo Option Pricing
#  Simulates stock price paths using Geometric Brownian Motion
#  and prices a European Call Option.
# ============================================================

using Statistics
using Plots

# ── Model Parameters ────────────────────────────────────────
S0    = 100.0   # Initial stock price ($)
K     = 105.0   # Strike price ($)
r     = 0.05    # Risk-free rate (5% annually)
σ     = 0.20    # Volatility (20% annually)
T     = 1.0     # Time to expiration (1 year)
N     = 252     # Trading days per year (time steps)
M     = 10_000  # Number of Monte Carlo simulations

# ── Geometric Brownian Motion Simulation ────────────────────
# Each path: S(t+dt) = S(t) * exp((r - 0.5σ²)dt + σ√dt * Z)
# where Z ~ N(0,1)

dt = T / N
paths = zeros(N + 1, M)
paths[1, :] .= S0

for t in 2:(N + 1)
    Z = randn(M)
    paths[t, :] = paths[t-1, :] .* exp.((r - 0.5 * σ^2) * dt .+ σ * sqrt(dt) .* Z)
end

# ── Option Pricing ───────────────────────────────────────────
# European Call payoff: max(S_T - K, 0), discounted to present value
final_prices = paths[end, :]
payoffs      = max.(final_prices .- K, 0.0)
call_price   = exp(-r * T) * mean(payoffs)
std_error    = exp(-r * T) * std(payoffs) / sqrt(M)

# ── Statistics Summary ───────────────────────────────────────
avg_final = mean(final_prices)
min_final = minimum(final_prices)
max_final = maximum(final_prices)
prob_profit = count(final_prices .> K) / M * 100

println("=" ^ 50)
println("  Monte Carlo Option Pricing Model")
println("=" ^ 50)
println("  Parameters:")
println("    Stock Price (S0):   \$$S0")
println("    Strike Price (K):   \$$K")
println("    Risk-Free Rate:     $(r*100)%")
println("    Volatility (σ):     $(σ*100)%")
println("    Time to Expiry:     $T year")
println("    Simulations:        $(M)")
println("-" ^ 50)
println("  Results:")
println("    Call Option Price:  \$$(round(call_price, digits=4))")
println("    Std Error:          \$$(round(std_error, digits=4))")
println("    95% CI:             \$$(round(call_price - 1.96*std_error, digits=2)) – \$$(round(call_price + 1.96*std_error, digits=2))")
println("-" ^ 50)
println("  Simulation Stats (at expiry):")
println("    Avg Final Price:    \$$(round(avg_final, digits=2))")
println("    Min Final Price:    \$$(round(min_final, digits=2))")
println("    Max Final Price:    \$$(round(max_final, digits=2))")
println("    Prob. Finishing > Strike: $(round(prob_profit, digits=1))%")
println("=" ^ 50)

# ── Plots ─────────────────────────────────────────────────────
# Plot 1: Sample of 50 price paths
sample_paths = paths[:, 1:50]
time_axis = LinRange(0, T, N + 1)

p1 = plot(time_axis, sample_paths,
    legend    = false,
    alpha     = 0.3,
    color     = :steelblue,
    xlabel    = "Time (years)",
    ylabel    = "Stock Price (\$)",
    title     = "Monte Carlo: 50 Sample Price Paths",
    linewidth = 1)
hline!([K], color=:red, linewidth=2, linestyle=:dash, label="Strike K=\$$K")

# Plot 2: Distribution of final stock prices
p2 = histogram(final_prices,
    bins      = 80,
    normalize = :pdf,
    color     = :steelblue,
    alpha     = 0.7,
    xlabel    = "Final Stock Price (\$)",
    ylabel    = "Density",
    title     = "Distribution of Final Prices (T=$T yr)",
    legend    = false)
vline!([K],        color=:red,    linewidth=2, linestyle=:dash,  label="Strike")
vline!([S0],       color=:green,  linewidth=2, linestyle=:solid, label="S0")
vline!([avg_final],color=:orange, linewidth=2, linestyle=:dot,   label="Mean")

# Plot 3: Distribution of payoffs
p3 = histogram(payoffs[payoffs .> 0],
    bins      = 60,
    normalize = :pdf,
    color     = :green,
    alpha     = 0.7,
    xlabel    = "Payoff (\$)",
    ylabel    = "Density",
    title     = "In-the-Money Payoff Distribution",
    legend    = false)
vline!([call_price], color=:red, linewidth=2, linestyle=:dash)

# Plot 4: Option price convergence as M increases
batch_sizes = 100:100:M
running_prices = [exp(-r * T) * mean(max.(paths[end, 1:m] .- K, 0.0)) for m in batch_sizes]

p4 = plot(batch_sizes, running_prices,
    color     = :purple,
    linewidth = 1.5,
    xlabel    = "Number of Simulations",
    ylabel    = "Estimated Call Price (\$)",
    title     = "Option Price Convergence",
    legend    = false)
hline!([call_price], color=:red, linewidth=2, linestyle=:dash)

# Combine all plots
combined = plot(p1, p2, p3, p4, layout=(2,2), size=(1000, 750))
output_path = "C:/Users/yturb/quant_results.png"
savefig(combined, output_path)
println("\n  Chart saved → $output_path")
