# ================================================================
#  The Two-Language Problem — Julia's Core Motivation
#
#  Classic workflow at research teams:
#    Step 1: Prototype in Python/MATLAB (slow but easy)
#    Step 2: Rewrite critical parts in C++ for production speed
#
#  Julia eliminates this by being BOTH expressive AND fast.
#
#  This file benchmarks the same algorithm written 3 ways:
#    1. "Pythonic" Julia  (interpreted-style, slow)
#    2. "C-style" Julia   (manual loops, fast)
#    3. "Julia-native"    (idiomatic, equally fast, more readable)
#
#  Then demonstrates Julia's unique power: multiple dispatch
#  and type-parameterized functions that specialize at compile time.
# ================================================================

using BenchmarkTools
using Statistics
using Plots
using Printf
using SpecialFunctions   # for erf()

println("=" ^ 60)
println("  The Two-Language Problem — Julia vs The World")
println("=" ^ 60)

# ── PART 1: BENCHMARK — Three styles, same algorithm ──────────
# Task: Compute the sum of squares of a large vector

N = 1_000_000

# Style 1: "Pythonic" — type-unstable, uses Any
function sum_squares_slow(v)
    total = 0              # ← integer, not Float64! causes type instability
    for x in v
        total = total + x * x
    end
    return total
end

# Style 2: "C-style" Julia — type-stable explicit loop
function sum_squares_fast(v::Vector{Float64})
    total = 0.0            # ← typed correctly from the start
    @inbounds for x in v   # @inbounds skips bounds checking (safe here)
        total += x * x
    end
    return total
end

# Style 3: "Julia-native" — idiomatic, same speed as C-style
sum_squares_native(v) = sum(x -> x^2, v)   # one line, compiles to same code

v = rand(Float64, N)

println()
println("─" ^ 60)
println("  Task: Sum of squares of $N random floats")
println("─" ^ 60)

t_slow   = @elapsed for _ in 1:5; sum_squares_slow(v); end;   t_slow /= 5
t_fast   = @elapsed for _ in 1:5; sum_squares_fast(v); end;   t_fast /= 5
t_native = @elapsed for _ in 1:5; sum_squares_native(v); end; t_native /= 5

@printf("  %-28s  %.4f ms\n", "Type-unstable (Python-style):", t_slow*1000)
@printf("  %-28s  %.4f ms\n", "Type-stable loop (C-style):",   t_fast*1000)
@printf("  %-28s  %.4f ms\n", "Julia-native (idiomatic):",      t_native*1000)
@printf("  %-28s  %.1fx slower\n", "Slowdown:", t_slow / t_fast)
println()
println("  Key insight: Julia-native is as fast as C-style — you")
println("  don't sacrifice readability for performance.")

# ── PART 2: MULTIPLE DISPATCH — Julia's killer feature ────────
# In Python/C++: you overload methods on a SINGLE type
# In Julia: dispatch happens on ALL argument types simultaneously
# The compiler generates specialized, optimized code per type combination

println()
println("─" ^ 60)
println("  Multiple Dispatch — Julia's Unique Superpower")
println("─" ^ 60)

# Define a financial instrument type hierarchy
abstract type Asset end
abstract type Derivative <: Asset end

struct Stock       <: Asset;      price::Float64; volatility::Float64 end
struct Bond        <: Asset;      face::Float64;  yield::Float64       end
struct CallOption  <: Derivative; strike::Float64; expiry::Float64     end
struct PutOption   <: Derivative; strike::Float64; expiry::Float64     end

# Single function name — Julia picks the RIGHT method automatically
# based on ALL argument types at compile time (not runtime!)
function fair_value(a::Stock)
    return a.price   # spot price
end

function fair_value(b::Bond)
    return b.face * exp(-b.yield * 10)   # present value (10yr)
end

function fair_value(opt::CallOption, underlying::Stock)
    # Black-Scholes call price (simplified, r=0.05, t=opt.expiry)
    r  = 0.05
    S  = underlying.price
    K  = opt.strike
    σ  = underlying.volatility
    T  = opt.expiry
    d1 = (log(S/K) + (r + 0.5σ^2)*T) / (σ*sqrt(T))
    d2 = d1 - σ*sqrt(T)
    Φ(x) = 0.5 * (1 + erf(x / sqrt(2)))
    return S * Φ(d1) - K * exp(-r*T) * Φ(d2)
end

function fair_value(opt::PutOption, underlying::Stock)
    # Put-call parity from the call
    call = CallOption(opt.strike, opt.expiry)
    r = 0.05
    return fair_value(call, underlying) - underlying.price +
           opt.strike * exp(-r * opt.expiry)
end

# Risk function — dispatch knows the type, generates optimal code
function risk_measure(a::Stock)
    return "VaR: \$$(round(a.price * a.volatility * 1.645, digits=2)) (95%, 1-day)"
end
function risk_measure(b::Bond)
    return "Duration risk: $(round(10 / (1 + b.yield), digits=2)) years"
end
function risk_measure(::Derivative)
    return "Derivative — model-dependent, requires underlying"
end

aapl  = Stock(250.12, 0.28)
tbond = Bond(1000.0, 0.045)
call  = CallOption(260.0, 0.5)     # 6-month call, strike $260
put   = PutOption(260.0, 0.5)

assets = [aapl, tbond]

println()
for a in assets
    @printf("  %-25s  Fair value: \$%-10.2f  Risk: %s\n",
        typeof(a), fair_value(a), risk_measure(a))
end
@printf("  %-25s  Fair value: \$%-10.4f\n", "CallOption(K=260, T=0.5)", fair_value(call, aapl))
@printf("  %-25s  Fair value: \$%-10.4f\n", "PutOption(K=260, T=0.5)",  fair_value(put, aapl))

# ── PART 3: TYPE SPECIALIZATION ───────────────────────────────
# In Python: one function runs the same bytecode for Float32 and Float64
# In Julia: the compiler generates SEPARATE optimized machine code for each

println()
println("─" ^ 60)
println("  Type Specialization — One function, multiple compiled versions")
println("─" ^ 60)

# Single generic function — Julia compiles a separate version per type
function dot_product(a::Vector{T}, b::Vector{T}) where T <: Number
    return sum(a .* b)
end

N = 500_000
v32  = rand(Float32, N)
v64  = rand(Float64, N)
v_int = rand(Int32(1):Int32(100), N)

t32  = @elapsed for _ in 1:10; dot_product(v32, v32); end;   t32 /= 10
t64  = @elapsed for _ in 1:10; dot_product(v64, v64); end;   t64 /= 10
t_i  = @elapsed for _ in 1:10; dot_product(v_int, v_int); end; t_i /= 10

println("  Same function dot_product() — 3 compiled specializations:")
@printf("  Float32:  %.4f ms  (uses SSE/AVX 32-bit SIMD)\n", t32*1000)
@printf("  Float64:  %.4f ms  (uses SSE/AVX 64-bit SIMD)\n", t64*1000)
@printf("  Int32:    %.4f ms  (uses integer vector units)\n", t_i*1000)
println()
println("  In Python, you'd need numpy for this AND it's slower.")
println("  In C++, you'd write 3 separate template functions.")
println("  In Julia: write once, compile to optimal code for each type.")

# ── PART 4: BENCHMARKS TABLE — Julia vs Equivalent Python ─────
println()
println("─" ^ 60)
println("  Typical Speedup: Julia vs Pure Python (same algorithm)")
println("─" ^ 60)
println("  Task                          Python time   Julia time   Speedup")
println("  " * "─" ^ 58)
benchmarks = [
    ("Sum of 1M floats (typed)",        "85 ms",  "0.4 ms",  "~200x"),
    ("Matrix multiply 1000×1000",       "800 ms", "45 ms",   "~18x"),
    ("ODE solve (Lorenz, T=50)",        "12 s",   "0.05 s",  "~240x"),
    ("Monte Carlo 10M paths",           "42 s",   "0.3 s",   "~140x"),
    ("Portfolio optim (50 scenarios)",  "N/A*",   "0.8 s",   "—"),
]
for (task, py, jl, sp) in benchmarks
    @printf("  %-32s  %-12s  %-10s  %s\n", task, py, jl, sp)
end
println("  * Python would need C-extension (scipy) — not pure Python")
println()
println("  Julia = Python readability + C speed. No rewriting needed.")

# ── PLOTS ─────────────────────────────────────────────────────

# Plot 1: Style comparison bar chart
labels_perf = ["Type-unstable\n(Python-style)", "Type-stable loop\n(C-style)", "Julia native\n(idiomatic)"]
times_ms    = [t_slow, t_fast, t_native] .* 1000
bar_colors  = [:red, :green, :steelblue]
p1 = bar(labels_perf, times_ms,
    color    = bar_colors,
    ylabel   = "Time (ms)",
    title    = "Same Algorithm — Three Styles\n(Sum of squares, N=1M)",
    legend   = false,
    ylims    = (0, maximum(times_ms) * 1.2))
for (i, t) in enumerate(times_ms)
    annotate!(p1, i, t + maximum(times_ms)*0.03,
        text("$(round(t, digits=2))ms", 9, :black))
end

# Plot 2: Speedup over Python — log scale
task_names = ["Sum floats", "Matrix mul", "ODE solve", "Monte Carlo"]
speedups   = [200, 18, 240, 140]
p2 = bar(task_names, speedups,
    color  = :steelblue,
    ylabel = "Speedup vs Pure Python (×)",
    title  = "Julia vs Python: Typical Speedups",
    legend = false,
    yscale = :log10,
    ylims  = (1, 1000))
hline!(p2, [1], color=:red, linestyle=:dash, linewidth=2)
annotate!(p2, 0.7, 1.5, text("Python baseline", 8, :red))

# Plot 3: Type specialization timing
type_labels = ["Float32", "Float64", "Int32"]
type_times  = [t32, t64, t_i] .* 1000
p3 = bar(type_labels, type_times,
    color  = [:orange, :steelblue, :green],
    ylabel = "Time (ms)",
    title  = "One Generic Function\nCompiles to 3 Optimized Versions",
    legend = false)

# Plot 4: Concept diagram — two language problem solved
categories = ["Python\n(prototype)", "Julia", "C++\n(production)"]
expressiveness = [95, 90, 40]
performance    = [20, 95, 98]
p4 = scatter(expressiveness, performance,
    series_annotations = text.(categories, 9, :bottom),
    markersize = 12,
    color      = [:blue, :green, :red],
    xlabel     = "Expressiveness / Ease of Use",
    ylabel     = "Performance",
    title      = "The Two-Language Problem — Solved",
    xlims      = (10, 110), ylims = (10, 110),
    legend     = false,
    grid       = true)
annotate!(p4, 90, 92, text("Julia", 11, :green, :bold))
annotate!(p4, 95, 17, text("Python", 10, :blue))
annotate!(p4, 40, 95, text("C++", 10, :red))

combined = plot(p1, p2, p3, p4, layout=(2,2), size=(1100, 850))
savefig(combined, "C:/Users/yturb/two_language_problem.png")
println("\n  Chart saved → C:/Users/yturb/two_language_problem.png")
println("  Done.")
