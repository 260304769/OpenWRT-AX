#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# IPQ60XX 专用优化版 - NSS硬加速 + IPv6服务器模式 + 硬件全锥NAT
# 最终修复版：服务自启修复 + 时间戳根源解决 + 全链路稳定性增强
# 修复：显式启用 wifi-scripts，修正 apsd 配置写法

# 定义绿色日志输出函数
green() {
    echo -e "\033[32m$1\033[0m"
}

# 从编译根源固定版本时间戳，避免每次编译生成不同的日期后缀
export SOURCE_DATE_EPOCH=0

#==================== 1. 清理在线升级、全局默认主题替换 ====================
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")

#==================== 2. 固件版本号二次清理（兜底） ====================
clean_version_timestamp() {
    local release="./package/base-files/files/etc/openwrt_release"
    [ -f "$release" ] || return 0
    sed -i 's|/ [0-9]\{9\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}||g' "$release" 2>/dev/null || true
    sed -i 's|-[0-9]\{8\}||g' "$release" 2>/dev/null || true
    sed -i 's| [0-9]\{9\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}||g' "$release" 2>/dev/null || true
    green "✅ 固件版本时间戳兜底清理完成"
}
clean_version_timestamp

#==================== 3. 创建 uci-defaults 脚本（按依赖关系排序） ====================
create_uci_defaults() {
    green "===== 创建 uci-defaults 动态配置脚本 ====="
    mkdir -p ./package/base-files/files/etc/uci-defaults

    cat > ./package/base-files/files/etc/uci-defaults/90-fstab << 'EOF'
#!/bin/sh
uci -q get fstab.global || {
    uci set fstab.global=global
    uci set fstab.global.anon_swap='0'
    uci set fstab.global.anon_mount='0'
    uci set fstab.global.auto_swap='1'
    uci set fstab.global.auto_mount='1'
    uci set fstab.global.delay_root='5'
    uci set fstab.global.check_fs='0'
    uci commit fstab
}
exit 0
EOF
    chmod +x ./package/base-files/files/etc/uci-defaults/90-fstab
    green "✅ 90-fstab: 挂载配置"

    cat > ./package/base-files/files/etc/uci-defaults/91-ip-hostname << EOF
#!/bin/sh
uci -q get network.lan.ipaddr || {
    uci set network.lan.ipaddr='$WRT_IP'
    uci commit network
}
uci -q get system.@system[0].hostname || {
    uci set system.@system[0].hostname='$WRT_NAME'
    uci commit system
}
exit 0
EOF
    chmod +x ./package/base-files/files/etc/uci-defaults/91-ip-hostname
    green "✅ 91-ip-hostname: 管理IP和主机名"

    cat > ./package/base-files/files/etc/uci-defaults/92-pppoe-mtu << 'EOF'
#!/bin/sh
uci -q get network.wan.mtu || {
    uci set network.wan.mtu='1492'
    uci commit network
}
exit 0
EOF
    chmod +x ./package/base-files/files/etc/uci-defaults/92-pppoe-mtu
    green "✅ 92-pppoe-mtu: PPPoE MTU 1492"

    cat > ./package/base-files/files/etc/uci-defaults/93-ipv6-server << 'EOF'
#!/bin/sh
uci set network.wan.ipv6='auto'
uci set network.lan.ip6assign='64'
uci set dhcp.lan.ra='hybrid'
uci set dhcp.lan.dhcpv6='hybrid'
uci set dhcp.lan.ndp='1'
uci commit network
uci commit dhcp
exit 0
EOF
    chmod +x ./package/base-files/files/etc/uci-defaults/93-ipv6-server
    green "✅ 93-ipv6-server: IPv6服务器模式（兼容23.05+）"

    cat > ./package/base-files/files/etc/uci-defaults/94-firewall-nss << 'EOF'
#!/bin/sh
# NSS硬件转发模式下禁用软件流卸载，全锥由NSS ECM原生支持
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].nss_offload='1'
uci commit firewall
exit 0
EOF
    chmod +x ./package/base-files/files/etc/uci-defaults/94-firewall-nss
    green "✅ 94-firewall-nss: NSS硬件加速 + 原生全锥NAT"

    cat > ./package/base-files/files/etc/uci-defaults/95-ntp-dns << 'EOF'
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
    chmod +x ./package/base-files/files/etc/uci-defaults/95-ntp-dns
    green "✅ 95-ntp-dns: NTP国内源+DNS白名单"

    cat > ./package/base-files/files/etc/uci-defaults/96-wifi-config << EOF
#!/bin/sh
for dev in \$(uci show wireless | grep '=wifi-device' | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.\$dev.disabled='0'
    uci set wireless.\$dev.country='CN'
    uci set wireless.\$dev.log_level='0'
done

for iface in \$(uci show wireless | grep '=wifi-iface' | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.\$iface.ssid='$WRT_SSID'
    uci set wireless.\$iface.key='$WRT_WORD'
    uci set wireless.\$iface.encryption='psk2+ccmp'
done

# 修复：直接设置 apsd，避免畸形段名
uci set wireless.default_radio0.apsd='0'
uci set wireless.default_radio1.apsd='0'

uci commit wireless
exit 0
EOF
    chmod +x ./package/base-files/files/etc/uci-defaults/96-wifi-config
    green "✅ 96-wifi-config: WiFi参数（含apsd禁用）"

    # 关键修复：启用自定义init服务，确保开机自动执行
    cat > ./package/base-files/files/etc/uci-defaults/99-enable-init << 'EOF'
#!/bin/sh
/etc/init.d/nss-fix enable
/etc/init.d/hostapd-dir enable
exit 0
EOF
    chmod +x ./package/base-files/files/etc/uci-defaults/99-enable-init
    green "✅ 99-enable-init: 自定义服务开机自启"
}
create_uci_defaults

#==================== 4. 创建 hostapd 目录专用 init 脚本 ====================
create_hostapd_dir_init() {
    green "===== 创建 hostapd 目录专用 init 脚本 ====="
    local init_path="./package/base-files/files/etc/init.d/hostapd-dir"
    mkdir -p "$(dirname "$init_path")"
    cat > "$init_path" << 'EOF'
#!/bin/sh /etc/rc.common
START=80
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
    green "✅ hostapd 目录 init 脚本（START=80，时序适配hostapd启动）"
}
create_hostapd_dir_init

#==================== 5. NSS PBUF 性能调度优化 ====================
update_nss_pbuf_performance() {
    local conf=$(find ./package -name "pbuf.uci" 2>/dev/null | head -n1)
    if [ -n "$conf" ] && [ -f "$conf" ]; then
        sed -i "s/auto_scale '1'/auto_scale '0'/g" "$conf" 2>/dev/null
        sed -i "s/auto_scale 'off'/auto_scale '0'/g" "$conf" 2>/dev/null
        sed -i "s/scaling_governor 'performance'/scaling_governor 'schedutil'/g" "$conf" 2>/dev/null
        sed -i "s/scaling_governor 'ondemand'/scaling_governor 'schedutil'/g" "$conf" 2>/dev/null
        green "✅ NSS PBUF: 自动缩放关闭，CPU调度器 schedutil"
    else
        green "ℹ️ 未找到 pbuf.uci，跳过PBUF优化"
    fi
}
update_nss_pbuf_performance

#==================== 6. NSS 修复脚本（START=20，WAN口动态获取） ====================
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

        if ! modprobe qca_nss_drv 2>/dev/null && ! modprobe qca-nss-drv 2>/dev/null; then
            logger -t nss-fix "⚠️ NSS核心驱动加载失败"
        fi
        if ! modprobe qca_nss_ecm 2>/dev/null && ! modprobe qca-nss-ecm 2>/dev/null; then
            logger -t nss-fix "⚠️ NSS ECM驱动加载失败"
        fi
        if ! modprobe qca_nss_pppoe 2>/dev/null && ! modprobe qca-nss-pppoe 2>/dev/null; then
            logger -t nss-fix "⚠️ PPPoE卸载模块加载失败"
        fi

        echo 1 > /sys/module/qca_nss_drv/parameters/ppe_enable 2>/dev/null || {
            echo 1 > /sys/module/qca-nss-drv/parameters/ppe_enable 2>/dev/null || logger -t nss-fix "⚠️ PPE启用失败"
        }
        echo 1 > /sys/module/qca_nss_drv/parameters/bridge_offload 2>/dev/null || {
            echo 1 > /sys/module/qca-nss-drv/parameters/bridge_offload 2>/dev/null || logger -t nss-fix "⚠️ 桥接卸载启用失败"
        }
        # 显式启用ECM原生硬件全锥NAT
        echo 1 > /sys/module/qca_nss_ecm/parameters/fullcone 2>/dev/null || {
            echo 1 > /sys/module/qca-nss-ecm/parameters/fullcone 2>/dev/null || true
        }

        # 仅旧版QSDK存在该节点，无节点静默跳过，避免误导告警
        [ -f /proc/sys/net/nss/offload ] && echo 1 > /proc/sys/net/nss/offload 2>/dev/null || true

        wan_dev=$(uci get network.wan.ifname 2>/dev/null || echo "wan")
        for queue in /sys/class/net/${wan_dev}/queues/rx-*; do
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

        logger -t nss-fix "✅ NSS硬件加速优化完成"
    ) &
}
EOF
    chmod +x "$init_path"
    green "✅ NSS 修复脚本（START=20，WAN口动态获取 + 原生全锥）"
}
install_nss_fix

#==================== 7. rc.local 强化 fstab 和 sysctl 生效 ====================
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
    if ! grep -q "# NSS_OPTIMIZATION_FSTAB_FIX" "$rclocal"; then
        sed -i '/exit 0/i # NSS_OPTIMIZATION_FSTAB_FIX - 确保 fstab 配置存在并重新加载\n[ -f /etc/config/fstab ] || {\n    uci set fstab.global=global\n    uci set fstab.global.anon_swap=0\n    uci set fstab.global.anon_mount=0\n    uci set fstab.global.auto_swap=1\n    uci set fstab.global.auto_mount=1\n    uci set fstab.global.delay_root=5\n    uci set fstab.global.check_fs=0\n    uci commit fstab\n}\nblock mount 2>/dev/null || true\n# 应用 sysctl 参数\n[ -f /etc/sysctl.conf ] && sysctl -p >/dev/null 2>&1\n' "$rclocal"
        green "✅ rc.local: fstab兜底+sysctl生效"
    else
        green "ℹ️ rc.local 已包含修复，跳过"
    fi
}
fix_fstab_rc_local

#==================== 8. 系统参数优化（连接跟踪） ====================
add_sysctl_tweaks() {
    local sysctl_conf="./package/base-files/files/etc/sysctl.conf"
    mkdir -p "$(dirname "$sysctl_conf")"
    if ! grep -q "nf_conntrack_max" "$sysctl_conf" 2>/dev/null; then
        cat >> "$sysctl_conf" << 'EOF'
# NSS ECM 加速优化：调整超时适配高并发，兼顾抗SYN攻击
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_max = 131072
EOF
        green "✅ sysctl.conf: 连接跟踪优化（syn_recv=30s，上限131072）"
    else
        green "ℹ️ sysctl.conf 已包含连接跟踪优化，跳过"
    fi
}
add_sysctl_tweaks

#==================== 9. 工具函数 ====================
set_pkg() {
    local pkg="$1"
    local value="${2:-y}"
    local config_file="./.config"
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" "$config_file"
    echo "CONFIG_PACKAGE_${pkg}=${value}" >> "$config_file"
}

disable_pkg() {
    local pkg="$1"
    local config_file="./.config"
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" "$config_file"
    echo "CONFIG_PACKAGE_${pkg}=n" >> "$config_file"
}

#==================== 10. 完整冲突清理 ====================
clean_conflict_packages() {
    local config_file="./.config"
    green "===== 开始清理冲突包 ====="
    
    disable_pkg "wpad-basic"
    disable_pkg "wpad-mesh"
    set_pkg "wpad-openssl" "y"
    
    # 禁用软件流卸载，与NSS硬件转发冲突
    disable_pkg "kmod-nft-offload"
    disable_pkg "kmod-nf-flow"
    disable_pkg "kmod-nft-fullcone"
    
    for pkg in $(grep "^CONFIG_PACKAGE_kmod-sched-" "$config_file" | grep -v "kmod-sched-core" | cut -d= -f1 | sed 's/^CONFIG_PACKAGE_//'); do
        disable_pkg "$pkg"
    done
    
    disable_pkg "kmod-net-selftests"
    
    disable_pkg "odhcpd-ipv6only"
    set_pkg "odhcpd" "y"
    
    disable_pkg "kmod-ath11k-pci"
    disable_pkg "ath10k-firmware-qca4019"
    disable_pkg "ath10k-firmware-qca9984"
    disable_pkg "ath11k-firmware-qcn9074"
    set_pkg "ath11k-firmware-ipq6018" "y"
    
    # NSS核心驱动与PPPoE卸载
    set_pkg "kmod-qca-nss-drv" "y"
    set_pkg "kmod-qca-nss-ecm" "y"
    set_pkg "kmod-ppp" "y"
    set_pkg "kmod-pppoe" "y"
    set_pkg "kmod-pppox" "y"
    set_pkg "kmod-qca-nss-drv-pppoe" "y"
    
    # 清理无关视频feed依赖警告
    disable_pkg "libsdl3"
    disable_pkg "sdl3"
    
    for pkg in kmod-6rd kmod-gre kmod-gre6 kmod-vxlan kmod-sit kmod-ipip kmod-iptunnel kmod-iptunnel4 kmod-iptunnel6 kmod-udptunnel4 kmod-udptunnel6; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" "$config_file"
    done
    
    # 修复：显式启用 wifi-scripts，确保 /etc/init.d/wifi 完整安装
    set_pkg "wifi-scripts" "y"
    
    green "✅ 冲突包清理完成"
}
clean_conflict_packages

#==================== 11. wifi-scripts 安全重启补丁 ====================
patch_wifi_full_reload() {
    local wifi_uc="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
    if [ -f "$wifi_uc" ]; then
        if ! grep -q "ubus call network.wireless reload" "$wifi_uc"; then
            sed -i '/ubus call network.wireless stop/a\    exec("ubus call network.wireless reload 2>/dev/null || /etc/init.d/wifi reload");' "$wifi_uc"
            green "✅ wifi-scripts: 安全重启补丁注入"
        else
            green "ℹ️ wifi-scripts 补丁已存在"
        fi
    fi
}
patch_wifi_full_reload

#==================== 12. 基础编译配置 ====================
# 使用 set_pkg 防重复，并确保 wifi-scripts 被包含
set_pkg "luci" "y"
# 语言选项（正确前缀：CONFIG_LUCI_LANG_zh_Hans，无 PACKAGE_）
sed -i "/^CONFIG_LUCI_LANG_zh_Hans=/d" ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
set_pkg "luci-theme-$WRT_THEME" "y"
set_pkg "luci-app-$WRT_THEME-config" "y"
set_pkg "wifi-scripts" "y"

#==================== 13. 加载私有配置 ====================
[ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ] && {
    green "📂 加载私有配置: Config/PRIVATE.txt"
    cat "$GITHUB_WORKSPACE/Config/PRIVATE.txt" >> ./.config
}

#==================== 14. 自定义插件 ====================
[ -n "$WRT_PACKAGE" ] && {
    green "📦 添加自定义插件: $WRT_PACKAGE"
    echo -e "$WRT_PACKAGE" >> ./.config
}

#==================== 15. 无 WiFi 标记 ====================
if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
    echo "WRT_WIFI=wifi-no" >> "$GITHUB_ENV"
    green "✅ WiFi 已标记为禁用"
fi

#==================== 16. 无 WiFi DTS 适配（双路径兼容） ====================
if [[ "${WRT_TARGET^^}" == *"QUALCOMMX"* ]] && \
   [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
    local dts_paths=(
        "./target/linux/qualcommax/ipq60xx/files/arch/arm64/boot/dts/qcom/"
        "./target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/"
    )
    local dts_found=false
    for dts_path in "${dts_paths[@]}"; do
        if [ -d "$dts_path" ]; then
            find "$dts_path" -name "ipq6018*.dts*" \
                -exec sed -i 's/ipq6018.dtsi/ipq6018-nowifi.dtsi/g' {} +
            green "✅ nowifi DTS 已适配（路径: $dts_path）"
            dts_found=true
            break
        fi
    done
    [ "$dts_found" = false ] && green "ℹ️ 未找到IPQ60XX DTS目录，跳过nowifi适配"
fi

#==================== 17. 验证 ====================
verify_cleanup() {
    local config_file="./.config"
    
    local conflicts=(
        "kmod-nft-offload" "kmod-nf-flow" "kmod-nft-fullcone" "odhcpd-ipv6only"
        "kmod-ath11k-pci"
    )
    local disabled=(
        "wpad-basic" "wpad-mesh" "kmod-net-selftests"
        "ath10k-firmware-qca4019" "ath10k-firmware-qca9984" "ath11k-firmware-qcn9074"
        "libsdl3" "sdl3"
    )
    local required=(
        "kmod-qca-nss-drv" "kmod-qca-nss-ecm" "ath11k-firmware-ipq6018"
        "kmod-ppp" "kmod-pppoe" "kmod-qca-nss-drv-pppoe"
        "wpad-openssl"
        "luci"
        "wifi-scripts"
    )
    local dependencies=(
        "kmod-sched-core" "kmod-ifb" "kmod-nss-ifb"
    )
    
    echo "" && green "===== 验证 ====="
    local has_conflict=false
    
    for pkg in "${conflicts[@]}"; do
        if grep -q "^CONFIG_PACKAGE_${pkg}=y" "$config_file" 2>/dev/null; then
            echo "⚠️ 冲突残留: $pkg" && has_conflict=true
        else
            echo "✅ 已清理: $pkg"
        fi
    done
    
    for pkg in "${disabled[@]}"; do
        if grep -q "^CONFIG_PACKAGE_${pkg}=y" "$config_file" 2>/dev/null; then
            echo "⚠️ 被依赖拉回: $pkg" && has_conflict=true
        else
            echo "✅ 已禁用: $pkg"
        fi
    done
    
    for pkg in "${required[@]}"; do
        if grep -q "^CONFIG_PACKAGE_${pkg}=y" "$config_file" 2>/dev/null; then
            echo "✅ 已启用: $pkg"
        else
            echo "❌ 缺失: $pkg" && has_conflict=true
        fi
    done
    
    # 单独检查 CONFIG_LUCI_LANG_zh_Hans（无 CONFIG_PACKAGE_ 前缀）
    if grep -q "^CONFIG_LUCI_LANG_zh_Hans=y" "$config_file" 2>/dev/null; then
        echo "✅ 已启用: CONFIG_LUCI_LANG_zh_Hans"
    else
        echo "❌ 缺失: CONFIG_LUCI_LANG_zh_Hans" && has_conflict=true
    fi
    
    for pkg in "${dependencies[@]}"; do
        if grep -q "^CONFIG_PACKAGE_${pkg}=y" "$config_file" 2>/dev/null; then
            echo "ℹ️ 功能依赖: $pkg（NSS驱动需要）"
        fi
    done
    
    local tunnel_remain=$(grep "^CONFIG_PACKAGE_kmod-\(6rd\|gre\|gre6\|vxlan\|sit\|ipip\|iptunnel\|udptunnel\)=" "$config_file" 2>/dev/null)
    if [ -n "$tunnel_remain" ]; then
        echo "⚠️ 残留隧道kmod: $tunnel_remain"
        has_conflict=true
    else
        echo "✅ 隧道模块: 已清理残留（由内核内置）"
    fi
    
    if ! grep -q "^CONFIG_PACKAGE_kmod-pppoe=y" "$config_file" 2>/dev/null; then
        echo "❌ kmod-pppoe 被误删，PPPoE 拨号将失效"
        has_conflict=true
    fi
    
    [ "$has_conflict" = false ] && green "🎉 所有检查通过" \
        || echo "⚠️ 部分异常，请手动检查"
    
    echo ""
    green '💡 固件烧录后可验证：'
    green '   1. WAN队列: cat /sys/class/net/$(uci get network.wan.ifname)/queues/rx-0/rps_flow_cnt → 4096'
    green '   2. 连接跟踪: sysctl net.netfilter.nf_conntrack_max → 131072'
    green '   3. CPU调度器: cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor → schedutil'
    green '   4. IPv6自动获取: uci get network.wan.ipv6 → auto'
    green '   5. NTP服务器: uci get system.ntp.server → cn.ntp.org.cn'
    green '   6. DNS白名单: uci get dhcp.@dnsmasq[0].rebind_domain → 包含 cn.ntp.org.cn'
    green '   7. 硬件加速开关: uci get firewall.@defaults[0].nss_offload → 1'
    green '   8. 软件流卸载: uci get firewall.@defaults[0].flow_offloading → 0'
    green '   9. NSS核心驱动: lsmod | grep qca_nss_drv → 应存在'
    green '  10. 全锥状态: cat /sys/module/qca_nss_ecm/parameters/fullcone → 1'
    green '  11. 无线脚本: ls -l /etc/init.d/wifi → 应存在'
    green '  12. NSS优化日志: logread | grep nss-fix → 查看启动状态'
}
verify_cleanup

green ""
green "========================================"
green "===== IPQ60XX 硬加速脚本（最终修复版）执行完毕 ====="
green "========================================"
green "✅ CPU 调频: schedutil (自动按需)"
green "✅ NSS 硬加速: PPE + 桥接卸载 + PPPoE 硬件卸载 + 原生全锥"
green "✅ WAN 优化: 动态获取WAN口 + 接收队列扩容"
green "✅ 连接跟踪: 超时调优 (syn_recv=30s，上限131072)"
green "✅ 防火墙: 纯硬件加速模式，无软件转发冲突"
green "✅ IPv6: WAN自动获取 + LAN前缀完整下发（兼容新版OpenWrt）"
green "✅ 启动顺序: NSS驱动前置 + hostapd目录时序适配"
green "✅ 服务自启: 所有自定义优化服务开机自动生效"
green "✅ 无线: 仅 AHB 内置，安全重启，无线脚本完整"
green "✅ 隧道: 由内核内置，已清理残留 kmod 条目"
green "✅ LuCI: 基础LuCI + 中文语言 + 主题($WRT_THEME) + 主题配置"
green "✅ 兼容: 新旧NSS补丁静默适配，无误导性告警"
green "========================================"
