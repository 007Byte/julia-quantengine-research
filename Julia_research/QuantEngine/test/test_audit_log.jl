# ── Audit Logger Tests ────────────────────────────────────────

@testset "AuditLogger creation" begin
    dir = mktempdir()
    logger = AuditLogger(dir)

    @test isfile(logger.filepath)
    @test logger.max_file_bytes == 50_000_000
    @test logger.write_count == 0
end

@testset "audit_log! writes valid JSON Lines" begin
    dir = mktempdir()
    logger = AuditLogger(dir)

    audit_log!(logger, "AAPL", :trigger, 1, "Volume spike detected")
    audit_log!(logger, "AAPL", :step_pass, 3, Dict("p_refined" => 0.65))
    audit_log!(logger, "BTC-USD", :skip, 7, "EV too low")

    lines = readlines(logger.filepath)
    @test length(lines) == 3

    # Each line should be valid JSON
    for line in lines
        parsed = JSON.parse(line)
        @test haskey(parsed, "timestamp")
        @test haskey(parsed, "event_id")
        @test haskey(parsed, "asset")
        @test haskey(parsed, "action")
        @test haskey(parsed, "step")
        @test haskey(parsed, "details")
    end
end

@testset "audit_log! with NamedTuple details" begin
    dir = mktempdir()
    logger = AuditLogger(dir)

    audit_log!(logger, "AAPL", :step_pass, 5, (probability=0.65, accuracy=0.58))

    lines = readlines(logger.filepath)
    parsed = JSON.parse(lines[1])
    @test haskey(parsed["details"], "probability")
    @test haskey(parsed["details"], "accuracy")
end

@testset "_safe_value handles edge cases" begin
    @test _safe_value(42.0) == "42.0"
    @test _safe_value(NaN) == "NaN"
    @test _safe_value(Inf) == "Inf"

    # Large vectors are summarized
    big_vec = collect(1.0:100.0)
    result = _safe_value(big_vec)
    @test occursin("100 elements", result)

    # Small vectors pass through
    small_vec = [1.0, 2.0, 3.0]
    @test _safe_value(small_vec) == small_vec

    # Dicts pass through
    d = Dict("a" => 1)
    @test _safe_value(d) == d
end

@testset "AuditLogger date rotation" begin
    dir = mktempdir()
    logger = AuditLogger(dir)

    today_str = Dates.format(Dates.today(), "yyyy-mm-dd")
    @test occursin(today_str, logger.filepath)
end
