# ── Chart Dashboards — 9 dashboard sets (PNG+SVG each) ────────
# Each dashboard is a multi-panel layout visualizing model results.
using Plots

# Helper: safely get a model result by keyword match
function _find_result(ctx, keyword)
    for (name, r) in ctx.results
        if occursin(keyword, name) && r isa NamedTuple
            return r
        end
    end
    return nothing
end

"""Generate all chart dashboards. Returns list of files created."""
function generate_charts(ctx::AnalysisContext, composite::NamedTuple)::Vector{String}
    files = String[]
    dir = ctx.output_dir
    tk = ctx.display_ticker

    if ctx.asset_type == :polymarket || length(ctx.returns) < 30
        @warn "Insufficient data for charts — skipping"
        return files
    end

    BG = :black; FG = :white  # consistent dark theme

    # Helper: save a dashboard as PNG+SVG
    _save(dashboard, name) = begin
        f_png = joinpath(dir, "$(tk)_$(name).png")
        f_svg = joinpath(dir, "$(tk)_$(name).svg")
        savefig(dashboard, f_png); savefig(dashboard, f_svg)
        push!(files, f_png, f_svg)
    end

    r = ctx.returns
    n = length(r)

    # ══════════════ 1. Model Consensus ═══════════════════════
    names_short = String[]; probs_v = Float64[]; cols = Symbol[]
    for (name, res) in sort(collect(ctx.results), by=x->x.first)
        if res isa NamedTuple && hasproperty(res, :probability)
            p = res.probability; isnan(p) && continue
            short = replace(name, r"^\d+\.\s*" => "")
            short = length(short) > 18 ? short[1:18]*".." : short
            push!(names_short, short); push!(probs_v, p)
            push!(cols, p > 0.55 ? :green : p < 0.45 ? :red : :yellow)
        end
    end
    p1 = plot(background_color=BG, foreground_color=FG,
        title="Model Direction Probabilities", ylabel="P(Up)", titlefontsize=11, legend=false, xrotation=45)
    !isempty(probs_v) && bar!(p1, names_short, probs_v, color=cols, alpha=0.85)
    hline!(p1, [0.5], color=:white, linestyle=:dash, linewidth=1)

    v_col = composite.direction == "BUY" ? :green : startswith(composite.direction, "LEAN") ? :yellow : :red
    p2 = plot(xlims=(0,10), ylims=(0,10), axis=false, grid=false, ticks=false,
        background_color=BG, foreground_color=FG, legend=false, title="Composite Decision", titlefontsize=12)
    annotate!(p2, 5, 7.5, text(composite.direction, 22, v_col, :center, :bold))
    annotate!(p2, 5, 5.5, text("Score: $(@sprintf("%+.3f", composite.score))", 12, :white, :center))
    annotate!(p2, 5, 4.0, text("Confidence: $(composite.confidence)%", 11, :white, :center))
    annotate!(p2, 5, 2.5, text("p(up): $(@sprintf("%.3f", composite.p_true)) | $(composite.n_models) models", 10, :gray, :center))

    # Model accuracy comparison
    acc_names = String[]; acc_vals = Float64[]; acc_cols = Symbol[]
    for (name, res) in sort(collect(ctx.results), by=x->x.first)
        if res isa NamedTuple && hasproperty(res, :accuracy) && !isnan(res.accuracy)
            short = replace(name, r"^\d+\.\s*" => "")
            short = length(short) > 15 ? short[1:15]*".." : short
            push!(acc_names, short); push!(acc_vals, res.accuracy * 100)
            push!(acc_cols, res.accuracy > 0.50 ? :green : :red)
        end
    end
    p3 = plot(background_color=BG, foreground_color=FG,
        title="Model Accuracy (%)", ylabel="Accuracy %", titlefontsize=11, legend=false, xrotation=45)
    !isempty(acc_vals) && bar!(p3, acc_names, acc_vals, color=acc_cols, alpha=0.85)
    hline!(p3, [50], color=:white, linestyle=:dash, linewidth=1, label="")

    # Key metrics text panel
    p4 = plot(xlims=(0,10), ylims=(0,10), axis=false, grid=false, ticks=false,
        background_color=BG, foreground_color=FG, legend=false, title="Key Metrics", titlefontsize=12)
    ym = 9.0
    for (name, res) in ctx.results
        res isa NamedTuple || continue
        if occursin("Kelly", name) && hasproperty(res, :kelly_half)
            annotate!(p4, 5, ym, text("Kelly 1/2: $(@sprintf("%.1f%%", res.kelly_half*100))", 10, :cyan, :center)); ym -= 1.2
        end
        if occursin("EV Gap", name) && hasproperty(res, :ev_after_fees)
            c = res.ev_after_fees > 0.02 ? :green : :red
            annotate!(p4, 5, ym, text("EV Gap: $(@sprintf("%.1f%%", res.ev_after_fees*100))", 10, c, :center)); ym -= 1.2
        end
        if occursin("GARCH", name) && !occursin("LSTM", name) && hasproperty(res, :σ_annual_forecast)
            annotate!(p4, 5, ym, text("GARCH Vol: $(@sprintf("%.1f%%", res.σ_annual_forecast*100))", 10, :orange, :center)); ym -= 1.2
        end
        if occursin("AR(1)", name) && hasproperty(res, :regime)
            annotate!(p4, 5, ym, text("AR(1): $(res.regime)", 9, :white, :center)); ym -= 1.2
        end
        if occursin("Martingale", name) && hasproperty(res, :regime)
            annotate!(p4, 5, ym, text("Martingale: $(res.regime)", 9, :yellow, :center)); ym -= 1.2
        end
        ym < 1.0 && break
    end
    _save(plot(p1, p2, p3, p4, layout=(2,2), size=(1400, 1000)), "01_model_consensus")

    # ══════════════ 2. Price & Returns ═══════════════════════
    p5 = plot(ctx.prices, color=:cyan, linewidth=2, legend=false,
        title="Price History — $tk", ylabel="Price (\$)", background_color=BG, foreground_color=FG, titlefontsize=11)
    p6 = histogram(r, bins=50, color=:cyan, alpha=0.7, legend=false,
        title="Return Distribution", xlabel="Daily Return", background_color=BG, foreground_color=FG, titlefontsize=11)
    vol_20 = [i >= 20 ? std(@view r[i-19:i]) * sqrt(252) * 100 : NaN for i in 1:n]
    p7 = plot(vol_20, color=:orange, linewidth=2, legend=false,
        title="Rolling 20-Day Volatility (%)", ylabel="Ann. Vol (%)", background_color=BG, foreground_color=FG, titlefontsize=11)
    cum_r = cumsum(r) .* 100
    p8 = plot(cum_r, color=cum_r[end] > 0 ? :green : :red, linewidth=2,
        fill=(0, 0.15, cum_r[end] > 0 ? :green : :red), legend=false,
        title="Cumulative Return (%)", ylabel="%", background_color=BG, foreground_color=FG, titlefontsize=11)
    hline!(p8, [0], color=:white, linestyle=:dash, linewidth=1)
    _save(plot(p5, p6, p7, p8, layout=(2,2), size=(1400, 1000)), "02_price_returns")

    # ══════════════ 3. ML Prediction Quality ═════════════════
    # Feature importance
    rf = _find_result(ctx, "Random Forest")
    pfi = plot(background_color=BG, foreground_color=FG,
        title="Feature Importance (Random Forest)", ylabel="Importance", titlefontsize=11, legend=false, xrotation=45)
    if rf !== nothing && hasproperty(rf, :feature_importance)
        fi = rf.feature_importance
        fn = length(FEATURE_NAMES) >= length(fi) ? FEATURE_NAMES[1:length(fi)] :
             ["F$i" for i in 1:length(fi)]
        bar!(pfi, fn, fi, color=:cyan, alpha=0.85)
    end

    # SGD cumulative PnL vs buy-and-hold
    sgd = _find_result(ctx, "SGD")
    psgd = plot(background_color=BG, foreground_color=FG,
        title="SGD Strategy vs Buy-and-Hold", ylabel="Cumulative PnL (%)", titlefontsize=11)
    if sgd !== nothing && hasproperty(sgd, :cumulative_pnl) && !isempty(sgd.cumulative_pnl)
        plot!(psgd, sgd.cumulative_pnl, color=:green, linewidth=2, label="SGD Strategy")
        bh = cumsum(r[end-length(sgd.cumulative_pnl)+1:end]) .* 100
        plot!(psgd, bh, color=:gray, linewidth=1, linestyle=:dash, label="Buy & Hold")
    end

    # Model accuracy comparison (larger version)
    pacc = plot(background_color=BG, foreground_color=FG,
        title="Out-of-Sample Accuracy by Model", ylabel="Accuracy %", titlefontsize=11, legend=false, xrotation=45)
    !isempty(acc_vals) && bar!(pacc, acc_names, acc_vals, color=acc_cols, alpha=0.85)
    hline!(pacc, [50], color=:white, linestyle=:dash, linewidth=1, label="")

    # Prediction distribution (how spread are model probabilities)
    pdist = histogram(filter(!isnan, probs_v), bins=15, color=:magenta, alpha=0.7, legend=false,
        title="Distribution of Model Probabilities", xlabel="P(Up)", ylabel="Count",
        background_color=BG, foreground_color=FG, titlefontsize=11)
    vline!(pdist, [0.5], color=:white, linestyle=:dash, linewidth=1)

    _save(plot(pfi, psgd, pacc, pdist, layout=(2,2), size=(1400, 1000)), "03_ml_predictions")

    # ══════════════ 4. Volatility & Options ══════════════════
    bs = _find_result(ctx, "Black-Scholes")
    garch = _find_result(ctx, "GARCH")

    # Vol estimator comparison
    pvol = plot(background_color=BG, foreground_color=FG,
        title="Volatility Estimators (Annualized %)", ylabel="Vol %", titlefontsize=11, legend=false)
    if bs !== nothing
        bar!(pvol, ["Historical", "Parkinson\n(High-Low)", "EWMA", "Best Est."],
            [bs.sigma_hist, bs.sigma_parkinson, bs.sigma_ewma, bs.sigma_best] .* 100,
            color=[:cyan, :orange, :magenta, :green], alpha=0.85)
    end

    # GARCH conditional volatility time series
    pgarch = plot(background_color=BG, foreground_color=FG,
        title="GARCH Conditional Volatility vs Realized", ylabel="Ann. Vol (%)", titlefontsize=11)
    if garch !== nothing && hasproperty(garch, :garch_α)
        r2 = r .^ 2; rv = var(r)
        sigma2_series = zeros(n)
        sigma2_series[1] = rv
        for i in 2:n
            sigma2_series[i] = garch.garch_ω + garch.garch_α * r2[i-1] + garch.garch_β * sigma2_series[i-1]
        end
        garch_vol = sqrt.(max.(sigma2_series, 1e-12)) .* sqrt(252) .* 100
        plot!(pgarch, garch_vol, color=:orange, linewidth=2, label="GARCH")
        plot!(pgarch, vol_20, color=:cyan, linewidth=1, linestyle=:dash, label="Realized 20d")
    end

    # Greeks bar chart
    pgreeks = plot(background_color=BG, foreground_color=FG,
        title="Black-Scholes Greeks (ATM Option)", titlefontsize=11, legend=false, xrotation=30)
    if bs !== nothing
        greek_names = ["Delta", "Gamma\n(x100)", "Theta\n(daily)", "Vega", "Rho"]
        greek_vals = [bs.delta_call, bs.gamma*100, bs.theta_call, bs.vega, bs.rho_call]
        greek_cols = [:green, :cyan, :red, :orange, :magenta]
        bar!(pgreeks, greek_names, greek_vals, color=greek_cols, alpha=0.85)
    end

    # FD Pricer: European vs American options
    fd = _find_result(ctx, "Crank-Nicolson")
    pfd = plot(background_color=BG, foreground_color=FG,
        title="Option Prices: BS vs Finite Difference", titlefontsize=11, legend=false)
    if fd !== nothing && bs !== nothing
        bar!(pfd, ["BS Call", "FD Call", "BS Put", "FD Put", "American\nPut"],
            [bs.call_price, fd.fd_price_call, bs.put_price, fd.fd_price_put, fd.american_put],
            color=[:green, :cyan, :red, :orange, :magenta], alpha=0.85)
    end
    _save(plot(pvol, pgarch, pgreeks, pfd, layout=(2,2), size=(1400, 1000)), "04_volatility_options")

    # ══════════════ 5. RL & Meta-Labeling ════════════════════
    rl = _find_result(ctx, "Reinforcement")
    meta = _find_result(ctx, "Meta-Label")

    # RL cumulative PnL
    prl = plot(background_color=BG, foreground_color=FG,
        title="RL Agent Cumulative PnL", ylabel="PnL (%)", titlefontsize=11, legend=false)
    if rl !== nothing && hasproperty(rl, :cumulative_pnl) && !isempty(rl.cumulative_pnl)
        cpnl = rl.cumulative_pnl
        plot!(prl, cpnl, color=cpnl[end] > 0 ? :green : :red, linewidth=2,
            fill=(0, 0.15, cpnl[end] > 0 ? :green : :red))
        hline!(prl, [0], color=:white, linestyle=:dash, linewidth=1)
    end

    # RL action distribution
    pact = plot(background_color=BG, foreground_color=FG,
        title="RL Agent Action Distribution", titlefontsize=11, legend=false)
    if rl !== nothing && hasproperty(rl, :actions) && !isempty(rl.actions)
        acts = rl.actions
        n_short = count(==(1), acts); n_flat = count(==(2), acts); n_long = count(==(3), acts)
        bar!(pact, ["Short", "Flat", "Long"], [n_short, n_flat, n_long],
            color=[:red, :yellow, :green], alpha=0.85)
    end

    # RL training rewards
    prew = plot(background_color=BG, foreground_color=FG,
        title="RL Training Reward by Episode", xlabel="Episode", ylabel="Reward", titlefontsize=11, legend=false)
    if rl !== nothing && hasproperty(rl, :training_rewards) && !isempty(rl.training_rewards)
        plot!(prew, rl.training_rewards, color=:cyan, linewidth=2, marker=:circle, markersize=6)
    end

    # Meta-labeling summary
    pmeta = plot(xlims=(0,10), ylims=(0,10), axis=false, grid=false, ticks=false,
        background_color=BG, foreground_color=FG, legend=false, title="Meta-Labeling Decision", titlefontsize=12)
    if meta !== nothing
        mc = meta.bet_size > 0.5 ? :green : :red
        annotate!(pmeta, 5, 8, text(meta.direction, 22, mc, :center, :bold))
        annotate!(pmeta, 5, 6, text("Bet Size: $(@sprintf("%.0f%%", meta.bet_size*100))", 14, :white, :center))
        annotate!(pmeta, 5, 4.5, text("Primary: $(meta.primary_direction) @ $(@sprintf("%.1f%%", meta.primary_probability*100))", 11, :cyan, :center))
        annotate!(pmeta, 5, 3, text("Meta Accuracy: $(@sprintf("%.1f%%", meta.meta_accuracy*100))", 10, :gray, :center))
    end
    _save(plot(prl, pact, prew, pmeta, layout=(2,2), size=(1400, 1000)), "05_rl_metalabeling")

    # ══════════════ 6. Statistical & Regime ══════════════════
    mart = _find_result(ctx, "Martingale")
    tb = _find_result(ctx, "Triple-Barrier")
    ar1 = _find_result(ctx, "AR(1)")
    bayes = _find_result(ctx, "Bayesian")

    # Variance ratio by horizon
    pvr = plot(background_color=BG, foreground_color=FG,
        title="Variance Ratio Test (VR=1 = Random Walk)", ylabel="VR", titlefontsize=11, legend=false)
    if mart !== nothing
        vr_vals = [mart.vr2, mart.vr5, mart.vr10, mart.vr20]
        vr_z = [mart.z_vr2, mart.z_vr5, mart.z_vr10, mart.z_vr20]
        valid = .!isnan.(vr_vals)
        if any(valid)
            vr_cols = [abs(z) > 1.96 ? :green : :gray for z in vr_z[valid]]
            bar!(pvr, ["q=2", "q=5", "q=10", "q=20"][valid], vr_vals[valid], color=vr_cols, alpha=0.85)
            hline!(pvr, [1.0], color=:white, linestyle=:dash, linewidth=1)
        end
    end

    # Triple-barrier regime pie
    ptb = plot(background_color=BG, foreground_color=FG,
        title="Triple-Barrier Outcomes", titlefontsize=11, legend=:right)
    if tb !== nothing
        bar!(ptb, ["Upper Hit\n(Profit)", "Lower Hit\n(Stop Loss)", "Expiry\n(No Move)"],
            [tb.upper_hit_rate, tb.lower_hit_rate, tb.expiry_rate] .* 100,
            color=[:green, :red, :yellow], alpha=0.85, ylabel="%", legend=false)
    end

    # AR(1) scatter: r_t vs r_{t+1}
    par1 = plot(background_color=BG, foreground_color=FG,
        title="AR(1): Return Autocorrelation", xlabel="Return(t)", ylabel="Return(t+1)",
        titlefontsize=11, legend=:topright)
    if length(r) > 10
        scatter!(par1, r[1:end-1], r[2:end], color=:cyan, alpha=0.3, markersize=2, label="")
        if ar1 !== nothing
            x_range = range(minimum(r), maximum(r), length=50)
            y_hat = ar1.alpha .+ ar1.beta .* x_range
            lc = ar1.beta > 0 ? :green : :orange
            plot!(par1, x_range, y_hat, color=lc, linewidth=2, label="beta=$(@sprintf("%.3f", ar1.beta))")
        end
    end

    # Bayesian prior → posterior
    pbay = plot(background_color=BG, foreground_color=FG,
        title="Bayesian Update: Prior to Posterior", titlefontsize=11, legend=false)
    if bayes !== nothing
        bar!(pbay, ["Prior P(up)", "Posterior P(up)"],
            [bayes.prior, bayes.posterior] .* 100,
            color=[bayes.prior > 0.5 ? :green : :red, bayes.posterior > 0.5 ? :green : :red], alpha=0.85, ylabel="%")
        hline!(pbay, [50], color=:white, linestyle=:dash, linewidth=1)
    end
    _save(plot(pvr, ptb, par1, pbay, layout=(2,2), size=(1400, 1000)), "06_regime_analysis")

    # ══════════════ 7. Information Theory ════════════════════
    kl = _find_result(ctx, "KL-Divergence")
    breg = _find_result(ctx, "Bregman")
    cal = _find_result(ctx, "Calibration")
    evg = _find_result(ctx, "EV Gap")

    # KL / JS divergence
    pkl = plot(background_color=BG, foreground_color=FG,
        title="KL & JS Divergence (lower = better calibrated)", ylabel="Divergence", titlefontsize=11, legend=false)
    if kl !== nothing
        bar!(pkl, ["KL Forward", "KL Reverse", "Jensen-Shannon"],
            [kl.kl_divergence, kl.kl_reverse, kl.js_divergence],
            color=[:cyan, :orange, :magenta], alpha=0.85)
    end

    # Bregman weights
    pbreg = plot(background_color=BG, foreground_color=FG,
        title="Bregman: Market vs Model vs Optimal", ylabel="Weight", titlefontsize=11, legend=:topright)
    if breg !== nothing && hasproperty(breg, :prior) && hasproperty(breg, :optimal_weights)
        x_pos = [1, 2, 3]
        bw = 0.25
        bar!(pbreg, x_pos .- bw, breg.prior, bar_width=bw, color=:gray, alpha=0.85, label="Market")
        bar!(pbreg, x_pos, breg.model_prior, bar_width=bw, color=:cyan, alpha=0.85, label="Model")
        bar!(pbreg, x_pos .+ bw, breg.optimal_weights, bar_width=bw, color=:green, alpha=0.85, label="Optimal")
        xticks!(pbreg, (x_pos, ["Big Up", "Flat", "Big Down"]))
    end

    # Calibration: model prob vs actual
    pcal = plot(background_color=BG, foreground_color=FG,
        title="Calibration Check", titlefontsize=11, legend=false)
    if cal !== nothing
        bar!(pcal, ["Avg Model\nProbability", "Actual\nUp Rate"],
            [cal.avg_model_prob, cal.actual_up_rate] .* 100,
            color=[:cyan, cal.is_calibrated ? :green : :red], alpha=0.85, ylabel="%")
        hline!(pcal, [50], color=:white, linestyle=:dash, linewidth=1)
    end

    # EV Gap waterfall
    pev = plot(background_color=BG, foreground_color=FG,
        title="Expected Value Decomposition", ylabel="Probability / EV", titlefontsize=11, legend=false)
    if evg !== nothing
        bar!(pev, ["Market P", "Model P", "Raw EV", "EV After\nFees"],
            [evg.p_market, evg.p_true, evg.ev, evg.ev_after_fees],
            color=[:gray, :cyan, evg.ev > 0 ? :green : :red, evg.ev_after_fees > 0 ? :green : :red], alpha=0.85)
        hline!(pev, [0], color=:white, linestyle=:dash, linewidth=1)
    end
    _save(plot(pkl, pbreg, pcal, pev, layout=(2,2), size=(1400, 1000)), "07_information_theory")

    # ══════════════ 8. Position Sizing & Risk ════════════════
    kelly = _find_result(ctx, "Kelly")

    # Kelly fraction ladder
    pkelly = plot(background_color=BG, foreground_color=FG,
        title="Kelly Position Sizing", ylabel="% of Bankroll", titlefontsize=11, legend=false)
    if kelly !== nothing
        bar!(pkelly, ["Full Kelly", "3/4 Kelly", "1/2 Kelly\n(Recommended)", "1/4 Kelly"],
            [kelly.kelly_full, kelly.kelly_three_quarter, kelly.kelly_half, kelly.kelly_quarter] .* 100,
            color=[:red, :orange, :green, :cyan], alpha=0.85)
    end

    # Monte Carlo ruin/profit probabilities
    pmc = plot(background_color=BG, foreground_color=FG,
        title="Monte Carlo: Profit vs Ruin Probability", ylabel="%", titlefontsize=11, legend=:topright)
    if kelly !== nothing
        x_pos = [1, 2]
        bw = 0.3
        bar!(pmc, x_pos .- bw/2, [kelly.prob_profit_full, kelly.prob_profit_half],
            bar_width=bw, color=:green, alpha=0.85, label="P(Profit)")
        bar!(pmc, x_pos .+ bw/2, [kelly.prob_ruin_full, kelly.prob_ruin_half],
            bar_width=bw, color=:red, alpha=0.85, label="P(Ruin)")
        xticks!(pmc, (x_pos, ["Full Kelly", "Half Kelly"]))
    end

    # Win/Loss analysis
    pwl = plot(background_color=BG, foreground_color=FG,
        title="Win Rate & Win/Loss Ratio", titlefontsize=11, legend=false)
    if kelly !== nothing
        bar!(pwl, ["Win Rate\n(%)", "Avg Win\n(%)", "Avg Loss\n(%)"],
            [kelly.win_rate, kelly.avg_win, kelly.avg_loss],
            color=[:cyan, :green, :red], alpha=0.85)
        hline!(pwl, [50], color=:white, linestyle=:dash, linewidth=1)
    end

    # Edge consistency & Sharpe
    pedge = plot(background_color=BG, foreground_color=FG,
        title="Edge Quality Metrics", titlefontsize=11, legend=false)
    if kelly !== nothing
        bar!(pedge, ["Edge\nConsistency (%)", "Edge\nSharpe"],
            [kelly.edge_consistency, kelly.edge_sharpe * 100],
            color=[:cyan, :orange], alpha=0.85)
        hline!(pedge, [65], color=:green, linestyle=:dash, linewidth=1, label="")
    end
    _save(plot(pkelly, pmc, pwl, pedge, layout=(2,2), size=(1400, 1000)), "08_position_sizing")

    # ══════════════ 9. Term Structure & Microstructure ════════
    ts = _find_result(ctx, "Term Structure")
    logistic = _find_result(ctx, "Logistic")
    ensemble = _find_result(ctx, "Ensemble")
    event = _find_result(ctx, "Event Study")

    # Nelson-Siegel yield curve
    pts = plot(background_color=BG, foreground_color=FG,
        title="Nelson-Siegel Yield Curve", xlabel="Maturity (years)", ylabel="Yield (%)",
        titlefontsize=11, legend=false)
    if ts !== nothing
        taus = range(0.25, 30, length=100)
        ns_y(tau) = begin
            lam = max(ts.ns_lambda, 0.01); x = tau / lam; ex = exp(-x)
            t1 = (1 - ex) / x; t2 = t1 - ex
            (ts.ns_beta0 + ts.ns_beta1 * t1 + ts.ns_beta2 * t2) * 100
        end
        yields = [ns_y(t) for t in taus]
        curve_col = ts.rate_regime == "INVERTED CURVE" ? :red : ts.rate_regime == "STEEPENING" ? :green : :cyan
        plot!(pts, collect(taus), yields, color=curve_col, linewidth=2)
        hline!(pts, [ts.ns_beta0 * 100], color=:gray, linestyle=:dash, linewidth=1)
    end

    # Logistic regression coefficients
    plog = plot(background_color=BG, foreground_color=FG,
        title="Logistic Regression: Feature Coefficients", titlefontsize=11, legend=false, xrotation=45)
    if logistic !== nothing && hasproperty(logistic, :coefficients) && hasproperty(logistic, :feature_names)
        fn = logistic.feature_names
        co = logistic.coefficients
        fn = length(fn) > 10 ? fn[1:10] : fn
        co = length(co) > length(fn) ? co[1:length(fn)] : co
        coef_cols = [c > 0 ? :green : :red for c in co]
        bar!(plog, fn, co, color=coef_cols, alpha=0.85)
        hline!(plog, [0], color=:white, linestyle=:dash, linewidth=1)
    end

    # Event study: post-shock behavior
    pevent = plot(background_color=BG, foreground_color=FG,
        title="Post-Shock Behavior (Event Study)", titlefontsize=11, legend=false)
    if event !== nothing
        bar!(pevent, ["Continue\n(Hold)", "Partial\nRetrace", "Full\nReversal"],
            [event.hold_rate, event.fade_rate, event.reversal_rate] .* 100,
            color=[:green, :yellow, :red], alpha=0.85, ylabel="%")
    end

    # Ensemble model weights
    pens = plot(background_color=BG, foreground_color=FG,
        title="Ensemble Model Weights", titlefontsize=11, legend=false, xrotation=45)
    if ensemble !== nothing && hasproperty(ensemble, :model_weights) && ensemble.model_weights isa Dict
        mw = sort(collect(ensemble.model_weights), by=x->-x.second)
        mw_names = [length(k) > 12 ? k[1:12]*".." : k for (k,_) in mw]
        mw_vals = [v * 100 for (_,v) in mw]
        bar!(pens, mw_names, mw_vals, color=:cyan, alpha=0.85, ylabel="Weight %")
    end
    _save(plot(pts, plog, pevent, pens, layout=(2,2), size=(1400, 1000)), "09_term_microstructure")

    println("  Charts generated: $(div(length(files), 2)) dashboards ($(length(files)) files)")
    return files
end
