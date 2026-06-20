# ── Input Validation Tests ────────────────────────────────────

@testset "validate_ticker" begin
    # Valid tickers
    @test validate_ticker("AAPL") == "AAPL"
    @test validate_ticker("BTC-USD") == "BTC-USD"
    @test validate_ticker("poly:will-trump-win") == "poly:will-trump-win"
    @test validate_ticker("SPY") == "SPY"
    @test validate_ticker("ETH-USD") == "ETH-USD"
    @test validate_ticker("MSFT.L") == "MSFT.L"

    # Whitespace stripping
    @test validate_ticker("  AAPL  ") == "AAPL"

    # Invalid tickers — injection attempts
    @test_throws ErrorException validate_ticker("AAPL; rm -rf /")
    @test_throws ErrorException validate_ticker("AAPL&action=delete")
    @test_throws ErrorException validate_ticker("AAPL%20DROP")
    @test_throws ErrorException validate_ticker("AAPL\nmalicious")
    @test_throws ErrorException validate_ticker("<script>alert(1)</script>")

    # Empty and too long
    @test_throws ErrorException validate_ticker("")
    @test_throws ErrorException validate_ticker("   ")
    @test_throws ErrorException validate_ticker("A" ^ 51)
end

@testset "ExecutionMode" begin
    @test PAPER isa ExecutionMode
    @test LIVE isa ExecutionMode
    @test PAPER != LIVE
end
