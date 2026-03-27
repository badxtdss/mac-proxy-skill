#!/bin/bash
# Install Mac Proxy Skill - downloads mihomo binary + GeoIP database
set -e
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$SKILL_DIR/config"

mkdir -p "$CONFIG_DIR"

# Download mihomo (Meta for darwin arm64)
if [ ! -f "$SKILL_DIR/mihomo" ]; then
    echo "📥 Downloading mihomo..."
    ARCH=$(uname -m)
    if [ "$ARCH" = "arm64" ]; then
        URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.21/mihomo-darwin-arm64-v1.19.21.gz"
    else
        URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.21/mihomo-darwin-amd64-v1.19.21.gz"
    fi
    curl -L --noproxy '*' -o "$SKILL_DIR/mihomo.gz" "$URL"
    gunzip -f "$SKILL_DIR/mihomo.gz"
    chmod +x "$SKILL_DIR/mihomo"
    echo "✅ mihomo installed"
fi

# Download GeoIP database
if [ ! -f "$CONFIG_DIR/Country.mmdb" ]; then
    echo "📥 Downloading GeoIP database..."
    curl -L --noproxy '*' -o "$CONFIG_DIR/Country.mmdb.gz" \
        "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/Country.mmdb.gz"
    gunzip -f "$CONFIG_DIR/Country.mmdb.gz"
    echo "✅ GeoIP database downloaded"
fi

echo "✅ Install complete"
