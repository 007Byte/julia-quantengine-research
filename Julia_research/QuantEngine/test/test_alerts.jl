# ── Alerts Tests ──────────────────────────────────────────────

using QuantEngine: AlertConfig, create_alert_config, send_alert

@testset "create_alert_config disabled by default" begin
    config = create_alert_config()
    @test config.enabled == false  # no tokens set
    @test config.min_level == :warn
end

@testset "create_alert_config with tokens" begin
    withenv("QE_TELEGRAM_BOT_TOKEN" => "test_token", "QE_TELEGRAM_CHAT_ID" => "12345") do
        config = create_alert_config()
        @test config.enabled == true
        @test config.bot_token == "test_token"
        @test config.chat_id == "12345"
    end
end

@testset "send_alert disabled config" begin
    config = create_alert_config()  # disabled (no tokens)
    result = send_alert(config, "Test message"; level=:critical)
    @test result == false  # should gracefully return false
end

@testset "send_alert level filtering" begin
    withenv("QE_TELEGRAM_BOT_TOKEN" => "test", "QE_TELEGRAM_CHAT_ID" => "123") do
        config = create_alert_config(min_level=:error)

        # Info and warn should be filtered out (below min_level)
        @test send_alert(config, "info msg"; level=:info) == false
        @test send_alert(config, "warn msg"; level=:warn) == false
        # Error and critical would pass level check (but fail on API call since token is fake)
        # We test the level filtering, not the actual HTTP call
    end
end

@testset "AlertConfig rate limiter" begin
    config = create_alert_config()
    @test config.rate_limiter.max_per_minute == 30
    @test config.rate_limiter.max_per_second == 1
end
