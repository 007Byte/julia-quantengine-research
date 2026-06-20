# ================================================================
#  Machine Learning — Neural Network with Flux.jl
#
#  Use case: Network Intrusion / Anomaly Detection
#  (Relevant to CyberSecurity — detect malicious traffic patterns)
#
#  Architecture: 4-layer feedforward neural network
#  Task: Binary classification — Normal vs Anomalous traffic
#
#  This is pure Julia ML — no Python, no TensorFlow, no PyTorch.
# ================================================================

using Flux
using Flux: train!, binarycrossentropy, sigmoid
using Statistics
using Random
using Plots
using Printf

Random.seed!(42)

# ── 1. GENERATE SYNTHETIC NETWORK TRAFFIC DATA ────────────────
# Features: [packet_size, connection_duration, bytes_sent,
#            bytes_recv, port_number_normalized, protocol_type]
# Label: 0 = normal, 1 = anomalous/intrusion

function generate_traffic(n_normal, n_anomalous)
    # Normal traffic: tightly clustered, predictable patterns
    X_normal = hcat(
        randn(n_normal) .* 0.3 .+ 0.5,   # packet_size ~normal
        randn(n_normal) .* 0.2 .+ 0.3,   # short duration
        randn(n_normal) .* 0.2 .+ 0.4,   # bytes_sent
        randn(n_normal) .* 0.2 .+ 0.4,   # bytes_recv
        rand(n_normal) .* 0.3,            # low port range
        rand(n_normal) .* 0.3             # common protocols
    )'
    y_normal = zeros(Float32, 1, n_normal)

    # Anomalous traffic: unusual patterns — large packets,
    # long connections, asymmetric data transfer, rare ports
    X_anom = hcat(
        randn(n_anomalous) .* 0.4 .+ 0.9,  # large packets
        randn(n_anomalous) .* 0.3 .+ 0.8,  # long duration
        randn(n_anomalous) .* 0.5 .+ 0.7,  # high bytes_sent (exfil)
        randn(n_anomalous) .* 0.1 .+ 0.1,  # low bytes_recv
        rand(n_anomalous) .* 0.4 .+ 0.6,   # unusual ports
        rand(n_anomalous) .* 0.4 .+ 0.6    # rare protocols
    )'
    y_anom = ones(Float32, 1, n_anomalous)

    X = Float32.(hcat(X_normal, X_anom))
    y = hcat(y_normal, y_anom)

    # Shuffle
    idx = shuffle(1:size(X, 2))
    return X[:, idx], y[:, idx]
end

X, y = generate_traffic(1500, 500)   # Realistic imbalance: 75/25

# Train/test split (80/20)
n     = size(X, 2)
n_train = Int(floor(0.8 * n))
X_train, y_train = X[:, 1:n_train],     y[:, 1:n_train]
X_test,  y_test  = X[:, n_train+1:end], y[:, n_train+1:end]

println("=" ^ 60)
println("  Neural Network — Network Intrusion Detection")
println("=" ^ 60)
println("  Training samples: $n_train  |  Test samples: $(n - n_train)")
println("  Features: 6 network traffic attributes")
println("  Classes:  Normal traffic (0) vs Intrusion (1)")

# ── 2. BUILD THE NEURAL NETWORK ───────────────────────────────
# This is what makes Flux elegant — the model IS the math
model = Chain(
    Dense(6 => 32, relu),       # Input layer:  6 features → 32 neurons
    BatchNorm(32),               # Normalize activations (stabilizes training)
    Dropout(0.2),                # Randomly drop 20% neurons (prevents overfitting)
    Dense(32 => 16, relu),       # Hidden layer: 32 → 16 neurons
    BatchNorm(16),
    Dense(16 => 8, relu),        # Hidden layer: 16 → 8 neurons
    Dense(8 => 1, sigmoid)       # Output:       8 → 1 probability [0,1]
)

println("\n  Model Architecture:")
println("  Input(6) → Dense(32,relu) → BN → Dropout → Dense(16,relu) → BN → Dense(8,relu) → Dense(1,sigmoid)")
println("  Total parameters: $(sum(length, Flux.params(model)))")

# ── 3. TRAINING ───────────────────────────────────────────────
loss(m, x, y) = binarycrossentropy(m(x), y)
opt_state = Flux.setup(Adam(0.001), model)

# Mini-batch training
batch_size  = 64
n_epochs    = 50
loader      = Flux.DataLoader((X_train, y_train), batchsize=batch_size, shuffle=true)

train_losses = Float64[]
test_losses  = Float64[]
accuracies   = Float64[]

println("\n  Training...\n  $(rpad("Epoch",8)) $(rpad("Train Loss",12)) $(rpad("Test Loss",12)) Accuracy")
println("  " * "─" ^ 44)

Flux.trainmode!(model)
for epoch in 1:n_epochs
    epoch_loss = 0.0
    for (xb, yb) in loader
        l, grads = Flux.withgradient(m -> loss(m, xb, yb), model)
        Flux.update!(opt_state, model, grads[1])
        epoch_loss += l
    end

    Flux.testmode!(model)
    t_loss = loss(model, X_test, y_test)
    preds  = vec(model(X_test)) .> 0.5
    acc    = mean(preds .== vec(y_test .> 0.5)) * 100

    push!(train_losses, epoch_loss / length(loader))
    push!(test_losses,  t_loss)
    push!(accuracies,   acc)

    if epoch % 10 == 0
        @printf("  Epoch %-4d  loss=%-10.4f  val_loss=%-10.4f  acc=%.1f%%\n",
            epoch, train_losses[end], t_loss, acc)
    end
    Flux.trainmode!(model)
end

# ── 4. EVALUATION ─────────────────────────────────────────────
Flux.testmode!(model)
probs     = vec(model(X_test))
preds_bin = probs .> 0.5
truth     = vec(y_test .> 0.5)

TP = sum(preds_bin .&  truth)
TN = sum(.!preds_bin .& .!truth)
FP = sum(preds_bin .& .!truth)
FN = sum(.!preds_bin .&  truth)

precision = TP / (TP + FP)
recall    = TP / (TP + FN)          # = True Positive Rate / Sensitivity
f1        = 2 * precision * recall / (precision + recall)
accuracy  = (TP + TN) / length(truth) * 100

println("\n" * "=" ^ 60)
println("  Final Evaluation on Test Set")
println("=" ^ 60)
@printf("  Accuracy:   %.2f%%\n", accuracy)
@printf("  Precision:  %.4f  (of flagged alerts, %% actually malicious)\n", precision)
@printf("  Recall:     %.4f  (of real intrusions, %% we caught)\n", recall)
@printf("  F1 Score:   %.4f\n", f1)
println("─" ^ 60)
@printf("  True Positives (caught intrusions):  %d\n", TP)
@printf("  True Negatives (correct normal):     %d\n", TN)
@printf("  False Positives (false alarms):      %d\n", FP)
@printf("  False Negatives (missed intrusions): %d\n", FN)
println("=" ^ 60)

# ── 5. PLOTS ──────────────────────────────────────────────────
epochs_range = 1:n_epochs

# Loss curves
p1 = plot(epochs_range, train_losses,
    label="Train Loss", color=:steelblue, linewidth=2,
    xlabel="Epoch", ylabel="Binary Cross-Entropy Loss",
    title="Training & Validation Loss")
plot!(p1, epochs_range, test_losses,
    label="Val Loss", color=:red, linewidth=2, linestyle=:dash)

# Accuracy curve
p2 = plot(epochs_range, accuracies,
    color=:green, linewidth=2, fill=(0, 0.1, :green),
    xlabel="Epoch", ylabel="Accuracy (%)",
    title="Classification Accuracy", legend=false, ylims=(50,101))
hline!(p2, [100.0], color=:black, linestyle=:dash, linewidth=1)

# Score distribution — can the model separate the two classes?
normal_scores   = probs[.!truth]
intrusion_scores = probs[truth]
p3 = histogram(normal_scores, bins=30, normalize=:pdf,
    color=:steelblue, alpha=0.6, label="Normal",
    xlabel="Model Score (intrusion probability)",
    ylabel="Density", title="Score Distribution by Class")
histogram!(p3, intrusion_scores, bins=30, normalize=:pdf,
    color=:red, alpha=0.6, label="Intrusion")
vline!(p3, [0.5], color=:black, linestyle=:dash, linewidth=2, label="Threshold")

# Confusion matrix heatmap
conf = [TN FP; FN TP]
p4 = heatmap(["Pred Normal","Pred Intrusion"],
             ["Actual Normal","Actual Intrusion"],
    conf, color=:Blues, title="Confusion Matrix",
    xlabel="Predicted", ylabel="Actual",
    annotate=[
        (1,1,text("$TN", 14, :black)),
        (2,1,text("$FP", 14, :red)),
        (1,2,text("$FN", 14, :red)),
        (2,2,text("$TP", 14, :black))
    ])

combined = plot(p1, p2, p3, p4, layout=(2,2), size=(1100, 850))
savefig(combined, "C:/Users/yturb/ml_intrusion_detection.png")
println("\n  Chart saved → C:/Users/yturb/ml_intrusion_detection.png")
println("  Done.")
