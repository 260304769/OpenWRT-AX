#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# OpenWrt NSS IPQ60xx 编译预处理脚本 v3.4 FINAL

#=========================================================
# 0. 全局配置与工具函数
#=========================================================
set -u
readonly DEBUG="${DEBUG:-0}"

# 颜色输出函数
green() { echo -e "\033[32m[INFO] $1\033[0m"; }
yellow() { echo -e "\033[33m[WARN] $1\033[0m"; }
red() { echo -e "\033[31m[ERROR] $1\033[0m" >&2; }
debug() { [ "${DEBUG}" -eq 1 ] && echo -e "\033[36m[DEBUG] $1\033[0m"; }

# 错误处理
error_exit() {
    red "脚本在第 $1 行执行失败"
    exit 1
}
trap 'error_exit $LINENO' ERR

# 全局路径变量
readonly CONFIG_FILE="./.config"
readonly BASE_FILES="./package/base-files/files"
readonly ETC_DIR="${BASE_FILES}/etc"
readonly INIT_DIR="${ETC_DIR}/init.d"
readonly CONFIG_DIR="${ETC_DIR}/config"
readonly HOTPLUG_DIR="${ETC_DIR}/hotplug.d"

# 标记段
readonly MARKER_START="# >>> VIKINGYFY AUTO CONFIG START >>>"
readonly MARKER_END="# <<< VIKINGYFY AUTO CONFIG END <<<"

#=========================================================
# 架构判断（v3.4：环境变量 + .config 双源检测）
#=========================================================
IS_IPQ60() {
    if [[ "${WRT_TARGET:-}" =~ ^ipq60 ]]; then
        debug "架构判断: WRT_TARGET=${WRT_TARGET} -> IPQ60xx"
        return 0
    fi
    if [ -f "$CONFIG_FILE" ]; then
        if grep -q "CONFIG_TARGET_qualcommax_ipq60xx=y" "$CONFIG_FILE" 2>/dev/null; then
            debug "架构判断: .config 检测到 CONFIG_TARGET_qualcommax_ipq60xx=y -> IPQ60xx"
            return 0
        fi
        if grep -qE "CONFIG_TARGET.*ipq60[0-9]*.*=y" "$CONFIG_FILE" 2>/dev/null; then
            debug "架构判断: .config 检测到 IPQ60 系列平台"
            return 0
        fi
    fi
    debug "架构判断: 非 IPQ60xx 平台"
    return 1
}

#=========================================================
# 1. 工具函数
#=========================================================

safe_find() {
    local path="$1"
    local exec_cmd="$2"
    local exec_arg="${3:-}"
    shift 3
    if [ -n "$exec_arg" ]; then
        find "$path" "$@" -print0 2>/dev/null | xargs -0 -r "$exec_cmd" "$exec_arg"
    else
        find "$path" "$@" -print0 2>/dev/null | xargs -0 -r "$exec_cmd"
    fi
}

safe_sed() {
    local file="$1"
    local pattern="$2"
    if [ -f "$file" ] && [ -w "$file" ]; then
        sed -i "$pattern" "$file" 2>/dev/null || yellow "无法修改: $file"
    else
        debug "跳过不存在的文件: $file"
    fi
}

safe_mkdir() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" 2>/dev/null || {
            red "无法创建目录: $dir"
            return 1
        }
    fi
}

safe_write_file() {
    local file="$1"
    local dir
    dir=$(dirname "$file")
    safe_mkdir "$dir" || return 1
    cat > "$file" 2>/dev/null || {
        red "无法写入文件: $file"
        return 1
    }
    debug "已写入: $file"
}

check_vars() {
    local required_vars=("WRT_IP" "WRT_NAME" "WRT_SSID" "WRT_WORD" "WRT_THEME" "WRT_MARK" "WRT_DATE" "WRT_TARGET")
    local missing=()
    
    for var in "${required_vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            missing+=("$var")
        fi
    done
    
    if [ ${#missing[@]} -ne 0 ]; then
        red "缺少必要环境变量: ${missing[*]}"
        exit 1
    fi
    green "所有必要变量已定义"

    if IS_IPQ60; then
        green "检测到 IPQ60xx 平台，将启用 NSS 硬件加速相关配置"
    else
        yellow "当前目标 ${WRT_TARGET} 非 IPQ60xx，将跳过全部 NSS 硬件加速相关配置"
        if [ -f "$CONFIG_FILE" ]; then
            local detected_target
            detected_target=$(grep -oE "CONFIG_TARGET_[A-Za-z0-9_]+=y" "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/CONFIG_TARGET_//;s/=y//' || echo "未知")
            yellow ".config 检测到平台: ${detected_target}"
        fi
    fi
}

clean_config_file() {
    green "===== 清理自动配置段 ====="
    if [ -f "$CONFIG_FILE" ]; then
        sed -i "/${MARKER_START}/,/${MARKER_END}/d" "$CONFIG_FILE" 2>/dev/null || true
        green "✅ 已清除之前的自动配置"
    fi
    echo "$MARKER_START" >> "$CONFIG_FILE"
}

write_config_entry() {
    local entry="$1"
    local config_file="${2:-$CONFIG_FILE}"
    local pkg_name
    pkg_name=$(echo "$entry" | sed 's/^# //;s/ is not set$//;s/^CONFIG_PACKAGE_//;s/=.*//')
    if [ -n "$pkg_name" ]; then
        sed -i "/CONFIG_PACKAGE_${pkg_name}[= ]/d" "$config_file" 2>/dev/null || true
    fi
    echo "$entry" >> "$config_file"
    debug "写入配置: $entry"
}

finalize_config_file() {
    echo "$MARKER_END" >> "$CONFIG_FILE"
    green "✅ 配置段标记完成"
}

load_private_config() {
    local private_configs=()
    if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
        private_configs+=("$GITHUB_WORKSPACE/Config/PRIVATE.txt")
    fi
    if [ -f "./Config/PRIVATE.txt" ]; then
        private_configs+=("./Config/PRIVATE.txt")
    fi
    if [ -f "./PRIVATE.txt" ]; then
        private_configs+=("./PRIVATE.txt")
    fi
    for config in "${private_configs[@]}"; do
        green "加载私有配置: $config"
        cat "$config" >> "$CONFIG_FILE"
    done
    [ ${#private_configs[@]} -eq 0 ] && yellow "未找到私有配置文件 (PRIVATE.txt)"
}

#=========================================================
# 2. 清理编译日志
#=========================================================
cleanup_logs() {
    green "===== 清理编译残留日志 ====="
    rm -rf ./logs/ ./tmp/ 2>/dev/null || true
    rm -f ./build.log ./feeds/*.log 2>/dev/null || true
    safe_find . rm -f -type f -name "*.log" -size +1M
    safe_find ./package rm -f -type f -name "*.dmesg"
    safe_find ./target rm -f -type f -name "*.dmesg"
    safe_mkdir "$ETC_DIR"
    cat <<-'EOF' | safe_write_file "${ETC_DIR}/syslog.conf"
# 空配置，防止默认日志写入固件
EOF
    safe_mkdir "${ETC_DIR}/logrotate.d"
    cat <<-'EOF' | safe_write_file "${ETC_DIR}/logrotate.d/openwrt"
/var/log/*.log {
    rotate 1
    size 50k
    compress
    missingok
    notifempty
}
EOF
    green "✅ 日志清理完成"
}

#=========================================================
# 3. 清理系统配置+Mesh
#=========================================================
clean_system_config() {
    green "===== 清理系统配置 ====="
    local luci_files
    luci_files=$(find ./feeds/luci/collections -type f -name "Makefile" 2>/dev/null || true)
    if [ -n "$luci_files" ]; then
        echo "$luci_files" | while read -r f; do
            [ -f "$f" ] || continue
            sed -i "/attendedsysupgrade/d" "$f" 2>/dev/null || true
            sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" "$f" 2>/dev/null || true
        done
    fi
    local flash_js
    flash_js=$(find ./feeds/luci/modules/luci-mod-system -type f -name "flash.js" 2>/dev/null || true)
    if [ -n "$flash_js" ]; then
        echo "$flash_js" | while read -r f; do
            [ -f "$f" ] && sed -i "s/192\.168\.[0-9]*\.[0-9]*/${WRT_IP}/g" "$f" 2>/dev/null || true
        done
    fi
    local system_js
    system_js=$(find ./feeds/luci/modules/luci-mod-status -type f -name "10_system.js" 2>/dev/null || true)
    if [ -n "$system_js" ]; then
        echo "$system_js" | while read -r f; do
            [ -f "$f" ] && sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" "$f" 2>/dev/null || true
        done
    fi
    green "✅ 系统配置清理完成"
}

#=========================================================
# 4. 清理版本时间戳
#=========================================================
clean_version_timestamp() {
    green "===== 清理版本时间戳 ====="
    local release="${BASE_FILES}/etc/openwrt_release"
    if [ -f "$release" ]; then
        safe_sed "$release" 's|/ [0-9]\{9\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}||g'
        safe_sed "$release" 's|-[0-9]\{8\}||g'
        safe_sed "$release" 's| [0-9]\{9\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}||g'
        safe_sed "$release" 's| [0-9]\{9\}||g'
        green "✅ 版本时间戳清理完毕"
    fi
}

#=========================================================
# 5. 修复启动错误 + 防止日志刷屏
#=========================================================
fix_boot_errors() {
    green "===== 修复启动错误 + 防止日志刷屏 ====="
    safe_mkdir "${CONFIG_DIR}"
    cat <<-'EOF' | safe_write_file "${CONFIG_DIR}/fstab"
config global
    option anon_swap '0'
    option anon_mount '0'
    option auto_swap '1'
    option auto_mount '1'
    option delay_root '5'
    option check_fs '0'
EOF
    cat <<-'EOF' | safe_write_file "${INIT_DIR}/hostapd-prepare"
#!/bin/sh /etc/rc.common
START=40
STOP=90
start() {
    mkdir -p /var/run/hostapd
    chown root:root /var/run/hostapd
    chmod 755 /var/run/hostapd
    rm -f /var/run/hostapd.pid /var/run/hostapd-phy*.pid
}
EOF
    chmod +x "${INIT_DIR}/hostapd-prepare"
    safe_mkdir "${ETC_DIR}/rsyslog.d"
    cat <<-'EOF' | safe_write_file "${ETC_DIR}/rsyslog.d/10-hostapd-filter.conf"
:msg, contains, "AP-STA-POLL-OK" ~
:msg, contains, "AP-STA-POLL" ~
if $programname == 'hostapd' and $syslogseverity <= 3 then /var/log/hostapd.log
& ~
EOF
    safe_mkdir "${ETC_DIR}/hostapd"
    cat <<-'EOF' | safe_write_file "${ETC_DIR}/hostapd/hostapd.conf"
logger_syslog=-1
logger_syslog_level=1
logger_stdout=-1
logger_stdout_level=1
EOF
    safe_mkdir "${ETC_DIR}/sysctl.d"
    cat <<-'EOF' | safe_write_file "${ETC_DIR}/sysctl.d/10-log-levels.conf"
kernel.printk = 3 3 1 7
kernel.printk_devkmsg = off
EOF
    green "✅ 启动修复完成"
}

#=========================================================
# 6. 网口自适应 + WAN/LAN智能识别
#=========================================================
configure_network_affinity() {
    green "===== 配置网口自适应RPS/XPS热插拔 ====="
    safe_mkdir "${HOTPLUG_DIR}/net"
    cat <<-'EOF' | safe_write_file "${HOTPLUG_DIR}/net/20-nss-queue"
#!/bin/sh
[ "$ACTION" = "add" ] || exit 0
CPU_COUNT=$(nproc 2>/dev/null || echo 4)
CPU_MASK_ALL=$(printf "%x" $(( (1 << CPU_COUNT) - 1 )))
generate_cpu_mask() {
    local cpu_total=$1
    local mask_type=$2
    case "$mask_type" in
        "lan") echo "$CPU_MASK_ALL" ;;
        "wan")
            if [ $cpu_total -ge 4 ]; then
                local wan_cores=$((cpu_total / 2))
                echo "$(printf "%x" $(( (1 << wan_cores) - 1 )))"
            else
                echo "$CPU_MASK_ALL"
            fi
            ;;
        "bridge") echo "$CPU_MASK_ALL" ;;
        *) echo "$CPU_MASK_ALL" ;;
    esac
}
get_interface_type() {
    local iface="$1"
    if [ -d "/sys/class/net/$iface/bridge" ]; then echo "bridge"; return; fi
    if [ -f /etc/config/network ]; then
        local net_sec=$(uci show network 2>/dev/null | grep "=interface" | grep "\.ifname='$iface'" || true)
        if echo "$net_sec" | grep -q "wan"; then echo "wan"; return; fi
        if echo "$net_sec" | grep -q "lan"; then echo "lan"; return; fi
    fi
    case "$iface" in
        eth0|wan*) echo "wan" ;;
        eth1|lan*) echo "lan" ;;
        br-lan|br-*) echo "bridge" ;;
        *)
            if [ -f "/sys/class/net/$iface/device/uevent" ]; then
                local drv=$(grep DRIVER /sys/class/net/$iface/device/uevent 2>/dev/null | cut -d= -f2)
                [[ "$drv" =~ nss-dp ]] && echo "wan" && return
            fi
            echo "lan"
            ;;
    esac
}
configure_interface() {
    local iface="$1"
    case "$iface" in lo|ifb*|gre*|tun*|tap*|veth*|docker*) return ;; esac
    local iface_type=$(get_interface_type "$iface")
    local cpu_mask=$(generate_cpu_mask $CPU_COUNT "$iface_type")
    [ -d "/sys/class/net/$iface/queues" ] && {
        for rxq in /sys/class/net/$iface/queues/rx-*/rps_cpus; do
            [ -f "$rxq" ] && echo "$cpu_mask" > "$rxq" 2>/dev/null
        done
        [ -d "/sys/class/net/$iface/queues/rx-0" ] && {
            rx_num=$(ls /sys/class/net/$iface/queues/rx-* 2>/dev/null | wc -l)
            echo $((32768 * rx_num)) > /sys/class/net/$iface/queues/rx-0/rps_flow_cnt 2>/dev/null
        }
        for txq in /sys/class/net/$iface/queues/tx-*/xps_cpus; do
            [ -f "$txq" ] && echo "$cpu_mask" > "$txq" 2>/dev/null
        done
    }
    if [ "$iface_type" = "wan" ]; then
        [ -f "/sys/class/net/$iface/tx_queue_len" ] && echo 10000 > "/sys/class/net/$iface/tx_queue_len" 2>/dev/null
        ethtool -K "$iface" tso on gso on gro on 2>/dev/null
        max_q=$(ethtool -l "$iface" 2>/dev/null | grep -A5 "Pre-set maximums" | grep Combined | awk '{print $2}' || echo 1)
        [ "$max_q" -gt 1 ] 2>/dev/null && ethtool -L "$iface" combined $((CPU_COUNT < max_q ? CPU_COUNT : max_q)) 2>/dev/null
    fi
    if [ "$iface_type" = "bridge" ]; then
        echo 0 > /sys/class/net/$iface/bridge/multicast_querier 2>/dev/null
        echo 300 > /sys/class/net/$iface/bridge/ageing_time 2>/dev/null
        echo 0 > /sys/class/net/$iface/bridge/forward_delay 2>/dev/null
    fi
}
echo 65536 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
for iface_path in /sys/class/net/*; do
    [ -d "$iface_path" ] || continue
    configure_interface "$(basename "$iface_path")"
done
sysctl -w net.core.netdev_budget=600 net.core.netdev_budget_usecs=8000 net.core.busy_poll=50 net.core.busy_read=50 2>/dev/null
EOF
    chmod +x "${HOTPLUG_DIR}/net/20-nss-queue"
    cat <<-'EOF' | safe_write_file "${INIT_DIR}/network-affinity"
#!/bin/sh /etc/rc.common
START=20
boot() { start; }
start() {
    for iface in /sys/class/net/eth* /sys/class/net/en* /sys/class/net/br-*; do
        [ -d "$iface" ] || continue
        export ACTION=add
        /etc/hotplug.d/net/20-nss-queue 2>/dev/null
    done
}
EOF
    chmod +x "${INIT_DIR}/network-affinity"
    green "✅ 网口自适应热插拔配置完成（网络配置由外部脚本管理）"
}

#=========================================================
# 7. NSS PBUF优化
#=========================================================
update_nss_pbuf_performance() {
    if ! IS_IPQ60; then yellow "非IPQ60架构，跳过PBUF优化"; return; fi
    green "===== NSS PBUF 优化 ====="
    local conf="./package/kernel/mac80211/files/pbuf.uci"
    if [ -f "$conf" ]; then
        safe_sed "$conf" "s/auto_scale '1'/auto_scale 'off'/g"
        safe_sed "$conf" "s/scaling_governor 'performance'/scaling_governor 'schedutil'/g"
        green "✅ NSS PBUF优化完成"
    else
        yellow "NSS PBUF配置文件不存在，跳过优化"
    fi
}

#=========================================================
# 8. NSS延迟卸载
#=========================================================
install_nss_fix() {
    if ! IS_IPQ60; then yellow "非IPQ60架构，跳过NSS卸载脚本"; return; fi
    green "===== 安装 NSS 延迟卸载 ====="
    cat <<-'EOF' | safe_write_file "${INIT_DIR}/nss-fix"
#!/bin/sh /etc/rc.common
START=100
STOP=10
boot() { start; }
start() {
    logger -t nss-fix "开始后台延迟卸载ECM模块"
    (
        for i in $(seq 1 30); do
            if lsmod | grep -q qca_nss_ecm_offload; then
                logger -t nss-fix "第${i}次尝试卸载ifb与ECM"
                lsmod | grep -q "^ifb " && rmmod ifb 2>/dev/null
                if rmmod qca-nss-ecm-offload 2>/dev/null; then
                    logger -t nss-fix "ECM卸载成功"
                    break
                fi
            fi
            sleep 10
        done
        logger -t nss-fix "延迟卸载任务结束"
    ) &
}
EOF
    chmod +x "${INIT_DIR}/nss-fix"
    green "✅ NSS延迟卸载安装完成"
}

#=========================================================
# 9. 网络硬加速配置
#=========================================================
configure_hardware_acceleration() {
    if ! IS_IPQ60; then yellow "非IPQ60架构，跳过全套NSS加速配置"; return; fi
    green "===== 配置网络硬加速 ====="
    cat <<-'EOF' | safe_write_file "${CONFIG_DIR}/ecm"
config ecm
    option enable '1'
    option mode 'auto'
    option offload 'full'
    option tcp_timeout '600'
    option udp_timeout '120'
    option enable_ipv4 '1'
    option enable_ipv6 '0'
    option enable_sfe '0'
    option enable_bridge '1'
    option enable_vlan '1'
    option enable_pppoe '1'
EOF
    safe_mkdir "${ETC_DIR}/sysctl.d"
    cat <<-'EOF' | safe_write_file "${ETC_DIR}/sysctl.d/20-nss-performance.conf"
net.core.rmem_default = 87380
net.core.wmem_default = 87380
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 5000
net.core.dev_weight = 512
net.core.dev_weight_rx_bias = 128
net.core.dev_weight_tx_bias = 128
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_syncookies = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 4096
net.netfilter.nf_conntrack_max = 65536
net.netfilter.nf_conntrack_buckets = 16384
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_udp_timeout = 120
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.nf_conntrack_max = 65536
EOF
    cat <<-'EOF' | safe_write_file "${INIT_DIR}/irq-affinity"
#!/bin/sh /etc/rc.common
START=99
start() {
    CPU_NUM=$(nproc)
    MASK=$(printf "%x" $(( (1 << CPU_NUM) - 1 )))
    irq_list=$(grep -E 'nss|qcom|ath' /proc/interrupts | awk '{print $1}' | sed 's/://g')
    for irq in $irq_list; do
        [ -z "$irq" ] && continue
        echo "$MASK" > /proc/irq/$irq/smp_affinity 2>/dev/null
    done
    logger -t irq-affinity "IRQ中断绑定掩码:$MASK，核心数:$CPU_NUM" 2>/dev/null || true
}
EOF
    chmod +x "${INIT_DIR}/irq-affinity"
    safe_mkdir "${BASE_FILES}/usr/bin"
    cat <<-'EOF' | safe_write_file "${BASE_FILES}/usr/bin/nss-status"
#!/bin/sh
echo "=== NSS 硬件加速状态 ==="
ubus call ecm status 2>/dev/null || echo "ECM未运行"
[ -f /proc/net/nss/status ] && cat /proc/net/nss/status || echo "NSS未启用"
echo "连接跟踪数量: $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)"
[ -f /proc/stat ] && echo "CPU信息:" && grep -E "cpu[0-9]|btime" /proc/stat 2>/dev/null
EOF
    chmod +x "${BASE_FILES}/usr/bin/nss-status"
    green "✅ 网络硬加速配置完成"
}

#=========================================================
# 10. 软件冲突卸载 + 无用包清理 + 依赖修复
#=========================================================
clean_unused_packages() {
    green "===== 卸载冲突软件 + 清理无用包 + 修复依赖 ====="
    
    local conflict_packages=(
        "kmod-qca-nss-drv-wifi-meshmgr" "wpad-basic" "wpad-mesh" "wpad-mini"
        "kmod-6rd" "kmod-gre" "kmod-gre6" "kmod-l2tp" "kmod-iptunnel"
        "kmod-iptunnel4" "kmod-iptunnel6" "kmod-vxlan" "kmod-udptunnel4"
        "kmod-udptunnel6" "kmod-sit" "kmod-ipip" "kmod-nft-offload"
        "kmod-nft-nat" "odhcpd-ipv6only" "odhcpd-basic" "kmod-net-selftests"
        "kmod-sched-cake" "ath10k-firmware-qca4019" "ath10k-firmware-qca9984"
        "ath10k-firmware-qca6174" "ath10k-firmware-qca988x" "kmod-ath9k"
        "kmod-ath9k-common" "kmod-ath5k" "kmod-ath6kl" "kmod-brcmsmac"
        "kmod-b43" "kmod-fast-classifier" "kmod-shortcut-fe"
        "sdl3" "libwayland"
    )
    
    local unused_packages=(
        "kmod-bluetooth" "bluez-libs" "bluez-utils" "kmod-nfc"
        "kmod-usb-printer" "p910nd" "cups" "kmod-sound-core"
        "kmod-usb-audio" "alsa-utils" "kmod-gameport" "kmod-video-core"
        "kmod-video-videobuf2" "kmod-usb-acm" "kmod-usb-serial" "kmod-ir-"
        "kmod-ppp" "kmod-pppoe" "kmod-pptp" "kmod-pppol2tp" "ppp"
        "ppp-mod-pppoe" "kmod-ifb" "tc" "tc-tiny" "kmod-hid"
        "kmod-hid-generic" "kmod-usb-hid" "kmod-crypto-arc4"
        "kmod-crypto-ecb" "kmod-fs-ntfs" "kmod-fs-vfat" "kmod-fs-exfat"
        "kmod-fs-hfs" "kmod-fs-hfsplus" "kmod-fs-isofs" "kmod-fs-udf"
        "kmod-usb-storage" "kmod-usb-storage-extras" "kmod-usb-storage-uas"
        "gdb" "strace" "ltrace" "valgrind" "kmod-can"
    )
    
    # 依赖修复映射表
    declare -A dependency_fix=(
        ["luci-app-zerotier"]="zerotier"
        ["zram-swap"]="kmod-zram"
    )
    
    double_remove_package() {
        local pkg="$1"
        sed -i "/CONFIG_PACKAGE_${pkg}[= ]/d" "$CONFIG_FILE" 2>/dev/null || true
        write_config_entry "# CONFIG_PACKAGE_${pkg} is not set"
        debug "双重清理: $pkg"
    }
    
    green "--- 双重清理冲突包 ---"
    for pkg in "${conflict_packages[@]}"; do
        double_remove_package "$pkg"
        echo "  ✅ $pkg"
    done
    
    green "--- 双重清理无用包 ---"
    for pkg in "${unused_packages[@]}"; do
        double_remove_package "$pkg"
        echo "  ✅ $pkg"
    done
    
    local wildcard_packages=(
        "kmod-usb-serial-*"
        "kmod-ir-*"
        "kmod-can-*"
        "kmod-qca-nss-drv-.*-mesh"
        "kmod-qca-nss-drv-wifi"
    )
    for pat in "${wildcard_packages[@]}"; do
        grep "CONFIG_PACKAGE_${pat//\*/.*}" "$CONFIG_FILE" 2>/dev/null | while read -r line; do
            p=$(echo "$line" | sed 's/^CONFIG_PACKAGE_\([^=]*\)=.*/\1/')
            double_remove_package "$p"
            echo "  ✅ 通配清理: $p"
        done
    done
    
    # v3.4 新增：自动修复依赖
    green "--- 自动修复已知依赖 ---"
    for app in "${!dependency_fix[@]}"; do
        local dep="${dependency_fix[$app]}"
        if grep -q "CONFIG_PACKAGE_${app}=y" "$CONFIG_FILE" 2>/dev/null; then
            if ! grep -q "CONFIG_PACKAGE_${dep}=y" "$CONFIG_FILE" 2>/dev/null; then
                write_config_entry "CONFIG_PACKAGE_${dep}=y"
                echo "  ✅ 自动添加依赖: ${app} -> ${dep}"
            else
                debug "依赖已存在: ${app} -> ${dep}"
            fi
        fi
    done
    
    green "✅ 软件冲突卸载 + 无用包清理 + 依赖修复完成"
}

#=========================================================
# 11. 写入正确的包配置
#=========================================================
write_correct_packages() {
    green "===== 写入硬件加速依赖包 ====="
    
    local basic_hw=(
        "wpad-openssl" "hostapd-common" "ethtool" "odhcpd" "ubus" "ubusd"
    )
    local nss_pkgs=(
        "kmod-qca-nss-ecm" "kmod-qca-nss-ecm-standard" "kmod-qca-nss-ecm-llc"
        "kmod-qca-nss-drv" "kmod-qca-nss-drv-bridge-mgr" "kmod-qca-nss-drv-pppoe"
        "kmod-qca-nss-drv-vlan" "kmod-qca-nss-crypto" "kmod-qca-nss-gmac"
        "ath11k-firmware-qcn9074" "kmod-sched-cake-oot"
    )
    local disabled=(
        "wpad-mesh" "wpad-basic" "wpad-mini" "kmod-fast-classifier"
        "kmod-shortcut-fe" "kmod-nft-offload"
    )
    
    for p in "${basic_hw[@]}"; do
        write_config_entry "CONFIG_PACKAGE_${p}=y"
    done
    
    if IS_IPQ60; then
        for p in "${nss_pkgs[@]}"; do
            write_config_entry "CONFIG_PACKAGE_${p}=y"
        done
        green "✅ 已启用 NSS 硬件加速包"
    fi
    
    for p in "${disabled[@]}"; do
        write_config_entry "# CONFIG_PACKAGE_${p} is not set"
    done
    
    green "✅ 包配置写入完成"
}

#=========================================================
# 12. WiFi Hotplug + 参数固化
#=========================================================
patch_wifi_full_reload() {
    green "===== 安装 WiFi Hotplug ====="
    safe_mkdir "${HOTPLUG_DIR}/ieee80211"
    cat <<-'EOF' | safe_write_file "${HOTPLUG_DIR}/ieee80211/00-ath11k-reset"
#!/bin/sh
[ "$ACTION" = "disable" ] || exit 0
(
    sleep 2
    rmmod ath11k_pci ath11k_ahb ath11k ath mac80211 cfg80211 2>/dev/null
    sleep 1
    modprobe cfg80211 mac80211 ath ath11k ath11k_ahb ath11k_pci 2>/dev/null
    ubus call network reload 2>/dev/null
    logger -t wifi-reset "无线驱动重载完成"
) &
EOF
    chmod +x "${HOTPLUG_DIR}/ieee80211/00-ath11k-reset"
    green "✅ WiFi Hotplug安装完成"
}

set_wifi_params() {
    green "===== 固化 WiFi 参数 ====="    local WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
    if [ -f "$WIFI_UC" ]; then
        safe_sed "$WIFI_UC" "s/ssid='[^']*'/ssid='$WRT_SSID'/g"
        safe_sed "$WIFI_UC" "s/key='[^']*'/key='$WRT_WORD'/g"
        safe_sed "$WIFI_UC" "s/country='[^']*'/country='CN'/g"
        safe_sed "$WIFI_UC" "s/encryption='[^']*'/encryption='psk2+ccmp'/g"
        safe_sed "$WIFI_UC" "s/disabled='1'/disabled='0'/g"
        safe_sed "$WIFI_UC" "s/mode='mesh'/mode='ap'/g"
        safe_sed "$WIFI_UC" "s/ieee80211s/mesh_disabled/g"
        green "✅ WiFi参数固化完成"
    else
        yellow "WiFi配置文件不存在: $WIFI_UC"
    fi
}

#=========================================================
# 13. 固化系统参数
#=========================================================
set_system_params() {
    green "===== 固化系统参数 ====="
    local CFG_FILE="${BASE_FILES}/bin/config_generate"
    if [ -f "$CFG_FILE" ]; then
        safe_sed "$CFG_FILE" "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g"
        safe_sed "$CFG_FILE" "s/hostname='[^']*'/hostname='$WRT_NAME'/g"
        green "✅ 管理 IP: $WRT_IP，主机名: $WRT_NAME"
    fi
}

#=========================================================
# 14. 写入基础编译配置
#=========================================================
write_basic_config() {
    green "===== 写入基础配置 ====="
    local basic=("luci" "logrotate" "iwinfo")
    for p in "${basic[@]}"; do
        write_config_entry "CONFIG_PACKAGE_${p}=y"
    done
    write_config_entry "CONFIG_LUCI_LANG_zh_Hans=y"
    write_config_entry "CONFIG_PACKAGE_luci-theme-${WRT_THEME}=y"
    write_config_entry "CONFIG_PACKAGE_luci-app-${WRT_THEME}-config=y"
    green "✅ 基础配置写入完成"
}

#=========================================================
# 15. 追加自定义插件
#=========================================================
append_custom_packages() {
    if [ -n "${WRT_PACKAGE:-}" ]; then
        echo "$WRT_PACKAGE" >> "$CONFIG_FILE"
        green "✅ 已追加自定义插件"
    fi
}

#=========================================================
# 16. 编译前最终检查与修复
#=========================================================
pre_build_check() {
    green "===== 编译前最终检查 ====="
    
    # 1. 检查 wpad 冲突
    local wpad_count=$(grep -c "CONFIG_PACKAGE_wpad.*=y" "$CONFIG_FILE" 2>/dev/null || echo 0)
    if [ "$wpad_count" -gt 1 ]; then
        yellow "检测到多个 wpad 变体，只保留 wpad-openssl"
        sed -i '/CONFIG_PACKAGE_wpad-basic/d' "$CONFIG_FILE" 2>/dev/null || true
        sed -i '/CONFIG_PACKAGE_wpad-mesh/d' "$CONFIG_FILE" 2>/dev/null || true
        sed -i '/CONFIG_PACKAGE_wpad-mini/d' "$CONFIG_FILE" 2>/dev/null || true
        grep -q "CONFIG_PACKAGE_wpad-openssl=y" "$CONFIG_FILE" 2>/dev/null || echo "CONFIG_PACKAGE_wpad-openssl=y" >> "$CONFIG_FILE"
    fi
    
    # 2. 检查 sdl3/wayland 冲突
    if grep -q "CONFIG_PACKAGE_sdl3=y" "$CONFIG_FILE" 2>/dev/null; then
        yellow "检测到 sdl3（已知有依赖问题），自动禁用"
        sed -i '/CONFIG_PACKAGE_sdl3/d' "$CONFIG_FILE" 2>/dev/null || true
        echo "# CONFIG_PACKAGE_sdl3 is not set" >> "$CONFIG_FILE"
        sed -i '/CONFIG_PACKAGE_libwayland/d' "$CONFIG_FILE" 2>/dev/null || true
        echo "# CONFIG_PACKAGE_libwayland is not set" >> "$CONFIG_FILE"
    fi
    
    # 3. 检查 zerotier 依赖
    if grep -q "CONFIG_PACKAGE_luci-app-zerotier=y" "$CONFIG_FILE" 2>/dev/null; then
        if ! grep -q "CONFIG_PACKAGE_zerotier=y" "$CONFIG_FILE" 2>/dev/null; then
            yellow "自动添加 zerotier 主程序依赖"
            write_config_entry "CONFIG_PACKAGE_zerotier=y"
        fi
    fi
    
    # 4. 检查 zram-swap 依赖
    if grep -q "CONFIG_PACKAGE_zram-swap=y" "$CONFIG_FILE" 2>/dev/null; then
        if ! grep -q "CONFIG_PACKAGE_kmod-zram=y" "$CONFIG_FILE" 2>/dev/null; then
            yellow "自动添加 kmod-zram 依赖"
            write_config_entry "CONFIG_PACKAGE_kmod-zram=y"
        fi
    fi
    
    # 5. 同步配置
    green "同步 make defconfig..."
    make defconfig 2>/dev/null || true
    
    green "✅ 编译前检查完成"
}

#=========================================================
# 17. 验证配置
#=========================================================
verify_cleanup() {
    echo ""
    green "===== 验证配置 ====="
    
    local hw_packages=(
        "kmod-qca-nss-ecm"
        "kmod-qca-nss-drv"
        "ath11k-firmware-qcn9074"
        "kmod-sched-cake-oot"
    )
    
    green "【硬件加速包校验】"
    for pkg in "${hw_packages[@]}"; do
        if IS_IPQ60; then
            grep -q "CONFIG_PACKAGE_${pkg}=y" "$CONFIG_FILE" 2>/dev/null \
                && echo "✅ $pkg" \
                || echo "⚠️ 缺失 $pkg"
        else
            grep -q "CONFIG_PACKAGE_${pkg}=y" "$CONFIG_FILE" 2>/dev/null \
                && echo "❌ 非NSS平台却启用 $pkg" \
                || echo "✅ 已自动跳过 $pkg"
        fi
    done
    
    local verify_conflicts=(
        "wpad-basic"
        "wpad-mesh"
        "kmod-nft-offload"
        "kmod-fast-classifier"
        "kmod-shortcut-fe"
        "sdl3"
    )
    
    green "【冲突包校验】"
    for pkg in "${verify_conflicts[@]}"; do
        if grep -q "CONFIG_PACKAGE_${pkg}=y" "$CONFIG_FILE" 2>/dev/null; then
            echo "❌ 残留 $pkg"
        elif grep -q "# CONFIG_PACKAGE_${pkg} is not set" "$CONFIG_FILE" 2>/dev/null; then
            echo "✅ 已禁用 $pkg"
        else
            echo "✅ 已清理 $pkg"
        fi
    done
    
    # 依赖校验
    green "【已知依赖校验】"
    if grep -q "CONFIG_PACKAGE_luci-app-zerotier=y" "$CONFIG_FILE" 2>/dev/null; then
        grep -q "CONFIG_PACKAGE_zerotier=y" "$CONFIG_FILE" 2>/dev/null \
            && echo "✅ luci-app-zerotier -> zerotier" \
            || echo "❌ luci-app-zerotier 缺少 zerotier 依赖"
    fi
    if grep -q "CONFIG_PACKAGE_zram-swap=y" "$CONFIG_FILE" 2>/dev/null; then
        grep -q "CONFIG_PACKAGE_kmod-zram=y" "$CONFIG_FILE" 2>/dev/null \
            && echo "✅ zram-swap -> kmod-zram" \
            || echo "❌ zram-swap 缺少 kmod-zram 依赖"
    fi
    
    # 架构检测来源验证
    green "【架构检测来源】"
    if [[ "${WRT_TARGET:-}" =~ ^ipq60 ]]; then
        echo "✅ 通过环境变量 WRT_TARGET=${WRT_TARGET} 检测到 IPQ60xx"
    elif [ -f "$CONFIG_FILE" ] && grep -q "CONFIG_TARGET_qualcommax_ipq60xx=y" "$CONFIG_FILE" 2>/dev/null; then
        echo "✅ 通过 .config 文件检测到 CONFIG_TARGET_qualcommax_ipq60xx=y"
    elif [ -f "$CONFIG_FILE" ] && grep -qE "CONFIG_TARGET.*ipq60" "$CONFIG_FILE" 2>/dev/null; then
        echo "✅ 通过 .config 文件模糊匹配检测到 IPQ60 系列"
    else
        echo "ℹ️ 未检测到 IPQ60xx 平台，NSS 配置已跳过"
    fi
    
    green "🎉 配置校验完成"
}

#=========================================================
# 18. 主执行流程
#=========================================================
main() {
    green ""
    green "========================================"
    green "=== OpenWrt 编译预配置 v3.4 FINAL ==="
    green "=== 目标平台: ${WRT_TARGET} ==="
    green "=== 网关地址: ${WRT_IP} ==="
    green "========================================"
    
    check_vars
    clean_config_file

    cleanup_logs
    clean_system_config
    clean_version_timestamp
    fix_boot_errors
    configure_network_affinity
    update_nss_pbuf_performance
    install_nss_fix
    configure_hardware_acceleration
    clean_unused_packages
    write_correct_packages
    patch_wifi_full_reload
    set_wifi_params
    set_system_params
    write_basic_config
    load_private_config
    append_custom_packages
    
    # v3.4 新增：编译前最终检查
    pre_build_check
    
    finalize_config_file
    verify_cleanup
    
    green ""
    green "========================================"
    green "✅ v3.4 FINAL 执行完成"
    green "更新项:"
    green "1. safe_write_file 改用管道输入，支持原生here-doc"
    green "2. safe_find 参数传递修正，避免 xargs 嵌套"
    green "3. clean_system_config 移除 xargs 嵌套调用"
    green "4. IRQ亲和 + logger 错误抑制"
    green "5. nss-status 改用 /proc/stat 替代 top 命令"
    green "6. 网络配置由外部脚本管理，本脚本不覆盖"
    green "7. IS_IPQ60 双源检测：环境变量 + .config 回退"
    green "8. ★ 新增依赖自动修复（zerotier/zram-swap）"
    green "9. ★ 新增冲突包 sdl3/libwayland 处理"
    green "10. ★ 新增 pre_build_check 编译前最终检查"
    green "========================================"
}

main "$@"
