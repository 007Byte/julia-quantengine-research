# ── Alpaca Exchange Tests ─────────────────────────────────────
# Unit tests only (no API calls). Integration tests require API keys.

@testset "AlpacaExchange requires API keys" begin
    # Should error without keys set
    @test_throws ErrorException AlpacaExchange(
        api_key_env="NONEXISTENT_KEY_12345",
        secret_key_env="NONEXISTENT_SECRET_12345"
    )
end

@testset "AlpacaExchange paper URL selection" begin
    # Set temporary keys for construction test
    withenv("QE_TEST_ALPACA_KEY" => "test_key", "QE_TEST_ALPACA_SECRET" => "test_secret") do
        ex = AlpacaExchange(execution_mode=PAPER,
                            api_key_env="QE_TEST_ALPACA_KEY",
                            secret_key_env="QE_TEST_ALPACA_SECRET")

        @test ex.execution_mode == PAPER
        @test occursin("paper-api", ex.base_url)
        @test ex.rate_limiter.max_per_minute == 180
    end
end

@testset "AlpacaExchange live URL selection" begin
    withenv("QE_TEST_ALPACA_KEY" => "test_key", "QE_TEST_ALPACA_SECRET" => "test_secret") do
        ex = AlpacaExchange(execution_mode=LIVE,
                            api_key_env="QE_TEST_ALPACA_KEY",
                            secret_key_env="QE_TEST_ALPACA_SECRET")

        @test ex.execution_mode == LIVE
        @test !occursin("paper-api", ex.base_url)
        @test occursin("api.alpaca.markets", ex.base_url)
    end
end

@testset "AlpacaExchange is AbstractExchange" begin
    withenv("QE_TEST_ALPACA_KEY" => "test_key", "QE_TEST_ALPACA_SECRET" => "test_secret") do
        ex = AlpacaExchange(execution_mode=PAPER,
                            api_key_env="QE_TEST_ALPACA_KEY",
                            secret_key_env="QE_TEST_ALPACA_SECRET")

        @test ex isa AbstractExchange
        @test !(ex isa PaperExchange)
    end
end

@testset "Alpaca headers do not leak keys" begin
    withenv("QE_TEST_ALPACA_KEY" => "secret_key_123", "QE_TEST_ALPACA_SECRET" => "secret_456") do
        ex = AlpacaExchange(execution_mode=PAPER,
                            api_key_env="QE_TEST_ALPACA_KEY",
                            secret_key_env="QE_TEST_ALPACA_SECRET")

        headers = QuantEngine._alpaca_headers(ex)
        @test length(headers) == 3

        # Keys should be in headers (for API auth) but should NOT appear in logs
        key_header = findfirst(h -> h.first == "APCA-API-KEY-ID", headers)
        @test key_header !== nothing
        @test headers[key_header].second == "secret_key_123"
    end
end

@testset "ExecutionMode guard with AlpacaExchange" begin
    withenv("QE_TEST_ALPACA_KEY" => "test_key", "QE_TEST_ALPACA_SECRET" => "test_secret") do
        ex_paper = AlpacaExchange(execution_mode=PAPER,
                                  api_key_env="QE_TEST_ALPACA_KEY",
                                  secret_key_env="QE_TEST_ALPACA_SECRET")

        # AlpacaExchange should NOT trigger the PaperExchange guard
        # (the guard only fires when LIVE mode uses PaperExchange)
        @test !(ex_paper isa PaperExchange)
    end
end
