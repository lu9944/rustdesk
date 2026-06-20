#!/bin/bash
set -euo pipefail

# ============================================================
# RustDesk 一键多平台构建脚本
#
# 用法:
#   ./build-all.sh              构建 macOS Universal（本地）
#   ./build-all.sh --linux      额外通过 Docker 构建 Linux x64 + ARM64
#   ./build-all.sh --ci         通过 GitHub Actions 构建全部 4 个目标
#   ./build-all.sh --all        macOS 本地 + Docker Linux + CI 触发 Windows
#
# 产物输出: dist/
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
DIST_DIR="$SCRIPT_DIR/dist"
mkdir -p "$DIST_DIR"

# ---- 颜色 ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

# ---- 参数解析 ----
BUILD_MACOS=true
BUILD_LINUX=false
BUILD_CI=false

for arg in "$@"; do
    case "$arg" in
        --linux)   BUILD_LINUX=true ;;
        --ci)      BUILD_CI=true; BUILD_MACOS=false ;;
        --all)     BUILD_LINUX=true; BUILD_CI=true ;;
        --macos)   BUILD_MACOS=true ;;
        --help|-h)
            echo "用法: ./build-all.sh [--macos|--linux|--ci|--all]"
            echo ""
            echo "选项:"
            echo "  (无参数)   仅构建 macOS Universal（本地）"
            echo "  --macos    同上"
            echo "  --linux    额外通过 Docker 构建 Linux x64 + ARM64"
            echo "  --ci       通过 GitHub Actions 构建全部 4 个目标"
            echo "  --all      macOS 本地 + Docker Linux + CI 触发其余"
            exit 0
            ;;
        *) warn "未知参数: $arg" ;;
    esac
done

# ---- 环境变量 ----
export VCPKG_ROOT="${VCPKG_ROOT:-$HOME/vcpkg}"
export LIBCLANG_PATH="${LIBCLANG_PATH:-/Library/Developer/CommandLineTools/usr/lib}"
export PATH="$HOME/flutter/bin:$HOME/.cargo/bin:$PATH"
VERSION=$(grep '^version' Cargo.toml | head -1 | sed 's/version.*=.*"\(.*\)".*/\1/')
info "版本: $VERSION"

# ============================================================
# macOS Universal 构建（本地原生）
# ============================================================
build_macos() {
    info "========== 构建 macOS Universal =========="

    command -v cargo   >/dev/null || fail "未找到 cargo"
    command -v flutter >/dev/null || fail "未找到 flutter"
    [ -x "$VCPKG_ROOT/vcpkg" ]    || fail "未找到 vcpkg，请设置 VCPKG_ROOT"

    # 1. 确保 Rust target 已安装
    info "安装 Rust target..."
    rustup target add aarch64-apple-darwin x86_64-apple-darwin

    # 1b. 确保 vcpkg 双架构 C 库已安装
    #     在 $VCPKG_ROOT 下执行以避免项目的 vcpkg.json 触发 manifest 模式
    #     x64-osx 构建需要系统级 cmake/ninja/nasm（vcpkg 自带的版本太旧）
    ARCH=$(uname -m)
    for triplet in arm64-osx x64-osx; do
        if [ -d "$VCPKG_ROOT/installed/$triplet/lib" ]; then
            ok "vcpkg $triplet 已就绪"
            continue
        fi
        info "安装 vcpkg $triplet (libvpx libyuv opus aom)..."
        if [ "$triplet" = "x64-osx" ]; then
            # 确保 nasm / ninja / cmake 是系统版本（vcpkg 下载的太旧）
            command -v nasm >/dev/null 2>&1 || brew install nasm
            command -v ninja >/dev/null 2>&1 || brew install ninja
            # macOS clang 原生支持 x86_64 交叉编译，不需要 Rosetta
            # VCPKG_FORCE_SYSTEM_BINARIES=1 让 vcpkg 用系统的 cmake/ninja
            (cd "$VCPKG_ROOT" && VCPKG_FORCE_SYSTEM_BINARIES=1 ./vcpkg install libvpx libyuv opus aom --triplet "$triplet")
        else
            (cd "$VCPKG_ROOT" && ./vcpkg install libvpx libyuv opus aom --triplet "$triplet")
        fi
    done

    # 2. 构建 Rust 库（arm64 + x86_64）
    info "编译 Rust 库 (aarch64-apple-darwin)..."
    cargo build --features flutter --lib --release --target aarch64-apple-darwin

    info "编译 Rust 库 (x86_64-apple-darwin)..."
    cargo build --features flutter --lib --release --target x86_64-apple-darwin

    # 3. 合并为 Universal Binary
    info "合并 Universal Binary (lipo)..."
    mkdir -p target/release
    lipo -create \
        target/aarch64-apple-darwin/release/liblibrustdesk.dylib \
        target/x86_64-apple-darwin/release/liblibrustdesk.dylib \
        -output target/release/liblibrustdesk.dylib
    ok "Universal Rust 库构建完成"

    # 4. 构建 Flutter macOS
    info "构建 Flutter macOS..."
    (cd flutter && flutter build macos --release)
    if [ $? -ne 0 ]; then fail "Flutter macOS 构建失败"; fi

    # 5. 拷贝产物
    APP_PATH="flutter/build/macos/Build/Products/Release/rustdesk.app"
    if [ -d "$APP_PATH" ]; then
        cp -R "$APP_PATH" "$DIST_DIR/"
        info "创建 DMG..."
        hdiutil create -volname "RustDesk" -srcfolder "$APP_PATH" \
            -ov -format UDZO "$DIST_DIR/rustdesk-$VERSION-universal.dmg"
        ok "macOS 产物: dist/rustdesk-$VERSION-universal.dmg"
    else
        warn "未找到 .app，跳过 DMG 打包"
    fi
}

# ============================================================
# Linux 构建（通过 Docker）
# ============================================================
build_linux() {
    info "========== 通过 Docker 构建 Linux =========="
    command -v docker >/dev/null || fail "未找到 docker，请安装 Docker Desktop"

    # 构建带 Flutter 的 Docker 镜像（首次会慢，后续走缓存）
    info "构建 Docker 镜像（包含 Rust + Flutter + vcpkg）..."
    docker build -t rustdesk-linux-builder -f docker/Dockerfile.linux .

    # ---- x86_64 ----
    info "构建 Linux x86_64 (.deb)..."
    docker run --rm \
        -v "$SCRIPT_DIR:/home/user/rustdesk" \
        -v "$DIST_DIR:/dist" \
        -e TARGET=x86_64-unknown-linux-gnu \
        -e DEB_ARCH=amd64 \
        rustdesk-linux-builder \
        bash -c 'cd /home/user/rustdesk && bash docker/build-linux.sh && cp *.deb /dist/'

    # ---- aarch64 ----
    info "构建 Linux ARM64 (.deb)..."
    docker run --rm --platform linux/arm64 \
        -v "$SCRIPT_DIR:/home/user/rustdesk" \
        -v "$DIST_DIR:/dist" \
        -e TARGET=aarch64-unknown-linux-gnu \
        -e DEB_ARCH=arm64 \
        rustdesk-linux-builder \
        bash -c 'cd /home/user/rustdesk && bash docker/build-linux.sh && cp *.deb /dist/'

    ok "Linux 产物: dist/*.deb"
}

# ============================================================
# GitHub Actions CI（全部 4 个目标）
# ============================================================
trigger_ci() {
    info "========== 通过 GitHub Actions 构建全部目标 =========="
    command -v gh >/dev/null || fail "未找到 gh CLI，请安装: brew install gh"
    gh auth status >/dev/null 2>&1 || fail "请先运行: gh auth login"

    # 确保有远程仓库
    if ! git remote get-url origin >/dev/null 2>&1; then
        fail "未找到 git remote origin，请先关联 GitHub 仓库"
    fi

    # 推送当前代码
    info "推送当前代码到 GitHub..."
    BRANCH=$(git branch --show-current)
    git push -u origin "$BRANCH" || warn "推送失败（可能有未提交的更改）"

    # 触发 workflow
    info "触发 build-all workflow..."
    gh workflow run build-all.yml --ref "$BRANCH" || fail "触发 workflow 失败"

    # 等待完成并下载
    info "等待 workflow 完成（这可能需要 20-40 分钟）..."
    sleep 5
    RUN_ID=$(gh run list --workflow=build-all.yml --limit=1 --json databaseId -q '.[0].databaseId')
    gh run watch "$RUN_ID" || fail "workflow 执行失败"

    info "下载产物..."
    gh run download "$RUN_ID" --dir "$DIST_DIR/ci"
    ok "CI 产物已下载到: dist/ci/"
}

# ============================================================
# Windows 说明
# ============================================================
print_windows_notice() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW} Windows 构建说明${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo "Flutter 无法从 macOS 交叉编译 Windows 应用。"
    echo "请选择以下方式之一："
    echo ""
    echo "  1. GitHub Actions（推荐）："
    echo "     ./build-all.sh --ci"
    echo ""
    echo "  2. Windows 机器上构建："
    echo "     git clone <repo> && cd rustdesk"
    echo "     python3 build.py --flutter --hwcodec"
    echo ""
    echo "  3. Windows 虚拟机（Parallels/UTM）："
    echo "     在 VM 中安装 Rust + Flutter + Visual Studio"
    echo ""
}

# ============================================================
# 主逻辑
# ============================================================
info "产物目录: $DIST_DIR"

if $BUILD_MACOS; then
    build_macos
fi

if $BUILD_LINUX; then
    build_linux
fi

if $BUILD_CI; then
    trigger_ci
fi

if ! $BUILD_CI; then
    print_windows_notice
fi

echo ""
ok "构建完成！产物在: $DIST_DIR/"
ls -lh "$DIST_DIR/" 2>/dev/null || true
