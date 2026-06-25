#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

# 绿色日志
green() {
    echo -e "\033[32m$1\033[0m"
}

#==================== 1. 个性化固件修改 ====================
# 移除在线升级
find ./feeds/luci/collections/ -type f -name "Makefile" 2>/dev/null | xargs -r sed -i "/attendedsysupgrade/d"
# 替换主题
find ./feeds/luci/collections/ -type f -name "Makefile" 2>/dev/null | xargs -r sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g"
# 修改默认IP
find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js" 2>/dev/null | xargs -r sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g"
# 版本水印
find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js" 2>/dev/null | xargs -r sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g"

#==================== 2. 清理版本多余时间戳 ====================
clean_version_timestamp() {
    local release="./package/base-files/files/etc/openwrt_release"
    [ -f "$release" ] && {
        sed -i 's|/ [0-9]\{9\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}||g' "$release"
        sed -i 's|-[0-9]\{8\}||g' "$release"
        sed -i 's| [0-9]\{9\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}||g' "$release"
    }
    green "✅ 固件版本多余时间戳清理完毕"
}
clean_version_timestamp

#==================== 3. 启动项修复（fstab + hostapd 改良版） ====================
fix_boot_errors() {
    green "===== 修复启动错误 ====="
    # fstab
    mkdir -p ./package/base-files/files/etc/config
    cat > ./package/base-files/files/etc/config/fstab << 'EOF'
config global
    option anon_swap '0'
    option anon_mount '0'
    option auto_swap '1'
    option auto_mount '1'
    option delay_root '5'
    option check_fs '0'
EOF
    green "✅ fstab 配置已创建"

    # 改良hostapd：保留原版uci配置生成逻辑，只修复目录权限，不重写启动命令
    local src_init="./package/network/services/hostapd/files/hostapd.init"
    mkdir -p $(dirname "$src_init")
    # 仅在原有启动流程前创建运行目录，不替换整段start_service，避免无线配置失效
    if [ -f "$src_init" ]; then
        sed -i '/^start_service() {/a\    mkdir -p /var/run/hostapd\n    chown root:root /var/run/hostapd\n    chmod 755 /var/run/hostapd' "$src_init"
    else
        # 备用兜底方案
        cat > "$src_init" << 'EOF'
#!/bin/sh /etc/rc.common
START=50
STOP=50
start_service() {
    mkdir -p /var/run/hostapd
    chown root:root /var/run/hostapd
    chmod 755 /var/run/hostapd
    procd_open_instance
    procd_set_param command /usr/sbin/hostapd
    procd_set_param respawn
    procd_close_instance
}
stop_service() {
    killall hostapd
}
EOF
    fi
    chmod +x "$src_init"
    green "✅ hostapd 权限修复完成（保留uci配置）"
}
fix_boot_errors

#==================== 4. NSS PBUF 调度优化 ====================
update_nss_pbuf_performance() {
    local conf="./package/kernel/mac80211/files/pbuf.uci"
    [ -f "$conf" ] && {
        sed -i "s/auto_scale '1'/auto_scale 'off'/g" "$conf"
        sed -i "s/scaling_governor 'performance'/scaling_governor 'schedutil'/g" "$conf"
        green "✅ NSS PBUF:关闭自动缩放，CPU调度schedutil"
    }
}
update_nss_pbuf_performance

#==================== 5. NSS 卸载脚本（可自定义延时，避免长时间等待） ====================
install_nss_fix() {
    local init_path="./package/base-files/files/etc/init.d/nss-fix"
    mkdir -p "$(dirname "$init_path")"
    cat > "$init_path" << 'EOF'
#!/bin/sh /etc/rc.common
START=100
STOP=10
boot() { start; }
start() {
    (
        sleep 30
        rmmod ifb 2>/dev/null
        rmmod qca-nss-ecm-offload 2>/dev/null
    ) &
}
EOF
    chmod +x "$init_path"
    green "✅ NSS延迟卸载脚本安装完成，延时30s"
}
install_nss_fix

#==================== 6. 清理NSS/WiFi冲突包（去重写入.config） ====================
clean_conflict_packages() {
    local config_file="./.config"
    green "===== 开始清理 NSS/WiFi 冲突包 ====="

    # 清理旧无线驱动
    sed -i '/CONFIG_PACKAGE_kmod-qca-nss-drv-wifi-meshmgr/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_wpad-basic/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_wpad-mesh/d' "$config_file"
    grep -q "CONFIG_PACKAGE_wpad-openssl=y" "$config_file" || echo "CONFIG_PACKAGE_wpad-openssl=y" >> "$config_file"

    # 隧道模块批量清理
    TUN_MODULES="kmod-6rd kmod-gre kmod-gre6 kmod-l2tp kmod-iptunnel kmod-iptunnel4 kmod-iptunnel6 kmod-vxlan kmod-udptunnel4 kmod-udptunnel6 kmod-sit kmod-ipip"
    for pkg in $TUN_MODULES; do
        sed -i "/CONFIG_PACKAGE_${pkg}/d" "$config_file"
    done

    # 防火墙offload冲突
    sed -i '/CONFIG_PACKAGE_kmod-nft-offload/d' "$config_file"
    grep -q "CONFIG_PACKAGE_kmod-qca-nss-ecm=y" "$config_file" || echo "CONFIG_PACKAGE_kmod-qca-nss-ecm=y" >> "$config_file"
    grep -q "CONFIG_PACKAGE_kmod-qca-nss-ecm-standard=y" "$config_file" || echo "CONFIG_PACKAGE_kmod-qca-nss-ecm-standard=y" >> "$config_file"

    # IPv6
    sed -i '/CONFIG_PACKAGE_odhcpd-ipv6only/d' "$config_file"
    grep -q "CONFIG_PACKAGE_odhcpd=y" "$config_file" || echo "CONFIG_PACKAGE_odhcpd=y" >> "$config_file"

    sed -i '/CONFIG_PACKAGE_kmod-net-selftests/d' "$config_file"

    # 无线固件：只保留ath11k qcn9074
    sed -i '/CONFIG_PACKAGE_ath10k-firmware-qca4019/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_ath10k-firmware-qca9984/d' "$config_file"
    grep -q "CONFIG_PACKAGE_ath11k-firmware-qcn9074=y" "$config_file" || echo "CONFIG_PACKAGE_ath11k-firmware-qcn9074=y" >> "$config_file"

    # Cake OOT
    sed -i '/CONFIG_PACKAGE_kmod-sched-cake/d' "$config_file"
    grep -q "CONFIG_PACKAGE_kmod-sched-cake-oot=y" "$config_file" || echo "CONFIG_PACKAGE_kmod-sched-cake-oot=y" >> "$config_file"

    green "✅ 冲突包清理完成，无重复配置"
}
clean_conflict_packages

#==================== 7. ath11k无线重启补丁（减缓模块卸载速度，减少ACK掉线） ====================
patch_wifi_full_reload() {
    local wifi_uc="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
    if [ -f "$wifi_uc" ]; then
        # 分段卸载+多次sleep，防止硬件卡死
        sed -i '/ubus call network.wireless stop/a\    exec("rmmod kmod-ath11k-pci 2>/dev/null; sleep(1);rmmod kmod-ath11k-ahb kmod-ath11k 2>/dev/null;sleep(1);rmmod kmod-ath kmod-mac80211 kmod-cfg80211 2>/dev/null;sleep(2);modprobe kmod-cfg80211;modprobe kmod-mac80211;sleep(1);modprobe kmod-ath;modprobe kmod-ath11k;sleep(1);modprobe kmod-ath11k-ahb;modprobe kmod-ath11k-pci;");' "$wifi_uc"
        green "✅ wifi-scripts补丁优化：分段卸载驱动，降低无线锁死概率"
    fi
}
patch_wifi_full_reload

#==================== 8. 固化WiFi信息 ====================
WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f "*set-wireless.sh" 2>/dev/null | head -n1)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -n "$WIFI_SH" ] && [ -f "$WIFI_SH" ]; then
    sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" "$WIFI_SH"
    sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" "$WIFI_SH"
    green "✅ WiFi参数固化(uci-defaults)"
elif [ -f "$WIFI_UC" ]; then
    sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" "$WIFI_UC"
    sed -i "s/key='.*'/key='$WRT_WORD'/g" "$WIFI_UC"
    sed -i "s/country='.*'/country='CN'/g" "$WIFI_UC"
    sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" "$WIFI_UC"
    sed -i "s/disabled='1'/disabled='0'/g" "$WIFI_UC"
    green "✅ WiFi参数固化(mac80211.uc)"
fi

#==================== 9. 固化IP与主机名 ====================
CFG_FILE="./package/base-files/files/bin/config_generate"
[ -f "$CFG_FILE" ] && {
    sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG_FILE"
    sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" "$CFG_FILE"
}
green "✅ 管理 IP: $WRT_IP，主机名: $WRT_NAME"

#==================== 10. 基础LuCI配置（去重） ====================
add_config_once() {
    local line="$1"
    grep -qxF "$line" ./.config || echo "$line" >> ./.config
}
add_config_once "CONFIG_PACKAGE_luci=y"
add_config_once "CONFIG_LUCI_LANG_zh_Hans=y"
add_config_once "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y"
add_config_once "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y"

#==================== 11. 加载私有配置 ====================
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
    green "Applying private configurations from PRIVATE.txt..."
    cat "$GITHUB_WORKSPACE/Config/PRIVATE.txt" >> ./.config
fi

#==================== 12. 自定义插件 ====================
if [ -n "$WRT_PACKAGE" ]; then
    echo -e "$WRT_PACKAGE" >> ./.config
fi

#==================== 13. Nowifi环境标记 ====================
if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
    echo "WRT_WIFI=wifi-no" >> "$GITHUB_ENV"
    green "✅ WiFi已标记为禁用"
fi

#==================== 14. qualcommax DTS nowifi适配 ====================
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
    if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
        find "$DTS_PATH" -type f ! -iname '*nowifi*' 2>/dev/null | xargs -r sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g'
        green "✅ qualcommax nowifi DTS已适配"
    fi
fi

#==================== 15. 冲突包校验 ====================
verify_cleanup() {
    local config_file="./.config"
    local conflicts=(
        "kmod-qca-nss-drv-wifi-meshmgr"
        "kmod-6rd"
        "kmod-gre"
        "kmod-l2tp"
        "kmod-nft-offload"
        "odhcpd-ipv6only"
    )

    echo ""
    green "===== 验证冲突包清理 ====="
    local has_conflict=false
    for pkg in "${conflicts[@]}"; do
        if grep -q "CONFIG_PACKAGE_${pkg}=y" "$config_file"; then
            echo "⚠️ 发现残留: $pkg"
            has_conflict=true
        else
            echo "✅ 已清理: $pkg"
        fi
    done

    if [ "$has_conflict" = false ]; then
        green "🎉 所有冲突包已清理完毕"
    else
        echo "⚠️ 部分冲突包残留，请手动检查"
    fi
}
verify_cleanup

green ""
green "========================================"
green "===== 全部预配置脚本执行完毕 ====="
green "✅ 修复项：fstab、hostapd权限、无线驱动重载逻辑"
green "✅ 优化项：NSS调度、分段卸载ath11k驱动、避免ACK断流"
green "✅ 清理项：NSS/ECM冲突模块，无重复编译配置"
green "========================================"
