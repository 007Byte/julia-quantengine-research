# ── PDF Report — Professional Quantitative Analysis Report via Luxor ──
# Designed for two audiences:
#   1. C-suite / beginners: Plain English summaries, clear profit projections
#   2. Quants: Full model data, statistical details, risk metrics

import Luxor

"""Generate a professional multi-page PDF report. Returns the file path."""
function generate_pdf(ctx::AnalysisContext, composite::NamedTuple,
                      chart_files::Vector{String};
                      trade_plan::Union{TradePlan, Nothing}=nothing)::String
    dir = ctx.output_dir
    tk  = ctx.display_ticker
    pdf_path = joinpath(dir, "REPORT_$(tk).pdf")

    PDF_W = 612; PDF_H = 792; M = 50; COL_W = PDF_W - 2*M
    c_navy   = parse(Luxor.Colorant, "midnightblue")
    c_green  = parse(Luxor.Colorant, "forestgreen")
    c_red    = parse(Luxor.Colorant, "firebrick")
    c_amber  = parse(Luxor.Colorant, "darkorange")
    c_gray   = parse(Luxor.Colorant, "gray40")
    c_ltgray = parse(Luxor.Colorant, "gray92")
    c_white  = parse(Luxor.Colorant, "white")
    c_black  = parse(Luxor.Colorant, "black")
    c_blue   = parse(Luxor.Colorant, "steelblue")

    verdict_color = if composite.direction == "BUY" || startswith(composite.direction, "LEAN B")
        c_green
    elseif composite.direction == "DO NOT BUY" || startswith(composite.direction, "LEAN S")
        c_red
    else
        c_amber
    end

    # ── Drawing Helpers ──────────────────────────────────────
    _section(title, y) = begin
        Luxor.sethue(c_navy); Luxor.fontsize(14); Luxor.fontface("Helvetica-Bold")
        Luxor.text(title, Luxor.Point(M, y))
        Luxor.setline(1.5); Luxor.line(Luxor.Point(M, y+4), Luxor.Point(PDF_W-M, y+4), action=:stroke)
        y + 22
    end
    _t(txt, y; sz=10, c=c_black, b=false, indent=0) = begin
        Luxor.sethue(c); Luxor.fontsize(sz); Luxor.fontface(b ? "Helvetica-Bold" : "Helvetica")
        Luxor.text(txt, Luxor.Point(M+indent, y)); y + sz + 4
    end
    _kv(k, v, y; vc=c_black, ki=10) = begin
        Luxor.sethue(c_gray); Luxor.fontsize(10); Luxor.fontface("Helvetica")
        Luxor.text(k, Luxor.Point(M+ki, y))
        Luxor.sethue(vc); Luxor.fontface("Helvetica-Bold")
        Luxor.text(v, Luxor.Point(M+220, y)); y + 16
    end
    _wrap(txt, y; sz=10, c=c_black, w=COL_W-10, indent=0) = begin
        Luxor.sethue(c); Luxor.fontsize(sz); Luxor.fontface("Helvetica")
        words = split(txt); line = ""; lw = 0
        for word in words
            test = isempty(line) ? word : line * " " * word
            if length(test) * sz * 0.5 > w
                Luxor.text(line, Luxor.Point(M+indent, y)); y += sz + 3; line = word
            else
                line = test
            end
        end
        !isempty(line) && (Luxor.text(line, Luxor.Point(M+indent, y)); y += sz + 3)
        y
    end
    _box(y, h; c=c_ltgray) = begin
        Luxor.sethue(c); Luxor.rect(Luxor.Point(M, y), COL_W, h, action=:fill); y
    end
    page_num = Ref(1)
    _newpage() = begin
        Luxor.Cairo.show_page(Luxor.currentdrawing().cr)
        Luxor.background("white"); page_num[] += 1
        Luxor.sethue(c_gray); Luxor.fontsize(7); Luxor.fontface("Helvetica")
        Luxor.text("$tk Quantitative Analysis Report — $(Dates.format(Dates.today(), "U d, yyyy")) — Page $(page_num[])",
            Luxor.Point(M, PDF_H-25))
        Luxor.text("NOT FINANCIAL ADVICE", Luxor.Point(PDF_W-M, PDF_H-25), halign=:right)
    end
    _embed_chart(svg_path, y_top, tw, th) = begin
        if isfile(svg_path)
            svgimg = Luxor.readsvg(svg_path)
            sc = min(tw / svgimg.width, th / svgimg.height)
            x_off = (PDF_W - svgimg.width * sc) / 2
            Luxor.gsave(); Luxor.translate(Luxor.Point(x_off, y_top)); Luxor.scale(sc)
            Luxor.placeimage(svgimg, Luxor.Point(0, 0), centered=false); Luxor.grestore()
        end
    end
    _checkpage(y, need=80) = begin
        if y > PDF_H - need; _newpage(); return 50; end; y
    end

    # ── Gather data we'll reference throughout ───────────────
    tp = trade_plan !== nothing ? trade_plan.strategy : nothing
    agg = trade_plan !== nothing ? trade_plan.comparison.aggressive : nothing
    con = trade_plan !== nothing ? trade_plan.comparison.conservative : nothing
    n_pass = count(r -> r.success, ctx.log)
    n_models = length(ctx.log)
    n_bullish = count(p -> p.second isa NamedTuple && hasproperty(p.second, :probability) &&
                !isnan(p.second.probability) && p.second.probability > 0.55, ctx.results)
    n_bearish = count(p -> p.second isa NamedTuple && hasproperty(p.second, :probability) &&
                !isnan(p.second.probability) && p.second.probability < 0.45, ctx.results)
    n_neutral = count(p -> p.second isa NamedTuple && hasproperty(p.second, :probability) &&
                !isnan(p.second.probability) && 0.45 <= p.second.probability <= 0.55, ctx.results)

    # ── BEGIN PDF ────────────────────────────────────────────
    Luxor.Drawing(PDF_W, PDF_H, pdf_path)
    Luxor.origin(Luxor.Point(0, 0))
    Luxor.background("white")

    # ═════════════════════════════════════════════════════════
    #  PAGE 1: COVER + EXECUTIVE SUMMARY
    # ═════════════════════════════════════════════════════════
    Luxor.sethue(c_navy)
    Luxor.rect(Luxor.Point(0, 0), PDF_W, 140, action=:fill)
    Luxor.sethue(c_white); Luxor.fontsize(36); Luxor.fontface("Helvetica-Bold")
    Luxor.text(tk, Luxor.Point(M, 55))
    Luxor.fontsize(16); Luxor.fontface("Helvetica")
    Luxor.text("Quantitative Analysis Report", Luxor.Point(M, 82))
    Luxor.fontsize(10)
    Luxor.text("30-Model Engine | $(Dates.format(Dates.today(), "U d, yyyy")) | Price: \$$(round(ctx.S0, digits=2))", Luxor.Point(M, 105))
    if ctx.asset_type != :polymarket && !isempty(ctx.dates)
        Luxor.text("Data: $(Date(ctx.dates[1])) to $(Date(ctx.dates[end])) ($(length(ctx.prices)) trading days)", Luxor.Point(M, 120))
    end

    # Verdict badge
    y = 165
    Luxor.sethue(verdict_color)
    Luxor.rect(Luxor.Point(M, y), COL_W, 50, action=:fill)
    Luxor.sethue(c_white); Luxor.fontsize(24); Luxor.fontface("Helvetica-Bold")
    Luxor.text("$(composite.direction)  —  Confidence: $(composite.confidence)%", Luxor.Point(M+15, y+33))
    y += 70

    # Executive Summary in plain English
    y = _section("Executive Summary", y)
    summary = "We analyzed $(tk) using 30 quantitative models spanning machine learning, " *
              "statistical analysis, derivatives pricing, and market microstructure. " *
              "$(n_bullish) models are bullish, $(n_bearish) are bearish, and $(n_neutral) are neutral. "
    if composite.direction == "BUY" || startswith(composite.direction, "LEAN B")
        summary *= "The overall consensus leans positive, suggesting a potential buying opportunity."
    elseif composite.direction == "HOLD"
        summary *= "The models are mixed — there is no strong directional signal at this time."
    else
        summary *= "The overall consensus leans negative, suggesting caution."
    end
    y = _wrap(summary, y; sz=10)
    y += 8

    # Profit projection box
    if tp !== nothing && tp.direction != :hold
        _box(y, 115; c=c_ltgray)
        y += 15
        y = _t("Profit Projection (Recommended Strategy)", y; sz=12, b=true, c=c_navy)
        y += 3
        tp_d = tp.size_dollars * tp.take_profit_pct / 100
        sl_d = tp.size_dollars * tp.stop_loss_pct / 100
        exp_d = tp.size_dollars * tp.expected_return_pct / 100
        p_w = clamp(tp.confidence / 100, 0.01, 0.99)
        y = _kv("Invest:", "\$$(round(tp.size_dollars, digits=0)) ($(round(tp.size_fraction*100,digits=1))% of bankroll)", y)
        y = _kv("Best case:", "+\$$(round(tp_d, digits=2)) (+$(round(tp.take_profit_pct,digits=1))%) — $(round(Int, p_w*100))% chance", y; vc=c_green)
        y = _kv("Worst case:", "-\$$(round(sl_d, digits=2)) (-$(round(tp.stop_loss_pct,digits=1))%) — $(round(Int, (1-p_w)*100))% chance", y; vc=c_red)
        y = _kv("Expected profit:", "\$$(round(exp_d, digits=2)) per trade (+$(round(tp.expected_return_pct,digits=1))%)", y; vc=exp_d > 0 ? c_green : c_red)
        y += 10
    else
        _box(y, 40; c=c_ltgray); y += 12
        y = _t("Recommendation: HOLD — Models do not show a strong enough edge to trade right now.", y; sz=11, c=c_amber, b=true)
        y += 15
    end

    # Key numbers grid
    y = _section("Key Numbers", y)
    y = _kv("Current Price:", "\$$(round(ctx.S0, digits=2))", y)
    y = _kv("Composite Score:", @sprintf("%+.3f", composite.score), y; vc=composite.score > 0 ? c_green : c_red)
    y = _kv("Bull / Bear / Neutral:", "$(n_bullish) / $(n_bearish) / $(n_neutral) models", y)
    y = _kv("Models Passed:", "$(n_pass) / $(n_models)", y)

    # Pull key model values
    for (name, r) in ctx.results
        r isa NamedTuple || continue
        if occursin("Kelly", name) && hasproperty(r, :kelly_half)
            y = _kv("Kelly Criterion (1/2):", @sprintf("%.1f%% of portfolio", r.kelly_half*100), y; vc=c_navy)
        end
        if occursin("GARCH", name) && !occursin("LSTM", name) && hasproperty(r, :σ_annual_forecast)
            y = _kv("Volatility Forecast:", @sprintf("%.1f%% annualized", r.σ_annual_forecast*100), y; vc=c_amber)
        end
        if occursin("Term Structure", name) && hasproperty(r, :rate_regime)
            y = _kv("Rate Environment:", r.rate_regime, y)
        end
        if occursin("Martingale", name) && hasproperty(r, :regime)
            y = _kv("Market Predictability:", r.regime, y)
        end
    end

    # ═════════════════════════════════════════════════════════
    #  PAGE 2: ACTION PLAN + PROFIT SCENARIOS
    # ═════════════════════════════════════════════════════════
    if tp !== nothing && tp.direction != :hold
        _newpage(); y = 50
        y = _section("Action Plan — What To Do", y)

        hold_str = tp.hold_time_hours < 24 ? "$(round(Int, tp.hold_time_hours)) hours" :
                   "$(round(Int, tp.hold_time_hours / 24)) days"

        _box(y, 100; c=c_ltgray); y += 15
        y = _t("1. Place a $(uppercase(string(tp.buy_type))) order for $(tk) at \$$(round(tp.limit_price, digits=2))", y; sz=11, b=true, indent=10)
        y = _t("2. Position size: \$$(round(tp.size_dollars, digits=0)) ($(round(tp.size_fraction*100,digits=1))% of your bankroll)", y; sz=11, indent=10)
        tp_price = round(tp.limit_price * (1 + tp.take_profit_pct/100), digits=2)
        sl_price = round(tp.limit_price * (1 - tp.stop_loss_pct/100), digits=2)
        y = _t("3. Take profit: sell at \$$(tp_price) (+$(round(tp.take_profit_pct,digits=1))%)", y; sz=11, indent=10, c=c_green)
        y = _t("4. Stop loss: sell at \$$(sl_price) (-$(round(tp.stop_loss_pct,digits=1))%)", y; sz=11, indent=10, c=c_red)
        y = _t("5. Hold for $(hold_str), then re-evaluate", y; sz=11, indent=10)
        y += 15

        # Strategy comparison
        y = _section("Strategy Comparison", y)
        y = _wrap("The engine runs two strategies and blends them. Here is what each would do:", y)
        y += 5

        for (label, strat, color) in [("Aggressive", agg, c_amber), ("Conservative", con, c_blue), ("Recommended (Blend)", tp, c_navy)]
            strat === nothing && continue
            dir = strat.direction == :buy ? "BUY" : strat.direction == :hold ? "HOLD" : "SELL"
            y = _t("$(label): $(dir)", y; sz=11, b=true, c=color)
            if strat.direction != :hold
                pos = round(strat.size_dollars, digits=0)
                best = round(strat.size_dollars * strat.take_profit_pct / 100, digits=2)
                worst = round(strat.size_dollars * strat.stop_loss_pct / 100, digits=2)
                avg = round(strat.size_dollars * strat.expected_return_pct / 100, digits=2)
                h = strat.hold_time_hours < 24 ? "$(round(Int, strat.hold_time_hours))h" :
                    "$(round(Int, strat.hold_time_hours / 24)) days"
                y = _t("Invest \$$(pos) for $(h). Best: +\$$(best). Worst: -\$$(worst). Average: \$$(avg)/trade.", y; sz=10, indent=15)
            else
                y = _t("Do not trade — models say wait for better conditions.", y; sz=10, indent=15)
            end
            y += 5
            y = _checkpage(y, 100)
        end
        y += 10

        # Scaling table
        y = _section("Profit Projections at Different Investment Levels", y)
        y = _wrap("These numbers scale linearly from the recommended strategy's take-profit and stop-loss targets.", y; sz=9, c=c_gray)
        y += 5
        _box(y, 16; c=c_navy)
        Luxor.sethue(c_white); Luxor.fontsize(9); Luxor.fontface("Helvetica-Bold")
        Luxor.text("You Invest", Luxor.Point(M+10, y+12))
        Luxor.text("Best Case", Luxor.Point(M+120, y+12))
        Luxor.text("Worst Case", Luxor.Point(M+230, y+12))
        Luxor.text("Expected Profit", Luxor.Point(M+350, y+12))
        y += 20
        for amount in [100, 250, 500, 1000, 2500, 5000, 10000]
            bg = isodd(div(amount, 100)) ? c_ltgray : c_white
            _box(y, 14; c=bg)
            tp_d = amount * tp.take_profit_pct / 100
            sl_d = amount * tp.stop_loss_pct / 100
            exp_d = amount * tp.expected_return_pct / 100
            Luxor.sethue(c_black); Luxor.fontsize(9); Luxor.fontface("Helvetica")
            Luxor.text("\$$(amount)", Luxor.Point(M+10, y+11))
            Luxor.sethue(c_green); Luxor.text("+\$$(round(tp_d, digits=0))", Luxor.Point(M+120, y+11))
            Luxor.sethue(c_red); Luxor.text("-\$$(round(sl_d, digits=0))", Luxor.Point(M+230, y+11))
            Luxor.sethue(exp_d >= 0 ? c_green : c_red); Luxor.fontface("Helvetica-Bold")
            Luxor.text("\$$(round(exp_d, digits=0))", Luxor.Point(M+350, y+11))
            y += 16
        end
    end

    # ═════════════════════════════════════════════════════════
    #  PAGE 3+: CHARTS WITH EXPLANATIONS
    # ═════════════════════════════════════════════════════════
    svg_files = filter(f -> endswith(f, ".svg"), chart_files)
    chart_explanations = Dict(
        "model_consensus" => "Model Consensus: Top-left shows each model's probability estimate (above 0.5 = bullish, below = bearish). Top-right shows the overall verdict. Bottom-left compares out-of-sample accuracy — models above 50% beat a coin flip. Bottom-right summarizes the most important metrics.",
        "price_returns" => "Price & Returns: Top-left shows price history. Top-right shows daily return distribution — wider = more volatile. Bottom-left tracks rolling volatility — spikes = higher risk. Bottom-right shows cumulative return — whether holding this asset made or lost money.",
        "ml_predictions" => "ML Prediction Quality: Top-left shows which features (price momentum, volatility, RSI) the Random Forest considers most important. Top-right compares the SGD online learner's strategy vs passive buy-and-hold. Bottom-left ranks model accuracy. Bottom-right shows how spread out model predictions are — tight clustering = consensus.",
        "volatility_options" => "Volatility & Options: Top-left compares three independent volatility estimators. Top-right shows GARCH conditional volatility tracking over time vs realized vol. Bottom-left displays the Black-Scholes Greeks (Delta, Gamma, Theta, Vega, Rho). Bottom-right compares analytical vs numerical option prices.",
        "rl_metalabeling" => "RL & Meta-Labeling: Top-left shows the reinforcement learning agent's cumulative profit/loss. Top-right shows how the agent distributed its actions (buy/sell/hold). Bottom-left tracks learning progress across training episodes. Bottom-right shows the meta-labeling decision — whether to trust the primary signal.",
        "regime_analysis" => "Statistical & Regime: Top-left tests whether the price follows a random walk (VR=1) at different horizons. Top-right shows triple-barrier outcomes (profit/stop-loss/expiry). Bottom-left visualizes return autocorrelation with the AR(1) regression line. Bottom-right shows how Bayesian updating shifted the probability estimate.",
        "information_theory" => "Information Theory: Top-left shows KL and Jensen-Shannon divergence — how different model predictions are from market base rates. Top-right compares Bregman-projected optimal weights vs market priors. Bottom-left checks model calibration — do predicted probabilities match reality? Bottom-right decomposes the expected value from market probability through model adjustment to after-fee EV.",
        "position_sizing" => "Position Sizing & Risk: Top-left shows the Kelly Criterion position size spectrum from aggressive (full Kelly) to conservative (quarter Kelly). Top-right shows Monte Carlo simulated profit vs ruin probability at each Kelly level. Bottom-left breaks down win rate and average win/loss magnitude. Bottom-right shows edge consistency and Sharpe ratio.",
        "term_microstructure" => "Term Structure & Microstructure: Top-left plots the Nelson-Siegel fitted yield curve — inverted (red) = recession warning, steepening (green) = growth signal. Top-right shows logistic regression coefficients revealing which microstructure features drive trade continuation vs reversal. Bottom-left shows post-shock price behavior. Bottom-right shows ensemble model weights.",
    )
    for svg_path in svg_files
        _newpage(); y = 50
        chart_name = replace(basename(svg_path), ".svg" => "", "$(tk)_" => "")
        display_name = replace(chart_name, "_" => " ") |> titlecase
        y = _section(display_name, y)
        # Add explanation
        for (key, explanation) in chart_explanations
            if occursin(key, chart_name)
                y = _wrap(explanation, y; sz=9, c=c_gray)
                y += 5
            end
        end
        _embed_chart(svg_path, y, COL_W, 550)
    end

    # ═════════════════════════════════════════════════════════
    #  MODEL RESULTS — Professional Table Layout
    # ═════════════════════════════════════════════════════════

    # Helper: draw a colored signal dot
    _dot(x, y_pos, color) = begin
        Luxor.sethue(color); Luxor.circle(Luxor.Point(x, y_pos-3), 4, action=:fill)
    end
    # Helper: probability bar (mini horizontal bar chart)
    _prob_bar(x, y_pos, prob, w=80) = begin
        Luxor.sethue(c_ltgray); Luxor.rect(Luxor.Point(x, y_pos-8), w, 8, action=:fill)
        bar_c = prob > 0.55 ? c_green : prob < 0.45 ? c_red : c_amber
        Luxor.sethue(bar_c); Luxor.rect(Luxor.Point(x, y_pos-8), w * clamp(prob, 0, 1), 8, action=:fill)
        # Midline at 0.5
        Luxor.sethue(c_black); Luxor.setline(0.5)
        Luxor.line(Luxor.Point(x + w*0.5, y_pos-9), Luxor.Point(x + w*0.5, y_pos+1), action=:stroke)
        Luxor.setline(1)
    end
    # Helper: draw a table row for a model
    _model_row(name, r, y_pos, row_idx) = begin
        bg = iseven(row_idx) ? c_ltgray : c_white
        _box(y_pos-10, 16; c=bg)

        dir_str = hasproperty(r, :direction) ? string(r.direction) : "N/A"
        has_prob = hasproperty(r, :probability) && !isnan(r.probability)
        prob = has_prob ? r.probability : NaN
        prob_str = has_prob ? @sprintf("%.1f%%", prob*100) : "N/A"
        acc_str = hasproperty(r, :accuracy) && !isnan(r.accuracy) ? @sprintf("%.0f%%", r.accuracy*100) : "N/A"

        # Signal dot
        dc = dir_str in ["UP", "BUY", "BET"] ? c_green :
             dir_str in ["DOWN", "SELL", "NO BET"] ? c_red : c_amber
        _dot(M+8, y_pos, dc)

        # Model name
        short = replace(name, r"^\d+\.\s*" => "")
        short = replace(short, r"\s*\(.*\)" => "")  # remove parenthetical
        short = length(short) > 28 ? short[1:28] * ".." : short
        Luxor.sethue(c_black); Luxor.fontsize(8); Luxor.fontface("Helvetica")
        Luxor.text(short, Luxor.Point(M+18, y_pos))

        # Signal text
        signal_str = dir_str in ["UP", "BUY"] ? "Bullish" :
                     dir_str in ["DOWN", "SELL"] ? "Bearish" :
                     dir_str == "BET" ? "Bet" :
                     dir_str == "NO BET" ? "No Bet" :
                     dir_str == "HOLD" ? "Neutral" :
                     occursin("MOMENTUM", dir_str) ? "Momentum" :
                     occursin("MEAN", dir_str) ? "Reversal" : "N/A"
        Luxor.sethue(dc); Luxor.fontface("Helvetica-Bold"); Luxor.fontsize(8)
        Luxor.text(signal_str, Luxor.Point(M+185, y_pos))

        # Probability bar
        if has_prob
            _prob_bar(M+250, y_pos, prob, 80)
            Luxor.sethue(c_black); Luxor.fontsize(7); Luxor.fontface("Helvetica")
            Luxor.text(prob_str, Luxor.Point(M+335, y_pos))
        else
            Luxor.sethue(c_gray); Luxor.fontsize(7); Luxor.fontface("Helvetica")
            Luxor.text("N/A", Luxor.Point(M+280, y_pos))
        end

        # Accuracy
        Luxor.sethue(c_black); Luxor.fontsize(8); Luxor.fontface("Helvetica")
        Luxor.text(acc_str, Luxor.Point(M+385, y_pos))

        # Quality verdict
        verdict = if !has_prob
            "Info only"
        elseif prob > 0.65
            "Strong Buy"
        elseif prob > 0.55
            "Lean Buy"
        elseif prob > 0.45
            "Neutral"
        elseif prob > 0.35
            "Lean Sell"
        else
            "Strong Sell"
        end
        vc = prob > 0.55 ? c_green : prob < 0.45 ? c_red : c_gray
        if !has_prob; vc = c_gray; end
        Luxor.sethue(vc); Luxor.fontsize(7); Luxor.fontface("Helvetica-Bold")
        Luxor.text(verdict, Luxor.Point(M+430, y_pos))

        return y_pos + 16
    end
    # Helper: draw table header
    _table_header(y_pos) = begin
        _box(y_pos-10, 16; c=c_navy)
        Luxor.sethue(c_white); Luxor.fontsize(8); Luxor.fontface("Helvetica-Bold")
        Luxor.text("Model", Luxor.Point(M+18, y_pos))
        Luxor.text("Signal", Luxor.Point(M+185, y_pos))
        Luxor.text("Probability", Luxor.Point(M+270, y_pos))
        Luxor.text("Accuracy", Luxor.Point(M+385, y_pos))
        Luxor.text("Verdict", Luxor.Point(M+430, y_pos))
        y_pos + 18
    end

    categories = [
        ("Deep Learning" =>
            "Neural networks trained on price sequences. These models detect complex non-linear patterns " *
            "that simpler models miss. When they agree on a direction, it is a strong signal.",
         ["LSTM", "GRU", "Helformer", "Conv-LSTM", "BiLSTM", "Temporal Fusion", "MLP"]),
        ("Machine Learning" =>
            "Tree-based and ensemble models that combine many weak predictions into a strong one. " *
            "XGBoost and LightGBM are typically the most reliable individual predictors.",
         ["Random Forest", "LightGBM", "XGBoost", "SGD", "Ensemble", "Logistic"]),
        ("Statistical & Volatility" =>
            "Classical models that analyze trends, volatility patterns, and optimal bet sizing. " *
            "GARCH forecasts risk, Kelly determines how much to invest, EV Gap measures if the trade is worth it.",
         ["GARCH", "AR(1)", "LMSR", "Kelly", "EV Gap"]),
        ("Derivatives & Rates" =>
            "Options pricing (Black-Scholes) and interest rate models. These detect whether volatility is " *
            "cheap or expensive and whether the rate environment favors this asset class.",
         ["Black-Scholes", "Crank-Nicolson", "Term Structure"]),
        ("Calibration & Bayesian" =>
            "These models measure how well-calibrated our predictions are and update beliefs as new evidence arrives. " *
            "They act as quality checks on the other models.",
         ["KL-Divergence", "Bregman", "Bayesian"]),
        ("Advanced ML" =>
            "Cutting-edge techniques from quantitative finance research. Meta-labeling decides whether to " *
            "trust the primary signal. Martingale detection tests if the market is predictable at all.",
         ["Martingale", "Meta-Label", "Fractional Diff", "Triple-Barrier"]),
        ("Reinforcement Learning" =>
            "An AI agent that learns optimal trading actions through simulated experience. " *
            "It discovers strategies that other models cannot express.",
         ["Reinforcement"]),
    ]

    _newpage(); y = 50
    y = _section("Model Results — How Each Model Voted", y)
    y = _wrap("Green = bullish (models predict price will rise). Red = bearish (predict decline). " *
              "Yellow = neutral (no strong signal). The probability bar shows how strongly each model leans.", y; sz=9, c=c_gray)
    y += 8

    row_idx = 0
    for (cat_info, keywords) in categories
        cat_name, cat_desc = cat_info
        y = _checkpage(y, 100)

        # Category header
        _box(y-5, 18; c=parse(Luxor.Colorant, "gray80"))
        y = _t(cat_name, y; sz=10, b=true, c=c_navy)
        y += 2

        # Category description
        y = _wrap(cat_desc, y; sz=8, c=c_gray, indent=5)
        y += 4

        # Table header
        y = _table_header(y)

        # Collect matching models
        cat_bullish = 0; cat_bearish = 0; cat_total = 0
        for (name, r) in sort(collect(ctx.results), by=x->x.first)
            r isa NamedTuple || continue
            matched = any(kw -> occursin(kw, name), keywords)
            matched || continue

            y = _checkpage(y, 25)
            if y < 70  # if we just did a page break, redraw header
                y = _table_header(y)
            end

            row_idx += 1
            y = _model_row(name, r, y, row_idx)

            # Track category consensus
            if hasproperty(r, :probability) && !isnan(r.probability)
                cat_total += 1
                r.probability > 0.55 && (cat_bullish += 1)
                r.probability < 0.45 && (cat_bearish += 1)
            end
        end

        # Category summary verdict
        if cat_total > 0
            y += 3
            cat_verdict = if cat_bullish > cat_bearish && cat_bullish > 0
                "Overall: $(cat_bullish)/$(cat_total) models bullish"
            elseif cat_bearish > cat_bullish && cat_bearish > 0
                "Overall: $(cat_bearish)/$(cat_total) models bearish"
            else
                "Overall: Mixed — no clear consensus"
            end
            vc = cat_bullish > cat_bearish ? c_green : cat_bearish > cat_bullish ? c_red : c_amber
            y = _t(cat_verdict, y; sz=9, b=true, c=vc, indent=10)
        end
        y += 10
    end

    # ═════════════════════════════════════════════════════════
    #  QUANTITATIVE MODEL DETAIL — Full mathematical output
    # ═════════════════════════════════════════════════════════
    _newpage(); y = 50
    y = _section("Quantitative Model Detail", y)
    y = _wrap("This section provides the full mathematical output from each model. " *
              "These are the raw numbers that drive the recommendation above. " *
              "Each subsection explains what the numbers mean and whether they are favorable or unfavorable.", y; sz=9, c=c_gray)
    y += 10

    # ── Helper: colored metric with good/bad indicator ──────
    _metric(label, value, y_pos; good=nothing, indent=15) = begin
        Luxor.sethue(c_gray); Luxor.fontsize(9); Luxor.fontface("Helvetica")
        Luxor.text(label, Luxor.Point(M+indent, y_pos))
        vc = c_black
        if good !== nothing
            vc = good ? c_green : c_red
            indicator = good ? "  [Good]" : "  [Caution]"
            Luxor.sethue(vc); Luxor.fontface("Helvetica-Bold")
            Luxor.text(value * indicator, Luxor.Point(M+220, y_pos))
        else
            Luxor.sethue(c_black); Luxor.fontface("Helvetica-Bold")
            Luxor.text(value, Luxor.Point(M+220, y_pos))
        end
        y_pos + 14
    end
    _model_title(name, y_pos) = begin
        y_pos = _checkpage(y_pos, 120)
        _box(y_pos-5, 18; c=parse(Luxor.Colorant, "gray85"))
        Luxor.sethue(c_navy); Luxor.fontsize(11); Luxor.fontface("Helvetica-Bold")
        Luxor.text(name, Luxor.Point(M+5, y_pos+8)); y_pos + 22
    end

    # ── 1. GARCH / EGARCH Volatility ──────────────────────
    for (name, r) in ctx.results
        r isa NamedTuple || continue
        if occursin("GARCH", name) && !occursin("LSTM", name) && hasproperty(r, :garch_α)
            y = _model_title("Volatility Model: EGARCH / GARCH Family", y)
            y = _wrap("GARCH models forecast future volatility — how much the price is expected to move. " *
                       "Higher volatility means higher risk but also higher potential reward. " *
                       "The leverage effect tells you if bad news moves prices more than good news.", y; sz=9, c=c_gray, indent=5)
            y += 5
            vol_pct = r.σ_annual_forecast * 100
            y = _metric("Volatility Forecast (annual):", @sprintf("%.1f%%", vol_pct), y; good=vol_pct < 35)
            y = _metric("GARCH Persistence (alpha+beta):", @sprintf("%.3f", r.persistence), y; good=r.persistence < 1.0)
            y = _metric("Leverage Effect:", r.leverage_effect ? "Yes — downside moves are amplified" : "No — symmetric response", y; good=!r.leverage_effect)
            y = _metric("Volume-Vol Correlation:", isnan(r.vol_correlation) ? "N/A" : @sprintf("%.2f", r.vol_correlation), y)
            y = _wrap("GARCH Parameters: omega=$(round(r.garch_ω, sigdigits=3)), alpha=$(round(r.garch_α, digits=3)), beta=$(round(r.garch_β, digits=3))", y; sz=8, c=c_gray, indent=15)
            y = _wrap("EGARCH Parameters: omega=$(round(r.egarch_ω, digits=3)), alpha=$(round(r.egarch_α, digits=3)), gamma=$(round(r.egarch_γ, digits=3)), beta=$(round(r.egarch_β, digits=3))", y; sz=8, c=c_gray, indent=15)
            y = _wrap("Interpretation: $(r.interpretation)", y; sz=9, indent=15)
            y += 12
        end
    end

    # ── 2. Black-Scholes Options Pricing ──────────────────
    for (name, r) in ctx.results
        r isa NamedTuple || continue
        if occursin("Black-Scholes", name) && hasproperty(r, :call_price)
            y = _checkpage(y, 200)
            y = _model_title("Options Pricing: Black-Scholes + Greeks", y)
            y = _wrap("Black-Scholes prices a theoretical option on this asset. The Greeks measure how sensitive " *
                       "the option price is to changes in price (Delta), volatility (Vega), and time (Theta). " *
                       "The volatility signal compares realized vol to expected vol — cheap vol suggests underpriced risk.", y; sz=9, c=c_gray, indent=5)
            y += 5
            y = _metric("ATM Call Price:", @sprintf("\$%.2f", r.call_price), y)
            y = _metric("ATM Put Price:", @sprintf("\$%.2f", r.put_price), y)
            y = _t("Greeks (sensitivities):", y; sz=10, b=true, indent=10)
            y = _metric("Delta (price sensitivity):", @sprintf("%.3f — a \$1 move changes option by \$%.3f", r.delta_call, r.delta_call), y)
            y = _metric("Gamma (acceleration):", @sprintf("%.4f", r.gamma), y)
            y = _metric("Theta (daily time decay):", @sprintf("\$%.3f lost per day", abs(r.theta_call)), y; good=false)
            y = _metric("Vega (vol sensitivity):", @sprintf("\$%.3f per 1%% vol change", r.vega), y)
            y = _metric("Rho (rate sensitivity):", @sprintf("\$%.3f per 1%% rate change", r.rho_call), y)
            y += 3
            y = _t("Volatility Analysis:", y; sz=10, b=true, indent=10)
            y = _metric("Historical Vol:", @sprintf("%.1f%%", r.sigma_hist*100), y)
            y = _metric("Parkinson Vol (high-low):", @sprintf("%.1f%%", r.sigma_parkinson*100), y)
            y = _metric("EWMA Vol (exponential):", @sprintf("%.1f%%", r.sigma_ewma*100), y)
            y = _metric("Best Estimate:", @sprintf("%.1f%%", r.sigma_best*100), y)
            fair = occursin("FAIR", r.vol_signal)
            y = _metric("Vol Signal:", r.vol_signal, y; good=fair ? nothing : occursin("RICH", r.vol_signal))
            y += 12
        end
    end

    # ── 3. Crank-Nicolson FD Pricer ───────────────────────
    for (name, r) in ctx.results
        r isa NamedTuple || continue
        if occursin("Crank-Nicolson", name) && hasproperty(r, :fd_price_call)
            y = _checkpage(y, 140)
            y = _model_title("PDE Pricing: Crank-Nicolson Finite Difference", y)
            y = _wrap("This model solves the Black-Scholes PDE numerically on a grid. It can price American options " *
                       "(which allow early exercise) — something the analytical formula cannot do. " *
                       "The BS error shows how accurately the numerical method matches the known analytical price.", y; sz=9, c=c_gray, indent=5)
            y += 5
            y = _metric("FD European Call:", @sprintf("\$%.2f", r.fd_price_call), y)
            y = _metric("FD European Put:", @sprintf("\$%.2f", r.fd_price_put), y)
            y = _metric("American Put:", @sprintf("\$%.2f", r.american_put), y)
            y = _metric("Early Exercise Premium:", @sprintf("\$%.3f", r.early_exercise_prem), y; good=r.early_exercise_prem > 0)
            y = _metric("BS Analytical Reference:", @sprintf("\$%.2f", r.bs_call_ref), y)
            y = _metric("FD vs BS Error:", @sprintf("%.4f%%", r.fd_vs_bs_error*100), y; good=r.grid_converged)
            y = _metric("Grid Converged:", r.grid_converged ? "Yes — results are reliable" : "No — increase grid resolution", y; good=r.grid_converged)
            y += 12
        end
    end

    # ── 4. Term Structure ─────────────────────────────────
    for (name, r) in ctx.results
        r isa NamedTuple || continue
        if occursin("Term Structure", name) && hasproperty(r, :ns_beta0)
            y = _checkpage(y, 160)
            y = _model_title("Interest Rates: Nelson-Siegel + Vasicek", y)
            y = _wrap("Nelson-Siegel fits the yield curve shape. A negative slope (beta1 < 0) means the curve is inverted — " *
                       "historically a recession warning. Vasicek models interest rate dynamics and prices bonds.", y; sz=9, c=c_gray, indent=5)
            y += 5
            y = _t("Nelson-Siegel Yield Curve:", y; sz=10, b=true, indent=10)
            y = _metric("Long-Rate Level (beta0):", @sprintf("%.4f (%.1f%%)", r.ns_beta0, r.ns_beta0*100), y)
            inverted = r.ns_beta1 < 0
            y = _metric("Slope (beta1):", @sprintf("%.4f", r.ns_beta1), y; good=!inverted)
            y = _metric("Curvature (beta2):", @sprintf("%.4f", r.ns_beta2), y)
            y = _metric("Rate Regime:", r.rate_regime, y; good=r.rate_regime == "STEEPENING")
            y += 3
            y = _t("Vasicek Short-Rate Model:", y; sz=10, b=true, indent=10)
            y = _metric("Mean-Reversion Speed (kappa):", @sprintf("%.2f", r.vasicek_kappa), y)
            y = _metric("Long-Run Mean Rate (theta):", @sprintf("%.1f%%", r.vasicek_theta*100), y)
            y = _metric("10-Year Bond Price:", @sprintf("\$%.4f per \$1 face", r.bond_10y_price), y)
            y = _metric("NS vs Vasicek RMSE:", @sprintf("%.4f", r.ns_vs_vasicek_err), y; good=r.ns_vs_vasicek_err < 0.01)
            y += 12
        end
    end

    # ── 5. Kelly Criterion ────────────────────────────────
    for (name, r) in ctx.results
        r isa NamedTuple || continue
        if occursin("Kelly", name) && hasproperty(r, :kelly_full)
            y = _checkpage(y, 200)
            y = _model_title("Position Sizing: Kelly Criterion", y)
            y = _wrap("Kelly Criterion calculates the mathematically optimal fraction of your bankroll to risk. " *
                       "Full Kelly maximizes long-term growth but is volatile. Half Kelly is recommended — " *
                       "it captures 75% of the growth with much less variance.", y; sz=9, c=c_gray, indent=5)
            y += 5
            y = _metric("Full Kelly:", @sprintf("%.1f%% of bankroll", r.kelly_full*100), y)
            y = _metric("3/4 Kelly:", @sprintf("%.1f%%", r.kelly_three_quarter*100), y)
            y = _metric("1/2 Kelly (recommended):", @sprintf("%.1f%%", r.kelly_half*100), y; good=r.kelly_half > 0.01)
            y = _metric("1/4 Kelly (conservative):", @sprintf("%.1f%%", r.kelly_quarter*100), y)
            y += 3
            y = _t("Edge Analysis:", y; sz=10, b=true, indent=10)
            y = _metric("Win Rate:", @sprintf("%.1f%%", r.win_rate), y; good=r.win_rate > 50)
            y = _metric("Average Win:", @sprintf("%.2f%%", r.avg_win), y)
            y = _metric("Average Loss:", @sprintf("%.2f%%", r.avg_loss), y)
            y = _metric("Edge Sharpe Ratio:", @sprintf("%.2f", r.edge_sharpe), y; good=r.edge_sharpe > 0.5)
            y = _metric("Edge Consistency:", @sprintf("%.0f%%", r.edge_consistency), y; good=r.edge_consistency > 65)
            y += 3
            y = _t("Monte Carlo Simulation:", y; sz=10, b=true, indent=10)
            y = _metric("P(Profit) at Full Kelly:", @sprintf("%.1f%%", r.prob_profit_full), y; good=r.prob_profit_full > 60)
            y = _metric("P(Profit) at Half Kelly:", @sprintf("%.1f%%", r.prob_profit_half), y; good=r.prob_profit_half > 60)
            y = _metric("P(Ruin) at Full Kelly:", @sprintf("%.1f%%", r.prob_ruin_full), y; good=r.prob_ruin_full < 5)
            y = _metric("Median Return (Half Kelly):", @sprintf("%.2f%%", r.median_return_half), y; good=r.median_return_half > 0)
            y += 12
        end
    end

    # ── 6. Martingale Detection ───────────────────────────
    for (name, r) in ctx.results
        r isa NamedTuple || continue
        if occursin("Martingale", name) && hasproperty(r, :vr2)
            y = _checkpage(y, 180)
            y = _model_title("Market Efficiency: Martingale Test", y)
            y = _wrap("Tests whether prices follow a random walk (unpredictable) or show exploitable patterns. " *
                       "Three statistical tests are combined. If the market IS predictable, our models have an edge. " *
                       "If it is a random walk, directional bets are less reliable.", y; sz=9, c=c_gray, indent=5)
            y += 5
            y = _t("Variance Ratio Test (Lo-MacKinlay):", y; sz=10, b=true, indent=10)
            y = _wrap("VR = 1.0 means random walk. VR > 1 = momentum. VR < 1 = mean reversion. |Z| > 1.96 = statistically significant.", y; sz=8, c=c_gray, indent=15)
            for (q, vr, z) in [(2, r.vr2, r.z_vr2), (5, r.vr5, r.z_vr5), (10, r.vr10, r.z_vr10), (20, r.vr20, r.z_vr20)]
                if !isnan(vr)
                    sig = abs(z) > 1.96 ? " [Significant]" : ""
                    y = _metric("VR($(q)):", @sprintf("%.3f  (Z=%.3f)%s", vr, z, sig), y; good=abs(z) > 1.96 ? true : nothing)
                end
            end
            y += 3
            y = _metric("Runs Test Z:", @sprintf("%.3f", r.runs_z), y; good=abs(r.runs_z) > 1.96 ? true : nothing)
            y = _metric("ADF Test (unit root):", @sprintf("t=%.3f", r.adf_t), y; good=r.adf_reject)
            y = _metric("Predictability Score:", @sprintf("%.0f%%", r.predictability*100), y; good=r.predictability > 0.5)
            y = _metric("Verdict:", r.regime, y; good=r.regime == "PREDICTABLE")
            y = _metric("Confidence Adjustment:", r.confidence_adj, y)
            y += 12
        end
    end

    # ── 7. AR(1) + Event Study ────────────────────────────
    for (name, r) in ctx.results
        r isa NamedTuple || continue
        if occursin("AR(1)", name) && hasproperty(r, :alpha)
            y = _checkpage(y, 160)
            y = _model_title("Trend Detection: AR(1) Autoregression", y)
            y = _wrap("AR(1) fits the simplest trend model: tomorrow's return = alpha + beta * today's return. " *
                       "If beta > 0 and significant, the market is trending (momentum). If beta < 0, it is mean-reverting.", y; sz=9, c=c_gray, indent=5)
            y += 5
            y = _metric("Alpha (drift):", @sprintf("%.6f", r.alpha), y)
            sig = abs(r.t_stat) > 1.96
            y = _metric("Beta (momentum coefficient):", @sprintf("%.4f (t=%.2f)", r.beta, r.t_stat), y; good=sig ? (r.beta > 0) : nothing)
            y = _metric("R-squared:", @sprintf("%.4f (%.2f%% of returns explained)", r.r_squared, r.r_squared*100), y)
            y = _metric("Regime:", r.regime, y)
            y = _metric("1-Step Forecast Return:", @sprintf("%.4f%%", r.forecast_return*100), y; good=r.forecast_return > 0)
            y = _metric("Post-Event Continuation:", @sprintf("%.0f%% (of %d large moves)", r.continuation_rate*100, r.event_study_n), y; good=r.continuation_rate > 0.55)
            y = _metric("Calibration Error:", isnan(r.calibration_error) ? "N/A" : @sprintf("%.3f", r.calibration_error), y; good=!isnan(r.calibration_error) && r.calibration_error < 0.05 ? true : !isnan(r.calibration_error) ? false : nothing)
            y += 12
        end
    end

    # ── 8. EV Gap ─────────────────────────────────────────
    for (name, r) in ctx.results
        r isa NamedTuple || continue
        if occursin("EV Gap", name) && hasproperty(r, :ev)
            y = _checkpage(y, 120)
            y = _model_title("Expected Value: EV Gap Analysis", y)
            y = _wrap("EV Gap measures whether the model's probability estimate exceeds the market's implied probability. " *
                       "Positive EV means the trade is worth taking (you have an edge). Negative EV means the market is right and you should not trade.", y; sz=9, c=c_gray, indent=5)
            y += 5
            y = _metric("Model's P(up):", @sprintf("%.3f (%.1f%%)", r.p_true, r.p_true*100), y)
            y = _metric("Market's implied P(up):", @sprintf("%.3f (%.1f%%)", r.p_market, r.p_market*100), y)
            y = _metric("Raw EV:", @sprintf("%.1f%%", r.ev*100), y; good=r.ev > 0)
            y = _metric("EV After Fees:", @sprintf("%.1f%%", r.ev_after_fees*100), y; good=r.ev_after_fees > 0)
            y = _metric("Trade Signal:", r.trade_signal, y; good=occursin("BUY", r.trade_signal))
            y = _metric("Models Used:", "$(r.n_models_used)", y)
            y += 12
        end
    end

    # ── 9. Bayesian Update ────────────────────────────────
    for (name, r) in ctx.results
        r isa NamedTuple || continue
        if occursin("Bayesian", name) && hasproperty(r, :posterior)
            y = _checkpage(y, 100)
            y = _model_title("Bayesian Probability Update", y)
            y = _wrap("Starts with a prior probability (base rate) and updates it with evidence from momentum and " *
                       "volatility signals. The posterior is the final probability estimate after all evidence is considered.", y; sz=9, c=c_gray, indent=5)
            y += 5
            y = _metric("Prior P(up):", @sprintf("%.3f (%.1f%%)", r.prior, r.prior*100), y)
            shifted = r.posterior > r.prior ? "Shifted UP" : r.posterior < r.prior ? "Shifted DOWN" : "Unchanged"
            y = _metric("Posterior P(up):", @sprintf("%.3f (%.1f%%) — %s", r.posterior, r.posterior*100, shifted), y; good=r.posterior > 0.55)
            y = _metric("Momentum Signal:", r.momentum_signal ? "Active" : "Inactive", y)
            y = _metric("Elevated Volatility:", r.vol_elevated ? "Yes" : "No", y)
            y += 12
        end
    end

    # ── 10. KL Divergence ─────────────────────────────────
    for (name, r) in ctx.results
        r isa NamedTuple || continue
        if occursin("KL-Divergence", name) && hasproperty(r, :kl_divergence)
            y = _checkpage(y, 100)
            y = _model_title("Model Calibration: KL & JS Divergence", y)
            y = _wrap("KL Divergence measures how different the model's probability distribution is from the market's. " *
                       "Low divergence = model agrees with market. High divergence = model sees something the market doesn't (or is wrong).", y; sz=9, c=c_gray, indent=5)
            y += 5
            y = _metric("KL Divergence:", @sprintf("%.4f", r.kl_divergence), y; good=r.kl_divergence < 0.05)
            y = _metric("Reverse KL:", @sprintf("%.4f", r.kl_reverse), y)
            y = _metric("JS Divergence:", @sprintf("%.4f", r.js_divergence), y; good=r.js_divergence < 0.02)
            y = _metric("Hedge Signal:", r.hedge_signal, y)
            y += 12
        end
    end

    # ── 11. Meta-Labeling ─────────────────────────────────
    for (name, r) in ctx.results
        r isa NamedTuple || continue
        if occursin("Meta-Label", name) && hasproperty(r, :bet_size)
            y = _checkpage(y, 100)
            y = _model_title("Meta-Labeling (Lopez de Prado)", y)
            y = _wrap("Meta-labeling asks: 'Should we trust the primary model's direction call?' " *
                       "A bet size of 1.0 = full confidence. A bet size near 0 = skip this trade. " *
                       "It learns from triple-barrier outcomes whether direction signals were historically profitable.", y; sz=9, c=c_gray, indent=5)
            y += 5
            y = _metric("Primary Model Direction:", r.primary_direction, y; good=r.primary_direction in ["UP", "BUY"])
            y = _metric("Primary Probability:", @sprintf("%.3f", r.primary_probability), y)
            y = _metric("Bet Size (meta confidence):", @sprintf("%.1f%%", r.bet_size*100), y; good=r.bet_size > 0.5)
            y = _metric("Meta-Model Accuracy:", @sprintf("%.1f%%", r.meta_accuracy*100), y; good=r.meta_accuracy > 0.5)
            y = _metric("Decision:", r.direction, y; good=r.direction == "BET")
            y += 12
        end
    end

    # ── 12. Triple-Barrier ────────────────────────────────
    for (name, r) in ctx.results
        r isa NamedTuple || continue
        if occursin("Triple-Barrier", name) && hasproperty(r, :upper_hit_rate)
            y = _checkpage(y, 120)
            y = _model_title("Market Regime: Triple-Barrier Analysis", y)
            y = _wrap("For each historical period, we simulate forward with take-profit and stop-loss barriers. " *
                       "Upper hit = price went up enough. Lower hit = price dropped. Expiry = no big move. " *
                       "High upper-hit rate = trending bullish. High expiry = mean-reverting.", y; sz=9, c=c_gray, indent=5)
            y += 5
            y = _metric("Upper Barrier Hit Rate:", @sprintf("%.0f%%", r.upper_hit_rate*100), y; good=r.upper_hit_rate > 0.4)
            y = _metric("Lower Barrier Hit Rate:", @sprintf("%.0f%%", r.lower_hit_rate*100), y; good=r.lower_hit_rate < 0.3)
            y = _metric("Vertical Expiry Rate:", @sprintf("%.0f%%", r.expiry_rate*100), y)
            y = _metric("Avg Barrier Width:", @sprintf("%.2f%%", r.avg_barrier_width*100), y)
            y = _metric("Market Regime:", r.regime, y; good=occursin("BULLISH", r.regime))
            y += 12
        end
    end

    # ── 13. Fractional Differentiation ────────────────────
    for (name, r) in ctx.results
        r isa NamedTuple || continue
        if occursin("Fractional Diff", name) && hasproperty(r, :d_optimal)
            y = _checkpage(y, 100)
            y = _model_title("Stationarity: Fractional Differentiation", y)
            y = _wrap("Standard differencing (d=1) makes prices stationary but destroys long-range memory. " *
                       "Fractional differentiation uses the minimum d that achieves stationarity while preserving as much " *
                       "memory as possible. Lower d = more memory preserved = better for prediction.", y; sz=9, c=c_gray, indent=5)
            y += 5
            y = _metric("Optimal d:", @sprintf("%.2f", r.d_optimal), y; good=r.d_optimal < 0.7)
            y = _metric("Memory Preserved:", @sprintf("%.0f%%", r.memory_preserved*100), y; good=r.memory_preserved > 0.3)
            y = _metric("ADF Statistic:", @sprintf("%.3f", r.adf_stat), y)
            y = _metric("Is Stationary:", r.is_stationary ? "Yes" : "No", y; good=r.is_stationary)
            y += 12
        end
    end

    # ── 14. Reinforcement Learning ────────────────────────
    for (name, r) in ctx.results
        r isa NamedTuple || continue
        if occursin("Reinforcement", name) && hasproperty(r, :sharpe)
            y = _checkpage(y, 100)
            y = _model_title("Reinforcement Learning: Double DQN", y)
            y = _wrap("A Q-learning agent that discovers trading strategies through simulated experience. " *
                       "It learns which actions (buy/sell/hold) maximize cumulative returns. " *
                       "A high Sharpe ratio means the agent found a risk-adjusted profitable strategy.", y; sz=9, c=c_gray, indent=5)
            y += 5
            y = _metric("Recommended Action:", string(r.action), y)
            y = _metric("Annualized Return:", @sprintf("%.1f%%", r.annual_return), y; good=r.annual_return > 10)
            y = _metric("Sharpe Ratio:", @sprintf("%.2f", r.sharpe), y; good=r.sharpe > 1.0)
            y = _metric("State Space Size:", "$(r.n_states) states", y)
            y += 12
        end
    end

    # ── 15. Ensemble Stacking ─────────────────────────────
    for (name, r) in ctx.results
        r isa NamedTuple || continue
        if occursin("Ensemble", name) && hasproperty(r, :model_weights)
            y = _checkpage(y, 100)
            y = _model_title("Ensemble: Model Stacking", y)
            y = _wrap("Combines predictions from multiple models using learned weights. " *
                       "Models that were historically more accurate get higher weights. " *
                       "High confidence means the underlying models strongly agree.", y; sz=9, c=c_gray, indent=5)
            y += 5
            y = _metric("Ensemble Direction:", string(r.direction), y; good=r.direction in ["UP", "BUY"])
            y = _metric("Ensemble Probability:", @sprintf("%.3f (%.1f%%)", r.probability, r.probability*100), y; good=abs(r.probability - 0.5) > 0.05)
            y = _metric("Number of Models:", "$(r.n_models)", y)
            y = _metric("High Confidence:", r.is_high_confidence ? "Yes" : "No", y; good=r.is_high_confidence)
            if r.model_weights isa Dict
                y = _t("Model Weights:", y; sz=9, b=true, indent=15)
                for (mname, mw) in sort(collect(r.model_weights), by=x->-x.second)
                    y = _checkpage(y, 15)
                    bar_w = round(Int, mw * 200)
                    Luxor.sethue(c_blue); Luxor.rect(Luxor.Point(M+25, y-8), bar_w, 8, action=:fill)
                    Luxor.sethue(c_black); Luxor.fontsize(8); Luxor.fontface("Helvetica")
                    Luxor.text("$(mname): $(@sprintf("%.0f%%", mw*100))", Luxor.Point(M+230, y)); y += 13
                end
            end
            y += 12
        end
    end

    # ── 16. Calibration Check ─────────────────────────────
    for (name, r) in ctx.results
        r isa NamedTuple || continue
        if occursin("Calibration", name) && hasproperty(r, :calibration_gap)
            y = _checkpage(y, 80)
            y = _model_title("Model Quality: Calibration Check", y)
            y = _wrap("Checks if models that predict 70% actually win 70% of the time. " *
                       "A small calibration gap means our probability estimates are trustworthy.", y; sz=9, c=c_gray, indent=5)
            y += 5
            y = _metric("Avg Model Probability:", @sprintf("%.3f", r.avg_model_prob), y)
            y = _metric("Actual Up Rate:", @sprintf("%.3f (%.1f%%)", r.actual_up_rate, r.actual_up_rate*100), y)
            y = _metric("Calibration Gap:", @sprintf("%.3f (%.1f%%)", r.calibration_gap, abs(r.calibration_gap)*100), y; good=abs(r.calibration_gap) < 0.05)
            y = _metric("Is Well-Calibrated:", r.is_calibrated ? "Yes — probabilities are trustworthy" : "No — probabilities may be unreliable", y; good=r.is_calibrated)
            y += 12
        end
    end

    # ═════════════════════════════════════════════════════════
    #  RISK ASSESSMENT
    # ═════════════════════════════════════════════════════════
    _newpage(); y = 50
    y = _section("Risk Assessment", y)
    y = _wrap("Understanding the risk is just as important as the potential reward. " *
              "Here is what the models say about the risk environment:", y; sz=10)
    y += 8

    # Volatility
    for (name, r) in ctx.results
        r isa NamedTuple || continue
        if occursin("GARCH", name) && !occursin("LSTM", name) && hasproperty(r, :σ_annual_forecast)
            y = _t("Volatility (GARCH Forecast)", y; sz=11, b=true, c=c_navy)
            vol_pct = round(r.σ_annual_forecast * 100, digits=1)
            vol_interp = vol_pct > 40 ? "Very High — expect large daily swings. Higher risk." :
                         vol_pct > 25 ? "Elevated — above-average price movement expected." :
                         vol_pct > 15 ? "Normal — typical market conditions." :
                         "Low — unusually calm market. Could precede a move."
            y = _kv("Annual Volatility:", "$(vol_pct)%", y; vc=vol_pct > 30 ? c_red : c_black)
            y = _wrap("Interpretation: $(vol_interp)", y; sz=9, c=c_gray, indent=10)
            if hasproperty(r, :leverage_effect)
                lev = r.leverage_effect ? "Yes — bad news moves prices more than good news." :
                                          "No — price reacts similarly to good and bad news."
                y = _kv("Leverage Effect:", lev, y)
            end
            y += 8
        end
        if occursin("Black-Scholes", name) && hasproperty(r, :vol_signal)
            y = _t("Volatility Assessment (Black-Scholes)", y; sz=11, b=true, c=c_navy)
            y = _kv("Vol Signal:", r.vol_signal, y; vc=occursin("CHEAP", r.vol_signal) ? c_red : occursin("RICH", r.vol_signal) ? c_green : c_black)
            y += 5
        end
        if occursin("Martingale", name) && hasproperty(r, :regime)
            y = _checkpage(y, 80)
            y = _t("Market Predictability (Martingale Test)", y; sz=11, b=true, c=c_navy)
            mart_interp = r.regime == "PREDICTABLE" ?
                "The price series shows statistical patterns — models may have an edge." :
                r.regime == "MARTINGALE" ?
                "The price series behaves like a random walk — limited predictability. Trade with caution." :
                "Borderline — some patterns exist but they are weak."
            y = _kv("Regime:", r.regime, y)
            y = _wrap("Interpretation: $(mart_interp)", y; sz=9, c=c_gray, indent=10)
            y += 5
        end
        if occursin("Term Structure", name) && hasproperty(r, :rate_regime)
            y = _checkpage(y, 80)
            y = _t("Interest Rate Environment", y; sz=11, b=true, c=c_navy)
            rate_interp = r.rate_regime == "INVERTED CURVE" ?
                "The yield curve is inverted — historically this precedes economic slowdowns. Be cautious with equities." :
                r.rate_regime == "STEEPENING" ?
                "The yield curve is steepening — typically a bullish sign for economic growth and equities." :
                r.rate_regime == "FLATTENING" ?
                "The yield curve is flattening — late-cycle signal. Be selective." :
                "Normal yield curve — no strong rate-driven signal."
            y = _kv("Rate Regime:", r.rate_regime, y)
            y = _wrap("Interpretation: $(rate_interp)", y; sz=9, c=c_gray, indent=10)
            y += 5
        end
        if occursin("Kelly", name) && hasproperty(r, :kelly_half)
            y = _checkpage(y, 80)
            y = _t("Position Sizing (Kelly Criterion)", y; sz=11, b=true, c=c_navy)
            kelly_interp = "The Kelly Criterion calculates the optimal bet size to maximize long-term growth. " *
                "Using half-Kelly ($(@sprintf("%.1f%%", r.kelly_half*100))) is recommended to reduce volatility."
            y = _kv("Full Kelly:", @sprintf("%.1f%%", r.kelly_full*100), y)
            y = _kv("Half Kelly (recommended):", @sprintf("%.1f%%", r.kelly_half*100), y; vc=c_navy)
            hasproperty(r, :win_rate) && (y = _kv("Historical Win Rate:", @sprintf("%.1f%%", r.win_rate*100), y))
            y = _wrap(kelly_interp, y; sz=9, c=c_gray, indent=10)
            y += 5
        end
        y = _checkpage(y, 60)
    end

    # ═════════════════════════════════════════════════════════
    #  DISCLAIMER
    # ═════════════════════════════════════════════════════════
    y = _checkpage(y, 100)
    y += 10
    _box(y, 55; c=c_ltgray); y += 10
    Luxor.sethue(c_gray); Luxor.fontsize(7); Luxor.fontface("Helvetica")
    Luxor.text("DISCLAIMER: This report is generated by an automated quantitative analysis engine for educational and research purposes only.", Luxor.Point(M+5, y)); y += 10
    Luxor.text("It is NOT financial advice. Past performance does not guarantee future results. All trading involves risk of loss.", Luxor.Point(M+5, y)); y += 10
    Luxor.text("Consult a licensed financial advisor before making investment decisions. Use at your own risk.", Luxor.Point(M+5, y)); y += 10
    Luxor.text("Generated by QuantEngine (30 Models) — $(Dates.format(Dates.now(), "yyyy-mm-dd HH:MM"))", Luxor.Point(M+5, y))

    Luxor.finish()
    println("  PDF generated: $(basename(pdf_path))")
    return pdf_path
end
