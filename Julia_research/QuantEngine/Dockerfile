# ── QuantEngine Docker Image ──────────────────────────────────
# Multi-stage build for minimal production image.

FROM julia:1.12 AS builder

WORKDIR /app

# Copy dependency files first (cache layer)
COPY Project.toml .
RUN julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

# Copy source code
COPY src/ src/
COPY bin/ bin/

# Precompile the full module
RUN julia --project=. -e 'using QuantEngine'

# ── Production image ─────────────────────────────────────────
FROM julia:1.12

WORKDIR /app

# Copy precompiled environment
COPY --from=builder /app /app
COPY --from=builder /root/.julia /root/.julia

# Create data directories with restricted permissions
RUN mkdir -p /data/audit /data/db /data/output && chmod -R 700 /data

# Health check
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Default environment
ENV QE_EXECUTION_MODE=PAPER \
    QE_INITIAL_BANKROLL=2000 \
    QE_POLL_INTERVAL_MS=5000 \
    QE_MAX_POSITION_PCT=0.10 \
    QE_MAX_DAILY_LOSS_PCT=0.05 \
    QE_MAX_DRAWDOWN_PCT=0.15 \
    QUANT_OUTPUT_DIR=/data/output

EXPOSE 8080

# Default: run the 24/7 pipeline
ENTRYPOINT ["julia", "--project=/app", "-t", "auto"]
CMD ["bin/run_pipeline.jl", "BTC-USD,ETH-USD"]
