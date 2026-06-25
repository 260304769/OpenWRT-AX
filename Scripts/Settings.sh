#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# 专为 IPQ6018 (4核A53) 优化

green() { echo -e "\033[32m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

#==================== 变量检查 ====================
check_variables() {
    local missing=0
    for var in WRT_THEME WRT_SSID WRT_WORD WRT_IP WRT_NAME WRT_MARK WRT_DATE; do
        if [ -z "${!var}" ]; then
            red "❌ 未定义变量: $var"
            missing=1
        fi
    done
    [ $missing -eq 1 ] && exit 1
    green "✅ 变量检查通过"
}
check_variables

#==================== 1. Luci 配置 ====================
clean_luci() {
    green "===== Luci 配置 ====="
    sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile" 2>/dev/null) 2>/dev/null
    sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile" 2>/dev/null) 2>/dev/null
    sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js" 2>/dev/null) 2>/dev/null
    sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js" 2>/dev/null) 2>/dev/null
    green "✅ Luci 配置完成"
}
clean_luci

#==================== 2. 清理版本时间戳 ====================
clean_version_timestamp() {
    green "===== 清理版本时间戳 ====="
    local release="./package/base-files/files/etc/openwrt_release"
    if [ -f "$release" ]; then
        sed -i 's|/ [0-9]\{9\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}||g' "$release" 2>/dev/null
        sed -i 's|-[0-9]\{8\}||g' "$release" 2>/dev/null
        sed -i 's| [0-9]\{9\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}||g' "$release" 2>/dev/null
        green "✅ 版本时间戳已清理"
    fi
}
clean_version_timestamp

#==================== 3. 整合修复（IPQ6018 专用） ====================
integrated_fix() {
    green "===== 安装整合修复脚本 ====="
    
    local all_fix="./package/base-files/files/etc/init.d/00-integrated-fix"
    mkdir -p "$(dirname "$all_fix")"
    
    cat > "$all_fix" << 'EOF'
#!/bin/sh /etc/rc.common

START=60
STOP=10

boot() { start; }

start() {
    # fstab 目录修复
    mkdir -p /var/run/hostapd
    chown root:root /var/run/hostapd
    chmod 755 /var/run/hostapd
    
    # 日志限制
    [ -f /var/log/messages ] && > /var/log/messages
    echo 3 > /proc/sys/kernel/printk 2>/dev/null
    
    # hostapd 日志级别降低
    [ -f /var/run/hostapd.pid ] && kill -SIGUSR1 $(cat /var/run/hostapd.pid) 2>/dev/null
    
    # IPQ6018 NSS 延迟卸载
    (
        sleep 300
        lsmod | grep -q "^ifb " && rmmod ifb 2>/dev/null
        lsmod | grep -q "qca_nss_ecm_offload" && rmmod qca-nss-ecm-offload 2>/dev/null
        
        sleep 5
        [ -f /proc/sys/net/nss/nss_enable ] && echo 1 > /proc/sys/net/nss/nss_enable 2>/dev/null
        
        mkdir -p /var/run/nss
        [ -f /proc/sys/net/nss/nss_enable ] && cat /proc/sys/net/nss/nss_enable > /var/run/nss/status 2>/dev/null
        echo "$(date)" > /var/run/nss/started_at 2>/dev/null
    ) &
    
    # CPU 调度器（IPQ6018 4核A53）
    [ -f /sys/devices/system/cpu/cpufreq/policy0/scaling_governor ] && \
        echo schedutil > /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null
    
    echo "✅ 整合修复完成"
}
EOF
    
    chmod +x "$all_fix"
    green "✅ 整合修复脚本已安装"
}
integrated_fix

#==================== 4. 日志过滤（屏蔽 POLL） ====================
cleanup_logs() {
    green "===== 配置日志过滤 ====="
    
    local rsyslog_conf="./package/base-files/files/etc/rsyslog.d/80-filter.conf"
    mkdir -p "$(dirname "$rsyslog_conf")"
    
    cat > "$rsyslog_conf" << 'EOF'
# 丢弃 hostapd 轮询日志
:msg, contains, "AP-STA-POLL-OK" ~
:msg, contains, "AP-STA-POLL-OK" stop
EOF
    
    green "✅ rsyslog 过滤规则已添加"
}
cleanup_logs

#==================== 5. NSS PBUF 优化 ====================
update_nss_pbuf() {
    green "===== 配置 NSS PBUF ====="
    
    local conf="./package/kernel/mac80211/files/pbuf.uci"
    if [ -f "$conf" ]; then
        sed -i "s/auto_scale '1'/auto_scale 'off'/g" "$conf" 2>/dev/null
        sed -i "s/scaling_governor 'performance'/scaling_governor 'schedutil'/g" "$conf" 2>/dev/null
        green "✅ NSS PBUF 已优化"
    fi
}
update_nss_pbuf

#==================== 6. 硬加速配置（IPQ6018 4核专用） ====================
setup_hardware_acceleration() {
    green "===== 配置硬加速 ====="
    
    # 6.1 NSS sysctl 参数
    local sysctl_conf="./package/base-files/files/etc/sysctl.d/99-nss.conf"
    mkdir -p "$(dirname "$sysctl_conf")"
    
    cat > "$sysctl_conf" << 'EOF'
# NSS 网络加速参数
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
    
    # 6.2 开机硬件卸载脚本（IPQ6018 4核自适应）
    local hw_offload="./package/base-files/files/etc/init.d/hw-offload"
    mkdir -p "$(dirname "$hw_offload")"
    
    cat > "$hw_offload" << 'EOF'
#!/bin/sh /etc/rc.common

START=80
STOP=10

boot() { start; }

start() {
    sleep 10
    
    # 启用 NSS
    [ -f /proc/sys/net/nss/nss_enable ] && echo 1 > /proc/sys/net/nss/nss_enable 2>/dev/null
    [ -f /sys/module/nss_driver/parameters/force_offload ] && echo 1 > /sys/module/nss_driver/parameters/force_offload 2>/dev/null
    
    # 防火墙硬件卸载
    uci set firewall.@defaults[0].flow_offloading='1' 2>/dev/null
    uci set firewall.@defaults[0].flow_offloading_hw='1' 2>/dev/null
    uci commit firewall 2>/dev/null
    /etc/init.d/firewall restart 2>/dev/null
    
    # IPQ6018 = 4核A53，掩码 = f
    cpu_cores=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo 4)
    mask=$(printf "%x" $(( (1 << cpu_cores) - 1 )) 2>/dev/null)
    [ -z "$mask" ] && mask="f"
    
    # RPS 接收分散（所有CPU）
    for cpu in /sys/class/net/*/queues/rx-*/rps_cpus; do
        [ -f "$cpu" ] && echo "$mask" > "$cpu"
    done
    
    # XPS 发送分散（所有CPU）
    for cpu in /sys/class/net/*/queues/tx-*/xps_cpus; do
        [ -f "$cpu" ] && echo "$mask" > "$cpu"
    done
    
    # IRQ 轮询分配到所有CPU
    irq_list=$(grep -E "nss|qcom|ath11k|eth|gmac" /proc/interrupts 2>/dev/null | awk '{print $1}' | sed 's/://g')
    if [ -n "$irq_list" ]; then
        irq_idx=0
        for irq in $irq_list; do
            cpu_idx=$((irq_idx % cpu_cores))
            cpu_mask=$(printf "%x" $((1 << cpu_idx)) 2>/dev/null)
            [ -n "$cpu_mask" ] && echo "$cpu_mask" > /proc/irq/$irq/smp_affinity 2>/dev/null
            irq_idx=$((irq_idx + 1))
        done
    fi
    
    echo "✅ IPQ6018 硬件加速已启用 (${cpu_cores}核, 掩码: $mask)"
}
EOF
    
    chmod +x "$hw_offload"
    green "✅ 硬件加速开机脚本已安装（IRQ 自动轮询分配）"
    
    # 6.3 防火墙配置
    local fw_conf="./package/network/config/firewall/files/firewall.config"
    if [ -f "$fw_conf" ]; then
        sed -i 's/option flow_offloading.*/option flow_offloading "1"/g' "$fw_conf"
        sed -i 's/option flow_offloading_hw.*/option flow_offloading_hw "1"/g' "$fw_conf"
        green "✅ 防火墙硬件加速已启用"
    fi
}
setup_hardware_acceleration

#==================== 7. 冲突包检测（不改 .config） ====================
check_conflicts() {
    green "===== 检测 NSS/WiFi 冲突包 ====="
    
    local config_file="./.config"
    local has_conflict=false
    
    # IPQ6018 平台冲突包列表
    local conflict_pkgs=(
        "kmod-qca-nss-drv-wifi-meshmgr"
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
        "kmod-nft-offload"
        "kmod-nf-flow"
        "kmod-net-selftests"
        "odhcpd-ipv6only"
        "wpad-basic"
        "wpad-mesh"
        "ath10k-firmware-qca4019"
        "ath10k-firmware-qca9984"
    )
    
    echo ""
    echo "----------------------------------------"
    echo "🔍 IPQ6018 冲突包检测："
    echo "----------------------------------------"
    
    for pkg in "${conflict_pkgs[@]}"; do
        if grep -q "CONFIG_PACKAGE_${pkg}=y" "$config_file" 2>/dev/null; then
            echo "   ⚠️  发现: $pkg"
            has_conflict=true
        fi
    done
    
    echo "----------------------------------------"
    
    if [ "$has_conflict" = true ]; then
        echo ""
        yellow "⚠️  检测到冲突包！"
        echo ""
        echo "   这些包可能与 NSS 硬件加速不兼容："
        echo ""
        echo "   📌 隧道协议 (gre/l2tp/sit/6rd/ipip)"
        echo "      → 与 NSS 硬件卸载冲突，建议禁用"
        echo ""
        echo "   📌 nft-offload / nf-flow"
        echo "      → 与 NSS ECM 冲突，建议禁用"
        echo ""
        echo "   📌 wpad-mesh / kmod-qca-nss-drv-wifi-meshmgr"
        echo "      → 与 ath11k 驱动冲突，建议禁用"
        echo ""
        echo "   📌 odhcpd-ipv6only"
        echo "      → 与 odhcpd 冲突，建议禁用"
        echo ""
        echo "   📌 ath10k-firmware"
        echo "      → IPQ6018 应使用 ath11k，建议禁用"
        echo ""
        echo "   🔧 解决方案（三选一）："
        echo "   1. 手动修改 .config 将上述包设为 n"
        echo "   2. 在 PRIVATE.txt 中添加禁用配置"
        echo "   3. 运行 make menuconfig 手动调整"
        echo ""
        echo "   ⚠️  当前脚本不会自动修改 .config"
        echo "========================================"
    else
        green "✅ 无冲突包，配置正确"
    fi
}
check_conflicts

#==================== 8. 固化 WiFi 参数 ====================
setup_wifi() {
    green "===== 固化 WiFi 参数 ====="
    
    WIFI_SH=$(find ./target/linux/qualcommax/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null | head -1)
    WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
    
    if [ -f "$WIFI_SH" ]; then
        sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" "$WIFI_SH"
        sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" "$WIFI_SH"
        green "✅ WiFi 参数已固化（uci-defaults）"
    elif [ -f "$WIFI_UC" ]; then
        sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" "$WIFI_UC"
        sed -i "s/key='.*'/key='$WRT_WORD'/g" "$WIFI_UC"
        sed -i "s/country='.*'/country='CN'/g" "$WIFI_UC"
        sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" "$WIFI_UC"
        sed -i "s/disabled='1'/disabled='0'/g" "$WIFI_UC"
        green "✅ WiFi 参数已固化（mac80211.uc）"
    fi
}
setup_wifi

#==================== 9. 固化管理 IP 和主机名 ====================
setup_system_config() {
    green "===== 固化系统配置 ====="
    
    local cfg_file="./package/base-files/files/bin/config_generate"
    if [ -f "$cfg_file" ]; then
        sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$cfg_file"
        sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" "$cfg_file"
        green "✅ 管理 IP: $WRT_IP，主机名: $WRT_NAME"
    fi
}
setup_system_config

#==================== 10. 验证脚本 ====================
install_verify_script() {
    green "===== 安装硬加速验证脚本 ====="
    
    local verify_script="./package/base-files/files/usr/bin/check-hw-accel"
    mkdir -p "$(dirname "$verify_script")"
    
    cat > "$verify_script" << 'EOF'
#!/bin/sh

red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

echo ""
echo "========================================"
echo "    IPQ6018 硬加速状态检查"
echo "========================================"
echo ""

PASS=0
FAIL=0

# NSS 状态
echo -n "📡 NSS 引擎: "
if [ -f /proc/sys/net/nss/nss_enable ]; then
    status=$(cat /proc/sys/net/nss/nss_enable 2>/dev/null)
    if [ "$status" = "1" ]; then
        green "✅ 已启用"
        PASS=$((PASS+1))
    else
        red "❌ 未启用"
        FAIL=$((FAIL+1))
    fi
else
    red "❌ 不支持"
    FAIL=$((FAIL+1))
fi

# NSS 模块
echo -n "📦 NSS 模块: "
if lsmod | grep -q "qca_nss"; then
    green "✅ 已加载"
    PASS=$((PASS+1))
else
    red "❌ 未加载"
    FAIL=$((FAIL+1))
fi

# 防火墙硬件卸载
echo -n "🔥 硬件卸载: "
hw=$(uci get firewall.@defaults[0].flow_offloading_hw 2>/dev/null)
if [ "$hw" = "1" ]; then
    green "✅ 已启用"
    PASS=$((PASS+1))
else
    red "❌ 未启用"
    FAIL=$((FAIL+1))
fi

# RPS
echo -n "🔄 RPS 分散: "
rps=$(cat /sys/class/net/*/queues/rx-*/rps_cpus 2>/dev/null | head -1)
if [ "$rps" = "f" ] || [ "$rps" = "0000000f" ]; then
    green "✅ 4核全开"
    PASS=$((PASS+1))
else
    yellow "⚠️ 当前: $rps (预期 f)"
fi

# TCP BBR
echo -n "🚀 TCP 算法: "
cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
if [ "$cc" = "bbr" ]; then
    green "✅ $cc"
    PASS=$((PASS+1))
else
    yellow "⚠️ $cc"
fi

# CPU 调度器
echo -n "⚡ CPU 调度: "
gov=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)
if [ "$gov" = "schedutil" ]; then
    green "✅ $gov"
    PASS=$((PASS+1))
else
    yellow "⚠️ $gov"
fi

echo ""
echo "========================================"
echo "检查结果: ✅ $PASS 通过 | ❌ $FAIL 失败"
echo "========================================"

if [ $FAIL -eq 0 ]; then
    green "🎉 IPQ6018 硬加速全部正常"
else
    yellow "⚠️ 发现 $FAIL 个问题，请检查日志:"
    echo "   dmesg | grep -E 'nss|offload'"
    echo "   logread | grep -E 'nss|offload'"
fi
EOF
    
    chmod +x "$verify_script"
    green "✅ 验证脚本: /usr/bin/check-hw-accel"
}
install_verify_script

#==================== 11. 回滚脚本 ====================
install_rollback_script() {
    green "===== 安装硬加速回滚脚本 ====="
    
    local rollback_script="./package/base-files/files/usr/bin/rollback-hw-accel"
    mkdir -p "$(dirname "$rollback_script")"
    
    cat > "$rollback_script" << 'EOF'
#!/bin/sh

red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }

echo ""
echo "========================================"
echo "    IPQ6018 硬加速回滚"
echo "========================================"
echo ""
echo -n "⚠️ 确认回滚? (y/N): "
read -r confirm

[ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && echo "❌ 已取消" && exit 0

# 关闭 NSS
[ -f /proc/sys/net/nss/nss_enable ] && echo 0 > /proc/sys/net/nss/nss_enable 2>/dev/null
green "✅ NSS 已关闭"

# 关闭防火墙卸载
uci set firewall.@defaults[0].flow_offloading='0' 2>/dev/null
uci set firewall.@defaults[0].flow_offloading_hw='0' 2>/dev/null
uci commit firewall 2>/dev/null
green "✅ 防火墙卸载已关闭"

# 恢复 RPS/XPS
for cpu in /sys/class/net/*/queues/rx-*/rps_cpus; do
    [ -f "$cpu" ] && echo 0 > "$cpu"
done
for cpu in /sys/class/net/*/queues/tx-*/xps_cpus; do
    [ -f "$cpu" ] && echo 0 > "$cpu"
done
green "✅ RPS/XPS 已恢复"

# 恢复 CPU 调度器
[ -f /sys/devices/system/cpu/cpufreq/policy0/scaling_governor ] && \
    echo performance > /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null
green "✅ CPU 调度器已恢复"

# 禁用开机脚本
/etc/init.d/hw-offload stop 2>/dev/null
/etc/init.d/hw-offload disable 2>/dev/null
green "✅ hw-offload 已禁用"

echo ""
green "✅ IPQ6018 回滚完成！建议重启生效"
EOF
    
    chmod +x "$rollback_script"
    green "✅ 回滚脚本: /usr/bin/rollback-hw-accel"
}
install_rollback_script

#==================== 执行完成 ====================
green ""
green "========================================"
green "===== IPQ6018 预配置脚本执行完毕 ====="
green "========================================"
green "✅ 已修复：fstab / hostapd / 时间戳"
green "✅ 已清理：日志（启动清空 + POLL过滤）"
green "✅ 已优化：NSS PBUF / 硬加速 / RPS/XPS"
green "✅ 已配置：WiFi SSID/密码 / 主机名/IP"
green "✅ IRQ 分配：自动轮询到 4 核"
green "✅ 冲突检测：已执行（不改 .config）"
green "✅ 验证脚本：check-hw-accel"
green "✅ 回滚脚本：rollback-hw-accel"
green "========================================"
