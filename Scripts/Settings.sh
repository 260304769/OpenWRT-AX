#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# IPQ60XX 专用优化版 - 硬加速 + IPv6自动获取 + 全锥NAT
# 最终完整版：隧道保留、防重复、无线安全重启、CGNAT优化

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

#==================== 3. 修复启动错误（fstab / hostapd / MTU / 防火墙 / IPv6） ====================
fix_boot_errors() {
    green "===== 修复启动错误 ====="
    
    # 3.1 fstab 基础配置
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

    # 3.2 hostapd 运行目录补丁
    local hostapd_init="./package/network/services/hostapd/files/hostapd.init"
    if [ -f "$hostapd_init" ]; then
        if ! grep -q "mkdir -p /var/run/hostapd" "$hostapd_init"; then
            sed -i '/start_service()/a\    mkdir -p /var/run/hostapd\n    chmod 755 /var/run/hostapd' "$hostapd_init"
            green "✅ hostapd init 已补丁"
        else
            green "ℹ️ hostapd init 已包含目录创建"
        fi
    else
        mkdir -p ./package/base-files/files/etc
        if [ ! -f ./package/base-files/files/etc/rc.local ]; then
            echo -e "#!/bin/sh\nexit 0" > ./package/base-files/files/etc/rc.local
            chmod +x ./package/base-files/files/etc/rc.local
        fi
        if ! grep -q "mkdir -p /var/run/hostapd" ./package/base-files/files/etc/rc.local; then
            sed -i '/exit 0/i mkdir -p /var/run/hostapd\nchmod 755 /var/run/hostapd\n' ./package/base-files/files/etc/rc.local
            green "✅ hostapd 运行目录已加入 rc.local 兜底"
        fi
    fi

    # 3.3 PPPoE MTU 优化
    mkdir -p ./package/base-files/files/etc/uci-defaults
    cat > ./package/base-files/files/etc/uci-defaults/99-pppoe-mtu << 'EOF'
#!/bin/sh
uci -q get network.wan.mtu || {
    uci set network.wan.mtu='1492'
    uci commit network
}
exit 0
EOF
    chmod +x ./package/base-files/files/etc/uci-defaults/99-pppoe-mtu
    green "✅ PPPoE MTU 1492 已预设"

    # 3.4 防火墙硬件加速开关
    cat > ./package/base-files/files/etc/uci-defaults/96-firewall-nss << 'EOF'
#!/bin/sh
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].nss_offload='1'
uci commit firewall
exit 0
EOF
    chmod +x ./package/base-files/files/etc/uci-defaults/96-firewall-nss
    green "✅ 防火墙硬件加速开关已设置"

    # 3.5 IPv6 自动获取（新增）
    cat > ./package/base-files/files/etc/uci-defaults/94-ipv6-auto << 'EOF'
#!/bin/sh
uci set network.wan.ipv6='auto'
uci commit network
exit 0
EOF
    chmod +x ./package/base-files/files/etc/uci-defaults/94-ipv6-auto
    green "✅ IPv6 自动获取已启用 (network.wan.ipv6=auto)"
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

#==================== 5. NSS 修复脚本（START=20，无ECM重载） ====================
install_nss_fix() {
    local init_path="./package/base-files/files/etc/init.d/nss-fix"
    mkdir -p "$(dirname "$init_path")"
    cat > "$init_path" << 'EOF'
#!/bin/sh /etc/rc.common
START=20
STOP=10
boot() { start; }
start() {
    (
        mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null

        modprobe qca_nss_pppoe 2>/dev/null && logger -t nss-fix "PPPoE硬件卸载模块加载成功"

        echo 1 > /sys/module/qca_nss_drv/parameters/ppe_enable 2>/dev/null || true
        echo 1 > /sys/module/qca_nss_drv/parameters/bridge_offload 2>/dev/null || true
        echo 1 > /proc/sys/net/nss/offload 2>/dev/null || true

        for queue in /sys/class/net/wan/queues/rx-*; do
            [ -d "$queue" ] || continue
            echo 4096 > "$queue/rps_flow_cnt" 2>/dev/null || true
        done
        echo 1 > /sys/kernel/debug/qca-nss-drv/rx_aggr/enable 2>/dev/null || true

        for dev in /sys/block/mmcblk[0-9]* /sys/block/sd[a-z]*; do
            [ -d "$dev" ] || continue
            [ -f "$dev/queue/nr_requests" ] && echo 256 > "$dev/queue/nr_requests" 2>/dev/null
            [ -f "$dev/queue/read_ahead_kb" ] && echo 1024 > "$dev/queue/read_ahead_kb" 2>/dev/null
        done
        for dev in /sys/devices/virtual/block/*/queue/zone_append_max_bytes; do
            [ -f "$dev" ] && echo 131072 > "$dev" 2>/dev/null
        done

        for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
            echo "schedutil" > "$cpu/cpufreq/scaling_governor" 2>/dev/null || true
        done

        logger -t nss-fix "NSS硬件加速优化完成"
    ) &
}
EOF
    chmod +x "$init_path"
    green "✅ NSS 修复脚本安装完成（START=20）"
}
install_nss_fix

#==================== 6. rc.local 强化 fstab 和 sysctl 生效 ====================
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
    if ! grep -q "block mount" "$rclocal"; then
        sed -i '/exit 0/i # 确保 fstab 配置存在并重新加载\n[ -f /etc/config/fstab ] || {\n    uci set fstab.global=global\n    uci set fstab.global.anon_swap=0\n    uci set fstab.global.anon_mount=0\n    uci set fstab.global.auto_swap=1\n    uci set fstab.global.auto_mount=1\n    uci set fstab.global.delay_root=5\n    uci set fstab.global.check_fs=0\n    uci commit fstab\n}\nblock mount 2>/dev/null || true\n# 应用 sysctl 参数\n[ -f /etc/sysctl.conf ] && sysctl -p >/dev/null 2>&1\n' "$rclocal"
        green "✅ rc.local 已添加 fstab 修复和 sysctl 生效"
    else
        green "ℹ️ rc.local 已包含修复"
    fi
}
fix_fstab_rc_local

#==================== 7. 系统参数优化（连接跟踪） ====================
add_sysctl_tweaks() {
    local sysctl_conf="./package/base-files/files/etc/sysctl.conf"
    mkdir -p "$(dirname "$sysctl_conf")"
    if ! grep -q "nf_conntrack_max" "$sysctl_conf" 2>/dev/null; then
        cat >> "$sysctl_conf" << 'EOF'
# NSS ECM 加速优化：调整超时适应高延迟网络
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_max = 65536
EOF
        green "✅ 连接跟踪优化参数已内置（syn_recv=60秒）"
    else
        green "ℹ️ sysctl.conf 已包含连接跟踪优化"
    fi
}
add_sysctl_tweaks

#==================== 8. PPPoE 防火墙放行规则 ====================
fix_pppoe_firewall() {
    mkdir -p ./package/base-files/files/etc/uci-defaults
    cat > ./package/base-files/files/etc/uci-defaults/97-pppoe-firewall << 'EOF'
#!/bin/sh
if ! uci -q get firewall.@rule[-1].name | grep -q "pppoe_allow"; then
    uci add firewall rule
    uci set firewall.@rule[-1].name='pppoe_allow'
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].proto='all'
    uci set firewall.@rule[-1].ethertype='0x8863'
    uci set firewall.@rule[-1].target='ACCEPT'
    
    uci add firewall rule
    uci set firewall.@rule[-1].name='pppoe_session_allow'
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].proto='all'
    uci set firewall.@rule[-1].ethertype='0x8864'
    uci set firewall.@rule[-1].target='ACCEPT'
    
    uci commit firewall
fi
exit 0
EOF
    chmod +x ./package/base-files/files/etc/uci-defaults/97-pppoe-firewall
    green "✅ PPPoE 防火墙放行规则已固化"
}
fix_pppoe_firewall

#==================== 9. NTP国内源 + DNS域名白名单 ====================
add_ntp_dns_whitelist() {
    mkdir -p ./package/base-files/files/etc/uci-defaults
    cat > ./package/base-files/files/etc/uci-defaults/98-ntp-dns << 'EOF'
#!/bin/sh
uci -q set system.ntp.enabled='1'
uci -q set system.ntp.enable_server='0'
uci -q delete system.ntp.server
uci -q add_list system.ntp.server='cn.ntp.org.cn'
uci commit system

if ! uci -q get dhcp.@dnsmasq[0].rebind_domain | grep -q 'cn.ntp.org.cn'; then
    uci -q add_list dhcp.@dnsmasq[0].rebind_domain='cn.ntp.org.cn'
    uci commit dhcp
fi
exit 0
EOF
    chmod +x ./package/base-files/files/etc/uci-defaults/98-ntp-dns
    green "✅ NTP 国内源和 DNS 白名单已预设"
}
add_ntp_dns_whitelist

#==================== 10. 工具函数：精确设置 .config 包配置（防重复） ====================
set_pkg() {
    local pkg="$1"
    local value="${2:-y}"
    local config_file="./.config"
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" "$config_file"
    echo "CONFIG_PACKAGE_${pkg}=${value}" >> "$config_file"
}

#==================== 11. 完整冲突清理（保留隧道基础模块） ====================
clean_conflict_packages() {
    local config_file="./.config"
    green "===== 开始清理冲突包（保留隧道基础模块） ====="
    
    # 11.1 WiFi Mesh：删除 basic 和 mesh，保留 openssl
    sed -i '/^CONFIG_PACKAGE_wpad-basic=/d' "$config_file"
    sed -i '/^CONFIG_PACKAGE_wpad-mesh=/d' "$config_file"
    set_pkg "wpad-openssl" "y"
    
    # 11.2 删除软件 nft-offload
    sed -i '/^CONFIG_PACKAGE_kmod-nft-offload=/d' "$config_file"
    
    # 11.3 删除软件队列调度器
    for pkg in $(grep "^CONFIG_PACKAGE_kmod-sched-" "$config_file" | cut -d= -f1 | sed 's/^CONFIG_PACKAGE_//'); do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" "$config_file"
    done
    sed -i '/^CONFIG_PACKAGE_kmod-sched-core=/d' "$config_file"
    
    # 11.4 网络测试包
    sed -i '/^CONFIG_PACKAGE_kmod-net-selftests=/d' "$config_file"
    
    # 11.5 IPv6：删除 ipv6only，保留 odhcpd
    sed -i '/^CONFIG_PACKAGE_odhcpd-ipv6only=/d' "$config_file"
    set_pkg "odhcpd" "y"
    
    # 11.6 无线驱动：仅 AHB，删除 PCI
    sed -i '/^CONFIG_PACKAGE_kmod-ath11k-pci=/d' "$config_file"
    sed -i '/^CONFIG_PACKAGE_ath10k-firmware-qca4019=/d' "$config_file"
    sed -i '/^CONFIG_PACKAGE_ath10k-firmware-qca9984=/d' "$config_file"
    sed -i '/^CONFIG_PACKAGE_ath11k-firmware-qcn9074=/d' "$config_file"
    set_pkg "ath11k-firmware-ipq6018" "y"
    
    # 11.7 保留所有隧道基础模块（不删除），仅确保 NSS ECM 和 PPPoE 硬件加速存在
    set_pkg "kmod-qca-nss-ecm" "y"
    set_pkg "kmod-ppp" "y"
    set_pkg "kmod-pppoe" "y"
    set_pkg "kmod-pppox" "y"
    set_pkg "kmod-qca-nss-drv-pppoe" "y"
    
    # 11.8 新增：全锥 NAT 模块（CGNAT 环境 P2P 优化）
    set_pkg "kmod-nft-fullcone" "y"
    
    green "✅ 冲突包清理完成（保留隧道模块，添加 nft-fullcone）"
}
clean_conflict_packages

#==================== 12. wifi-scripts 补丁（安全重启，不卸载内核模块） ====================
patch_wifi_full_reload() {
    local wifi_uc="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
    if [ -f "$wifi_uc" ]; then
        if ! grep -q "ubus call network.wireless reload" "$wifi_uc"; then
            sed -i '/ubus call network.wireless stop/a\    exec("ubus call network.wireless reload 2>/dev/null || /etc/init.d/wifi restart");' "$wifi_uc"
            green "✅ wifi-scripts 补丁注入成功（安全重启无线）"
        else
            green "ℹ️ wifi-scripts 补丁已存在"
        fi
    fi
}
patch_wifi_full_reload

#==================== 13. 固化 WiFi 参数 ====================
WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"

if [ -f "$WIFI_SH" ]; then
    sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
    sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
    sed -i "/wifi-device/a\    option disabled '0'" $WIFI_SH 2>/dev/null || true
    cat >> $WIFI_SH << 'EOF'
for dev in $(uci show wireless | grep '=wifi-device' | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.$dev.log_level='0'
    uci set wireless.$dev.disabled='0'
done
uci commit wireless
EOF
    green "✅ WiFi 参数已固化"
elif [ -f "$WIFI_UC" ]; then
    sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
    sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
    sed -i "s/country='.*'/country='CN'/g" $WIFI_UC
    sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
    sed -i "s/disabled='1'/disabled='0'/g" $WIFI_UC
    grep -q "log_level" "$WIFI_UC" && \
        sed -i "s/log_level='.*'/log_level='0'/g" $WIFI_UC || \
        sed -i "/option encryption/a\    option log_level '0'" $WIFI_UC
    grep -q "disabled" "$WIFI_UC" || sed -i "/wifi-device/a\    disabled '0'" $WIFI_UC
    green "✅ WiFi 参数已固化"
fi

#==================== 14. 固化管理 IP、主机名 ====================
CFG_FILE="./package/base-files/files/bin/config_generate"
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE
green "✅ 管理 IP: $WRT_IP，主机名: $WRT_NAME"

#==================== 15. 基础编译配置（防重复） ====================
set_pkg "luci" "y"
set_pkg "LUCI_LANG_zh_Hans" "y"
set_pkg "luci-theme-$WRT_THEME" "y"
set_pkg "luci-app-$WRT_THEME-config" "y"

#==================== 16. 加载私有配置 ====================
[ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ] && {
    green "Applying private configurations..."
    cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
}

#==================== 17. 自定义插件 ====================
[ -n "$WRT_PACKAGE" ] && echo -e "$WRT_PACKAGE" >> ./.config

#==================== 18. 无 WiFi 标记 ====================
[[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]] && {
    echo "WRT_WIFI=wifi-no" >> $GITHUB_ENV
    green "✅ WiFi 已标记为禁用"
}

#==================== 19. 无 WiFi DTS 适配 ====================
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]] && \
   [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
    find ./target/linux/qualcommax/dts/ -type f ! -iname '*nowifi*' \
        -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
    green "✅ nowifi DTS 已适配"
fi

#==================== 20. 验证 ====================
verify_cleanup() {
    local config_file="./.config"
    local conflicts=(
        "kmod-nft-offload" "odhcpd-ipv6only" "kmod-sched-core"
        "kmod-ath11k-pci"
    )
    local required=(
        "kmod-qca-nss-ecm" "ath11k-firmware-ipq6018"
        "kmod-ppp" "kmod-pppoe" "kmod-qca-nss-drv-pppoe"
        "wpad-openssl" "kmod-nft-fullcone"
    )
    local tunnel_required=(
        "kmod-6rd" "kmod-gre" "kmod-vxlan"
    )
    
    echo "" && green "===== 验证 ====="
    local has_conflict=false
    for pkg in "${conflicts[@]}"; do
        if grep -q "^CONFIG_PACKAGE_${pkg}=y" "$config_file" 2>/dev/null; then
            echo "⚠️ 残留: $pkg" && has_conflict=true
        else
            echo "✅ 已清理: $pkg"
        fi
    done
    for pkg in "${required[@]}"; do
        if grep -q "^CONFIG_PACKAGE_${pkg}=y" "$config_file" 2>/dev/null; then
            echo "✅ 已启用: $pkg"
        else
            echo "❌ 缺失: $pkg" && has_conflict=true
        fi
    done
    for pkg in "${tunnel_required[@]}"; do
        if grep -q "^CONFIG_PACKAGE_${pkg}=y" "$config_file" 2>/dev/null; then
            echo "✅ 保留: $pkg (NSS隧道依赖)"
        else
            echo "❌ 缺失: $pkg (NSS隧道可能失效)" && has_conflict=true
        fi
    done
    
    if ! grep -q "^CONFIG_PACKAGE_kmod-pppoe=y" "$config_file" 2>/dev/null; then
        echo "❌ kmod-pppoe 被误删，PPPoE 拨号将失效"
        has_conflict=true
    fi
    
    [ "$has_conflict" = false ] && green "🎉 所有检查通过" \
        || echo "⚠️ 部分异常，请手动检查"
    
    echo ""
    green '💡 固件烧录后可验证：'
    green '   1. WAN队列: cat /sys/class/net/wan/queues/rx-0/rps_flow_cnt → 4096'
    green '   2. 连接跟踪: sysctl net.netfilter.nf_conntrack_max → 65536'
    green '   3. CPU调度器: cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor → schedutil'
    green '   4. IPv6自动获取: uci get network.wan.ipv6 → auto'
    green '   5. NTP服务器: uci get system.ntp.server → cn.ntp.org.cn'
    green '   6. DNS白名单: uci get dhcp.@dnsmasq[0].rebind_domain → 包含 cn.ntp.org.cn'
    green '   7. PPPoE防火墙规则: uci show firewall | grep pppoe → 应看到两条规则'
    green '   8. 防火墙硬件加速: uci get firewall.@defaults[0].nss_offload → 1'
    green '   9. 全锥NAT模块: lsmod | grep nft_fullcone → 应存在'
    green '  10. 隧道模块保留: lsmod | grep -E "6rd|gre|vxlan" → 应存在'
    green '  11. NSS优化日志: logread | grep nss-fix → 查看启动状态'
}
verify_cleanup

green ""
green "========================================"
green "===== IPQ60XX 硬加速脚本（最终完整版）执行完毕 ====="
green "========================================"
green "✅ CPU 调频: schedutil (自动按需)"
green "✅ 队列调度器: 已完全移除"
green "✅ NSS 硬加速: PPE + 桥接卸载 + PPPoE 硬件卸载 (无ECM重载)"
green "✅ WAN 优化: 接收队列扩容 + NSS接收聚合"
green "✅ 连接跟踪: 超时调优 (syn_recv=60s) 避免高延迟断连"
green "✅ 防火墙: 硬件加速开关 + PPPoE放行 + 全锥NAT (nft-fullcone)"
green "✅ IPv6: 自动获取 (network.wan.ipv6=auto)"
green "✅ 启动顺序: NSS优化提前到 START=20，早于网络拨号"
green "✅ 存储优化: 实体闪存+虚拟设备双维度IO优化"
green "✅ 无线: 仅 AHB 内置，安全重启（不卸载内核模块）"
green "✅ 隧道: 保留所有基础隧道模块 (6rd/gre/vxlan)，确保NSS硬件卸载可用"
green "✅ 配置写入: 使用 set_pkg 防重复污染"
green "✅ 启动修复: fstab + hostapd + sysctl 自动生效"
green "✅ 国内适配: NTP国内源 + DNS域名白名单"
green "========================================"
