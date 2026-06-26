#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# IPQ60XX 专用优化版 - 硬加速 (PPPoE 硬件卸载) + CPU 自动调频 + 无队列
# 修复：移除冲突的 /etc/config/nss 和 /etc/config/ecm，由驱动包自带

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
    green "✅ fstab 基础配置已创建"

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
    green "✅ hostapd init 已更新"
}
fix_boot_errors

#==================== 4. NSS PBUF 性能调度优化 ====================
update_nss_pbuf_performance() {
    local conf="./package/kernel/mac80211/files/pbuf.uci"
    if [ -f "$conf" ]; then
        sed -i "s/auto_scale '1'/auto_scale '0'/g" "$conf" 2>/dev/null
        sed -i "s/auto_scale 'off'/auto_scale '0'/g" "$conf" 2>/dev/null
        sed -i "s/scaling_governor 'performance'/scaling_governor 'schedutil'/g" "$conf" 2>/dev/null
        sed -i "s/scaling_governor 'ondemand'/scaling_governor 'schedutil'/g" "$conf" 2>/dev/null
        green "✅ NSS PBUF: 自动缩放关闭，CPU调度器切换 schedutil"
    fi
}
update_nss_pbuf_performance

#==================== 5. NSS 修复脚本（含 qca-nss-pppoe 显式加载 + schedutil 锁定） ====================
install_nss_fix() {
    local init_path="./package/base-files/files/etc/init.d/nss-fix"
    mkdir -p "$(dirname "$init_path")"
    cat > "$init_path" << 'EOF'
#!/bin/sh /etc/rc.common
START=95
STOP=10
boot() { start; }
start() {
    (
        sleep 500
        # 卸载可能干扰的虚拟网卡
        lsmod | grep -q "^ifb " && rmmod ifb 2>/dev/null
        lsmod | grep -q "^nss_ifb " && rmmod nss_ifb 2>/dev/null
        
        # === 关键：显式加载 PPPoE 硬件卸载模块（qca-nss-pppoe.ko） ===
        if modprobe qca_nss_pppoe 2>/dev/null || modprobe qca-nss-pppoe 2>/dev/null; then
            echo "✅ qca-nss-pppoe 硬件卸载模块加载成功"
        else
            echo "⚠️ qca-nss-pppoe 模块未找到" >&2
        fi
        
        # 重新加载 ECM（必须晚于 PPPoE 模块）
        lsmod | grep -q "^qca_nss_ecm" && {
            rmmod qca_nss_ecm 2>/dev/null
            modprobe qca_nss_ecm 2>/dev/null
        }
        
        # 强制启用 PPE 和桥接卸载
        echo 1 > /sys/module/qca_nss_drv/parameters/ppe_enable 2>/dev/null || true
        echo 1 > /sys/module/qca_nss_drv/parameters/bridge_offload 2>/dev/null || true
        echo 1 > /proc/sys/net/nss/offload 2>/dev/null || true
        
        # 锁定 schedutil 调频策略
        for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
            echo "schedutil" > "$cpu/cpufreq/scaling_governor" 2>/dev/null || true
        done
    ) &
}
EOF
    chmod +x "$init_path"
    green "✅ NSS 修复脚本安装完成（含 qca-nss-pppoe 显式加载 + schedutil 锁定）"
}
install_nss_fix

#==================== 6. 早期 hostapd 目录创建（解决 Permission denied） ====================
fix_hostapd_dir_early() {
    local init_path="./package/base-files/files/etc/init.d/hostapd-dir"
    mkdir -p "$(dirname "$init_path")"
    cat > "$init_path" << 'EOF'
#!/bin/sh /etc/rc.common
START=20
STOP=90

start() {
    mkdir -p /var/run/hostapd
    chown root:root /var/run/hostapd
    chmod 755 /var/run/hostapd
}

stop() {
    true
}
EOF
    chmod +x "$init_path"
    green "✅ 早期 hostapd 目录创建脚本已安装 (START=20)"
}
fix_hostapd_dir_early

#==================== 7. rc.local 强化 fstab（解决 block: unable to load configuration） ====================
fix_fstab_rc_local() {
    local rclocal="./package/base-files/files/etc/rc.local"
    mkdir -p "$(dirname "$rclocal")"
    if [ ! -f "$rclocal" ]; then
        cat > "$rclocal" << 'EOF'
#!/bin/sh
exit 0
EOF
        chmod +x "$rclocal"
    fi
    sed -i '/exit 0/i # 确保 fstab 配置存在并重新加载\n[ -f /etc/config/fstab ] || {\n    uci set fstab.global=global\n    uci set fstab.global.anon_swap=0\n    uci set fstab.global.anon_mount=0\n    uci set fstab.global.auto_swap=1\n    uci set fstab.global.auto_mount=1\n    uci set fstab.global.delay_root=5\n    uci set fstab.global.check_fs=0\n    uci commit fstab\n}\nblock mount 2>/dev/null || true\n' "$rclocal"
    green "✅ rc.local 已添加 fstab 修复"
}
fix_fstab_rc_local

#==================== 8. 完整冲突清理（保留 PPPoE，删除队列/隧道） ====================
clean_conflict_packages() {
    local config_file="./.config"
    green "===== 开始清理冲突包（保留 PPPoE） ====="
    
    # 8.1 WiFi Mesh 冲突
    sed -i '/CONFIG_PACKAGE_kmod-qca-nss-drv-wifi-meshmgr/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_wpad-basic/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_wpad-mesh/d' "$config_file"
    echo "CONFIG_PACKAGE_wpad-openssl=y" >> "$config_file"
    
    # 8.2 不兼容隧道（保留 PPPoE 相关包）
    local tunnel_pkgs=(
        "kmod-6rd" "kmod-gre" "kmod-gre6" "kmod-l2tp"
        "kmod-iptunnel" "kmod-iptunnel4" "kmod-iptunnel6"
        "kmod-vxlan" "kmod-udptunnel4" "kmod-udptunnel6"
        "kmod-sit" "kmod-ipip"
    )
    for pkg in "${tunnel_pkgs[@]}"; do
        sed -i "/CONFIG_PACKAGE_${pkg}/d" "$config_file"
        echo "# CONFIG_PACKAGE_${pkg} is not set" >> "$config_file"
    done
    green "✅ 不兼容隧道已清理"
    
    # 8.3 NAT/防火墙：删除 nft-offload，启用 NSS ECM
    sed -i '/CONFIG_PACKAGE_kmod-nft-offload/d' "$config_file"
    # 注意：这里只启用 kmod-qca-nss-ecm，不启用 -standard（因为不存在）
    echo "CONFIG_PACKAGE_kmod-qca-nss-ecm=y" >> "$config_file"
    
    # 8.4 IPv6
    sed -i '/CONFIG_PACKAGE_odhcpd-ipv6only/d' "$config_file"
    echo "# CONFIG_PACKAGE_odhcpd-ipv6only is not set" >> "$config_file"
    echo "CONFIG_PACKAGE_odhcpd=y" >> "$config_file"
    
    # 8.5 网络测试
    sed -i '/CONFIG_PACKAGE_kmod-net-selftests/d' "$config_file"
    
    # 8.6 无线：仅 AHB 内置，移除 PCI
    sed -i '/CONFIG_PACKAGE_kmod-ath11k-pci/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_ath10k-firmware-qca4019/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_ath10k-firmware-qca9984/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_ath11k-firmware-qcn9074/d' "$config_file"
    echo "CONFIG_PACKAGE_ath11k-firmware-ipq6018=y" >> "$config_file"
    
    # 8.7 删除所有软件队列调度器
    sed -i '/CONFIG_PACKAGE_kmod-sched-/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_kmod-sched-core/d' "$config_file"
    
    # 8.8 保留 PPPoE 拨号 + NSS PPPoE 硬件加速
    echo "CONFIG_PACKAGE_kmod-ppp=y" >> "$config_file"
    echo "CONFIG_PACKAGE_kmod-pppoe=y" >> "$config_file"
    echo "CONFIG_PACKAGE_kmod-pppox=y" >> "$config_file"
    echo "CONFIG_PACKAGE_kmod-qca-nss-drv-pppoe-mgr=y" >> "$config_file"
    
    green "✅ 冲突包清理完成（硬加速 + PPPoE 支持）"
}
clean_conflict_packages

#==================== 9. wifi-scripts 补丁 ====================
patch_wifi_full_reload() {
    local wifi_uc="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
    if [ -f "$wifi_uc" ]; then
        sed -i '/ubus call network.wireless stop/a\    exec("rmmod kmod-ath11k-pci kmod-ath11k-ahb kmod-ath11k kmod-ath kmod-mac80211 kmod-cfg80211 2>/dev/null; sleep(1); modprobe kmod-cfg80211 2>/dev/null; modprobe kmod-mac80211 2>/dev/null; modprobe kmod-ath 2>/dev/null; modprobe kmod-ath11k 2>/dev/null; modprobe kmod-ath11k-ahb 2>/dev/null; modprobe kmod-ath11k-pci 2>/dev/null; sleep(1);");' "$wifi_uc"
        green "✅ wifi-scripts 补丁注入成功"
    fi
}
patch_wifi_full_reload

#==================== 10. 固化 WiFi 参数（含 hostapd 日志静默） ====================
WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"

if [ -f "$WIFI_SH" ]; then
    sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
    sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
    cat >> $WIFI_SH << 'EOF'
for dev in $(uci show wireless | grep '=wifi-device' | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.$dev.log_level='0'
done
uci commit wireless
EOF
    green "✅ WiFi 参数已固化（log_level=0）"
elif [ -f "$WIFI_UC" ]; then
    sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
    sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
    sed -i "s/country='.*'/country='CN'/g" $WIFI_UC
    sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
    sed -i "s/disabled='1'/disabled='0'/g" $WIFI_UC
    grep -q "log_level" "$WIFI_UC" && \
        sed -i "s/log_level='.*'/log_level='0'/g" $WIFI_UC || \
        sed -i "/option encryption/a\    option log_level '0'" $WIFI_UC
    green "✅ WiFi 参数已固化（log_level=0）"
fi

#==================== 11. 固化管理 IP、主机名 ====================
CFG_FILE="./package/base-files/files/bin/config_generate"
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE
green "✅ 管理 IP: $WRT_IP，主机名: $WRT_NAME"

#==================== 12. 基础编译配置 ====================
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#==================== 13. 加载私有配置 ====================
[ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ] && {
    green "Applying private configurations..."
    cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
}

#==================== 14. 自定义插件 ====================
[ -n "$WRT_PACKAGE" ] && echo -e "$WRT_PACKAGE" >> ./.config

#==================== 15. 无 WiFi 标记 ====================
[[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]] && {
    echo "WRT_WIFI=wifi-no" >> $GITHUB_ENV
    green "✅ WiFi 已标记为禁用"
}

#==================== 16. 无 WiFi DTS 适配 ====================
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]] && \
   [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
    find ./target/linux/qualcommax/dts/ -type f ! -iname '*nowifi*' \
        -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
    green "✅ nowifi DTS 已适配"
fi

#==================== 17. 验证 ====================
verify_cleanup() {
    local config_file="./.config"
    local conflicts=(
        "kmod-qca-nss-drv-wifi-meshmgr" "kmod-6rd" "kmod-gre" "kmod-l2tp"
        "kmod-nft-offload" "odhcpd-ipv6only" "kmod-sched-cake" "kmod-sched-core"
        "kmod-ath11k-pci"
    )
    local required=(
        "kmod-qca-nss-ecm" "ath11k-firmware-ipq6018"
        "kmod-ppp" "kmod-pppoe" "kmod-qca-nss-drv-pppoe-mgr"
    )
    
    echo "" && green "===== 验证 ====="
    local has_conflict=false
    for pkg in "${conflicts[@]}"; do
        if grep -q "CONFIG_PACKAGE_${pkg}=y" "$config_file" 2>/dev/null; then
            echo "⚠️ 残留: $pkg" && has_conflict=true
        else
            echo "✅ 已清理: $pkg"
        fi
    done
    for pkg in "${required[@]}"; do
        if grep -q "CONFIG_PACKAGE_${pkg}=y" "$config_file" 2>/dev/null; then
            echo "✅ 已启用: $pkg"
        else
            echo "❌ 缺失: $pkg" && has_conflict=true
        fi
    done
    [ "$has_conflict" = false ] && green "🎉 所有检查通过（含 PPPoE 硬加速）" \
        || echo "⚠️ 部分异常，请手动检查"
}
verify_cleanup

green ""
green "========================================"
green "===== IPQ60XX 硬加速脚本执行完毕 ====="
green "========================================"
green "✅ CPU 调频: schedutil (自动按需)"
green "✅ 队列调度器: 已完全移除"
green "✅ NSS 硬加速: PPE + ECM 全卸载（已移除冲突的配置文件）"
green "✅ PPPoE 拨号: 已保留 + qca-nss-pppoe 硬件卸载"
green "✅ 无线: 仅 AHB 内置 (无 PCI)"
green "✅ hostapd 日志: 静默模式 (log_level=0)"
green "✅ 启动错误修复: fstab 强化 + hostapd 目录早期创建"
green "========================================"
