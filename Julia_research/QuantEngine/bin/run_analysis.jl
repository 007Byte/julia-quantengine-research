#!/usr/bin/env julia
# ════════════════════════════════════════════════════════════════
#  QUANT PRINTING DEV — Full Analysis (ALL 23 Models)
#  Usage:  julia run_analysis.jl AAPL
#          julia run_analysis.jl BTC-USD
#
#  Automatically spawns worker processes for parallel NN models.
#  No special flags needed — it uses all available CPU cores.
# ════════════════════════════════════════════════════════════════

using Pkg
const PROJECT_DIR = joinpath(@__DIR__, "..")
Pkg.activate(PROJECT_DIR)

using Distributed

# Add worker processes BEFORE loading the package
n_cores = Sys.CPU_THREADS
n_heavy = 7  # LSTM, GRU, Helformer, Conv-LSTM, BiLSTM, TFT, MLP
n_workers_needed = min(n_heavy, max(1, n_cores - 1))

if nworkers() == 1
    addprocs(n_workers_needed; exeflags="--project=$PROJECT_DIR")
    println("  Spawned $n_workers_needed worker processes ($(nprocs()) total)")
end

# Load package on ALL processes (main + workers)
@everywhere using QuantEngine

using Printf
using Dates

# Parse args
ticker = length(ARGS) >= 1 ? strip(ARGS[1]) : "AAPL"

println()
println("╔══════════════════════════════════════════════════════════════╗")
println("║     QUANT PRINTING DEV — 23-Model Analysis Engine          ║")
println("╚══════════════════════════════════════════════════════════════╝")
println("  Ticker:    $ticker")
println("  Processes: $(nprocs()) (1 main + $(nworkers()) workers)")
println("  CPU Cores: $n_cores")
println()

t0 = time_ns()

# ── 1. Prepare data ──────────────────────────────────────────
println("  Preparing data...")
ctx = prepare_context(ticker)
println("  Asset: $(ctx.asset_type) | Price: \$$(round(ctx.S0, digits=2)) | Returns: $(length(ctx.returns))")
println("  Output: $(ctx.output_dir)")
println()

# ── 2. Run ALL 23 models (fast first, heavy on workers) ──────
run_all_models(ctx)

# ── 3. Composite signal ─────────────────────────────────────
composite = compute_composite(ctx.results)

# ── 4. Trade plan ────────────────────────────────────────────
println("  ── GENERATING TRADE PLAN ──────────────────────────────────")
plan = generate_trade_plan(ctx, composite)

# ── 5. Console output ────────────────────────────────────────
print_console_report(ctx, composite)
print_trade_plan(plan)

# ── 6. Output files ──────────────────────────────────────────
println("  ── GENERATING OUTPUT FILES ────────────────────────────────")

println("  Writing trade plan...")
write_trade_plan(plan, ctx.output_dir)

println("  Generating charts...")
chart_files = generate_charts(ctx, composite)

println("  Generating PDF...")
pdf_file = generate_pdf(ctx, composite, chart_files; trade_plan=plan)

println("  Generating text report...")
txt_file = generate_text_report(ctx, composite)

elapsed = (time_ns() - t0) / 1e9
metrics_file = generate_metrics(ctx, elapsed)

# ── 7. Summary ───────────────────────────────────────────────
println()
println("═" ^ 64)
println("  OUTPUT FILES")
println("═" ^ 64)
println("  Directory: $(ctx.output_dir)")
for f in sort(readdir(ctx.output_dir))
    fsize = filesize(joinpath(ctx.output_dir, f))
    size_str = fsize > 1024*1024 ? "$(@sprintf("%.1f", fsize/1024/1024)) MB" :
               fsize > 1024 ? "$(@sprintf("%.1f", fsize/1024)) KB" :
               "$fsize bytes"
    println("    $(rpad(f, 45)) $size_str")
end
println("═" ^ 64)
@printf("  Total runtime: %.2f seconds\n", elapsed)
println("  Analysis complete.")

# Clean up workers
rmprocs(workers())
