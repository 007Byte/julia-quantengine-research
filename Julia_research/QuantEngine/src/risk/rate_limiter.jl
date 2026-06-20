# ── Rate Limiter — Defense-in-Depth Layer 6 ──────────────────

mutable struct RateLimiter
    requests::Vector{DateTime}
    max_per_minute::Int
    max_per_second::Int
    lock::ReentrantLock
end

function RateLimiter(; max_per_minute::Int=30, max_per_second::Int=2)
    RateLimiter(DateTime[], max_per_minute, max_per_second, ReentrantLock())
end

"""Try to make a request. Returns true if allowed, false if rate limited."""
function try_request!(limiter::RateLimiter)::Bool
    lock(limiter.lock) do
        now_t = now()
        # Prune entries older than 60 seconds
        filter!(t -> now_t - t < Second(60), limiter.requests)
        # Check per-minute limit
        length(limiter.requests) >= limiter.max_per_minute && return false
        # Check per-second limit
        last_second = count(t -> now_t - t < Second(1), limiter.requests)
        last_second >= limiter.max_per_second && return false
        # Record this request
        push!(limiter.requests, now_t)
        return true
    end
end

"""Wait until a request is allowed (blocking)."""
function wait_for_slot!(limiter::RateLimiter; max_wait_ms::Int=10000)::Bool
    start = time_ns()
    while (time_ns() - start) / 1e6 < max_wait_ms
        if try_request!(limiter)
            return true
        end
        sleep(0.1)  # 100ms backoff
    end
    return false  # timed out
end

"""Create rate limiters for each data source."""
function create_rate_limiters()::Dict{Symbol, RateLimiter}
    Dict(
        :yahoo      => RateLimiter(max_per_minute=30, max_per_second=2),
        :polymarket  => RateLimiter(max_per_minute=60, max_per_second=5),
        :general     => RateLimiter(max_per_minute=120, max_per_second=10),
    )
end
