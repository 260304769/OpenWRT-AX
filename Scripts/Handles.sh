#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

# 工作目录统一：openwrt源码根目录
OPENWRT_ROOT="$PWD"
# 自定义插件包路径（仓库根目录wrt/package）
PKG_PATH="$GITHUB_WORKSPACE/wrt/package/"

echo -e "\n==================== Start Custom DIY Script ====================\n"

# ===================== 1. 固化 Argon 主题默认配置（主色 #5e72e4） =====================
if ls ${PKG_PATH} | grep -q "luci-theme-argon"; then
    echo "[DIY] 开始固化 Argon 主题配色/壁纸/字体，主色调 #5e72e4"
    cd ${PKG_PATH}/luci-theme-argon || exit 0
    sed -i "s/primary '.*'/primary '#5e72e4'/; s/'0.2'/'0.5'/; s/'none'/'bing'/; s/'600'/'normal'/" ./luci-app-argon-config/root/etc/config/argon
    echo "[DIY] Argon 主题参数固化完成"
    cd ${OPENWRT_ROOT}
fi

# ===================== 2. 强制 Aurora 下拉导航菜单 =====================
if ls ${PKG_PATH} | grep -q "luci-app-aurora-config"; then
    echo -e "\n[DIY] 设置 Aurora 默认下拉菜单"
    cd ${PKG_PATH}/luci-app-aurora-config || exit 0
    find ./root/usr/share/aurora/ -type f -name "*.template" -exec sed -i "s/nav_type '.*'/nav_type 'dropdown'/g" {} \;
    echo "[DIY] Aurora 菜单样式固化完成"
    cd ${OPENWRT_ROOT}
fi

# ===================== 3. 修复 Rust 编译 LLVM 内存溢出 =====================
RUST_FILE=$(find ${OPENWRT_ROOT}/feeds/packages/ -maxdepth 3 -type f -path "*/rust/Makefile")
if [ -f "${RUST_FILE}" ]; then
    echo -e "\n[DIY] 关闭 Rust CI LLVM 避免编译失败"
    sed -i 's/ci-llvm=true/ci-llvm=false/g' "${RUST_FILE}"
    echo "[DIY] Rust 编译修复完成"
fi

echo -e "\n==================== DIY Script All Tasks Finished ====================\n"
