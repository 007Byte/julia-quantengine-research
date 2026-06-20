# ── Step 1: Trigger Detection ─────────────────────────────────
# Detects actionable events across all monitored assets.

"""Check if an asset has triggered a pipeline event."""
function check_triggers(asset::String, asset_type::Symbol,
                        snapshot::LiveSnapshot, history::RollingHistory,
                        config::PipelineConfig)::Union{PipelineEvent, Nothing}
    recent_prices  = get_recent_prices(history, asset)
    recent_volumes = get_recent_volumes(history, asset)

    # Need minimum history before triggering
    if length(recent_prices) < 20
        return nothing
    end

    # Check each trigger type
    trigger_type = nothing
    trigger_data = Dict{String,Any}()

    # Trigger 1: Volume spike
    avg_volume = mean(recent_volumes[max(1,end-19):end])
    if avg_volume > 0 && snapshot.volume > config.volume_spike_multiplier * avg_volume
        trigger_type = :volume_spike
        trigger_data["volume_ratio"] = snapshot.volume / avg_volume
        trigger_data["avg_volume"] = avg_volume
        trigger_data["current_volume"] = snapshot.volume
    end

    # Trigger 2: Price jump (rapid price change)
    if length(recent_prices) >= 5
        recent_price = recent_prices[end]
        price_change = abs(snapshot.price - recent_price) / max(recent_price, 1e-8)
        if price_change > config.price_jump_threshold
            trigger_type = :price_jump
            trigger_data["price_change_pct"] = price_change * 100
            trigger_data["prev_price"] = recent_price
            trigger_data["current_price"] = snapshot.price
            trigger_data["direction"] = snapshot.price > recent_price ? "UP" : "DOWN"
        end
    end

    # Trigger 3: Orderbook imbalance (for Polymarket — estimated from price movement)
    if asset_type == :polymarket && length(recent_prices) >= 10
        # Approximate imbalance from recent price trend
        up_moves = count(i -> recent_prices[i] > recent_prices[i-1], 2:length(recent_prices))
        total_moves = length(recent_prices) - 1
        imbalance = up_moves / max(total_moves, 1)
        if abs(imbalance - 0.5) > (config.orderbook_imbalance_threshold - 0.5)
            if trigger_type === nothing  # don't override volume spike
                trigger_type = :orderbook_imbalance
                trigger_data["imbalance_ratio"] = imbalance
                trigger_data["direction"] = imbalance > 0.5 ? "BUY_PRESSURE" : "SELL_PRESSURE"
            end
        end
    end

    if trigger_type === nothing
        return nothing
    end

    return PipelineEvent(
        now(), asset, asset_type, trigger_type,
        trigger_data, snapshot.price, snapshot.volume
    )
end

"""Poll all assets for triggers. Returns events found."""
function poll_for_triggers(assets::Vector{String}, config::PipelineConfig,
                           history::RollingHistory,
                           rate_limiters::Dict{Symbol, RateLimiter})::Vector{PipelineEvent}
    events = PipelineEvent[]

    for asset in assets
        asset_type = detect_asset_type(asset)
        source = asset_type == :polymarket ? :polymarket : :yahoo

        # Respect rate limits
        if !try_request!(rate_limiters[source])
            continue  # skip this asset this iteration
        end

        snapshot = try
            fetch_live_snapshot(asset, asset_type)
        catch e
            @warn "Failed to fetch $asset: $(sprint(showerror, e)[1:min(80,end)])"
            continue
        end

        # Update history
        update_history!(history, asset, snapshot)

        # Check triggers
        event = check_triggers(asset, asset_type, snapshot, history, config)
        if event !== nothing
            push!(events, event)
        end
    end

    return events
end
