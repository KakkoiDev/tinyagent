#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL_DIR="$SCRIPT_DIR/models"
LLAMA_DIR="$SCRIPT_DIR/llama.cpp"
MODEL_NAME="Qwen2.5-Coder-0.5B-Instruct-Q4_K_M.gguf"
MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF/resolve/main/$MODEL_NAME"

echo "=== miniagents setup ==="

# Install packages
echo "[1/4] Installing packages..."
pkg install -y jq make clang git curl

# Clone and build llama.cpp
if [ -d "$LLAMA_DIR" ]; then
    echo "[2/4] llama.cpp already exists, pulling latest..."
    cd "$LLAMA_DIR" && git pull
else
    echo "[2/4] Cloning llama.cpp..."
    git clone --depth 1 https://github.com/ggerganov/llama.cpp "$LLAMA_DIR"
fi

echo "[2/4] Building llama.cpp..."
cd "$LLAMA_DIR"
make -j$(nproc) llama-server

# Download model
mkdir -p "$MODEL_DIR"
if [ -f "$MODEL_DIR/$MODEL_NAME" ]; then
    echo "[3/4] Model already downloaded."
else
    echo "[3/4] Downloading model ($MODEL_NAME)..."
    curl -L -o "$MODEL_DIR/$MODEL_NAME" "$MODEL_URL"
fi

# Setup storage access
echo "[4/4] Setting up storage access..."
termux-setup-storage || true

# Create dirs
mkdir -p "$SCRIPT_DIR/logs"

echo ""
echo "=== Setup complete ==="
echo "Model: $MODEL_DIR/$MODEL_NAME"
echo "Server: $LLAMA_DIR/llama-server"
echo "Run: bash agent.sh"
