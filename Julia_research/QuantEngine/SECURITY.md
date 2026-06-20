# QuantEngine — Security Policy

## Threat Model

QuantEngine handles financial data and (in LIVE mode) real money. The primary threats are:

1. **API Key Exposure** — Leaked keys enable unauthorized trading or data access
2. **Data Injection** — Malicious ticker symbols or malformed API responses could cause unexpected behavior
3. **Audit Tampering** — Modified audit logs could hide unauthorized trades
4. **Accidental Live Execution** — Running real trades when paper trading was intended
5. **Excessive Risk** — Bypassing position limits or circuit breakers

## Security Controls

### Execution Mode Guard
- `ExecutionMode` enum (`PAPER` / `LIVE`) in `PipelineConfig`
- Default is always `PAPER` — `QE_EXECUTION_MODE` must be explicitly set to `"LIVE"`
- Guard in `execute_trade!` prevents LIVE mode with `PaperExchange`
- Real exchange implementations validate mode before placing orders

### Input Validation
- `validate_ticker()` enforces allowlist: alphanumeric, `.`, `-`, `:` only (max 50 chars)
- Called at all data entry points: `fetch_ohlcv`, `fetch_polymarket_data`, `fetch_live_snapshot`
- Prevents URL injection attacks via ticker parameters

### Data Sanitization (Defense-in-Depth Layer 1)
- `sanitize_price()` — rejects NaN, Inf, negative, >$1B
- `sanitize_volume()` — handles NaN/Inf gracefully
- `sanitize_returns()` — clamps extreme values (default +/-50%)
- `sanitize_ohlcv()` — validates array lengths and minimum data
- `sanitize_polymarket()` — validates prices in [0,1] and sum ~1.0

### TLS Verification
- All HTTP calls use HTTPS — HTTP.jl verifies TLS certificates by default
- Yahoo Finance and Polymarket APIs are accessed exclusively over TLS

### API Key Management
- All secrets are stored in environment variables (never hardcoded)
- `validate_api_keys()` warns on startup if required keys are missing
- `.env` files are excluded via `.gitignore`
- See `.env.example` for the full list of supported environment variables
- **Future:** Encrypted vault integration planned (Sprint 7)

### Audit Trail (Defense-in-Depth Layer 5)
- Append-only JSON Lines files in `audit/` directory
- Thread-safe writes via `ReentrantLock`
- Daily file rotation + size-based rotation at 50MB
- File permissions set to `0o600` (owner read/write only)
- Directory permissions set to `0o700` (owner only)
- Every trigger, step pass/fail, trade, skip, and abort is logged

### Risk Management (Defense-in-Depth Layers 2-4)
- **Circuit Breakers:** Daily loss limit, max drawdown halt, consecutive-loss cooling
- **Position Limits:** Max concurrent positions, per-position size cap
- **RALPH Framework:** Every model wrapped in Review-Analyze-Log-Print-Halt
- **Preflight Checks:** Run before every pipeline execution

### File Permissions
- Output directories: `0o700` (owner only)
- Audit log files: `0o600` (owner read/write)
- Prevents other users on shared systems from reading trade data

## Credential Rotation

1. Rotate API keys immediately if you suspect exposure
2. Update the relevant `QE_*` environment variable
3. Restart the pipeline to load the new key
4. Check audit logs for any unauthorized activity during the exposure window

## Reporting Security Issues

If you discover a security vulnerability in QuantEngine:
1. Do not open a public issue
2. Contact the project maintainer directly
3. Include: description, reproduction steps, potential impact

## Checklist for New Code

Every new file or feature must satisfy:

- [ ] No hardcoded secrets (API keys, passwords, tokens)
- [ ] All new mutable state wrapped in `ReentrantLock`
- [ ] All new model/pipeline code wrapped in RALPH
- [ ] All config from ENV vars with safe defaults
- [ ] All external data passes through sanitizer
- [ ] All operations logged to audit trail
- [ ] Money-touching code checks `ExecutionMode`
- [ ] User-provided strings validated
- [ ] Network calls use TLS (HTTPS)
- [ ] Sensitive output has restrictive file permissions
