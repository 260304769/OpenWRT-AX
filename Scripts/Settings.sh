#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

# 定义绿色日志输出函数
green() {
    echo -e "\033[32m$1\033[0m"
}

#==================== 1. 清理在线升级、全局默认主题替换 ====================
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

#==================== 2. 清理固件内置多余编译时间戳 ====================
clean_version_timestamp() {
    local release="./package/base-files/files/etc/openwrt_release"
    sed -i 's|/ [0-9]\{9\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}||g' "$release" 2>/dev/null || true
    sed -i 's|-[0-9]\{8\}||g' "$release" 2>/dev/null || true
    sed -i 's| [0-9]\{9\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}||g' "$release" 2>/dev/null || true
    green "✅ 固件版本多余时间戳清理完毕"
}
clean_version_timestamp

#==================== 3. 修复启动错误（fstab / hostapd） ====================
fix_boot_errors() {
    green "===== 修复启动错误 ====="
    
    # 3.1 创建默认 fstab 配置
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

    # 3.2 修复 hostapd 权限
    mkdir -p ./package/network/services/hostapd/files
    cat > ./package/network/services/hostapd/files/hostapd.init << 'EOF'
#!/bin/sh /etc/rc.common
START=50
STOP=50

start_service() {
    mkdir -p /var/run/hostapd
    chown root:root /var/run/hostapd
    chmod 755 /var/run/hostapd
    /usr/sbin/hostapd -P /var/run/hostapd.pid -B /var/run/hostapd.conf
}

stop_service() {
    killall hostapd
}
EOF
    chmod +x ./package/network/services/hostapd/files/hostapd.init
    green "✅ hostapd 权限修复完成"
}
fix_boot_errors

#==================== 4. NSS PBUF 性能调度优化 ====================
update_nss_pbuf_performance() {
    local conf="./package/kernel/mac80211/files/pbuf.uci"
    if [ -f "$conf" ]; then
        sed -i "s/auto_scale '1'/auto_scale 'off'/g" "$conf" 2>/dev/null
        sed -i "s/scaling_governor 'performance'/scaling_governor 'schedutil'/g" "$conf" 2>/dev/null
        green "✅ NSS PBUF: 自动缩放关闭，CPU调度器切换 schedutil"
    fi
}
update_nss_pbuf_performance

#==================== 5. NSS 延迟卸载修复脚本 ====================
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
        sleep 500
        lsmod | grep -q "^ifb " && rmmod ifb 2>/dev/null
        lsmod | grep -q "qca_nss_ecm_offload" && rmmod qca-nss-ecm-offload 2>/dev/null
    ) &
}
EOF
    chmod +x "$init_path"
    green "✅ NSS延迟卸载脚本安装完成"
}
install_nss_fix

#==================== 6. 完整冲突清理（IPQ60XX 硬加速 / 无队列限速 / 无线无PCI） ====================
clean_conflict_packages() {
    local config_file="./.config"
    green "===== 开始清理冲突包（IPQ60XX 优化） ====="
    
    # 6.1 WiFi Mesh 冲突
    sed -i '/CONFIG_PACKAGE_kmod-qca-nss-drv-wifi-meshmgr/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_wpad-basic/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_wpad-mesh/d' "$config_file"
    echo "CONFIG_PACKAGE_wpad-openssl=y" >> "$config_file"
    
    # 6.2 隧道协议冲突（通用隧道 + ECM 编译依赖强制断开）
    local tunnel_pkgs=(
        "kmod-6rd"
        "kmod-gre"
        "kmod-gre6"
        "kmod-l2tp"
        "kmod-iptunnel"
        "kmod-iptunnel4"
        "kmod-iptunnel6"
        "kmod-vxlan"
        "kmod-udptunnel4"
        "kmod-udptunnel6"
        "kmod-sit"
        "kmod-ipip"
        # === ECM 硬编码依赖的隧道/PPP模块（必须断开） ===
        "kmod-ppp"
        "kmod-pppoe"
        "kmod-pptp"
        "kmod-pppox"
        "kmod-nat46"
    )
    for pkg in "${tunnel_pkgs[@]}"; do
        sed -i "/CONFIG_PACKAGE_${pkg}/d" "$config_file"
        echo "# CONFIG_PACKAGE_${pkg} is not set" >> "$config_file"
    done
    green "✅ 隧道协议及 ECM 隧道依赖已全部断开"
    
    # 6.3 NAT/防火墙冲突（强制 NSS ECM 硬加速，删除软件 offload）
    sed -i '/CONFIG_PACKAGE_kmod-nft-offload/d' "$config_file"
    echo "CONFIG_PACKAGE_kmod-qca-nss-ecm=y" >> "$config_file"
    echo "CONFIG_PACKAGE_kmod-qca-nss-ecm-standard=y" >> "$config_file"
    
    # 6.4 IPv6 冲突
    sed -i '/CONFIG_PACKAGE_odhcpd-ipv6only/d' "$config_file"
    echo "CONFIG_PACKAGE_odhcpd=y" >> "$config_file"
    
    # 6.5 网络测试冲突
    sed -i '/CONFIG_PACKAGE_kmod-net-selftests/d' "$config_file"
    
    # 6.6 IPQ6018 无线：仅保留 AHB 内置驱动，移除 PCI 驱动及无关固件
    sed -i '/CONFIG_PACKAGE_kmod-ath11k-pci/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_ath10k-firmware-qca4019/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_ath10k-firmware-qca9984/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_ath11k-firmware-qcn9074/d' "$config_file"
    echo "CONFIG_PACKAGE_ath11k-firmware-ipq6018=y" >> "$config_file"
    
    # 6.7 队列限速：删除所有软件调度器，完全依赖 NSS 硬件 QoS
    sed -i '/CONFIG_PACKAGE_kmod-sched-/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_kmod-sched-core/d' "$config_file"
    
    green "✅ 冲突包清理完成（IPQ60XX 硬加速 / 无队列限速 / 无线无PCI）"
}
clean_conflict_packages

#==================== 7. wifi-scripts 补丁（ath11k 完整重置） ====================
patch_wifi_full_reload() {
    local wifi_uc="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
    if [ -f "$wifi_uc" ]; then
        sed -i '/ubus call network.wireless stop/a\    exec("rmmod kmod-ath11k-pci kmod-ath11k-ahb kmod-ath11k kmod-ath kmod-mac80211 kmod-cfg80211 2>/dev/null; sleep(1); modprobe kmod-cfg80211 2>/dev/null; modprobe kmod-mac80211 2>/dev/null; modprobe kmod-ath 2>/dev/null; modprobe kmod-ath11k 2>/dev/null; modprobe kmod-ath11k-ahb 2>/dev/null; modprobe kmod-ath11k-pci 2>/dev/null; sleep(1);");' "$wifi_uc"
        green "✅ wifi-scripts 补丁注入成功（ath11k 完整重置）"
    fi
}
patch_wifi_full_reload

#==================== 8. 固化 WiFi 参数（含 hostapd 日志静默） ====================
WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"

if [ -f "$WIFI_SH" ]; then
    sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
    sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH

    cat >> $WIFI_SH << 'EOF'

# === 降低 hostapd 日志级别，避免连接/断开刷屏 ===
for dev in $(uci show wireless | grep '=wifi-device' | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.$dev.log_level='0'
done
uci commit wireless
EOF
    green "✅ WiFi 参数已固化（uci-defaults）并已设置 hostapd log_level=0"

elif [ -f "$WIFI_UC" ]; then
    sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
    sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
    sed -i "s/country='.*'/country='CN'/g" $WIFI_UC
    sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
    sed -i "s/disabled='1'/disabled='0'/g" $WIFI_UC

    if grep -q "log_level" "$WIFI_UC"; then
        sed -i "s/log_level='.*'/log_level='0'/g" $WIFI_UC
    else
        sed -i "/option encryption/a\    option log_level '0'" $WIFI_UC
    fi
    green "✅ WiFi 参数已固化（mac80211.uc）并已设置 hostapd log_level=0"
fi

#==================== 9. 固化默认管理 IP、主机名 ====================
CFG_FILE="./package/base-files/files/bin/config_generate"
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE
green "✅ 管理 IP: $WRT_IP，主机名: $WRT_NAME"

#==================== 10. 写入基础编译配置 ====================
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#==================== 11. 加载私有配置文件 ====================
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
    green "Applying private configurations from PRIVATE.txt..."
    cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

#==================== 12. 追加手动输入自定义插件参数 ====================
if [ -n "$WRT_PACKAGE" ]; then
    echo -e "$WRT_PACKAGE" >> ./.config
fi

#==================== 13. 标记无 WiFi 编译环境变量 ====================
if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
    echo "WRT_WIFI=wifi-no" >> $GITHUB_ENV
    green "✅ WiFi 已标记为禁用"
fi

#==================== 14. 高通 qualcommax 无 WiFi DTS 适配 ====================
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
    if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
        find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
        green "✅ qualcommax nowifi DTS 已适配"
    fi
fi

#==================== 15. 验证清理结果 ====================
verify_cleanup() {
    local config_file="./.config"
    local conflicts=(
        "kmod-qca-nss-drv-wifi-meshmgr"
        "kmod-6rd"
        "kmod-gre"
        "kmod-l2tp"
        "kmod-nft-offload"
        "odhcpd-ipv6only"
        "kmod-sched-cake"
        "kmod-sched-core"
        "kmod-ath11k-pci"
        # ECM 隧道依赖检查
        "kmod-ppp"
        "kmod-pppoe"
        "kmod-pptp"
        "kmod-pppox"
        "kmod-vxlan"
        "kmod-nat46"
    )
    
    echo ""
    green "===== 验证冲突包清理 ====="
    local has_conflict=false
    for pkg in "${conflicts[@]}"; do
        if grep -q "CONFIG_PACKAGE_${pkg}=y" "$config_file" 2>/dev/null; then
            echo "⚠️ 发现残留: $pkg"
            has_conflict=true
        else
            echo "✅ 已清理: $pkg"
        fi
    done
    
    # 确认必要包已存在
    local required=(
        "kmod-qca-nss-ecm"
        "ath11k-firmware-ipq6018"
    )
    for pkg in "${required[@]}"; do
        if grep -q "CONFIG_PACKAGE_${pkg}=y" "$config_file" 2>/dev/null; then
            echo "✅ 已启用: $pkg"
        else
            echo "❌ 缺失: $pkg"
            has_conflict=true
        fi
    done
    
    if [ "$has_conflict" = false ]; then
        green "🎉 所有冲突包已清理完毕，IPQ60XX 优化全部生效"
    else
        echo "⚠️ 部分项目异常，请手动检查"
    fi
}
verify_cleanup

green ""
green "========================================"
green "===== 全部预配置脚本执行完毕 ====="
green "========================================"
green "✅ 已修复：fstab / hostapd / 时间戳"
green "✅ 已优化：NSS PBUF / 延迟卸载 / IPQ60XX硬加速+无队列限速+无线无PCI"
green "✅ 已配置：WiFi SSID/密码/地区/加密 / 主机名/IP"
green "✅ hostapd 日志已默认设为静默（仅输出错误），不再刷屏"
green "✅ ECM 隧道编译依赖已断开，OFFLOAD 将正常生效"
green "========================================"
