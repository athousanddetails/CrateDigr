#!/bin/bash
# ============================================================
# Crate Digr - Binary Setup Script
# Downloads required binaries that are too large for git.
# Run this once after cloning the repo.
# ============================================================
set -e

BINARIES_DIR="CrateDigr/Resources/Binaries"
mkdir -p "$BINARIES_DIR"

echo "============================================"
echo "  Crate Digr - Downloading Binaries"
echo "============================================"
echo ""

# --- yt-dlp ---
if [ ! -f "$BINARIES_DIR/yt-dlp" ]; then
    echo "[1/5] Downloading yt-dlp..."
    curl -L -o "$BINARIES_DIR/yt-dlp" "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
    chmod +x "$BINARIES_DIR/yt-dlp"
    echo "      Done."
else
    echo "[1/5] yt-dlp already exists, skipping."
fi

# --- ffmpeg ---
if [ ! -f "$BINARIES_DIR/ffmpeg" ]; then
    echo "[2/5] Downloading ffmpeg..."
    curl -L -o /tmp/ffmpeg.zip "https://evermeet.cx/ffmpeg/getrelease/zip"
    unzip -o /tmp/ffmpeg.zip -d "$BINARIES_DIR/"
    rm /tmp/ffmpeg.zip
    chmod +x "$BINARIES_DIR/ffmpeg"
    echo "      Done."
else
    echo "[2/5] ffmpeg already exists, skipping."
fi

# --- deno ---
if [ ! -f "$BINARIES_DIR/deno" ]; then
    echo "[3/5] Downloading deno..."
    curl -L -o /tmp/deno.zip "https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip"
    unzip -o /tmp/deno.zip deno -d "$BINARIES_DIR/"
    rm /tmp/deno.zip
    chmod +x "$BINARIES_DIR/deno"
    echo "      Done."
else
    echo "[3/5] deno already exists, skipping."
fi

# --- demucs_mt ---
if [ ! -f "$BINARIES_DIR/demucs_mt" ]; then
    echo "[4/5] Downloading demucs_mt..."
    curl -L -o "$BINARIES_DIR/demucs_mt" "https://github.com/CrazyNeil/OVern-demucs/releases/download/v0.0.1/demucs_mt"
    chmod +x "$BINARIES_DIR/demucs_mt"
    echo "      Done."
else
    echo "[4/5] demucs_mt already exists, skipping."
fi

# --- Demucs GGML model ---
if [ ! -f "$BINARIES_DIR/ggml-model-htdemucs-4s-f16.bin" ]; then
    echo "[5/5] Downloading demucs GGML model..."
    curl -L -o "$BINARIES_DIR/ggml-model-htdemucs-4s-f16.bin" "https://huggingface.co/CrazyNeil/ggml-demucs/resolve/main/ggml-model-htdemucs-4s-f16.bin"
    echo "      Done."
else
    echo "[5/5] Demucs model already exists, skipping."
fi

echo ""
echo "============================================"
echo "  All binaries ready!"
echo "  Build with: bash build-app.sh"
echo "============================================"
