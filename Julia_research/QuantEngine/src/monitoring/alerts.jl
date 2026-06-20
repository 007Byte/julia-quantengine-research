# ── Telegram Alerts ──────────────────────────────────────────
# Sends critical events to Telegram for real-time notification.
# Graceful no-op when tokens are not configured.

"""Configuration for Telegram alerting."""
struct AlertConfig
    bot_token::String
    chat_id::String
    enabled::Bool
    min_level::Symbol          # :info, :warn, :error, :critical
    rate_limiter::RateLimiter
end

"""Create alert config from environment variables."""
function create_alert_config(; min_level::Symbol=:warn)
    token = get(ENV, "QE_TELEGRAM_BOT_TOKEN", "")
    chat_id = get(ENV, "QE_TELEGRAM_CHAT_ID", "")
    enabled = !isempty(token) && !isempty(chat_id)

    # Max 30 messages per minute to respect Telegram API limits
    limiter = RateLimiter(max_per_minute=30, max_per_second=1)

    AlertConfig(token, chat_id, enabled, min_level, limiter)
end

"""Send an alert via Telegram Bot API."""
function send_alert(config::AlertConfig, message::String; level::Symbol=:info)
    !config.enabled && return false

    level_rank = Dict(:info => 1, :warn => 2, :error => 3, :critical => 4)
    get(level_rank, level, 1) < get(level_rank, config.min_level, 1) && return false

    # Rate limit check
    if !try_request!(config.rate_limiter)
        return false
    end

    emoji = Dict(:info => "ℹ️", :warn => "⚠️", :error => "❌", :critical => "🚨")
    text = "$(get(emoji, level, "📊")) *QuantEngine* [$(uppercase(string(level)))]\n$(message)"

    url = "https://api.telegram.org/bot$(config.bot_token)/sendMessage"
    body = JSON.json(Dict("chat_id" => config.chat_id,
                          "text" => text,
                          "parse_mode" => "Markdown"))

    try
        HTTP.post(url, ["Content-Type" => "application/json"], body;
                  connect_timeout=5, readtimeout=5)
        return true
    catch e
        @warn "Telegram alert failed: $(sprint(showerror, e)[1:min(60,end)])"
        return false
    end
end

"""Send alert for a trade event."""
function alert_trade(config::AlertConfig, asset::String, direction::Symbol,
                      pnl::Float64; exit_reason::String="")
    emoji = pnl >= 0 ? "💰" : "📉"
    pnl_str = pnl >= 0 ? "+\$$(round(pnl, digits=2))" : "-\$$(round(abs(pnl), digits=2))"
    msg = "$emoji *$asset* $(uppercase(string(direction)))\nPnL: $pnl_str"
    if !isempty(exit_reason)
        msg *= "\nReason: $exit_reason"
    end
    send_alert(config, msg; level=pnl >= 0 ? :info : :warn)
end

"""Send alert for circuit breaker activation."""
function alert_circuit_breaker(config::AlertConfig, reason::String)
    send_alert(config, "🛑 Circuit breaker: $reason"; level=:critical)
end
