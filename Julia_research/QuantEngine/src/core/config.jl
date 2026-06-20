# ── Configuration & Path Resolution ──────────────────────────

function detect_asset_type(ticker::AbstractString)
    if startswith(lowercase(ticker), "poly:")
        return :polymarket
    elseif uppercase(ticker) in CRYPTO_TICKERS || occursin(r"-USD$"i, ticker)
        return :crypto
    else
        return :stock
    end
end

function resolve_output_base()
    env_path = get(ENV, "QUANT_OUTPUT_DIR", "")
    if !isempty(env_path)
        return env_path
    end
    if Sys.iswindows()
        docs = get(ENV, "USERPROFILE", homedir())
        return joinpath(docs, "Documents", "Quant_Analysis")
    elseif Sys.isapple()
        return joinpath(homedir(), "Documents", "Quant_Analysis")
    else
        xdg = get(ENV, "XDG_DATA_HOME", joinpath(homedir(), ".local", "share"))
        return joinpath(xdg, "quant_analysis")
    end
end

function make_output_dir(display_ticker::String)
    base = resolve_output_base()
    dir = joinpath(base, "$(display_ticker)_$(Dates.format(Dates.now(), "yyyy-mm-dd_HHMMSS"))")
    mkpath(dir)
    # Restrict permissions: owner-only (rwx------) to protect trade data
    try
        chmod(dir, 0o700)
    catch
        @warn "Could not set restrictive permissions on $dir"
    end
    return dir
end
