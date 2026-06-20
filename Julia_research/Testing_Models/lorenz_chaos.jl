# ============================================================
#  Chaos Theory — The Lorenz Attractor
#  Julia Superpower: DifferentialEquations.jl
#
#  The Lorenz system (1963) describes atmospheric convection:
#    dx/dt = σ(y - x)
#    dy/dt = x(ρ - z) - y
#    dz/dt = xy - βz
#
#  Tiny differences in initial conditions → wildly different
#  outcomes. This is the "butterfly effect."
# ============================================================

using OrdinaryDiffEq
using Plots
using Statistics
using LinearAlgebra

# ── The Lorenz equations ─────────────────────────────────────
function lorenz!(du, u, p, _)
    σ, ρ, β = p
    x, y, z = u
    du[1] = σ * (y - x)          # dx/dt
    du[2] = x * (ρ - z) - y      # dy/dt
    du[3] = x * y - β * z        # dz/dt
end

# ── Classic parameters (Edward Lorenz's original values) ─────
σ = 10.0      # Prandtl number
ρ = 28.0      # Rayleigh number  ← chaos lives above ρ ≈ 24.74
β = 8.0 / 3   # Geometric factor

p      = (σ, ρ, β)
tspan  = (0.0, 50.0)

# ── Solve a single trajectory ─────────────────────────────────
u0   = [1.0, 0.0, 0.0]
prob = ODEProblem(lorenz!, u0, tspan, p)

println("Solving Lorenz system...")
@time sol = solve(prob, Tsit5(), reltol=1e-8, abstol=1e-10)

println("Steps taken by solver: $(length(sol.t))")
println("Done.\n")

# ── The Butterfly Effect: two nearly identical starting points ─
# Shift x by just 0.000001 — watch what happens after t ≈ 30
u0_twin = [1.000001, 0.0, 0.0]
prob_twin = ODEProblem(lorenz!, u0_twin, tspan, p)
sol_twin  = solve(prob_twin, Tsit5(), reltol=1e-8, abstol=1e-10)

# Compute divergence over time
common_t  = range(0, 40, length=2000)
traj1 = hcat([sol(t) for t in common_t]...)'
traj2 = hcat([sol_twin(t) for t in common_t]...)'
divergence = [norm(traj1[i,:] - traj2[i,:]) for i in 1:length(common_t)]

# ── Statistics ───────────────────────────────────────────────
xs = sol[1, :]
ys = sol[2, :]
zs = sol[3, :]

println("=" ^ 50)
println("  Lorenz Attractor Summary")
println("=" ^ 50)
println("  Parameters:  σ=$σ  ρ=$ρ  β=$(round(β,digits=4))")
println("  Time span:   $(tspan[1]) → $(tspan[2])")
println("  Solver:      Tsit5 (5th order Runge-Kutta)")
println("-" ^ 50)
println("  x range:  $(round(minimum(xs),digits=2)) → $(round(maximum(xs),digits=2))")
println("  y range:  $(round(minimum(ys),digits=2)) → $(round(maximum(ys),digits=2))")
println("  z range:  $(round(minimum(zs),digits=2)) → $(round(maximum(zs),digits=2))")
println("-" ^ 50)
println("  Butterfly Effect:")
println("  Initial separation:  1e-6")
println("  Final separation:    $(round(divergence[end], digits=2))")
println("  Amplification:       $(round(divergence[end]/1e-6, digits=0))x")
println("=" ^ 50)

# ── Plot 1: The Lorenz Butterfly (x vs z) ────────────────────
# Color the path by time to show evolution
n = length(sol.t)
colors = cgrad(:plasma, n, categorical=false)

p1 = plot(xs, zs,
    line_z    = 1:n,
    color     = :plasma,
    linewidth = 0.5,
    legend    = false,
    xlabel    = "x",
    ylabel    = "z",
    title     = "The Lorenz Attractor (Butterfly)",
    background_color = :black,
    foreground_color = :white,
    size      = (500, 400))

# ── Plot 2: x vs y ────────────────────────────────────────────
p2 = plot(xs, ys,
    line_z    = 1:n,
    color     = :viridis,
    linewidth = 0.5,
    legend    = false,
    xlabel    = "x",
    ylabel    = "y",
    title     = "Lorenz Attractor (x-y plane)",
    background_color = :black,
    foreground_color = :white,
    size      = (500, 400))

# ── Plot 3: x(t) over time — chaotic oscillation ─────────────
t_plot = sol.t[1:10:end]
x_plot = sol[1, 1:10:end]

p3 = plot(t_plot, x_plot,
    color     = :cyan,
    linewidth = 0.8,
    legend    = false,
    xlabel    = "Time",
    ylabel    = "x(t)",
    title     = "Chaotic Time Series — x(t)",
    background_color = :black,
    foreground_color = :white)

# ── Plot 4: Butterfly Effect — divergence of two paths ───────
p4 = plot(common_t, divergence,
    color     = :red,
    linewidth = 1.5,
    yscale    = :log10,
    legend    = false,
    xlabel    = "Time",
    ylabel    = "Separation (log scale)",
    title     = "Butterfly Effect: Δu₀ = 1×10⁻⁶",
    background_color = :black,
    foreground_color = :white)

# Combine
combined = plot(p1, p2, p3, p4,
    layout = (2, 2),
    size   = (1100, 850))

savefig(combined, "C:/Users/yturb/lorenz_chaos.png")
println("\n  Chart saved → C:/Users/yturb/lorenz_chaos.png")
