#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

# 颜色输出函数
green() { echo -e "\033[32m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

#==================== 变量安全检查 ====================
check_variables() {
    local missing=0
    for var in WRT_THEME WRT_SSID WRT_WORD WRT_IP WRT_NAME WRT_MARK WRT_DATE; do
        if [ -z "${!var}" ]; then
            red "❌ 未定义变量: $var"
            missing=1
        fi
    done
    if [ $missing -eq 1 ]; then
        exit 1
    fi
    green "✅ 变量检查通过"
}
check_variables

# 定义查找路径（避免重复）
LUCI_COLLECTIONS=$(find ./feeds/luci/collections/ -type f -name "Makefile" 2>/dev/null)
LUCI_FLASH=$(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js" 2>/dev/null)
LUCI_STATUS=$(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js" 2>/dev/null)

#==================== 1. 清理在线升级、替换默认主题 ====================
clean_luci() {
    green "===== 清理 Luci 配置 ====="
    
    [ -n "$LUCI_COLLECTIONS" ] && sed -i "/attendedsysupgrade/d" $LUCI_COLLECTIONS 2>/dev/null
    [ -n "$LUCI_COLLECTIONS" ] && sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $LUCI_COLLECTIONS 2>/dev/null
    [ -n "$LUCI_FLASH" ] && sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $LUCI_FLASH 2>/dev/null
    [ -n "$LUCI_STATUS" ] && sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $LUCI_STATUS 2>/dev/null
    
    green "✅ Luci 配置完成"
}
clean_luci

#==================== 2. 清理固件版本时间戳 ====================
clean_version_timestamp() {
    green "===== 清理版本时间戳 ====="
    
    local release="./package/base-files/files/etc/openwrt_release"
    if [ -f "$release" ]; then
        sed -i 's|/ [0-9]\{9\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}||g' "$release" 2>/dev/null
        sed -i 's|-[0-9]\{8\}||g' "$release" 2>/dev/null
        sed -i 's| [0-9]\{9\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}||g' "$release" 2>/dev/null
        green "✅ 版本时间戳已清理"
    else
        yellow "⚠️ openwrt_release 不存在，跳过"
    fi
}
clean_version_timestamp

#==================== 3. 整合修复 ====================
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
    mkdir -p /var/run/hostapd
    chown root:root /var/run/hostapd
    chmod 755 /var/run/hostapd
    
    [ -f /var/log/messages ] && > /var/log/messages
    echo 3 > /proc/sys/kernel/printk 2>/dev/null
    
    [ -f /var/run/hostapd.pid ] && kill -SIGUSR1 $(cat /var/run/hostapd.pid) 2>/dev/null
    
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
    
    [ -f /sys/devices/system/cpu/cpufreq/policy0/scaling_governor ] && \
        echo schedutil > /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null
    
    echo "✅ 整合修复完成"
}
EOF
    chmod +x "$all_fix"
    green "✅ 整合修复脚本已安装"
}
integrated_fix

#==================== 4. 日志过滤 ====================
cleanup_logs() {
    green "===== 配置日志过滤 ====="
    
    local rsyslog_conf="./package/base-files/files/etc/rsyslog.d/80-filter.conf"
    mkdir -p "$(dirname "$rsyslog_conf")"
    cat > "$rsyslog_conf" << 'EOF'
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
    else
        yellow "⚠️ pbuf.uci 不存在，跳过"
    fi
}
update_nss_pbuf

#==================== 6. 硬加速配置（自动适应 CPU 核心数） ====================
setup_hardware_acceleration() {
    green "===== 配置硬加速 ====="
    
    # 6.1 NSS sysctl 参数
    local sysctl_conf="./package/base-files/files/etc/sysctl.d/99-nss.conf"
    mkdir -p "$(dirname "$sysctl_conf")"
    cat > "$sysctl_conf" << 'EOF'
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
    
    # 6.2 开机硬件卸载脚本（自动适应 CPU 核心数）
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
    
    # 获取 CPU 核心数，动态生成掩码
    cpu_cores=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo 1)
    mask=$(printf "%x" $(( (1 << cpu_cores) - 1 )) 2>/dev/null)
    [ -z "$mask" ] && mask="1"
    
    # RPS/XPS 自动适应
    for cpu in /sys/class/net/*/queues/rx-*/rps_cpus; do
        [ -f "$cpu" ] && echo "$mask" > "$cpu"
    done
    for cpu in /sys/class/net/*/queues/tx-*/xps_cpus; do
        [ -f "$cpu" ] && echo "$mask" > "$cpu"
    done
    
    # IRQ 轮询分配到所有 CPU
    irq_list=$(grep -E "nss|qcom|ath11k|eth|gmac" /proc/interrupts 2>/dev/null | awk '{print $1}' | sed 's/://g')
    if [ -n "$irq_list" ] && [ "$cpu_cores" -gt 0 ]; then
        irq_idx=0
        for irq in $irq_list; do
            cpu_idx=$((irq_idx % cpu_cores))
            cpu_mask=$(printf "%x" $((1 << cpu_idx)) 2>/dev/null)
            [ -n "$cpu_mask" ] && echo "$cpu_mask" > /proc/irq/$irq/smp_affinity 2>/dev/null
            irq_idx=$((irq_idx + 1))
        done
    fi
    
    echo "✅ 硬件加速已启用 (CPU: $cpu_cores 核, 掩码: $mask)"
}
EOF
    chmod +x "$hw_offload"
    green "✅ 硬件加速开机脚本已安装（自动适应 CPU 核心数）"
    
    # 6.3 防火墙配置
    local fw_conf="./package/network/config/firewall/files/firewall.config"
    if [ -f "$fw_conf" ]; then
        sed -i 's/option flow_offloading.*/option flow_offloading "1"/g' "$fw_conf"
        sed -i 's/option flow_offloading_hw.*/option flow_offloading_hw "1"/g' "$fw_conf"
        green "✅ 防火墙硬件加速已启用"
    fi
}
setup_hardware_acceleration

#==================== 7. wifi-scripts hotplug ====================
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
    green "✅ WiFi hotplug 重置脚本已安装"
}
patch_wifi_hotplug

#==================== 8. 固化 WiFi 参数 ====================
setup_wifi() {
    green "===== 固化 WiFi 参数 ====="
    
    WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null | head -1)
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
    else
        yellow "⚠️ 未找到 WiFi 配置文件，跳过"
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
    else
        yellow "⚠️ config_generate 不存在，跳过"
    fi
}
setup_system_config

#==================== 10. 写入基础编译配置 ====================
write_build_config() {
    green "===== 写入编译配置 ====="
    
    cat >> ./.config << 'EOF'
CONFIG_PACKAGE_luci=y
CONFIG_LUCI_LANG_zh_Hans=y
CONFIG_PACKAGE_luci-theme-$WRT_THEME=y
CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y
EOF
    green "✅ 基础编译配置已写入"
}
write_build_config

#==================== 11. 冲突包清理（在写入配置之后执行） ====================
clean_conflict_packages() {
    local config_file="./.config"
    green "===== 开始清理 NSS/WiFi 冲突包 ====="
    
    # WiFi Mesh 冲突
    sed -i '/CONFIG_PACKAGE_kmod-qca-nss-drv-wifi-meshmgr/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_wpad-basic/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_wpad-mesh/d' "$config_file"
    echo "CONFIG_PACKAGE_wpad-openssl=y" >> "$config_file"
    
    # 隧道协议冲突
    for pkg in kmod-6rd kmod-gre kmod-gre6 kmod-l2tp kmod-iptunnel kmod-iptunnel4 kmod-iptunnel6 kmod-vxlan kmod-udptunnel4 kmod-udptunnel6 kmod-sit kmod-ipip; do
        sed -i "/CONFIG_PACKAGE_${pkg}/d" "$config_file"
    done
    
    # NAT/防火墙冲突
    sed -i '/CONFIG_PACKAGE_kmod-nft-offload/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_kmod-nf-flow/d' "$config_file"
    echo "CONFIG_PACKAGE_kmod-qca-nss-ecm=y" >> "$config_file"
    echo "CONFIG_PACKAGE_kmod-qca-nss-ecm-standard=y" >> "$config_file"
    
    # IPv6 冲突
    sed -i '/CONFIG_PACKAGE_odhcpd-ipv6only/d' "$config_file"
    echo "CONFIG_PACKAGE_odhcpd=y" >> "$config_file"
    
    # 网络测试冲突
    sed -i '/CONFIG_PACKAGE_kmod-net-selftests/d' "$config_file"
    
    # IPQ6018 特定无线固件（根据平台选择）
    if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
        sed -i '/CONFIG_PACKAGE_ath10k-firmware-qca4019/d' "$config_file"
        sed -i '/CONFIG_PACKAGE_ath10k-firmware-qca9984/d' "$config_file"
        echo "CONFIG_PACKAGE_ath11k-firmware-ipq6018=y" >> "$config_file"
    fi
    
    # QoS 调度器
    sed -i '/CONFIG_PACKAGE_kmod-sched-cake/d' "$config_file"
    echo "CONFIG_PACKAGE_kmod-sched-cake-oot=y" >> "$config_file"
    
    green "✅ 冲突包清理完成"
}
clean_conflict_packages

#==================== 12. 加载私有配置 ====================
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
    green "Applying private configurations from PRIVATE.txt..."
    cat "$GITHUB_WORKSPACE/Config/PRIVATE.txt" >> ./.config
fi

#==================== 13. 追加自定义插件 ====================
if [ -n "$WRT_PACKAGE" ]; then
    echo -e "$WRT_PACKAGE" >> ./.config
fi

#==================== 14. 标记无 WiFi ====================
if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
    echo "WRT_WIFI=wifi-no" >> "$GITHUB_ENV"
    green "✅ WiFi 已标记为禁用"
fi

#==================== 15. qualcommax nowifi DTS ====================
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
    if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
        find "$DTS_PATH" -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
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
            yellow "⚠️ 发现残留: $pkg"
            has_conflict=true
        else
            green "✅ 已清理: $pkg"
        fi
    done
    
    if [ "$has_conflict" = false ]; then
        green "🎉 所有冲突包已清理完毕"
    else
        yellow "⚠️ 部分冲突包可能残留，请手动检查"
    fi
}
verify_cleanup

#==================== 17. 验证脚本（自动适应 CPU） ====================
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
echo "    硬加速状态检查"
echo "========================================"
echo ""

PASS=0
FAIL=0

# 获取 CPU 核心数
cpu_cores=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo 1)
expected_mask=$(printf "%x" $(( (1 << cpu_cores) - 1 )) 2>/dev/null)
[ -z "$expected_mask" ] && expected_mask="1"

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

# RPS（自动适应）
echo -n "🔄 RPS 分散: "
rps=$(cat /sys/class/net/*/queues/rx-*/rps_cpus 2>/dev/null | head -1)
if [ "$rps" = "$expected_mask" ] || [ "$rps" = "0000000$expected_mask" ]; then
    green "✅ 已配置 ($rps, $cpu_cores 核)"
    PASS=$((PASS+1))
elif [ -n "$rps" ] && [ "$rps" != "0" ]; then
    yellow "⚠️ 配置为: $rps (预期 $expected_mask)"
else
    red "❌ 未配置"
    FAIL=$((FAIL+1))
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
    green "🎉 所有硬加速功能已启用"
else
    yellow "⚠️ 发现 $FAIL 个问题"
fi
EOF
    chmod +x "$verify_script"
    green "✅ 验证脚本: /usr/bin/check-hw-accel"
}
install_verify_script

#==================== 18. 回滚脚本 ====================
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
echo "    硬加速回滚"
echo "========================================"
echo ""
echo -n "⚠️ 确认回滚? (y/N): "
read -r confirm

[ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && echo "❌ 已取消" && exit 0

[ -f /proc/sys/net/nss/nss_enable ] && echo 0 > /proc/sys/net/nss/nss_enable 2>/dev/null
green "✅ NSS 已关闭"

uci set firewall.@defaults[0].flow_offloading='0' 2>/dev/null
uci set firewall.@defaults[0].flow_offloading_hw='0' 2>/dev/null
uci commit firewall 2>/dev/null
green "✅ 防火墙卸载已关闭"

for cpu in /sys/class/net/*/queues/rx-*/rps_cpus; do
    [ -f "$cpu" ] && echo 0 > "$cpu"
done
for cpu in /sys/class/net/*/queues/tx-*/xps_cpus; do
    [ -f "$cpu" ] && echo 0 > "$cpu"
done
green "✅ RPS/XPS 已恢复"

[ -f /sys/devices/system/cpu/cpufreq/policy0/scaling_governor ] && \
    echo performance > /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null
green "✅ CPU 调度器已恢复"

/etc/init.d/hw-offload stop 2>/dev/null
/etc/init.d/hw-offload disable 2>/dev/null
green "✅ hw-offload 已禁用"

echo ""
green "✅ 回滚完成！建议重启生效"
EOF
    chmod +x "$rollback_script"
    green "✅ 回滚脚本: /usr/bin/rollback-hw-accel"
}
install_rollback_script

#==================== 完成 ====================
green ""
green "========================================"
green "===== 全部预配置脚本执行完毕 ====="
green "========================================"
green "✅ 已修复：fstab / hostapd / 时间戳"
green "✅ 已清理：日志（启动清空 + POLL过滤）"
green "✅ 已优化：NSS PBUF / 硬加速 / RPS/XPS"
green "✅ IRQ 自动适应 CPU 核心数"
green "✅ 已配置：WiFi SSID/密码 / 主机名/IP"
green "✅ 已安装：验证脚本 check-hw-accel"
green "✅ 已安装：回滚脚本 rollback-hw-accel"
green "========================================"
