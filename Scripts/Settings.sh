#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

# 定义绿色日志输出函数
green() {
    echo -e "\033[32m$1\033[0m"
}

#==================== 新增模块：删除全部无线/NSS冲突内核包（适配IPQ6018 AX5） ====================
clean_conflict_packages() {
    local config_file="./.config"
    green "===== 开始清理NSS/WiFi冲突插件 ====="
    # 1. WiFi Mesh双重调度冲突 头号元凶
    sed -i '/CONFIG_PACKAGE_kmod-qca-nss-drv-wifi-meshmgr/d' "$config_file"
    # 2. 系统原生隧道模块，与NSS内置隧道驱动冲突
    sed -i '/CONFIG_PACKAGE_kmod-6rd/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_kmod-gre/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_kmod-gre6/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_kmod-l2tp/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_kmod-iptunnel/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_kmod-iptunnel4/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_kmod-iptunnel6/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_kmod-vxlan/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_kmod-udptunnel4/d' "$config_file"
    sed -i '/CONFIG_PACKAGE_kmod-udptunnel6/d' "$config_file"
    # 3. nft硬件卸载 和 NSS ECM NAT冲突
    sed -i '/CONFIG_PACKAGE_kmod-nft-offload/d' "$config_file"
    # 4. IPv6双DHCP服务地址分配冲突
    sed -i '/CONFIG_PACKAGE_odhcpd-ipv6only/d' "$config_file"
    # 5. 仅删除网络自检内核模块，保留coremark、iperf3测速工具
    sed -i '/CONFIG_PACKAGE_kmod-net-selftests/d' "$config_file"
    green "冲突模块清理完成，消除wifi-scripts与NSS驱动抢占问题（保留coremark/iperf3）"
}

#==================== 新增模块：wifi-scripts补丁，重载完整卸载ath11k驱动（解决5G消失） ====================
patch_wifi_full_reload() {
    local wifi_uc="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
    if [ -f "$wifi_uc" ]; then
        # 在wifi停止函数末尾追加ath11k全套驱动卸载逻辑
        sed -i '/ubus call network.wireless stop/a\    exec("rmmod kmod-ath11k-pci kmod-ath11k-ahb kmod-ath11k kmod-ath kmod-mac80211 kmod-cfg80211; sleep(1); modprobe kmod-cfg80211; modprobe kmod-mac80211; modprobe kmod-ath; modprobe kmod-ath11k; modprobe kmod-ath11k-ahb; modprobe kmod-ath11k-pci; sleep(1);");' "$wifi_uc"
        green "wifi-scripts补丁注入成功：wifi reload时完整重置ath11k无线固件"
    fi
}

#==================== 1. 清理在线升级、全局默认主题替换 ====================
#移除luci-app-attendedsysupgrade
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改系统默认主题为传入变量WRT_THEME
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP为自定义网关
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#页面底部追加编译标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

#==================== 2. 清理固件内置多余编译时间戳 ====================
clean_version_timestamp() {
    local release="./package/base-files/files/etc/openwrt_release"
    sed -i 's/ \/ [0-9]*-[0-9\.]*-[0-9\.]* \/ [0-9]*-[0-9\.]*-[0-9\.]*//g' "$release" 2>/dev/null || true
    green "固件版本多余时间戳清理完毕"
}
clean_version_timestamp

#==================== 3. NSS PBUF 性能调度优化（IPQ高通NSS专用） ====================
update_nss_pbuf_performance() {
    local conf="./package/kernel/mac80211/files/pbuf.uci"
    sed -i "s/auto_scale '1'/auto_scale 'off'/g; s/scaling_governor 'performance'/scaling_governor 'schedutil'/g" "$conf" 2>/dev/null || true
    green "NSS PBUF: 自动缩放关闭，CPU调度器切换 schedutil"
}
update_nss_pbuf_performance

#==================== 4. NSS 延迟卸载修复脚本，后台休眠不阻塞开机 ====================
install_nss_fix() {
    local init_path="./package/base-files/files/etc/init.d/nss-fix"
    mkdir -p "$(dirname "$init_path")"
    cat > "$init_path" << 'EOF'
#!/bin/sh /etc/rc.common
START=100
STOP=10
boot() { start; }
start() {
    # 全部延时逻辑放入后台子shell，等待500秒再卸载模块，不阻塞开机
    (
        sleep 500
        # 仅模块存在时卸载，彻底屏蔽不存在的报错输出
        lsmod | grep -q "^ifb " && rmmod ifb
        lsmod | grep -q "qca_nss_ecm_offload" && rmmod qca-nss-ecm-offload
    ) &
}
EOF
    chmod +x "$init_path"
    green "NSS延迟卸载脚本安装完成，开机8分20秒后后台自动清理NSS模块，不拖慢开机"
}
install_nss_fix

#==================== 5. 固化WiFi参数（SSID、密码、CN地区、加密） ====================
WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	#修改WIFI地区中国
	sed -i "s/country='.*'/country='CN'/g" $WIFI_UC
	#加密模式WPA2-CCMP
	sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
fi

#==================== 6. 固化默认管理IP、主机名 ====================
CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#==================== 7. 写入基础编译配置 ====================
#基础LuCI与中文
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
#自动编译启用主题与主题设置面板
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#==================== 8. 加载私有配置文件 ====================
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

#==================== 9. 追加手动输入自定义插件参数 ====================
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#==================== 10. 标记无WIFI编译环境变量 ====================
if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
	echo "WRT_WIFI=wifi-no" >> $GITHUB_ENV
fi

#==================== 11. 高通qualcommax平台无WiFi设备DTS适配 ====================
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#无WIFI配置调整Q6大小，替换nowifi设备树
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
fi

#==================== 执行冲突清理 + WiFi底层补丁 ====================
clean_conflict_packages
patch_wifi_full_reload

green "===== 全部预配置脚本执行完毕，已消除WiFi/NSS模块冲突 ====="
