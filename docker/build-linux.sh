#!/bin/bash
set -euo pipefail

# Docker 容器内的 Linux 构建脚本
# 由 build-all.sh 通过 docker run 调用

cd /home/builder/rustdesk

TARGET="${TARGET:-x86_64-unknown-linux-gnu}"
DEB_ARCH="${DEB_ARCH:-amd64}"
export VCPKG_ROOT=/opt/vcpkg
export CARGO_HOME=/opt/cargo
export PATH="/opt/cargo/bin:/opt/flutter/bin:${PATH}"

echo "[INFO] Building for $TARGET (deb: $DEB_ARCH)"

# 1. 编译 Rust 库
cargo build --features flutter --lib --release --target "$TARGET"

# 2. 符号链接到 Flutter 期望的位置
mkdir -p target/release
case "$TARGET" in
    x86_64-unknown-linux-gnu)
        ln -sf ../"$TARGET"/release/liblibrustdesk.so target/release/liblibrustdesk.so
        FLUTTER_TARGET="linux/x64"
        ;;
    aarch64-unknown-linux-gnu)
        ln -sf ../"$TARGET"/release/liblibrustdesk.so target/release/liblibrustdesk.so
        FLUTTER_TARGET="linux/arm64"
        ;;
esac

# 3. 构建 Flutter bundle
cd flutter
flutter pub get
flutter build linux --release --target-platform "$FLUTTER_TARGET"
cd ..

# 4. 打包 .deb
python3 build.py --flutter --skip-cargo || true

# 5. 拷贝产物
cp -v rustdesk-*.deb /dist/ 2>/dev/null || echo "[WARN] No .deb found"
echo "[OK] Build complete for $TARGET"
