#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL_DIR="$SCRIPT_DIR/models"
LLAMA_DIR="$SCRIPT_DIR/llama.cpp"
MODEL_NAME="Qwen2.5-Coder-0.5B-Instruct-Q4_K_M.gguf"
MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF/resolve/main/$MODEL_NAME"

# ── Platform detection ──────────────────────────────────
detect_platform() {
    if [ -d "/data/data/com.termux" ]; then
        echo "termux"
    elif [ "$(uname)" = "Darwin" ]; then
        echo "macos"
    else
        echo "linux"
    fi
}

ncpus() {
    if command -v nproc > /dev/null 2>&1; then
        nproc
    elif sysctl -n hw.ncpu > /dev/null 2>&1; then
        sysctl -n hw.ncpu
    else
        echo 2
    fi
}

PLATFORM="$(detect_platform)"
echo "=== miniagents setup ($PLATFORM) ==="

# ── Install packages ────────────────────────────────────
echo "[1/4] Installing packages..."
case "$PLATFORM" in
    termux)
        pkg install -y jq cmake clang git curl
        ;;
    macos)
        if ! command -v brew > /dev/null 2>&1; then
            echo "Error: Homebrew required. Install from https://brew.sh"
            exit 1
        fi
        brew install jq cmake llvm curl git
        ;;
    linux)
        if command -v apt-get > /dev/null 2>&1; then
            sudo apt-get update -qq && sudo apt-get install -y jq cmake clang git curl build-essential
        elif command -v dnf > /dev/null 2>&1; then
            sudo dnf install -y jq cmake clang git curl
        elif command -v pacman > /dev/null 2>&1; then
            sudo pacman -Sy --noconfirm jq cmake clang git curl
        else
            echo "Warning: Unknown package manager. Install manually: jq cmake clang git curl"
        fi
        ;;
esac

# ── Clone and build llama.cpp ───────────────────────────
if [ -d "$LLAMA_DIR" ]; then
    echo "[2/4] llama.cpp already exists, pulling latest..."
    cd "$LLAMA_DIR" && git pull
else
    echo "[2/4] Cloning llama.cpp..."
    git clone --depth 1 https://github.com/ggerganov/llama.cpp "$LLAMA_DIR"
fi

echo "[2/4] Building llama.cpp (cmake)..."
cd "$LLAMA_DIR"
cmake -B build -DLLAMA_CURL=OFF -DGGML_CUDA=OFF -DGGML_METAL=OFF
cmake --build build --config Release -j"$(ncpus)" --target llama-server

# ── Download model ──────────────────────────────────────
mkdir -p "$MODEL_DIR"
if [ -f "$MODEL_DIR/$MODEL_NAME" ]; then
    echo "[3/4] Model already downloaded."
else
    echo "[3/4] Downloading model ($MODEL_NAME)..."
    curl -L -o "$MODEL_DIR/$MODEL_NAME" "$MODEL_URL"
fi

# ── Platform-specific setup ─────────────────────────────
echo "[4/4] Platform setup..."
case "$PLATFORM" in
    termux)
        termux-setup-storage || true
        ;;
    macos|linux)
        echo "No additional setup needed."
        ;;
esac

# Create dirs
mkdir -p "$SCRIPT_DIR/logs"

echo ""
echo "=== Setup complete ==="
echo "Platform: $PLATFORM"
echo "Model: $MODEL_DIR/$MODEL_NAME"
echo "Server: $LLAMA_DIR/build/bin/llama-server"
echo "Run: bash agent.sh"
