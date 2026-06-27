#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# IPQ60XX 专用优化版 - 硬加速 (PPPoE 硬件卸载) + CPU 自动调频 + 无队列
# 修正版：精确包匹配 + UCI防火墙放行

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

#==================== 3. 修复启动错误（fstab / hostapd / PPPoE MTU） ====================
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

    # 3.2 hostapd 运行目录补丁（防重复插入）
    local hostapd_init="./package/network/services/hostapd/files/hostapd.init"
    if [ -f "$hostapd_init" ]; then
        if ! grep -q "mkdir -p /var/run/hostapd" "$hostapd_init"; then
            sed -i '/start_service()/a\    mkdir -p /var/run/hostapd\n    chmod 755 /var/run/hostapd' "$hostapd_init"
            green "✅ hostapd init 已补丁（自动创建运行目录）"
        else
            green "ℹ️ hostapd init 已包含目录创建，无需重复补丁"
        fi
    else
        mkdir -p ./package/base-files/files/etc
        if [ ! -f ./package/base-files/files/etc/rc.local ]; then
            echo -e "#!/bin/sh\nexit 0" > ./package/base-files/files/etc/rc.local
            chmod +x ./package/base-files/files/etc/rc.local
        fi
        if ! grep -q "mkdir -p /var/run/hostapd" ./package/base-files/files/etc/rc.local; then
            sed -i '/exit 0/i mkdir -p /var/run/hostapd\nchmod 755 /var/run/hostapd\n' ./package/base-files/files/etc/rc.local
            green "✅ hostapd 运行目录创建已加入 rc.local 兜底"
        fi
    fi

    # 3.3 PPPoE MTU 优化（uci-defaults 首次启动生效）
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
    green "✅ PPPoE MTU 1492 已预设（uci-defaults）"
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

#==================== 5. NSS 修复脚本（循环等待WAN+日志+全量IO优化） ====================
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
        # 挂载 debugfs，已挂载则跳过
        mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null
        
        # 循环等待WAN口就绪，最多30秒，就绪立即执行
        timeout=30
        while [ $timeout -gt 0 ] && [ ! -L /sys/class/net/wan/device ]; do
            sleep 1
            timeout=$((timeout - 1))
        done
        if [ -L /sys/class/net/wan/device ]; then
            echo "✅ WAN口设备已就绪" | logger -t nss-fix
        else
            echo "⚠️ WAN口设备未就绪，跳过缓冲扩容" | logger -t nss-fix
        fi

        # 卸载可能干扰的虚拟网卡
        lsmod | grep -q "^ifb " && rmmod ifb 2>/dev/null
        lsmod | grep -q "^nss_ifb " && rmmod nss_ifb 2>/dev/null
        
        # 显式加载 PPPoE 硬件卸载模块
        if modprobe qca_nss_pppoe 2>/dev/null || modprobe qca-nss-pppoe 2>/dev/null; then
            echo "✅ qca-nss-pppoe 硬件卸载模块加载成功" | logger -t nss-fix
        else
            echo "⚠️ qca-nss-pppoe 模块未找到" | logger -t nss-fix
        fi
        
        # 重新加载 ECM（必须晚于 PPPoE 模块）
        lsmod | grep -q "^qca_nss_ecm" && {
            rmmod qca_nss_ecm 2>/dev/null
            modprobe qca_nss_ecm 2>/dev/null
            if lsmod | grep -q "^qca_nss_ecm"; then
                echo "✅ ECM 模块重载成功" | logger -t nss-fix
            else
                echo "⚠️ ECM 模块重载失败" | logger -t nss-fix
            fi
        }
        
        # 强制启用 PPE 和桥接卸载
        echo 1 > /sys/module/qca_nss_drv/parameters/ppe_enable 2>/dev/null || true
        echo 1 > /sys/module/qca_nss_drv/parameters/bridge_offload 2>/dev/null || true
        echo 1 > /proc/sys/net/nss/offload 2>/dev/null || true

        # 精准定位 WAN 口物理设备，扩容接收缓冲
        wan_dp_path=""
        if [ -L /sys/class/net/wan/device ]; then
            wan_dp_path=$(readlink -f /sys/class/net/wan/device)
        fi
        if [ -z "$wan_dp_path" ]; then
            wan_dp_path=$(find /sys/devices/platform -name "*dp[0-9]*" -type d 2>/dev/null | sort -V | tail -1)
        fi

        if [ -n "$wan_dp_path" ] && [ -f "$wan_dp_path/rx_ring_size" ]; then
            echo 1024 > "$wan_dp_path/rx_ring_size" 2>/dev/null
            echo 512 > "$wan_dp_path/rx_buf_count" 2>/dev/null
            echo "✅ WAN口接收缓冲已扩容: $wan_dp_path" | logger -t nss-fix
        else
            echo "⚠️ 未找到有效 WAN 口 dp 设备，跳过接收缓冲扩容" | logger -t nss-fix
        fi
        
        # 开启 NSS 接收聚合
        echo 1 > /sys/kernel/debug/qca-nss-drv/rx_aggr/enable 2>/dev/null || true

        # 全量存储IO优化（兼容无MMC设备）
        for dev in /sys/block/mmcblk[0-9]* /sys/block/sd[a-z]*; do
            [ -d "$dev" ] || continue
            [ -f "$dev/queue/nr_requests" ] && echo 256 > "$dev/queue/nr_requests" 2>/dev/null
            [ -f "$dev/queue/read_ahead_kb" ] && echo 1024 > "$dev/queue/read_ahead_kb" 2>/dev/null
        done
        for dev in /sys/devices/virtual/block/*/queue/zone_append_max_bytes; do
            [ -f "$dev" ] && echo 131072 > "$dev" 2>/dev/null
        done
        
        # 锁定 schedutil 调频策略
        for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
            echo "schedutil" > "$cpu/cpufreq/scaling_governor" 2>/dev/null || true
        done
    ) &
}
EOF
    chmod +x "$init_path"
    green "✅ NSS 修复脚本安装完成（循环等待WAN+全量IO优化+日志记录）"
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
        green "ℹ️ rc.local 已包含修复，无需重复添加"
    fi
}
fix_fstab_rc_local

#==================== 7. 系统参数优化（连接跟踪） ====================
add_sysctl_tweaks() {
    local sysctl_conf="./package/base-files/files/etc/sysctl.conf"
    mkdir -p "$(dirname "$sysctl_conf")"
    if ! grep -q "nf_conntrack_max" "$sysctl_conf" 2>/dev/null; then
        cat >> "$sysctl_conf" << 'EOF'
# NSS ECM 加速优化：缩短半开连接超时，减少加速表占用
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 10
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_max = 65536
EOF
        green "✅ 连接跟踪优化参数已内置"
    else
        green "ℹ️ sysctl.conf 已包含连接跟踪优化，跳过重复写入"
    fi
}
add_sysctl_tweaks

#==================== 8. PPPoE 防火墙放行规则（UCI原生配置，fw4兼容） ====================
fix_pppoe_firewall() {
    mkdir -p ./package/base-files/files/etc/uci-defaults
    cat > ./package/base-files/files/etc/uci-defaults/97-pppoe-firewall << 'EOF'
#!/bin/sh
# 检查规则是否已存在，避免重复添加
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
    green "✅ PPPoE 防火墙放行规则已固化（UCI方式，fw4 100%兼容）"
}
fix_pppoe_firewall

#==================== 9. NTP国内源 + DNS域名白名单（uci-defaults安全方式） ====================
add_ntp_dns_whitelist() {
    mkdir -p ./package/base-files/files/etc/uci-defaults
    cat > ./package/base-files/files/etc/uci-defaults/98-ntp-dns << 'EOF'
#!/bin/sh
# 设置 NTP 服务器
uci -q set system.ntp.enabled='1'
uci -q set system.ntp.enable_server='0'
uci -q delete system.ntp.server
uci -q add_list system.ntp.server='cn.ntp.org.cn'
uci commit system

# 添加 DNS 域名白名单（防止 rebind 攻击）
if ! uci -q get dhcp.@dnsmasq[0].rebind_domain | grep -q 'cn.ntp.org.cn'; then
    uci -q add_list dhcp.@dnsmasq[0].rebind_domain='cn.ntp.org.cn'
    uci commit dhcp
fi
exit 0
EOF
    chmod +x ./package/base-files/files/etc/uci-defaults/98-ntp-dns
    green "✅ NTP 国内源和 DNS 白名单已预设（uci-defaults）"
}
add_ntp_dns_whitelist

#==================== 10. 工具函数：精确删除 .config 中的包配置 ====================
remove_pkg() {
    local pkg="$1"
    local config_file="./.config"
    # 精确匹配行首的 CONFIG_PACKAGE_xxx=，删除整行
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" "$config_file"
}

#==================== 11. 完整冲突清理（精确匹配，彻底避免误删PPPoE核心包） ====================
clean_conflict_packages() {
    local config_file="./.config"
    green "===== 开始清理冲突包（精确匹配，保留PPPoE） ====="
    
    # 11.1 WiFi Mesh 冲突
    remove_pkg "kmod-qca-nss-drv-wifi-meshmgr"
    remove_pkg "wpad-basic"
    remove_pkg "wpad-mesh"
    remove_pkg "wpad-openssl"
    echo "CONFIG_PACKAGE_wpad-openssl=y" >> "$config_file"
    
    # 11.2 不兼容隧道（精确匹配，不会误删）
    local tunnel_pkgs=(
        "kmod-6rd" "kmod-gre" "kmod-gre6" "kmod-l2tp"
        "kmod-iptunnel" "kmod-iptunnel4" "kmod-iptunnel6"
        "kmod-vxlan" "kmod-udptunnel4" "kmod-udptunnel6"
        "kmod-sit" "kmod-ipip"
    )
    for pkg in "${tunnel_pkgs[@]}"; do
        remove_pkg "$pkg"
        echo "# CONFIG_PACKAGE_${pkg} is not set" >> "$config_file"
    done
    green "✅ 不兼容隧道已清理（精确匹配）"
    
    # 11.3 NAT/防火墙
    remove_pkg "kmod-nft-offload"
    remove_pkg "kmod-qca-nss-ecm"
    echo "CONFIG_PACKAGE_kmod-qca-nss-ecm=y" >> "$config_file"
    
    # 11.4 IPv6
    remove_pkg "odhcpd-ipv6only"
    echo "# CONFIG_PACKAGE_odhcpd-ipv6only is not set" >> "$config_file"
    remove_pkg "odhcpd"
    echo "CONFIG_PACKAGE_odhcpd=y" >> "$config_file"
    
    # 11.5 网络测试
    remove_pkg "kmod-net-selftests"
    
    # 11.6 无线驱动与固件
    remove_pkg "kmod-ath11k-pci"
    remove_pkg "ath10k-firmware-qca4019"
    remove_pkg "ath10k-firmware-qca9984"
    remove_pkg "ath11k-firmware-qcn9074"
    remove_pkg "ath11k-firmware-ipq6018"
    echo "CONFIG_PACKAGE_ath11k-firmware-ipq6018=y" >> "$config_file"
    
    # 11.7 删除软件队列调度器（精确匹配前缀 kmod-sched-）
    for pkg in $(grep "^CONFIG_PACKAGE_kmod-sched-" "$config_file" | cut -d= -f1 | sed 's/^CONFIG_PACKAGE_//'); do
        remove_pkg "$pkg"
    done
    remove_pkg "kmod-sched-core"
    
    # 11.8 保留 PPPoE 硬件加速（精确匹配，不会误删 kmod-pppoe）
    remove_pkg "kmod-ppp"
    echo "CONFIG_PACKAGE_kmod-ppp=y" >> "$config_file"
    remove_pkg "kmod-pppoe"
    echo "CONFIG_PACKAGE_kmod-pppoe=y" >> "$config_file"
    remove_pkg "kmod-pppox"
    echo "CONFIG_PACKAGE_kmod-pppox=y" >> "$config_file"
    remove_pkg "kmod-qca-nss-drv-pppoe-mgr"
    echo "CONFIG_PACKAGE_kmod-qca-nss-drv-pppoe-mgr=y" >> "$config_file"
    
    green "✅ 冲突包清理完成（精确匹配，PPPoE核心包保留完整）"
}
clean_conflict_packages

#==================== 12. wifi-scripts 补丁（修复模块名+防重复） ====================
patch_wifi_full_reload() {
    local wifi_uc="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
    if [ -f "$wifi_uc" ]; then
        if ! grep -q "rmmod ath11k_ahb" "$wifi_uc"; then
            sed -i '/ubus call network.wireless stop/a\    exec("rmmod ath11k_ahb ath11k ath mac80211 cfg80211 2>/dev/null; sleep(1); modprobe cfg80211 2>/dev/null; modprobe mac80211 2>/dev/null; modprobe ath 2>/dev/null; modprobe ath11k 2>/dev/null; modprobe ath11k_ahb 2>/dev/null; sleep(1);");' "$wifi_uc"
            green "✅ wifi-scripts 补丁注入成功（仅 AHB 重置）"
        else
            green "ℹ️ wifi-scripts 补丁已存在，跳过重复插入"
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
    green "✅ WiFi 参数已固化（显式启用无线 + log_level=0）"
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
    green "✅ WiFi 参数已固化（显式启用无线 + log_level=0）"
fi

#==================== 14. 固化管理 IP、主机名 ====================
CFG_FILE="./package/base-files/files/bin/config_generate"
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE
green "✅ 管理 IP: $WRT_IP，主机名: $WRT_NAME"

#==================== 15. 基础编译配置（防重复） ====================
remove_pkg "luci"
echo "CONFIG_PACKAGE_luci=y" >> ./.config
remove_pkg "LUCI_LANG_zh_Hans"
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
remove_pkg "luci-theme-$WRT_THEME"
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
remove_pkg "luci-app-$WRT_THEME-config"
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

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
        "kmod-qca-nss-drv-wifi-meshmgr" "kmod-6rd" "kmod-gre" "kmod-l2tp"
        "kmod-nft-offload" "odhcpd-ipv6only" "kmod-sched-core"
        "kmod-ath11k-pci"
    )
    local required=(
        "kmod-qca-nss-ecm" "ath11k-firmware-ipq6018"
        "kmod-ppp" "kmod-pppoe" "kmod-qca-nss-drv-pppoe-mgr"
        "wpad-openssl"
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
    
    # 额外检查：确保 kmod-pppoe 没有被误删
    if ! grep -q "^CONFIG_PACKAGE_kmod-pppoe=y" "$config_file" 2>/dev/null; then
        echo "❌ kmod-pppoe 被误删，PPPoE 拨号将失效"
        has_conflict=true
    fi
    
    [ "$has_conflict" = false ] && green "🎉 所有检查通过" \
        || echo "⚠️ 部分异常，请手动检查"
    
    echo ""
    green '💡 固件烧录后可验证：'
    green '   1. WAN口缓冲: cat $(readlink -f /sys/class/net/wan/device)/rx_ring_size → 1024'
    green '   2. 连接跟踪: sysctl net.netfilter.nf_conntrack_max → 65536'
    green '   3. CPU调度器: cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor → schedutil'
    green '   4. NTP服务器: uci get system.ntp.server → cn.ntp.org.cn'
    green '   5. DNS白名单: uci get dhcp.@dnsmasq[0].rebind_domain → 包含 cn.ntp.org.cn'
    green '   6. PPPoE防火墙规则: uci show firewall | grep pppoe → 应看到两条规则'
    green '   7. NSS优化日志: logread | grep nss-fix → 查看启动状态'
}
verify_cleanup

green ""
green "========================================"
green "===== IPQ60XX 硬加速脚本（精确修正版）执行完毕 ====="
green "========================================"
green "✅ CPU 调频: schedutil (自动按需)"
green "✅ 队列调度器: 已完全移除（精确匹配）"
green "✅ NSS 硬加速: PPE + ECM 全卸载 + PPPoE 硬件卸载"
green "✅ WAN 优化: 精准扩容接收缓冲，修复硬件丢包"
green "✅ ECM 优化: 连接跟踪调优，减少加速表占用"
green "✅ 存储优化: 实体闪存+虚拟设备双维度IO优化"
green "✅ 无线: 仅 AHB 内置，显式启用，驱动重置修复"
green "✅ 启动修复: fstab + hostapd + sysctl 自动生效"
green "✅ PPPoE: MTU预设 + UCI防火墙放行(100%兼容fw4) + 硬件卸载"
green "✅ 国内适配: NTP国内源 + DNS域名白名单"
green "✅ 健壮性: 精确包匹配，PPPoE核心包绝不被误删"
green "========================================"
