# ── Master Orchestrator ───────────────────────────────────────
# ALL 30 models run. Fast models in-process, heavy NN models
# as SEPARATE OS PROCESSES via Distributed.jl for true parallelism.

const MODEL_DISPATCH = Dict{Int, Function}()
const FAST_MODELS  = Set([4, 5, 6, 7, 10, 14, 15, 16, 17, 22, 23, 24, 25, 26, 29, 30, 31, 32, 33])
const HEAVY_MODELS = Set([1, 2, 3, 8, 9, 11, 13])

function _register_models!()
    MODEL_DISPATCH[1]  = (ctx) -> run_lstm(ctx.Xseq_train, ctx.yseq_train, ctx.Xseq_test, ctx.yseq_test, ctx.n_features;
                                          cache=ctx.weight_cache, ticker=ctx.ticker)
    MODEL_DISPATCH[2]  = (ctx) -> run_gru(ctx.Xseq_train, ctx.yseq_train, ctx.Xseq_test, ctx.yseq_test, ctx.n_features;
                                          cache=ctx.weight_cache, ticker=ctx.ticker)
    MODEL_DISPATCH[3]  = (ctx) -> run_helformer(ctx.prices, ctx.returns, ctx.Xseq_train, ctx.yseq_train, ctx.Xseq_test, ctx.yseq_test, ctx.n_features;
                                                cache=ctx.weight_cache, ticker=ctx.ticker)
    MODEL_DISPATCH[4]  = (ctx) -> begin
        lstm_r = get(ctx.results, "1. LSTM (BD-LSTM/ED-LSTM)", nothing)
        run_lstm_garch(ctx.returns, ctx.Xseq_train, ctx.yseq_train, ctx.n_features, ctx.S0; lstm_result=lstm_r)
    end
    MODEL_DISPATCH[5]  = (ctx) -> run_random_forest(ctx.X_train, ctx.y_train, ctx.X_test, ctx.y_test)
    MODEL_DISPATCH[6]  = (ctx) -> run_lightgbm(ctx.X_train, ctx.y_train, ctx.X_test, ctx.y_test)
    MODEL_DISPATCH[7]  = (ctx) -> run_xgboost(ctx.X_train, ctx.y_train, ctx.X_test, ctx.y_test, ctx.returns, ctx.asset_type)
    MODEL_DISPATCH[8]  = (ctx) -> run_conv_lstm(ctx.Xseq_train, ctx.yseq_train, ctx.Xseq_test, ctx.yseq_test, ctx.n_features;
                                               cache=ctx.weight_cache, ticker=ctx.ticker)
    MODEL_DISPATCH[9]  = (ctx) -> run_bilstm(ctx.Xseq_train, ctx.yseq_train, ctx.Xseq_test, ctx.yseq_test, ctx.n_features;
                                             cache=ctx.weight_cache, ticker=ctx.ticker)
    MODEL_DISPATCH[10] = (ctx) -> run_sgd(ctx.X_train, ctx.y_train, ctx.X_test, ctx.y_test, ctx.returns, ctx.asset_type)
    MODEL_DISPATCH[11] = (ctx) -> run_tft(ctx.X_train, ctx.y_train, ctx.X_test, ctx.y_test, ctx.n_features;
                                         cache=ctx.weight_cache, ticker=ctx.ticker)
    MODEL_DISPATCH[12] = (ctx) -> run_ensemble(ctx.results)
    MODEL_DISPATCH[13] = (ctx) -> run_mlp(ctx.X_train, ctx.y_train, ctx.X_test, ctx.y_test, ctx.n_features;
                                         cache=ctx.weight_cache, ticker=ctx.ticker)
    MODEL_DISPATCH[14] = (ctx) -> run_garch_egarch(ctx.returns; vol_data=ctx.volumes)
    MODEL_DISPATCH[15] = (ctx) -> run_rl(ctx.returns)
    MODEL_DISPATCH[16] = (ctx) -> begin
        mp = ctx.poly_data !== nothing ? ctx.poly_data.prices[1] : 0.5
        run_lmsr(mp)
    end
    MODEL_DISPATCH[17] = (ctx) -> run_kelly(ctx.returns)
    MODEL_DISPATCH[18] = (ctx) -> begin
        mp = if ctx.poly_data !== nothing
            ctx.poly_data.prices[1]
        else
            # Historical base rate: fraction of positive return days
            n_up = count(r -> r > 0, ctx.returns)
            length(ctx.returns) > 0 ? n_up / length(ctx.returns) : 0.52
        end
        run_ev_gap(ctx.results, mp, ctx.asset_type)
    end
    MODEL_DISPATCH[19] = (ctx) -> run_kl_divergence(ctx.returns, ctx.results)
    MODEL_DISPATCH[20] = (ctx) -> run_bregman(ctx.returns, ctx.results)
    MODEL_DISPATCH[21] = (ctx) -> run_bayesian(ctx.returns, ctx.results)
    MODEL_DISPATCH[22] = (ctx) -> run_logistic_regression(ctx.returns, ctx.prices[2:end], ctx.volumes[2:end])
    MODEL_DISPATCH[23] = (ctx) -> run_ar1(ctx.returns)
    MODEL_DISPATCH[24] = (ctx) -> run_black_scholes(ctx.returns, ctx.S0, ctx.high, ctx.low;
                                                     asset_type=ctx.asset_type)
    MODEL_DISPATCH[25] = (ctx) -> run_fd_pricer(ctx.returns, ctx.S0, ctx.high, ctx.low;
                                                 asset_type=ctx.asset_type)
    MODEL_DISPATCH[26] = (ctx) -> run_term_structure(ctx.returns; asset_type=ctx.asset_type)
    MODEL_DISPATCH[27] = (ctx) -> run_martingale_test(ctx.returns, ctx.results)
    MODEL_DISPATCH[28] = (ctx) -> run_meta_labeling(ctx.X_train, ctx.y_train, ctx.X_test, ctx.y_test,
                                                     ctx.results, ctx.returns, ctx.volumes)
    MODEL_DISPATCH[29] = (ctx) -> run_fracdiff_signal(ctx.prices, ctx.returns)
    MODEL_DISPATCH[30] = (ctx) -> run_triple_barrier_signal(ctx.returns, ctx.volumes)

    # Prediction market models (31-33) — also registered in plugin registry
    MODEL_DISPATCH[31] = (ctx) -> begin
        price_series = ctx.asset_type == :polymarket && ctx.poly_data !== nothing ?
            [ctx.poly_data.prices[1]] : ctx.prices
        run_kalman_filter(Float64.(price_series))
    end
    MODEL_DISPATCH[32] = (ctx) -> begin
        days_to_exp = ctx.asset_type == :polymarket && ctx.poly_data !== nothing ?
            (let ed = ctx.poly_data.end_date; isempty(ed) ? 30.0 :
             max(1.0, Float64(Dates.value(Date(ed[1:min(10,end)]) - today()))) end) : 30.0
        run_time_decay(Float64.(ctx.prices), days_to_exp)
    end
    MODEL_DISPATCH[33] = (ctx) -> begin
        mp = ctx.poly_data !== nothing ? ctx.poly_data.prices[1] : 0.5
        vol = tryparse(Float64, string(ctx.poly_data !== nothing ? ctx.poly_data.volume : "0"))
        run_cross_market_arb(mp, vol !== nothing ? vol : 0.0)
    end

    # Register m31-m33 in the plugin registry as well
    register_model!(31, "Kalman Filter (Prediction Market)", :fast, MODEL_DISPATCH[31])
    register_model!(32, "Time Decay (Prediction Market)", :fast, MODEL_DISPATCH[32])
    register_model!(33, "Cross-Market Arbitrage", :fast, MODEL_DISPATCH[33])
end

function run_model(ctx::AnalysisContext, model_id::Int; verbose::Bool=true)
    if !haskey(MODEL_DISPATCH, model_id)
        # Check plugin registry as fallback
        if is_registered(model_id)
            name = "$model_id. $(registered_model_name(model_id))"
            return ralph(() -> run_registered_model(model_id, ctx), name, ctx; verbose)
        end
        @warn "Unknown model ID: $model_id"
        return nothing
    end
    name = "$model_id. $(MODEL_NAMES[model_id])"
    return ralph(() -> MODEL_DISPATCH[model_id](ctx), name, ctx; verbose)
end

function run_supporting(ctx::AnalysisContext; verbose::Bool=true)
    ralph(() -> run_event_study(ctx.returns, ctx.prices), "S1. Event Study", ctx; verbose)
    ralph(() -> run_calibration_check(ctx.returns, ctx.results), "S2. Calibration Check", ctx; verbose)
end

"""
    _run_heavy_model_isolated(model_id, data) → NamedTuple or nothing

Run a single heavy model in isolation (called on worker process).
Takes serializable data (not AnalysisContext) to avoid transfer issues.
"""
function _run_heavy_model_isolated(model_id::Int,
                                   Xseq_tr, yseq_tr, Xseq_te, yseq_te,
                                   X_tr, y_tr, X_te, y_te,
                                   prices, returns, n_features)
    t0 = time_ns()
    result = try
        if model_id == 1
            run_lstm(Xseq_tr, yseq_tr, Xseq_te, yseq_te, n_features)
        elseif model_id == 2
            run_gru(Xseq_tr, yseq_tr, Xseq_te, yseq_te, n_features)
        elseif model_id == 3
            run_helformer(prices, returns, Xseq_tr, yseq_tr, Xseq_te, yseq_te, n_features)
        elseif model_id == 8
            run_conv_lstm(Xseq_tr, yseq_tr, Xseq_te, yseq_te, n_features)
        elseif model_id == 9
            run_bilstm(Xseq_tr, yseq_tr, Xseq_te, yseq_te, n_features)
        elseif model_id == 11
            run_tft(X_tr, y_tr, X_te, y_te, n_features)
        elseif model_id == 13
            run_mlp(X_tr, y_tr, X_te, y_te, n_features)
        else
            nothing
        end
    catch e
        @warn "Worker model $model_id failed: $(sprint(showerror, e)[1:min(80,end)])"
        nothing
    end
    elapsed_ms = (time_ns() - t0) / 1e6
    return (model_id=model_id, result=result, elapsed_ms=elapsed_ms)
end

"""
    run_all_models(ctx; selected, verbose)

Runs ALL 23 models using maximum parallelism:
  1. Fast models in-process (< 2 sec each, sequential)
  2. Heavy NN models on SEPARATE WORKER PROCESSES (true parallel)
  3. Phase 2 dependent models after all Phase 1 complete
"""
function run_all_models(ctx::AnalysisContext;
                        selected::Vector{Int}=collect(1:N_MODELS),
                        verbose::Bool=true)
    if isempty(MODEL_DISPATCH)
        _register_models!()
    end

    phase1 = filter(m -> m in selected && !(m in PHASE2_MODELS), selected)
    phase2 = filter(m -> m in selected && m in PHASE2_MODELS, selected)
    fast   = sort(filter(m -> m in FAST_MODELS, phase1))
    heavy  = sort(filter(m -> m in HEAVY_MODELS, phase1))

    n_workers = nworkers()
    n_procs   = nprocs()

    if verbose
        println("═" ^ 64)
        println("  RUNNING ALL $(length(selected)) MODELS")
        println("  Workers: $n_workers processes | Fast: $(length(fast)) | Heavy: $(length(heavy))")
        println("═" ^ 64)
        println()
    end

    # ── Phase 1A: Fast models FIRST (threaded when available) ──
    n_threads = Threads.nthreads()
    if verbose println("  ── FAST MODELS ($(length(fast)) models, $(n_threads > 1 ? "$(n_threads) threads" : "sequential")) ──────────") end
    if n_threads > 1
        fast_vec = collect(fast)
        Threads.@threads for m in fast_vec
            run_model(ctx, m; verbose=false)  # verbose=false to avoid interleaved output
        end
    else
        for m in fast
            run_model(ctx, m; verbose)
        end
    end

    if verbose
        n_fast_pass = count(r -> r.success, ctx.log)
        println("  Fast models done: $n_fast_pass/$(length(fast)) passed")
        println()
    end

    # ── Phase 1B: Heavy models on WORKER PROCESSES ───────────────
    if !isempty(heavy)
        if verbose
            println("  ── HEAVY MODELS ($(length(heavy)) models, $n_workers workers) ────────")
        end

        if n_workers > 1
            # Dispatch each heavy model to a separate worker process
            futures = Dict{Int, Future}()
            for m in heavy
                f = @spawnat :any _run_heavy_model_isolated(
                    m,
                    ctx.Xseq_train, ctx.yseq_train, ctx.Xseq_test, ctx.yseq_test,
                    ctx.X_train, ctx.y_train, ctx.X_test, ctx.y_test,
                    ctx.prices, ctx.returns, ctx.n_features
                )
                futures[m] = f
                if verbose
                    println("  → Dispatched Model $m ($(MODEL_NAMES[m])) to worker")
                end
            end

            # Collect results as they complete
            for (m, f) in futures
                worker_result = fetch(f)
                name = "$m. $(MODEL_NAMES[m])"
                if worker_result.result !== nothing
                    lock(ctx.lock) do
                        ctx.results[name] = worker_result.result
                        push!(ctx.log, RalphLog(name, true, worker_result.elapsed_ms, "OK"))
                    end
                    if verbose
                        @printf("  ✓ %-40s  %8.1f ms\n", name, worker_result.elapsed_ms)
                    end
                else
                    lock(ctx.lock) do
                        push!(ctx.log, RalphLog(name, false, worker_result.elapsed_ms, "Worker failed"))
                    end
                    if verbose
                        @printf("  ✗ %-40s  FAILED\n", name)
                    end
                end
            end
        else
            # No workers — fall back to sequential (still runs all models)
            if verbose
                println("  ⚠ No worker processes. Running sequentially.")
                println("    Use: julia -p auto run_analysis.jl $ticker")
            end
            for m in heavy
                run_model(ctx, m; verbose)
            end
        end
    end

    # ── Phase 2: Dependent models ────────────────────────────────
    if verbose
        println()
        println("  ── DEPENDENT MODELS ──────────────────────────────────")
    end
    for m in phase2
        run_model(ctx, m; verbose)
    end

    run_supporting(ctx; verbose)

    if verbose
        n_pass = count(r -> r.success, ctx.log)
        total_ms = sum(r.time_ms for r in ctx.log)
        println()
        println("═" ^ 64)
        println("  ALL $(length(ctx.log)) MODELS COMPLETE — $n_pass passed RALPH")
        @printf("  Total CPU time: %.1f sec", total_ms/1000)
        if n_workers > 1
            # Wall time is roughly max(heavy) not sum(heavy)
            heavy_times = [r.time_ms for r in ctx.log if any(occursin(MODEL_NAMES[m], r.model_name) for m in heavy if haskey(MODEL_NAMES, m))]
            if !isempty(heavy_times)
                @printf(" | Parallel wall time: ~%.0f sec", maximum(heavy_times)/1000)
            end
        end
        println()
        println("═" ^ 64)
        println()
    end
end
