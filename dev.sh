#!/bin/bash
set -euo pipefail

# ============================================================
# RustDesk 一键开发脚本 (macOS)
# 用法: ./dev.sh [命令]
#   (无参数)  构建 Rust 后端 + 启动 Flutter macOS 桌面端
#   sciter    Sciter 模式 (cargo run, 快速调试后端)
#   build     仅构建 Flutter 后端 (--lib)
#   bridge    重新生成 flutter_rust_bridge 桥接代码
#   clean     清理构建后重新构建
#   release   Release 模式构建 + 运行
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---- 代理 (按需修改) ----
PROXY_HOST="127.0.0.1"
PROXY_PORT="10808"
export ALL_PROXY="socks5h://${PROXY_HOST}:${PROXY_PORT}"
export HTTPS_PROXY="http://${PROXY_HOST}:${PROXY_PORT}"
export HTTP_PROXY="http://${PROXY_HOST}:${PROXY_PORT}"
git config --global http.proxy "socks5h://${PROXY_HOST}:${PROXY_PORT}" 2>/dev/null || true

# ---- RustDesk 开发环境 ----
export VCPKG_ROOT="${VCPKG_ROOT:-$HOME/vcpkg}"
export LIBCLANG_PATH="${LIBCLANG_PATH:-/Library/Developer/CommandLineTools/usr/lib}"
export PATH="$HOME/flutter/bin:$HOME/.cargo/bin:$PATH"

# ---- Flutter 国内镜像 ----
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

# ---- 颜色 ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

# ---- 依赖检查 ----
check_deps() {
    command -v cargo   >/dev/null || fail "未找到 cargo，请安装 Rust: https://rustup.rs"
    command -v flutter >/dev/null || fail "未找到 flutter，请确认 ~/flutter/bin 在 PATH 中"
    [ -d "$VCPKG_ROOT/installed/arm64-osx/lib" ] || fail "vcpkg C 库未安装，运行: vcpkg install libvpx libyuv opus aom"
    [ -f "$LIBCLANG_PATH/libclang.dylib" ] || fail "libclang.dylib 未找到于 $LIBCLANG_PATH"
}

# ---- Xcode 检查 (仅 Flutter macOS 构建需要) ----
check_xcode() {
    local dev_dir
    dev_dir="$(xcode-select -p 2>/dev/null || true)"
    if [[ "$dev_dir" != *Xcode.app* ]]; then
        fail "Flutter macOS 构建需要完整版 Xcode，但当前开发者目录为:
    $dev_dir
请安装 Xcode 后执行:
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
    sudo xcodebuild -runFirstLaunch"
    fi
    xcrun --find xcodebuild >/dev/null 2>&1 || fail "xcodebuild 不可用，请确认 Xcode 已完整安装并执行:
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
}

# ---- 构建 Flutter 后端 ----
build_flutter_lib() {
    local mode="${1:-debug}"
    info "编译 Rust 后端 (flutter, $mode)..."
    if [ "$mode" = "release" ]; then
        cargo build --features flutter --lib --release
    else
        cargo build --features flutter --lib
        # Xcode pbxproj 引用的是 release 路径，debug 模式下创建符号链接
        mkdir -p target/release
        ln -sf ../debug/liblibrustdesk.dylib target/release/liblibrustdesk.dylib
    fi
    ok "Rust 后端编译完成"
}

# ---- 生成桥接代码 ----
gen_bridge() {
    info "生成 flutter_rust_bridge 桥接代码..."
    flutter_rust_bridge_codegen \
        --rust-input ./src/flutter_ffi.rs \
        --dart-output ./flutter/lib/generated_bridge.dart \
        --c-output ./flutter/macos/Runner/bridge_generated.h
    ok "桥接代码生成完成"
}

# ---- Flutter pub get ----
flutter_pub_get() {
    info "拉取 Flutter 依赖..."
    (cd flutter && flutter pub get)
    ok "Flutter 依赖就绪"
}

# ---- 启动 Flutter macOS ----
run_flutter_macos() {
    local mode="${1:-debug}"
    check_xcode
    flutter_pub_get
    build_flutter_lib "$mode"
    info "启动 Flutter macOS 桌面端..."
    if [ "$mode" = "release" ]; then
        (cd flutter && flutter run -d macos --release)
    else
        (cd flutter && flutter run -d macos)
    fi
}

# ---- Sciter 模式 ----
run_sciter() {
    local mode="${1:-debug}"
    info "Sciter 模式 ($mode)..."
    mkdir -p "target/$mode"
    if [ ! -f "target/$mode/libsciter.dylib" ]; then
        warn "libsciter.dylib 不存在，正在下载..."
        curl -L -o "target/$mode/libsciter.dylib" \
            "https://raw.githubusercontent.com/c-smile/sciter-sdk/master/bin.osx/libsciter.dylib"
    fi
    if [ "$mode" = "release" ]; then
        cargo run --release
    else
        cargo run
    fi
}

# ---- 主逻辑 ----
main() {
    local cmd="${1:-flutter}"
    check_deps

    case "$cmd" in
        flutter|run|"")
            run_flutter_macos debug
            ;;
        sciter)
            run_sciter debug
            ;;
        build)
            build_flutter_lib debug
            ;;
        bridge)
            gen_bridge
            ;;
        clean)
            warn "清理构建产物..."
            cargo clean
            build_flutter_lib debug
            ;;
        release)
            run_flutter_macos release
            ;;
        sciter-release)
            run_sciter release
            ;;
        *)
            echo "用法: ./dev.sh [flutter|sciter|build|bridge|clean|release]"
            echo ""
            echo "命令:"
            echo "  (无参数)       构建 + 启动 Flutter macOS (debug)"
            echo "  flutter        同上"
            echo "  sciter         Sciter 模式 (cargo run)"
            echo "  build          仅构建 Rust 后端"
            echo "  bridge         重新生成桥接代码"
            echo "  clean          清理并重新构建"
            echo "  release        Release 模式构建 + 运行"
            exit 1
            ;;
    esac
}

main "$@"
