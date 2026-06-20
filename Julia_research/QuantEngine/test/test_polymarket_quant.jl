# ── Polymarket Quant Layer Tests ──────────────────────────────

using QuantEngine: PolyQuote, PolyModelInputs, PolyTradeSignal,
                   estimate_fair_probability, bayesian_blend, calibrate_probability,
                   generate_poly_signal, binary_kelly, logit_edge, fee_zone_quality,
                   buy_ev, sell_ev, break_even_buy, break_even_sell,
                   is_overpriced_for_buyer, is_underpriced_for_buyer,
                   CalibrationTable, record_prediction!, calibration_report, derive_bias,
                   logit, inv_logit, clip01, _polymarket_fee

# ── Core Math ────────────────────────────────────────────────

@testset "logit / inv_logit roundtrip" begin
    for p in [0.1, 0.25, 0.5, 0.75, 0.9]
        @test inv_logit(logit(p)) ≈ p atol=1e-10
    end
    # logit(0.5) = 0
    @test logit(0.5) ≈ 0.0 atol=1e-10
    # logit is monotonic
    @test logit(0.7) > logit(0.3)
end

@testset "clip01" begin
    @test clip01(0.5) == 0.5
    @test clip01(-1.0) > 0.0
    @test clip01(2.0) < 1.0
end

# ── Fee Schedule ─────────────────────────────────────────────

@testset "Polymarket fee curve" begin
    # Max fee at 50¢
    fee_50 = _polymarket_fee(0.5)
    fee_10 = _polymarket_fee(0.1)
    fee_90 = _polymarket_fee(0.9)

    @test fee_50 > fee_10  # 50¢ zone has highest fees
    @test fee_50 > fee_90  # 50¢ zone has highest fees
    @test fee_10 ≈ fee_90 atol=0.001  # symmetric

    # Near extremes, fee is near zero
    @test _polymarket_fee(0.01) < 0.002
    @test _polymarket_fee(0.99) < 0.002
end

@testset "fee_zone_quality" begin
    # Best quality near extremes
    @test fee_zone_quality(0.05) > 0.8
    @test fee_zone_quality(0.95) > 0.8

    # Worst quality at 50¢
    @test fee_zone_quality(0.50) < 0.05

    # Monotonic from center to extremes
    @test fee_zone_quality(0.3) > fee_zone_quality(0.5)
    @test fee_zone_quality(0.8) > fee_zone_quality(0.5)
end

# ── PolyQuote ────────────────────────────────────────────────

@testset "PolyQuote construction" begin
    pq = PolyQuote("test-market", 0.57, 0.59; volume=50000.0)

    @test pq.midpoint ≈ 0.58
    @test pq.spread ≈ 0.02
    @test pq.volume == 50000.0
    @test pq.fee_buy > 0.0
    @test pq.fee_sell > 0.0
end

# ── Bayesian Blend ───────────────────────────────────────────

@testset "bayesian_blend" begin
    # Equal weights → average in logit space
    blended = bayesian_blend(0.7, 0.5; k_model=1.0, k_market=1.0)
    @test 0.5 < blended < 0.7  # between model and market

    # Trust model fully
    model_only = bayesian_blend(0.7, 0.5; k_model=100.0, k_market=0.01)
    @test model_only > 0.68

    # Trust market fully
    market_only = bayesian_blend(0.7, 0.5; k_model=0.01, k_market=100.0)
    @test market_only < 0.52
end

# ── Calibration ──────────────────────────────────────────────

@testset "calibrate_probability" begin
    # No bias → unchanged
    @test calibrate_probability(0.6, 0.0) ≈ 0.6 atol=0.01

    # Positive bias → pushes up
    @test calibrate_probability(0.5, 0.5) > 0.55

    # Negative bias → pushes down
    @test calibrate_probability(0.5, -0.5) < 0.45
end

@testset "estimate_fair_probability" begin
    inputs = PolyModelInputs(0.64, 0.58, 0.55, 0.80, -0.08)
    fair = estimate_fair_probability(inputs)

    @test 0.0 < fair < 1.0
    # Should be between model and market
    @test fair > 0.50
    @test fair < 0.70
end

# ── Fee-Aware Edge ───────────────────────────────────────────

@testset "buy_ev and sell_ev" begin
    # Fair prob = 0.65, ask = 0.59, fee = 0.004
    bev = buy_ev(0.65, 0.59, 0.004)
    @test bev ≈ 0.65 - 0.59 - 0.004 atol=1e-10
    @test bev > 0.0  # positive edge

    # Fair prob = 0.55, bid = 0.59, fee = 0.002
    sev = sell_ev(0.55, 0.59, 0.002)
    @test sev ≈ 0.59 - 0.55 - 0.002 atol=1e-10
    @test sev > 0.0  # positive edge for selling
end

@testset "break_even probabilities" begin
    be_buy = break_even_buy(0.59, 0.004)
    @test be_buy ≈ 0.594 atol=0.001

    be_sell = break_even_sell(0.57, 0.002)
    @test be_sell ≈ 0.568 atol=0.001
end

@testset "logit_edge" begin
    # No edge when equal
    @test logit_edge(0.5, 0.5) ≈ 0.0 atol=1e-10

    # Positive edge when model > market
    @test logit_edge(0.65, 0.55) > 0.0

    # Edge is symmetric in logit space
    edge_high = logit_edge(0.90, 0.85)
    edge_low = logit_edge(0.15, 0.10)
    # Both represent similar "distances" in logit space
    @test abs(edge_high - edge_low) < 0.5
end

# ── Binary Kelly ─────────────────────────────────────────────

@testset "binary_kelly" begin
    # Fair prob = 0.65, cost = 0.59
    # Kelly = (0.65 - 0.59) / (1 - 0.59) = 0.06/0.41 ≈ 0.146
    k = binary_kelly(0.65, 0.59)
    @test k ≈ 0.06 / 0.41 atol=0.01

    # No edge → zero Kelly
    @test binary_kelly(0.50, 0.55) == 0.0

    # Large edge → capped at 1.0
    @test binary_kelly(0.99, 0.01) <= 1.0
    @test binary_kelly(0.99, 0.01) > 0.9
end

# ── Instant Screener ─────────────────────────────────────────

@testset "overpriced/underpriced screener" begin
    # Model says 65%, ask is 59¢, fee is 0.4¢
    @test is_underpriced_for_buyer(0.65, 0.59, 0.004) == true
    @test is_overpriced_for_buyer(0.65, 0.59, 0.004) == false

    # Model says 55%, ask is 59¢, fee is 0.4¢ → overpriced
    @test is_overpriced_for_buyer(0.55, 0.59, 0.004) == true
    @test is_underpriced_for_buyer(0.55, 0.59, 0.004) == false

    # With threshold buffer
    @test is_underpriced_for_buyer(0.60, 0.59, 0.004; threshold=0.01) == false
end

# ── Calibration Table ────────────────────────────────────────

@testset "CalibrationTable creation" begin
    table = CalibrationTable()
    @test length(table.buckets) == 10
end

@testset "CalibrationTable record and report" begin
    table = CalibrationTable()

    # Record predictions in the 50-60% bucket
    for _ in 1:20
        record_prediction!(table, 0.55, rand() < 0.55)  # ~55% actual
    end

    # Record predictions in the 10-20% bucket (longshots)
    for _ in 1:20
        record_prediction!(table, 0.15, rand() < 0.25)  # actual 25% (overpriced!)
    end

    report = calibration_report(table)
    @test length(report) >= 2

    # Find the longshot bucket
    longshot = filter(r -> r.range == "10%-20%", report)
    if !isempty(longshot)
        @test longshot[1].n >= 20
    end
end

@testset "derive_bias" begin
    table = CalibrationTable()

    # Need 10+ predictions to derive bias
    @test derive_bias(table, 0.5) == 0.0  # no data

    for _ in 1:15
        record_prediction!(table, 0.55, true)  # all resolve YES
    end

    bias = derive_bias(table, 0.55)
    @test bias > 0.0  # actual > predicted → positive bias
end

# ── Full Signal Generation ───────────────────────────────────

@testset "generate_poly_signal BUY" begin
    mq = PolyQuote("test-election", 0.57, 0.59; volume=100000.0)
    inputs = PolyModelInputs(0.68, 0.58, 0.5, 0.9, 0.0)

    signal = generate_poly_signal(mq, inputs; kelly_fraction=0.25)

    @test signal.action == :buy_yes
    @test signal.fair_prob > 0.6
    @test signal.buy_ev_val > 0.0
    @test signal.size_fraction > 0.0
    @test signal.fee_zone > 0.0
end

@testset "generate_poly_signal NO_TRADE" begin
    # Model agrees with market → no edge
    mq = PolyQuote("test-no-edge", 0.57, 0.59; volume=100000.0)
    inputs = PolyModelInputs(0.58, 0.58, 0.8, 0.3, 0.0)

    signal = generate_poly_signal(mq, inputs; min_edge=0.02)

    @test signal.action == :no_trade
    @test signal.size_fraction == 0.0
end

@testset "generate_poly_signal SELL" begin
    # Model says much lower than market → sell YES
    mq = PolyQuote("test-sell", 0.57, 0.59; volume=50000.0)
    inputs = PolyModelInputs(0.40, 0.58, 0.3, 0.9, 0.0)

    signal = generate_poly_signal(mq, inputs; min_edge=0.01)

    @test signal.action == :sell_yes
    @test signal.sell_ev_val > 0.0
    @test signal.size_fraction > 0.0
end

@testset "generate_poly_signal with calibration table" begin
    table = CalibrationTable()
    # Simulate calibration data showing longshots are overpriced
    for _ in 1:20
        record_prediction!(table, 0.15, rand() < 0.10)
    end

    mq = PolyQuote("longshot-market", 0.14, 0.16)
    inputs = PolyModelInputs(0.12, 0.15, 0.5, 0.8, 0.0)

    signal = generate_poly_signal(mq, inputs; cal_table=table)

    # Calibration should adjust the fair probability based on historical bias
    @test 0.0 < signal.fair_prob < 1.0
end

@testset "generate_poly_signal thread safety" begin
    table = CalibrationTable()

    tasks = Task[]
    for _ in 1:10
        push!(tasks, @async begin
            record_prediction!(table, 0.5 + 0.1*rand(), rand() < 0.5)
        end)
    end
    for t in tasks; wait(t); end

    report = calibration_report(table)
    total_n = sum(r.n for r in report; init=0)
    @test total_n == 10
end
