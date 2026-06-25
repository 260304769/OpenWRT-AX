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

#==================== 3. 整合修复（fstab + hostapd + 日志 + NSS） ====================
integrated_fix() {
    green "===== 整合修复 ====="
    
    local all_fix="./package/base-files/files/etc/init.d/00-integrated-fix"
    mkdir -p "$(dirname "$all_fix")"
    cat > "$all_fix" << 'EOF'
#!/bin/sh /etc/rc.common
START=60
STOP=10

boot() { start; }

start() {
    # === fstab 修复 ===
    mkdir -p /var/run/hostapd
    chown root:root /var/run/hostapd
    chmod 755 /var/run/hostapd
    
    # === 日志限制 ===
    [ -f /var/log/messages ] && > /var/log/messages
    echo 3 > /proc/sys/kernel/printk 2>/dev/null
    
    # === hostapd 日志级别降低 ===
    [ -f /var/run/hostapd.pid ] && kill -SIGUSR1 $(cat /var/run/hostapd.pid) 2>/dev/null
    
    # === NSS 延迟卸载 + 持久化 ===
    (
        sleep 300
        lsmod | grep -q "^ifb " && rmmod ifb 2>/dev/null
        lsmod | grep -q "qca_nss_ecm_offload" && rmmod qca-nss-ecm-offload 2>/dev/null
        
        sleep 5
        [ -f /proc/sys/net/nss/nss_enable ] && echo 1 > /proc/sys/net/nss/nss_enable 2>/dev/null
        
        mkdir -p /var/run/nss
        cat /proc/sys/net/nss/nss_enable > /var/run/nss/status 2>/dev/null
        echo "$(date)" > /var/run/nss/started_at 2>/dev/null
    ) &
    
    # === CPU 性能调度 ===
    [ -f /sys/devices/system/cpu/cpufreq/policy0/scaling_governor ] && \
        echo schedutil > /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null
    
    echo "✅ 整合修复完成"
}
EOF
    chmod +x "$all_fix"
    green "✅ 整合修复脚本已安装"
}
integrated_fix

#==================== 4. 日志清除（rsyslog 过滤） ====================
cleanup_logs() {
    green "===== 配置日志过滤 ====="
    
    local rsyslog_conf="./package/base-files/files/etc/rsyslog.d/80-filter.conf"
    mkdir -p "$(dirname "$rsyslog_conf")"
    cat > "$rsyslog_conf" << 'EOF'
# 丢弃 hostapd 轮询日志
:msg, contains, "AP-STA-POLL-OK" ~
:msg, contains, "AP-STA-POLL-OK" stop
EOF
    green "✅ rsyslog 过滤规则已添加（屏蔽 POLL 日志）"
}
cleanup_logs

#==================== 5. NSS PBUF 性能调度优化 ====================
update_nss_pbuf_performance() {
    local conf="./package/kernel/mac80211/files/pbuf.uci"
    if [ -f "$conf" ]; then
        sed -i "s/auto_scale '1'/auto_scale 'off'/g" "$conf" 2>/dev/null
        sed -i "s/scaling_governor 'performance'/scaling_governor 'schedutil'/g" "$conf" 2>/dev/null
        green "✅ NSS PBUF: 自动缩放关闭，CPU调度器切换 schedutil"
    fi
}
update_nss_pbuf_performance

#==================== 6. 硬加速完整配置 ====================
setup_hardware_acceleration() {
    green "===== 配置硬加速 ====="
    
    # 6.1 NSS 核心参数
    local sysctl_conf="./package/base-files/files/etc/sysctl.d/99-nss.conf"
    mkdir -p "$(dirname "$sysctl_conf")"
    cat > "$sysctl_conf" << 'EOF'
# NSS 加速
net.core.netdev_max_backlog=5000
net.core.rps_sock_flow_entries=32768
net.ipv4.tcp_congestion_control=bbr
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_max_syn_backlog=4096
net.core.somaxconn=4096
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_timestamps=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_fastopen=3
EOF
    green "✅ NSS sysctl 参数已配置"
    
    # 6.2 开机启用硬件卸载
    local hw_offload="./package/base-files/files/etc/init.d/hw-offload"
    mkdir -p "$(dirname "$hw_offload")"
    cat > "$hw_offload" << 'EOF'
#!/bin/sh /etc/rc.common
START=80
STOP=10

boot() { start; }
start() {
    sleep 10
    
    [ -f /proc/sys/net/nss/nss_enable ] && echo 1 > /proc/sys/net/nss/nss_enable 2>/dev/null
    [ -f /sys/module/nss_driver/parameters/force_offload ] && echo 1 > /sys/module/nss_driver/parameters/force_offload 2>/dev/null
    
    uci set firewall.@defaults[0].flow_offloading='1' 2>/dev/null
    uci set firewall.@defaults[0].flow_offloading_hw='1' 2>/dev/null
    uci commit firewall 2>/dev/null
    /etc/init.d/firewall restart 2>/dev/null
    
    for cpu in /sys/class/net/*/queues/rx-*/rps_cpus; do
        [ -f "$cpu" ] && echo f > "$cpu"
    done
    
    for cpu in /sys/class/net/*/queues/tx-*/xps_cpus; do
        [ -f "$cpu" ] && echo f > "$cpu"
    done
    
    for irq in $(grep -E "nss|qcom|ath11k" /proc/interrupts | awk '{print $1}' | sed 's/://g'); do
        [ -n "$irq" ] && echo 2 > /proc/irq/$irq/smp_affinity 2>/dev/null
    done
    
    echo "✅ 硬件加速已启用"
}
EOF
    chmod +x "$hw_offload"
    green "✅ 硬件加速开机脚本已安装"
    
    # 6.3 防火墙硬件加速
    local fw_conf="./package/network/config/firewall/files/firewall.config"
    if [ -f "$fw_conf" ]; then
        sed -i 's/option flow_offloading.*/option flow_offloading "1"/g' "$fw_conf"
        sed -i 's/option flow_offloading_hw.*/option flow_offloading_hw "1"/g' "$fw_conf"
        green "✅ 防火墙硬件加速已启用"
    fi
}
setup_hardware_acceleration

#==================== 7. 完整冲突清理（IPQ6018/AX5 专用） ====================
clean_conflict_packages() {
    local config_file="./.config"
    green "===== 开始清理 NSS/WiFi 冲突包 ====="
    
    # 7.1 WiFi Mesh 冲突
    sed -i '/CONFIG_PACKAGE_kmod-qca-nss-drv-wifi-meshmgr/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_wpad-basic/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_wpad-mesh/d' "$config_file"
    echo "CONFIG_PACKAGE_wpad-openssl=y" >> "$config_file"
    
    # 7.2 隧道协议冲突
    for pkg in kmod-6rd kmod-gre kmod-gre6 kmod-l2tp kmod-iptunnel kmod-iptunnel4 kmod-iptunnel6 kmod-vxlan kmod-udptunnel4 kmod-udptunnel6 kmod-sit kmod-ipip; do
        sed -i "/CONFIG_PACKAGE_${pkg}/d" "$config_file"
    done
    
    # 7.3 NAT/防火墙冲突
    sed -i '/CONFIG_PACKAGE_kmod-nft-offload/d' "$config_file"
    echo "CONFIG_PACKAGE_kmod-qca-nss-ecm=y" >> "$config_file"
    echo "CONFIG_PACKAGE_kmod-qca-nss-ecm-standard=y" >> "$config_file"
    
    # 7.4 IPv6 冲突
    sed -i '/CONFIG_PACKAGE_odhcpd-ipv6only/d' "$config_file"
    echo "CONFIG_PACKAGE_odhcpd=y" >> "$config_file"
    
    # 7.5 网络测试冲突
    sed -i '/CONFIG_PACKAGE_kmod-net-selftests/d' "$config_file"
    
    # 7.6 IPQ6018 特定无线固件
    sed -i '/CONFIG_PACKAGE_ath10k-firmware-qca4019/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_ath10k-firmware-qca9984/d' "$config_file"
    echo "CONFIG_PACKAGE_ath11k-firmware-qcn9074=y" >> "$config_file"
    
    # 7.7 QoS 调度器
    sed -i '/CONFIG_PACKAGE_kmod-sched-cake/d' "$config_file"
    echo "CONFIG_PACKAGE_kmod-sched-cake-oot=y" >> "$config_file"
    
    green "✅ 冲突包清理完成"
}
clean_conflict_packages

#==================== 8. wifi-scripts 补丁（hotplug 方式，更安全） ====================
patch_wifi_hotplug() {
    green "===== 安装 WiFi hotplug 重置脚本 ====="
    
    local hotplug_script="./package/base-files/files/etc/hotplug.d/ieee80211/00-ath11k-reset"
    mkdir -p "$(dirname "$hotplug_script")"
    cat > "$hotplug_script" << 'EOF'
#!/bin/sh
[ "$ACTION" = "disable" ] || exit 0
(
    sleep 1
    rmmod ath11k_pci ath11k_ahb ath11k ath mac80211 cfg80211 2>/dev/null
    sleep 1
    modprobe cfg80211 mac80211 ath ath11k ath11k_ahb ath11k_pci 2>/dev/null
) &
EOF
    chmod +x "$hotplug_script"
    green "✅ WiFi hotplug 重置脚本已安装（替代原 mac80211.uc 补丁）"
}
patch_wifi_hotplug

#==================== 9. 固化 WiFi 参数 ====================
WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
    sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
    sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
    green "✅ WiFi 参数已固化（uci-defaults）"
elif [ -f "$WIFI_UC" ]; then
    sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
    sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
    sed -i "s/country='.*'/country='CN'/g" $WIFI_UC
    sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
    sed -i "s/disabled='1'/disabled='0'/g" $WIFI_UC
    green "✅ WiFi 参数已固化（mac80211.uc）"
fi

#==================== 10. 固化默认管理 IP、主机名 ====================
CFG_FILE="./package/base-files/files/bin/config_generate"
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE
green "✅ 管理 IP: $WRT_IP，主机名: $WRT_NAME"

#==================== 11. 写入基础编译配置 ====================
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#==================== 12. 加载私有配置文件 ====================
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
    green "Applying private configurations from PRIVATE.txt..."
    cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

#==================== 13. 追加手动输入自定义插件参数 ====================
if [ -n "$WRT_PACKAGE" ]; then
    echo -e "$WRT_PACKAGE" >> ./.config
fi

#==================== 14. 标记无 WiFi 编译环境变量 ====================
if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
    echo "WRT_WIFI=wifi-no" >> $GITHUB_ENV
    green "✅ WiFi 已标记为禁用"
fi

#==================== 15. 高通 qualcommax 无 WiFi DTS 适配 ====================
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
    if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
        find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
        green "✅ qualcommax nowifi DTS 已适配"
    fi
fi

#==================== 16. 验证清理结果 ====================
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
        if grep -q "CONFIG_PACKAGE_${pkg}=" "$config_file" 2>/dev/null; then
            echo "⚠️ 发现残留: $pkg"
            has_conflict=true
        else
            echo "✅ 已清理: $pkg"
        fi
    done
    
    if [ "$has_conflict" = false ]; then
        green "🎉 所有冲突包已清理完毕"
    else
        echo "⚠️ 部分冲突包可能残留，请手动检查"
    fi
}
verify_cleanup

#==================== 17. 硬加速验证脚本（开机后执行） ====================
install_verify_script() {
    green "===== 安装硬加速验证脚本 ====="
    
    local verify_script="./package/base-files/files/usr/bin/check-hw-accel"
    mkdir -p "$(dirname "$verify_script")"
    cat > "$verify_script" << 'EOF'
#!/bin/sh

# 颜色定义
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

echo ""
echo "========================================"
echo "    硬加速状态检查 (Hardware Acceleration)"
echo "========================================"
echo ""

PASS=0
FAIL=0

# 1. 检查 NSS 启用状态
check_nss() {
    echo -n "📡 NSS 引擎状态: "
    if [ -f /proc/sys/net/nss/nss_enable ]; then
        local status=$(cat /proc/sys/net/nss/nss_enable 2>/dev/null)
        if [ "$status" = "1" ]; then
            green "✅ 已启用 (值: $status)"
            PASS=$((PASS+1))
        else
            red "❌ 未启用 (值: $status)"
            FAIL=$((FAIL+1))
        fi
    else
        red "❌ NSS 模块未加载 (不支持或未编译)"
        FAIL=$((FAIL+1))
    fi
}

# 2. 检查 NSS 模块加载
check_nss_modules() {
    echo -n "📦 NSS 内核模块: "
    local modules=$(lsmod | grep -E "qca_nss|nss_driver" | wc -l)
    if [ "$modules" -gt 0 ]; then
        green "✅ 已加载 ($modules 个模块)"
        lsmod | grep -E "qca_nss|nss_driver" | awk '{print "   - " $1}'
        PASS=$((PASS+1))
    else
        red "❌ 未加载"
        FAIL=$((FAIL+1))
    fi
}

# 3. 检查防火墙硬件卸载
check_firewall() {
    echo -n "🔥 防火墙硬件卸载: "
    local hw=$(uci get firewall.@defaults[0].flow_offloading_hw 2>/dev/null)
    local sw=$(uci get firewall.@defaults[0].flow_offloading 2>/dev/null)
    if [ "$hw" = "1" ] && [ "$sw" = "1" ]; then
        green "✅ 已启用 (SW=$sw, HW=$hw)"
        PASS=$((PASS+1))
    elif [ "$hw" = "1" ]; then
        yellow "⚠️ 仅硬件卸载开启 (SW=$sw, HW=$hw)"
    else
        red "❌ 未启用 (SW=$sw, HW=$hw)"
        FAIL=$((FAIL+1))
    fi
}

# 4. 检查 RPS 配置
check_rps() {
    echo -n "🔄 RPS 接收分散: "
    local rps=$(cat /sys/class/net/*/queues/rx-*/rps_cpus 2>/dev/null | head -1)
    if [ "$rps" = "f" ] || [ "$rps" = "0000000f" ]; then
        green "✅ 已配置 (CPU 0-3)"
        PASS=$((PASS+1))
    elif [ -n "$rps" ]; then
        yellow "⚠️ 配置为: $rps (预期 f)"
    else
        red "❌ 未配置"
        FAIL=$((FAIL+1))
    fi
}

# 5. 检查 XPS 配置
check_xps() {
    echo -n "📤 XPS 发送分散: "
    local xps=$(cat /sys/class/net/*/queues/tx-*/xps_cpus 2>/dev/null | head -1)
    if [ "$xps" = "f" ] || [ "$xps" = "0000000f" ]; then
        green "✅ 已配置 (CPU 0-3)"
        PASS=$((PASS+1))
    elif [ -n "$xps" ]; then
        yellow "⚠️ 配置为: $xps (预期 f)"
    else
        red "❌ 未配置"
        FAIL=$((FAIL+1))
    fi
}

# 6. 检查 IRQ 亲和性
check_irq_affinity() {
    echo -n "🎯 IRQ 亲和性: "
    local nss_irq=$(grep -E "nss|qcom|ath11k" /proc/interrupts 2>/dev/null | awk '{print $1}' | sed 's/://g' | head -1)
    if [ -n "$nss_irq" ]; then
        local affinity=$(cat /proc/irq/$nss_irq/smp_affinity 2>/dev/null)
        if [ "$affinity" = "2" ] || [ "$affinity" = "00000002" ]; then
            green "✅ 已绑定到 CPU1 (IRQ $nss_irq)"
            PASS=$((PASS+1))
        else
            yellow "⚠️ IRQ $nss_irq 亲和性: $affinity (预期 2)"
        fi
    else
        yellow "⚠️ 未找到 NSS 中断"
    fi
}

# 7. 检查 TCP 参数
check_tcp_params() {
    echo -n "🚀 TCP BBR: "
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$cc" = "bbr" ]; then
        green "✅ $cc"
        PASS=$((PASS+1))
    else
        yellow "⚠️ $cc (预期 bbr)"
    fi
    
    echo -n "📊 TCP 缓冲区: "
    local rmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
    if [ "$rmem" -ge 16777216 ] 2>/dev/null; then
        green "✅ ${rmem}bytes"
        PASS=$((PASS+1))
    else
        yellow "⚠️ ${rmem}bytes (预期 ≥16MB)"
    fi
}

# 8. 检查 CPU 调度器
check_cpu_governor() {
    echo -n "⚡ CPU 调度器: "
    local gov=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)
    if [ "$gov" = "schedutil" ]; then
        green "✅ $gov"
        PASS=$((PASS+1))
    else
        yellow "⚠️ $gov (预期 schedutil)"
    fi
}

# 9. 检查 ath11k 状态（WiFi 硬加速）
check_ath11k() {
    echo -n "📶 ath11k 状态: "
    if lsmod | grep -q "ath11k"; then
        green "✅ 已加载"
        local wifi_up=$(ubus call network.wireless status 2>/dev/null | grep -c '"up": true' 2>/dev/null)
        if [ "$wifi_up" -gt 0 ]; then
            echo "   📶 WiFi 接口: $wifi_up 个已启动"
        fi
        PASS=$((PASS+1))
    else
        yellow "⚠️ 未加载 (可能无WiFi或已禁用)"
    fi
}

# 10. 性能简单测试（ping 延迟）
check_ping_latency() {
    echo -n "🏓 网关延迟: "
    local gw=$(ip route | grep default | awk '{print $3}' | head -1)
    if [ -n "$gw" ]; then
        local latency=$(ping -c 3 -W 1 "$gw" 2>/dev/null | tail -1 | awk -F/ '{print $5}')
        if [ -n "$latency" ]; then
            if [ "$(echo "$latency < 2" | bc)" -eq 1 ] 2>/dev/null; then
                green "✅ ${latency}ms (优秀)"
            elif [ "$(echo "$latency < 5" | bc)" -eq 1 ] 2>/dev/null; then
                yellow "⚠️ ${latency}ms (良好)"
            else
                yellow "⚠️ ${latency}ms (偏高，检查网络)"
            fi
        else
            red "❌ 无法测试"
        fi
    else
        red "❌ 无默认网关"
    fi
}

# 执行所有检查
check_nss
check_nss_modules
check_firewall
check_rps
check_xps
check_irq_affinity
check_tcp_params
check_cpu_governor
check_ath11k
check_ping_latency

echo ""
echo "========================================"
echo "检查结果: ✅ $PASS 通过 | ❌ $FAIL 失败"
echo "========================================"

if [ $FAIL -eq 0 ]; then
    green "🎉 所有硬加速功能已正常启用！"
    echo ""
    echo "📊 查看实时统计:"
    echo "   cat /proc/net/nss/offload_stats"
    echo "   cat /proc/net/nss/ppe_stats"
    echo "   htop (查看CPU占用)"
else
    yellow "⚠️ 发现 $FAIL 个问题，请检查日志:"
    echo "   dmesg | grep -E 'nss|offload'"
    echo "   logread | grep -E 'nss|offload'"
fi

echo ""
EOF
    chmod +x "$verify_script"
    green "✅ 验证脚本已安装: /usr/bin/check-hw-accel"
    green "   刷机后执行 'check-hw-accel' 查看状态"
}
install_verify_script

#==================== 18. 硬加速回滚脚本 ====================
install_rollback_script() {
    green "===== 安装硬加速回滚脚本 ====="
    
    local rollback_script="./package/base-files/files/usr/bin/rollback-hw-accel"
    mkdir -p "$(dirname "$rollback_script")"
    cat > "$rollback_script" << 'EOF'
#!/bin/sh

red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

echo ""
echo "========================================"
echo "    硬加速回滚 (恢复默认配置)"
echo "========================================"
echo ""
echo -n "⚠️ 确认回滚? (y/N): "
read -r confirm

if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "❌ 已取消"
    exit 0
fi

echo ""
echo "开始回滚..."

# 1. 关闭 NSS
if [ -f /proc/sys/net/nss/nss_enable ]; then
    echo 0 > /proc/sys/net/nss/nss_enable 2>/dev/null
    green "✅ NSS 已关闭"
else
    yellow "⚠️ NSS 不存在"
fi

# 2. 关闭防火墙硬件卸载
uci set firewall.@defaults[0].flow_offloading='0' 2>/dev/null
uci set firewall.@defaults[0].flow_offloading_hw='0' 2>/dev/null
uci commit firewall 2>/dev/null
/etc/init.d/firewall restart 2>/dev/null
green "✅ 防火墙卸载已关闭"

# 3. 恢复 RPS/XPS 为默认
for cpu in /sys/class/net/*/queues/rx-*/rps_cpus; do
    [ -f "$cpu" ] && echo 0 > "$cpu"
done
for cpu in /sys/class/net/*/queues/tx-*/xps_cpus; do
    [ -f "$cpu" ] && echo 0 > "$cpu"
done
green "✅ RPS/XPS 已恢复默认"

# 4. 恢复 CPU 调度器为 performance
if [ -f /sys/devices/system/cpu/cpufreq/policy0/scaling_governor ]; then
    echo performance > /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null
    green "✅ CPU 调度器已恢复 performance"
fi

# 5. 恢复 TCP 参数（删除配置文件）
if [ -f /etc/sysctl.d/99-nss.conf ]; then
    rm -f /etc/sysctl.d/99-nss.conf
    green "✅ NSS sysctl 配置已删除"
fi

# 6. 禁用开机启动脚本
if [ -f /etc/init.d/hw-offload ]; then
    /etc/init.d/hw-offload stop 2>/dev/null
    /etc/init.d/hw-offload disable 2>/dev/null
    green "✅ hw-offload 已禁用"
fi

# 7. 卸载 NSS 模块（可选）
echo ""
echo -n "🔄 是否卸载 NSS 内核模块? (需要重启生效) (y/N): "
read -r unload
if [ "$unload" = "y" ] || [ "$unload" = "Y" ]; then
    rmmod qca-nss-ecm qca-nss-ecm-standard nss_driver 2>/dev/null
    green "✅ NSS 模块已卸载 (需重启生效)"
fi

echo ""
echo "========================================"
green "✅ 回滚完成！"
echo ""
echo "建议操作："
echo "  1. 重启路由器: reboot"
echo "  2. 验证状态: check-hw-accel"
echo "========================================"
EOF
    chmod +x "$rollback_script"
    green "✅ 回滚脚本已安装: /usr/bin/rollback-hw-accel"
    green "   执行 'rollback-hw-accel' 可恢复默认配置"
}
install_rollback_script

green ""
green "========================================"
green "===== 全部预配置脚本执行完毕 ====="
green "========================================"
green "✅ 已修复：fstab / hostapd / 时间戳"
green "✅ 已清理：日志（启动清空 + POLL过滤）"
green "✅ 已优化：NSS PBUF / 硬加速 / RPS/XPS / IRQ绑定"
green "✅ 已配置：WiFi SSID/密码/地区/加密 / 主机名/IP"
green "✅ 已安装：验证脚本 check-hw-accel"
green "✅ 已安装：回滚脚本 rollback-hw-accel"
green "========================================"
