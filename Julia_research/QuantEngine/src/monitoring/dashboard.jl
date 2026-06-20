# ── Web Dashboard (HTTP.jl + Chart.js) ────────────────────────
# Single-page dashboard served at /dashboard with auto-refresh.
# Uses Chart.js from CDN for equity curves and model charts.
# Polls JSON APIs every 5 seconds for real-time updates.

"""Generate the complete HTML dashboard page."""
function _dashboard_html()::String
    return """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>QuantEngine Dashboard</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { background: #0d1117; color: #c9d1d9; font-family: 'Segoe UI', monospace; padding: 20px; }
        .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; }
        .header h1 { color: #58a6ff; font-size: 24px; }
        .header .status { padding: 6px 16px; border-radius: 20px; font-size: 14px; font-weight: bold; }
        .status-ok { background: #238636; color: #fff; }
        .status-warn { background: #d29922; color: #000; }
        .status-error { background: #da3633; color: #fff; }
        .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 20px; }
        .card { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 16px; }
        .card .label { color: #8b949e; font-size: 12px; text-transform: uppercase; margin-bottom: 4px; }
        .card .value { font-size: 28px; font-weight: bold; }
        .card .change { font-size: 14px; margin-top: 4px; }
        .positive { color: #3fb950; }
        .negative { color: #f85149; }
        .neutral { color: #8b949e; }
        .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 20px; }
        .panel { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 16px; }
        .panel h2 { color: #58a6ff; font-size: 16px; margin-bottom: 12px; border-bottom: 1px solid #30363d; padding-bottom: 8px; }
        .full-width { grid-column: 1 / -1; }
        table { width: 100%; border-collapse: collapse; font-size: 13px; }
        th { text-align: left; color: #8b949e; padding: 8px; border-bottom: 1px solid #30363d; }
        td { padding: 8px; border-bottom: 1px solid #21262d; }
        .progress-bar { background: #21262d; border-radius: 10px; height: 20px; overflow: hidden; margin-top: 8px; }
        .progress-fill { height: 100%; background: linear-gradient(90deg, #238636, #3fb950); border-radius: 10px; transition: width 0.5s; }
        .last-update { color: #484f58; font-size: 11px; text-align: right; margin-top: 10px; }
        @media (max-width: 900px) { .grid { grid-template-columns: 1fr; } }
    </style>
</head>
<body>
    <div class="header">
        <h1>QuantEngine v8.0</h1>
        <span class="status status-ok" id="server-status">LIVE</span>
    </div>

    <div class="cards">
        <div class="card">
            <div class="label">Bankroll</div>
            <div class="value" id="bankroll">\$--</div>
            <div class="change" id="bankroll-change">--</div>
        </div>
        <div class="card">
            <div class="label">Daily PnL</div>
            <div class="value" id="daily-pnl">\$--</div>
        </div>
        <div class="card">
            <div class="label">Win Rate</div>
            <div class="value" id="win-rate">--%</div>
        </div>
        <div class="card">
            <div class="label">Drawdown</div>
            <div class="value" id="drawdown">--%</div>
        </div>
        <div class="card">
            <div class="label">Open Positions</div>
            <div class="value" id="positions">--</div>
        </div>
        <div class="card">
            <div class="label">Total Trades</div>
            <div class="value" id="total-trades">--</div>
        </div>
    </div>

    <div class="grid">
        <div class="panel full-width">
            <h2>Equity Curve</h2>
            <canvas id="equityChart" height="80"></canvas>
        </div>

        <div class="panel">
            <h2>Goal Progress</h2>
            <div id="goal-info">
                <div style="display: flex; justify-content: space-between; margin-bottom: 8px;">
                    <span id="goal-current">\$--</span>
                    <span id="goal-target">\$--</span>
                </div>
                <div class="progress-bar">
                    <div class="progress-fill" id="goal-fill" style="width: 0%;"></div>
                </div>
                <div style="margin-top: 12px; font-size: 13px;">
                    <div>Completion: <span id="goal-pct">--</span>%</div>
                    <div>Daily Growth: <span id="goal-daily">--</span>%</div>
                    <div>Projected Days: <span id="goal-days">--</span></div>
                </div>
            </div>
        </div>

        <div class="panel">
            <h2>Recent Trades</h2>
            <div style="max-height: 300px; overflow-y: auto;">
                <table>
                    <thead><tr><th>Asset</th><th>Dir</th><th>PnL</th><th>Exit</th></tr></thead>
                    <tbody id="trades-body"></tbody>
                </table>
            </div>
        </div>
    </div>

    <div class="last-update">Last updated: <span id="last-update">--</span></div>

    <script>
    let equityChart = null;

    async function fetchJSON(url) {
        try {
            const res = await fetch(url);
            if (!res.ok) return null;
            return await res.json();
        } catch { return null; }
    }

    async function updateDashboard() {
        // Health / positions
        const health = await fetchJSON('/health');
        if (health) {
            document.getElementById('bankroll').textContent = '\$' + health.bankroll.toLocaleString(undefined, {minimumFractionDigits: 2});
            document.getElementById('daily-pnl').textContent = '\$' + (health.daily_pnl || 0).toFixed(2);
            document.getElementById('daily-pnl').className = 'value ' + ((health.daily_pnl || 0) >= 0 ? 'positive' : 'negative');
            document.getElementById('positions').textContent = health.positions;
            document.getElementById('total-trades').textContent = health.trades;
            document.getElementById('server-status').textContent = health.cooling ? 'COOLING' : 'ACTIVE';
            document.getElementById('server-status').className = 'status ' + (health.cooling ? 'status-warn' : 'status-ok');
        }

        // Positions data for win rate and drawdown
        const pos = await fetchJSON('/api/positions');
        if (pos) {
            document.getElementById('win-rate').textContent = (pos.win_rate || 0).toFixed(1) + '%';
            document.getElementById('drawdown').textContent = (pos.drawdown || 0).toFixed(1) + '%';
            document.getElementById('drawdown').className = 'value ' + ((pos.drawdown || 0) > 5 ? 'negative' : 'neutral');
        }

        // Goal progress
        const goal = await fetchJSON('/api/goal');
        if (goal) {
            document.getElementById('goal-current').textContent = '\$' + (goal.current_bankroll || 0).toLocaleString();
            document.getElementById('goal-target').textContent = '\$' + (goal.goal_target || 10000000).toLocaleString();
            document.getElementById('goal-pct').textContent = (goal.completion_pct || 0).toFixed(4);
            document.getElementById('goal-daily').textContent = (goal.daily_growth_pct || 0).toFixed(3);
            document.getElementById('goal-days').textContent = goal.projected_days || '--';
            const pct = Math.min(goal.completion_pct || 0, 100);
            document.getElementById('goal-fill').style.width = pct + '%';
        }

        // Equity curve
        const equity = await fetchJSON('/api/equity');
        if (equity && equity.length > 0) {
            const labels = equity.map(e => e.date || '');
            const values = equity.map(e => e.bankroll || 0);
            if (equityChart) {
                equityChart.data.labels = labels;
                equityChart.data.datasets[0].data = values;
                equityChart.update('none');
            } else {
                const ctx = document.getElementById('equityChart').getContext('2d');
                equityChart = new Chart(ctx, {
                    type: 'line',
                    data: {
                        labels: labels,
                        datasets: [{
                            label: 'Equity',
                            data: values,
                            borderColor: '#58a6ff',
                            backgroundColor: 'rgba(88,166,255,0.1)',
                            fill: true,
                            tension: 0.3,
                            pointRadius: 0
                        }]
                    },
                    options: {
                        responsive: true,
                        plugins: { legend: { display: false } },
                        scales: {
                            x: { display: true, ticks: { color: '#484f58', maxTicksLimit: 10 }, grid: { color: '#21262d' } },
                            y: { display: true, ticks: { color: '#484f58' }, grid: { color: '#21262d' } }
                        }
                    }
                });
            }
        }

        // Recent trades
        const trades = await fetchJSON('/api/trades');
        if (trades && trades.length > 0) {
            const tbody = document.getElementById('trades-body');
            tbody.innerHTML = trades.slice(0, 20).map(t => {
                const cls = (t.pnl || 0) >= 0 ? 'positive' : 'negative';
                const pnl = (t.pnl || 0) >= 0 ? '+\$' + t.pnl.toFixed(2) : '-\$' + Math.abs(t.pnl).toFixed(2);
                return '<tr><td>' + (t.asset || '--') + '</td><td>' + (t.direction || '--') +
                       '</td><td class="' + cls + '">' + pnl +
                       '</td><td>' + (t.exit_reason || '--') + '</td></tr>';
            }).join('');
        }

        document.getElementById('last-update').textContent = new Date().toLocaleTimeString();
    }

    // Initial load + auto-refresh every 5 seconds
    updateDashboard();
    setInterval(updateDashboard, 5000);
    </script>
</body>
</html>"""
end
