#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL_DIR="$SCRIPT_DIR/models"
LLAMA_DIR="$SCRIPT_DIR/llama.cpp"
MODEL_NAME="qwen2.5-coder-0.5b-instruct-q4_k_m.gguf"
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
echo "=== tinyagent setup ($PLATFORM) ==="

# ── Install packages ────────────────────────────────────
echo "[1/5] Installing packages..."
case "$PLATFORM" in
    termux)
        pkg install -y jq cmake clang git curl aspell
        ;;
    macos)
        if ! command -v brew > /dev/null 2>&1; then
            echo "Error: Homebrew required. Install from https://brew.sh"
            exit 1
        fi
        brew install jq cmake llvm curl git aspell
        ;;
    linux)
        if command -v apt-get > /dev/null 2>&1; then
            sudo apt-get update -qq && sudo apt-get install -y jq cmake clang git curl build-essential aspell
        elif command -v dnf > /dev/null 2>&1; then
            sudo dnf install -y jq cmake clang git curl aspell
        elif command -v pacman > /dev/null 2>&1; then
            sudo pacman -Sy --noconfirm jq cmake clang git curl aspell
        else
            echo "Warning: Unknown package manager. Install manually: jq cmake clang git curl"
        fi
        ;;
esac

# ── Install lightpanda (optional: SKIP_LIGHTPANDA=1 to skip) ──
if [ "${SKIP_LIGHTPANDA:-}" != "1" ]; then
    LIGHTPANDA_BIN="$SCRIPT_DIR/lightpanda"
    if [ -x "$LIGHTPANDA_BIN" ]; then
        echo "[2/5] lightpanda already installed."
    else
        echo "[2/5] Installing lightpanda..."
        ARCH="$(uname -m)"
        OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
        case "$ARCH" in
            x86_64)  LP_ARCH="x86_64" ;;
            aarch64|arm64) LP_ARCH="aarch64" ;;
            *) echo "Error: unsupported architecture $ARCH for lightpanda"; exit 1 ;;
        esac
        case "$OS" in
            linux)  LP_OS="linux" ;;
            darwin) LP_OS="macos" ;;
            *) echo "Error: unsupported OS $OS for lightpanda"; exit 1 ;;
        esac
        LP_URL="https://github.com/lightpanda-io/browser/releases/download/nightly/lightpanda-${LP_ARCH}-${LP_OS}"
        curl -L --fail -o "$LIGHTPANDA_BIN" "$LP_URL"
        chmod +x "$LIGHTPANDA_BIN"
        echo "  lightpanda installed at $LIGHTPANDA_BIN"
    fi
else
    echo "[2/5] Skipping lightpanda (SKIP_LIGHTPANDA=1)."
fi

# ── Clone and build llama.cpp ───────────────────────────
if [ -d "$LLAMA_DIR" ]; then
    echo "[3/5] llama.cpp already exists, pulling latest..."
    cd "$LLAMA_DIR" && git pull
else
    echo "[3/5] Cloning llama.cpp..."
    git clone --depth 1 https://github.com/ggerganov/llama.cpp "$LLAMA_DIR"
fi

echo "[3/5] Building llama.cpp (cmake)..."
cd "$LLAMA_DIR"
cmake -B build -DLLAMA_CURL=OFF -DGGML_CUDA=OFF -DGGML_METAL=OFF
cmake --build build --config Release -j"$(ncpus)" --target llama-server

# ── Download model ──────────────────────────────────────
mkdir -p "$MODEL_DIR"
MIN_MODEL_SIZE=100000000  # ~100MB minimum for a valid GGUF
if [ -f "$MODEL_DIR/$MODEL_NAME" ] && [ "$(stat -c%s "$MODEL_DIR/$MODEL_NAME" 2>/dev/null || stat -f%z "$MODEL_DIR/$MODEL_NAME" 2>/dev/null)" -gt "$MIN_MODEL_SIZE" ]; then
    echo "[4/5] Model already downloaded."
else
    rm -f "$MODEL_DIR/$MODEL_NAME"
    echo "[4/5] Downloading model ($MODEL_NAME)..."
    curl -L --fail -o "$MODEL_DIR/$MODEL_NAME" "$MODEL_URL"
    # Verify download
    local_size="$(stat -c%s "$MODEL_DIR/$MODEL_NAME" 2>/dev/null || stat -f%z "$MODEL_DIR/$MODEL_NAME" 2>/dev/null)"
    if [ "$local_size" -lt "$MIN_MODEL_SIZE" ]; then
        echo "Error: Downloaded file too small (${local_size} bytes). Download likely failed."
        rm -f "$MODEL_DIR/$MODEL_NAME"
        exit 1
    fi
fi

# ── Platform-specific setup ─────────────────────────────
echo "[5/5] Platform setup..."
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
