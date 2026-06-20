# ── NTP Check — Clock Skew Detection ──────────────────────────────────
# Trading systems need accurate timestamps.
# Even 300-800ms skew causes cancel races on Binance futures.
#
# Thresholds (per feedback):
#   < 50ms:   healthy
#   50-150ms: warning
#   > 150ms:  critical — should block trading
#
# Tightened from 1000ms to 150ms based on production experience.

using Sockets
using Dates

const NTP_SERVERS = ["time.apple.com", "time.google.com", "pool.ntp.org"]
const NTP_EPOCH_OFFSET = 2208988800  # seconds between 1900-01-01 and 1970-01-01

struct NTPResult
    skew_ms::Float64
    server::String
    level::Symbol       # :healthy, :warning, :critical
    checked_at::DateTime
end

"""
Query an NTP server and return clock skew in seconds.
Uses simplified SNTP (UDP port 123).
"""
function query_ntp(server::String; timeout_s::Float64=2.0)::Float64
    sock = UDPSocket()

    try
        # Resolve hostname
        addr = getaddrinfo(server)

        # Build NTP request packet (48 bytes, LI=0, VN=3, Mode=3)
        packet = zeros(UInt8, 48)
        packet[1] = 0x1b  # LI=0, VN=3, Mode=3 (client)

        t1 = time()
        send(sock, addr, 123, packet)

        # Wait for response with timeout
        response = Channel{Vector{UInt8}}(1)
        @async begin
            try
                data, _ = recvfrom(sock)
                put!(response, data)
            catch
            end
        end

        result = timedwait(() -> isready(response), timeout_s)
        if result === :timed_out
            error("NTP timeout from $server")
        end

        t4 = time()
        data = take!(response)

        # Parse transmit timestamp (bytes 41-44 = seconds since 1900)
        transmit_seconds = UInt32(data[41]) << 24 | UInt32(data[42]) << 16 |
                          UInt32(data[43]) << 8  | UInt32(data[44])
        t3 = Float64(transmit_seconds) - NTP_EPOCH_OFFSET

        # Simplified offset
        rtt = t4 - t1
        offset = t3 - t1 - rtt / 2

        return offset
    finally
        close(sock)
    end
end

"""
Check clock skew against NTP servers.
Returns NTPResult with skew and severity level.
Threshold: 150ms critical (tightened per Binance cancel race feedback).
"""
function check_ntp(;
    warning_ms::Float64 = 50.0,
    critical_ms::Float64 = 150.0,
    servers::Vector{String} = NTP_SERVERS,
)::NTPResult
    for server in servers
        try
            offset = query_ntp(server)
            skew_ms = abs(offset) * 1000.0

            level = if skew_ms < warning_ms
                :healthy
            elseif skew_ms < critical_ms
                @warn "Clock skew: $(round(skew_ms, digits=1))ms (server=$server)"
                :warning
            else
                @error "CRITICAL clock skew: $(round(skew_ms, digits=1))ms — cancel races possible"
                :critical
            end

            return NTPResult(skew_ms, server, level, now(UTC))
        catch e
            @debug "NTP query failed for $server: $e"
            continue
        end
    end

    @warn "All NTP servers unreachable"
    return NTPResult(0.0, "unreachable", :unknown, now(UTC))
end

"""Should trading be blocked due to clock skew?"""
function ntp_blocks_trading(result::NTPResult)::Bool
    return result.level == :critical
end
