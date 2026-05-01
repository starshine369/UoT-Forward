#!/usr/bin/env bash
#
# UoT-Forward - 基于 Phantun 的 UDP-over-TCP 隧道穿透面板
# 仓库地址: https://github.com/starshine369/UoT-Forward
# 全局快捷命令: sudo uot
#
set -euo pipefail

readonly SCRIPT_VERSION="1.1.1"
readonly PHANTUN_VERSION="v0.8.1"
readonly PHANTUN_SHA256_AMD64="8a7e143db2eb06ad8969bbafd8dcaedd5483b7f3683090865074872e0938e14a"
readonly INSTALL_DIR="/usr/local/bin"
readonly CONFIG_DIR="/etc/uot-forward"
readonly SERVICE_PREFIX="uot-fwd"
readonly IPTABLES_COMMENT="uot-forward"
readonly TUN_SUBNET_BASE=210

GITHUB_MIRROR="${GITHUB_MIRROR:-}"

# ─── 颜色定义 (仅 CLI 模式) ────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[提示]${NC} $*"; }
warn()  { echo -e "${YELLOW}[警告]${NC} $*"; }
error() { echo -e "${RED}[错误]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

# ═══════════════════════════════════════════════════════════════════
#  核心辅助函数
# ═══════════════════════════════════════════════════════════════════
require_root() {
    [[ $EUID -eq 0 ]] || die "必须使用 root 权限运行此脚本 (请使用 sudo)。"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "x86_64-unknown-linux-gnu" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
        *)             return 1 ;;
    esac
}

detect_iface() {
    ip route show default 2>/dev/null | awk '/default/{print $5; exit}'
}

next_tun_index() {
    local max=0
    if [[ -d "$CONFIG_DIR" ]]; then
        for conf in "$CONFIG_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            local idx
            idx=$(grep -oP '^TUN_INDEX=\K\d+' "$conf" 2>/dev/null || echo 0)
            (( idx > max )) && max=$idx
        done
    fi
    echo $(( max + 1 ))
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

validate_addr_port() {
    local val="$1"
    local addr="${val%:*}" port="${val##*:}"
    [[ -n "$addr" && -n "$port" ]] && validate_port "$port"
}

config_name_exists() { [[ -f "$CONFIG_DIR/$1.conf" ]]; }

auto_name() {
    local prefix="$1" port="$2" name="${1}${2}" i=1
    while config_name_exists "$name"; do
        name="${prefix}${port}_${i}"; (( i++ ))
    done
    echo "$name"
}

list_config_names() {
    local names=()
    if [[ -d "$CONFIG_DIR" ]]; then
        for conf in "$CONFIG_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            local n; n=$(grep -oP '^NAME=\K.+' "$conf" 2>/dev/null || true)
            [[ -n "$n" ]] && names+=("$n")
        done
    fi
    printf '%s\n' "${names[@]}"
}

# ═══════════════════════════════════════════════════════════════════
#  后台逻辑: 安装 / 添加服务端 / 添加客户端 / 删除 / 卸载
# ═══════════════════════════════════════════════════════════════════
do_install() {
    local arch_target
    arch_target=$(detect_arch) || { echo "错误: 不支持的系统架构 $(uname -m)"; return 1; }

    echo "正在安装 Phantun ${PHANTUN_VERSION} (${arch_target})..."

    local gh_base="https://github.com"
    if [[ -n "$GITHUB_MIRROR" ]]; then
        gh_base="${GITHUB_MIRROR}/https://github.com"
        echo "使用加速镜像: ${GITHUB_MIRROR}"
    fi
    local url="${gh_base}/dndx/phantun/releases/download/${PHANTUN_VERSION}/phantun_${arch_target}.zip"
    local tmpdir; tmpdir=$(mktemp -d)

    echo "正在下载: ${url} ..."
    if command -v wget &>/dev/null; then
        wget -q -O "$tmpdir/phantun.zip" "$url" 2>&1
    elif command -v curl &>/dev/null; then
        curl -fSL -o "$tmpdir/phantun.zip" "$url" 2>&1
    else
        rm -rf "$tmpdir"
        echo "错误: 未找到 wget 或 curl 命令。"; return 1
    fi

    if [[ "$arch_target" == x86_64* ]]; then
        echo "正在校验 SHA256..."
        local actual; actual=$(sha256sum "$tmpdir/phantun.zip" | awk '{print $1}')
        if [[ "$actual" != "$PHANTUN_SHA256_AMD64" ]]; then
            rm -rf "$tmpdir"
            echo "错误: 校验和不匹配!"; echo "期望: $PHANTUN_SHA256_AMD64"; echo "实际: $actual"; return 1
        fi
        echo "校验通过。"
    fi

    command -v unzip &>/dev/null || { echo "安装 unzip..."; apt-get update -qq && apt-get install -y -qq unzip; }
    unzip -o "$tmpdir/phantun.zip" -d "$tmpdir/phantun" >/dev/null

    cp "$tmpdir/phantun/phantun_server" "$INSTALL_DIR/phantun_server"
    cp "$tmpdir/phantun/phantun_client" "$INSTALL_DIR/phantun_client"
    chmod +x "$INSTALL_DIR/phantun_server" "$INSTALL_DIR/phantun_client"
    setcap cap_net_admin=+pe "$INSTALL_DIR/phantun_server"
    setcap cap_net_admin=+pe "$INSTALL_DIR/phantun_client"

    if ! sysctl -n net.ipv4.ip_forward 2>/dev/null | grep -q 1; then
        echo "正在开启 IPv4 转发..."
        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    fi

    mkdir -p "$CONFIG_DIR"
    echo -e "\nPhantun ${PHANTUN_VERSION} 内核安装成功！"
    echo "服务端核心 -> $INSTALL_DIR/phantun_server"
    echo "客户端核心 -> $INSTALL_DIR/phantun_client"
    echo "配置文件目录 -> $CONFIG_DIR"

    rm -rf "$tmpdir"
}

do_server_add() {
    local tcp_port="$1" udp_target="$2" name="$3" iface="$4"

    validate_port "$tcp_port"      || { echo "错误: 无效的 TCP 端口: $tcp_port"; return 1; }
    validate_addr_port "$udp_target" || { echo "错误: 无效的 UDP 目标: $udp_target (格式应为 IP:端口)"; return 1; }
    [[ -f "$INSTALL_DIR/phantun_server" ]] || { echo "错误: 未安装 Phantun 内核，请先安装。"; return 1; }
    [[ -z "$iface" ]] && iface=$(detect_iface)
    [[ -n "$iface" ]] || { echo "错误: 无法检测到网络接口。"; return 1; }
    [[ -z "$name" ]] && name=$(auto_name "s" "$tcp_port")
    config_name_exists "$name" && { echo "错误: 规则名 '$name' 已存在。"; return 1; }

    local tun_idx; tun_idx=$(next_tun_index)
    local tun_name="ptn_s_${name}"
    local tun_subnet=$((TUN_SUBNET_BASE + tun_idx))
    (( tun_subnet > 254 )) && { echo "错误: 映射规则过多 (子网溢出)。"; return 1; }
    local tun_local="192.168.${tun_subnet}.1"
    local tun_peer="192.168.${tun_subnet}.2"

    echo "正在创建 服务端(接收端) 规则 '${name}'..."
    echo "  监听 TCP:  :${tcp_port}"
    echo "  还原 UDP:  ${udp_target}"
    echo "  TUN 接口:  ${tun_name} (${tun_local} <-> ${tun_peer})"
    echo "  物理网卡:  ${iface}"

    cat > "$CONFIG_DIR/${name}.conf" <<EOF
MODE=server
NAME=${name}
TCP_PORT=${tcp_port}
UDP_TARGET=${udp_target}
TUN_NAME=${tun_name}
TUN_LOCAL=${tun_local}
TUN_PEER=${tun_peer}
TUN_INDEX=${tun_idx}
IFACE=${iface}
EOF

    cat > "$CONFIG_DIR/${name}-iptables-up.sh" <<EOF
#!/usr/bin/env bash
iptables -t nat -A PREROUTING -p tcp -i ${iface} --dport ${tcp_port} -j DNAT --to-destination ${tun_peer} -m comment --comment "${IPTABLES_COMMENT}-${name}"
EOF
    chmod +x "$CONFIG_DIR/${name}-iptables-up.sh"

    cat > "$CONFIG_DIR/${name}-iptables-down.sh" <<EOF
#!/usr/bin/env bash
iptables -t nat -D PREROUTING -p tcp -i ${iface} --dport ${tcp_port} -j DNAT --to-destination ${tun_peer} -m comment --comment "${IPTABLES_COMMENT}-${name}" 2>/dev/null || true
EOF
    chmod +x "$CONFIG_DIR/${name}-iptables-down.sh"

    local svc_name="${SERVICE_PREFIX}-${name}"
    cat > "/etc/systemd/system/${svc_name}.service" <<EOF
[Unit]
Description=UoT Forward (服务端) - ${name} [TCP:${tcp_port} -> UDP:${udp_target}]
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=RUST_LOG=warn
ExecStartPre=${CONFIG_DIR}/${name}-iptables-up.sh
ExecStart=${INSTALL_DIR}/phantun_server --local ${tcp_port} --remote ${udp_target} --tun ${tun_name} --tun-local ${tun_local} --tun-peer ${tun_peer} -4
ExecStopPost=${CONFIG_DIR}/${name}-iptables-down.sh
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${svc_name}.service" 2>&1

    echo -e "\n服务端规则 '${name}' 已创建并成功启动。"
    echo "守护进程: ${svc_name}.service"
}

do_client_add() {
    local server_addr="$1" server_port="$2" local_port="$3" name="$4" iface="$5"

    validate_port "$server_port" || { echo "错误: 无效的服务端端口: $server_port"; return 1; }
    validate_port "$local_port"  || { echo "错误: 无效的本地端口: $local_port"; return 1; }
    [[ -n "$server_addr" ]]      || { echo "错误: 服务端地址不能为空。"; return 1; }
    [[ -f "$INSTALL_DIR/phantun_client" ]] || { echo "错误: 未安装 Phantun 内核，请先安装。"; return 1; }
    [[ -z "$iface" ]] && iface=$(detect_iface)
    [[ -n "$iface" ]] || { echo "错误: 无法检测到网络接口。"; return 1; }
    [[ -z "$name" ]] && name=$(auto_name "c" "$local_port")
    config_name_exists "$name" && { echo "错误: 规则名 '$name' 已存在。"; return 1; }

    local tun_idx; tun_idx=$(next_tun_index)
    local tun_name="ptn_c_${name}"
    local tun_subnet=$((TUN_SUBNET_BASE + tun_idx))
    (( tun_subnet > 254 )) && { echo "错误: 映射规则过多 (子网溢出)。"; return 1; }
    local tun_local="192.168.${tun_subnet}.1"
    local tun_peer="192.168.${tun_subnet}.2"

    echo "正在创建 客户端(发送端) 规则 '${name}'..."
    echo "  目标服务:   ${server_addr}:${server_port}"
    echo "  本地伪装:   127.0.0.1:${local_port} (UDP)"
    echo "  TUN 接口:   ${tun_name} (${tun_local} <-> ${tun_peer})"
    echo "  物理网卡:   ${iface}"

    cat > "$CONFIG_DIR/${name}.conf" <<EOF
MODE=client
NAME=${name}
SERVER_ADDR=${server_addr}
SERVER_PORT=${server_port}
LOCAL_PORT=${local_port}
TUN_NAME=${tun_name}
TUN_LOCAL=${tun_local}
TUN_PEER=${tun_peer}
TUN_INDEX=${tun_idx}
IFACE=${iface}
EOF

    cat > "$CONFIG_DIR/${name}-iptables-up.sh" <<EOF
#!/usr/bin/env bash
iptables -t nat -A POSTROUTING -s ${tun_local}/24 -o ${iface} -j MASQUERADE -m comment --comment "${IPTABLES_COMMENT}-${name}"
EOF
    chmod +x "$CONFIG_DIR/${name}-iptables-up.sh"

    cat > "$CONFIG_DIR/${name}-iptables-down.sh" <<EOF
#!/usr/bin/env bash
iptables -t nat -D POSTROUTING -s ${tun_local}/24 -o ${iface} -j MASQUERADE -m comment --comment "${IPTABLES_COMMENT}-${name}" 2>/dev/null || true
EOF
    chmod +x "$CONFIG_DIR/${name}-iptables-down.sh"

    local svc_name="${SERVICE_PREFIX}-${name}"
    cat > "/etc/systemd/system/${svc_name}.service" <<EOF
[Unit]
Description=UoT Forward (客户端) - ${name} [UDP:${local_port} -> ${server_addr}:${server_port}]
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=RUST_LOG=warn
ExecStartPre=${CONFIG_DIR}/${name}-iptables-up.sh
ExecStart=${INSTALL_DIR}/phantun_client --local 127.0.0.1:${local_port} --remote ${server_addr}:${server_port} --tun ${tun_name} --tun-local ${tun_local} --tun-peer ${tun_peer} -4
ExecStopPost=${CONFIG_DIR}/${name}-iptables-down.sh
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${svc_name}.service" 2>&1

    echo -e "\n客户端规则 '${name}' 已创建并成功启动。"
    echo "守护进程: ${svc_name}.service\n"
    echo "🚀 提示: 请将您的代理工具(如 TUIC/Hysteria) 指向 127.0.0.1:${local_port}"
}

do_remove() {
    local target_name="$1"
    [[ -n "$target_name" ]] || { echo "错误: 需要提供规则名称。"; return 1; }
    config_name_exists "$target_name" || { echo "错误: 找不到规则 '$target_name'。"; return 1; }

    source "$CONFIG_DIR/${target_name}.conf"
    local svc_name="${SERVICE_PREFIX}-${NAME}"

    echo "正在移除规则 '${target_name}'..."
    systemctl stop "${svc_name}.service" 2>/dev/null || true
    systemctl disable "${svc_name}.service" 2>/dev/null || true
    [[ -x "$CONFIG_DIR/${target_name}-iptables-down.sh" ]] && "$CONFIG_DIR/${target_name}-iptables-down.sh"
    rm -f "/etc/systemd/system/${svc_name}.service"
    rm -f "$CONFIG_DIR/${target_name}.conf"
    rm -f "$CONFIG_DIR/${target_name}-iptables-up.sh"
    rm -f "$CONFIG_DIR/${target_name}-iptables-down.sh"
    systemctl daemon-reload
    echo "规则 '${target_name}' 已彻底移除。"
}

do_uninstall() {
    local names=()
    if [[ -d "$CONFIG_DIR" ]]; then
        for conf in "$CONFIG_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            local n; n=$(grep -oP '^NAME=\K.+' "$conf" 2>/dev/null || true)
            [[ -n "$n" ]] && names+=("$n")
        done
        for n in "${names[@]}"; do
            do_remove "$n"
        done
    fi
    rm -f "$INSTALL_DIR/phantun_server" "$INSTALL_DIR/phantun_client"
    rm -rf "$CONFIG_DIR"
    echo "系统卸载完毕，干净如初。"
}

build_status_text() {
    local target_name="${1:-}"
    if [[ -n "$target_name" ]]; then
        config_name_exists "$target_name" || { echo "找不到规则 '$target_name'。"; return; }
        source "$CONFIG_DIR/${target_name}.conf"
        local svc_name="${SERVICE_PREFIX}-${NAME}"
        echo "规则名称: ${NAME}"
        echo "运行模式: ${MODE}"
        if [[ "$MODE" == "server" ]]; then
            echo "监听 TCP: ${TCP_PORT}"
            echo "还原 UDP: ${UDP_TARGET}"
        else
            echo "目标机器: ${SERVER_ADDR}:${SERVER_PORT}"
            echo "本地 UDP: ${LOCAL_PORT}"
        fi
        echo "虚拟网卡: ${TUN_NAME} (${TUN_LOCAL} <-> ${TUN_PEER})"
        echo "物理网卡: ${IFACE}"
        echo ""
        systemctl status "$svc_name" --no-pager 2>/dev/null || echo "(未找到服务状态)"
        return
    fi
    
    if [[ ! -d "$CONFIG_DIR" ]] || ! ls "$CONFIG_DIR"/*.conf &>/dev/null 2>&1; then
        echo "当前没有任何转发规则。"
        return
    fi
    printf "%-12s | %-8s | %-8s | %-30s | %-10s\n" "规则名称" "模式" "状态" "映射详情" "网卡"
    printf '%.0s-' {1..75}; echo ""
    for conf in "$CONFIG_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue
        source "$conf"
        local svc_name="${SERVICE_PREFIX}-${NAME}"
        local st="已停止"
        systemctl is-active "$svc_name" &>/dev/null && st="运行中"
        local mapping
        if [[ "$MODE" == "server" ]]; then
            mapping="TCP:${TCP_PORT} -> ${UDP_TARGET}"
        else
            mapping="UDP:${LOCAL_PORT} -> ${SERVER_ADDR}:${SERVER_PORT}"
        fi
        printf "%-12s | %-8s | %-8s | %-30s | %-10s\n" "$NAME" "$MODE" "$st" "$mapping" "$IFACE"
    done
}

# ═══════════════════════════════════════════════════════════════════
#  图形界面 TUI
# ═══════════════════════════════════════════════════════════════════
DIALOG_OK=0
DIALOG_CANCEL=1
DIALOG_ESC=255
DLG_TEMP=""

ensure_dialog() {
    if ! command -v dialog &>/dev/null; then
        echo "正在安装交互界面依赖 (dialog)..."
        apt-get update -qq && apt-get install -y -qq dialog
    fi
    DLG_TEMP=$(mktemp)
}

dlg_msgbox() {
    local title="$1" msg="$2"
    dialog --title "$title" --msgbox "$msg" 20 76
}

dlg_error() {
    dialog --title "错误" --msgbox "$1" 10 60
}

# ─── 主菜单 ──────────────────────────────────────────────────────
menu_main() {
    while true; do
        local phantun_status="未安装"
        [[ -f "$INSTALL_DIR/phantun_server" ]] && phantun_status="已安装 (${PHANTUN_VERSION})"

        local mapping_count=0
        if [[ -d "$CONFIG_DIR" ]]; then
            mapping_count=$(ls "$CONFIG_DIR"/*.conf 2>/dev/null | wc -l || true)
        fi

        local ret=0
        dialog --title "UoT 隧道穿透面板 v${SCRIPT_VERSION}" \
            --cancel-label "退出" \
            --menu "\n  Phantun 内核: ${phantun_status}\n  现有转发规则: ${mapping_count}\n" \
            20 60 8 \
            1 "安装 / 更新 Phantun 内核" \
            2 "添加端口转发规则" \
            3 "查看所有转发规则" \
            4 "查看规则详细信息" \
            5 "启动 / 停止 某条规则" \
            6 "删除指定的转发规则" \
            7 "彻底卸载整个系统" \
            2>"$DLG_TEMP" || ret=$?

        [[ $ret -ne $DIALOG_OK ]] && break

        local choice; choice=$(<"$DLG_TEMP")
        case "$choice" in
            1) menu_install ;;
            2) menu_add_mapping ;;
            3) menu_list ;;
            4) menu_details ;;
            5) menu_startstop ;;
            6) menu_remove ;;
            7) menu_uninstall ;;
        esac
    done
    rm -f "$DLG_TEMP"
    clear
}

# ─── 安装 ────────────────────────────────────────────────────────
menu_install() {
    local ret=0
    dialog --title "下载源选择" \
        --menu "\n请选择 Phantun 内核的下载通道:\n" 14 60 3 \
        fast   "国内极速镜像 1 (ghfast.top，首选)" \
        proxy  "国内极速镜像 2 (ghproxy.net，备选)" \
        eng    "GitHub 官方源 (海外机器适用)" \
        2>"$DLG_TEMP" || ret=$?
    [[ $ret -ne $DIALOG_OK ]] && return

    local src; src=$(<"$DLG_TEMP")
    case "$src" in
        eng)   GITHUB_MIRROR="" ;;
        fast)  GITHUB_MIRROR="https://ghfast.top" ;;
        proxy) GITHUB_MIRROR="https://ghproxy.net" ;;
    esac

    dialog --title "安装中" --infobox "\n正在下载并部署 Phantun ${PHANTUN_VERSION}...\n请稍候..." 7 55
    local output
    output=$(do_install 2>&1) || true
    dlg_msgbox "安装结果" "$output"
}

# ─── 添加规则 ────────────────────────────────────────────────────
menu_add_mapping() {
    local ret=0
    dialog --title "选择运行模式" \
        --menu "\n请选择本台机器的角色:\n" 12 60 2 \
        server "作为服务端 (落地机: 接收 TCP，还原为 UDP)" \
        client "作为客户端 (中转机: 接收 UDP，伪装为 TCP)" \
        2>"$DLG_TEMP" || ret=$?
    [[ $ret -ne $DIALOG_OK ]] && return

    local mode; mode=$(<"$DLG_TEMP")
    case "$mode" in
        server) menu_add_server ;;
        client) menu_add_client ;;
    esac
}

menu_add_server() {
    local def_iface; def_iface=$(detect_iface || true)
    local def_name; def_name=$(auto_name "s" "1001")

    local ret=0
    dialog --title "添加服务端 (落地机)" \
        --form "\n此模式下，机器将监听 TCP 端口，并将解包后的 UDP 发送到本地节点(如 127.0.0.1:xxx)。\n" \
        18 65 5 \
        "TCP 监听端口 :"  1 1 "1001"             1 18 20 0 \
        "UDP 目标地址 :"  2 1 "127.0.0.1:1002"   2 18 40 0 \
        "本条规则名称 :"  3 1 "$def_name"         3 18 20 0 \
        "使用物理网卡 :"  4 1 "$def_iface"        4 18 20 0 \
        2>"$DLG_TEMP" || ret=$?
    [[ $ret -ne $DIALOG_OK ]] && return

    local fields
    mapfile -t fields < "$DLG_TEMP"
    local tcp_port="${fields[0]}"
    local udp_target="${fields[1]}"
    local name="${fields[2]}"
    local iface="${fields[3]}"

    if ! validate_port "$tcp_port"; then dlg_error "无效的 TCP 端口: ${tcp_port}"; return; fi
    if ! validate_addr_port "$udp_target"; then dlg_error "无效的 UDP 目标: ${udp_target}\n格式应为 IP:端口"; return; fi

    ret=0
    dialog --title "信息确认" --yesno "\n即将创建 服务端 规则?\n\n  TCP 监听:  :${tcp_port}\n  还原 UDP:  ${udp_target}\n  规则名称:  ${name}\n  网络接口:  ${iface}\n" 14 50 || ret=$?
    [[ $ret -ne $DIALOG_OK ]] && return

    dialog --title "执行中" --infobox "\n正在部署 服务端 规则 '${name}'...\n请稍候..." 7 50
    local output
    output=$(do_server_add "$tcp_port" "$udp_target" "$name" "$iface" 2>&1) || true
    dlg_msgbox "部署结果" "$output"
}

menu_add_client() {
    local def_iface; def_iface=$(detect_iface || true)
    local def_name; def_name=$(auto_name "c" "1001")

    local ret=0
    dialog --title "添加客户端 (中转机)" \
        --form "\n此模式下，机器将接收您的 UDP 请求，伪装成 TCP 后发往远端服务端。\n" \
        18 65 5 \
        "目标机器 IP  :"  1 1 ""                  1 18 40 0 \
        "目标机器端口 :"  2 1 "1001"              2 18 20 0 \
        "本地暴露 UDP :"  3 1 "1001"              3 18 20 0 \
        "本条规则名称 :"  4 1 "$def_name"         4 18 20 0 \
        "使用物理网卡 :"  5 1 "$def_iface"        5 18 20 0 \
        2>"$DLG_TEMP" || ret=$?
    [[ $ret -ne $DIALOG_OK ]] && return

    local fields
    mapfile -t fields < "$DLG_TEMP"
    local server_addr="${fields[0]}"
    local server_port="${fields[1]}"
    local local_port="${fields[2]}"
    local name="${fields[3]}"
    local iface="${fields[4]}"

    if [[ -z "$server_addr" ]]; then dlg_error "目标 IP 地址不能为空。"; return; fi
    if ! validate_port "$server_port"; then dlg_error "无效的目标端口: ${server_port}"; return; fi
    if ! validate_port "$local_port"; then dlg_error "无效的本地端口: ${local_port}"; return; fi

    ret=0
    dialog --title "信息确认" --yesno "\n即将创建 客户端 规则?\n\n  目标机器:   ${server_addr}:${server_port}\n  本地伪装:   127.0.0.1:${local_port} (UDP)\n  规则名称:   ${name}\n  网络接口:   ${iface}\n" 14 55 || ret=$?
    [[ $ret -ne $DIALOG_OK ]] && return

    dialog --title "执行中" --infobox "\n正在部署 客户端 规则 '${name}'...\n请稍候..." 7 50
    local output
    output=$(do_client_add "$server_addr" "$server_port" "$local_port" "$name" "$iface" 2>&1) || true
    dlg_msgbox "部署结果" "$output"
}

# ─── 列表与详情 ──────────────────────────────────────────────────
menu_list() {
    local text
    text=$(build_status_text 2>&1) || true
    dlg_msgbox "转发规则列表" "$text"
}

menu_details() {
    local names_raw; names_raw=$(list_config_names) || true
    [[ -z "$names_raw" ]] && { dlg_msgbox "详情" "目前没有任何规则。"; return; }

    local menu_items=()
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        source "$CONFIG_DIR/${n}.conf"
        local desc
        if [[ "$MODE" == "server" ]]; then desc="[服务端] TCP:${TCP_PORT} -> ${UDP_TARGET}"
        else desc="[客户端] UDP:${LOCAL_PORT} -> ${SERVER_ADDR}:${SERVER_PORT}"; fi
        menu_items+=("$n" "$desc")
    done <<< "$names_raw"

    local ret=0
    dialog --title "选择规则" \
        --menu "\n请选择要查看的规则:\n" 18 65 10 \
        "${menu_items[@]}" \
        2>"$DLG_TEMP" || ret=$?
    [[ $ret -ne $DIALOG_OK ]] && return

    local selected; selected=$(<"$DLG_TEMP")
    local text; text=$(build_status_text "$selected" 2>&1) || true
    dlg_msgbox "规则详情: ${selected}" "$text"
}

# ─── 启动/停止 ──────────────────────────────────────────────────
menu_startstop() {
    local names_raw; names_raw=$(list_config_names) || true
    [[ -z "$names_raw" ]] && { dlg_msgbox "启动/停止" "目前没有任何规则。"; return; }

    local menu_items=()
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        local svc="${SERVICE_PREFIX}-${n}"
        local st="已停止"
        systemctl is-active "$svc" &>/dev/null && st="运行中"
        menu_items+=("$n" "[${st}]")
    done <<< "$names_raw"

    local ret=0
    dialog --title "启动 / 停止 规则" \
        --menu "\n请选择要操作的规则:\n" 18 55 10 \
        "${menu_items[@]}" \
        2>"$DLG_TEMP" || ret=$?
    [[ $ret -ne $DIALOG_OK ]] && return

    local selected; selected=$(<"$DLG_TEMP")
    local svc="${SERVICE_PREFIX}-${selected}"

    if systemctl is-active "$svc" &>/dev/null; then
        ret=0
        dialog --title "停止" --yesno "\n规则 '${selected}' 正在运行。\n\n要停止它吗?" 9 45 || ret=$?
        if [[ $ret -eq $DIALOG_OK ]]; then
            systemctl stop "${svc}.service" 2>/dev/null || true
            dlg_msgbox "已停止" "规则 '${selected}' 已停止。"
        fi
    else
        ret=0
        dialog --title "启动" --yesno "\n规则 '${selected}' 已停止。\n\n要启动它吗?" 9 45 || ret=$?
        if [[ $ret -eq $DIALOG_OK ]]; then
            systemctl start "${svc}.service" 2>/dev/null || true
            dlg_msgbox "已启动" "规则 '${selected}' 已启动。"
        fi
    fi
}

# ─── 删除与卸载 ────────────────────────────────────────────────
menu_remove() {
    local names_raw; names_raw=$(list_config_names) || true
    [[ -z "$names_raw" ]] && { dlg_msgbox "删除" "目前没有任何规则。"; return; }

    local menu_items=()
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        source "$CONFIG_DIR/${n}.conf"
        local desc
        if [[ "$MODE" == "server" ]]; then desc="[服务端] TCP:${TCP_PORT} -> ${UDP_TARGET}"
        else desc="[客户端] UDP:${LOCAL_PORT} -> ${SERVER_ADDR}:${SERVER_PORT}"; fi
        menu_items+=("$n" "$desc")
    done <<< "$names_raw"

    local ret=0
    dialog --title "删除规则" \
        --menu "\n请选择要删除的规则:\n" 18 65 10 \
        "${menu_items[@]}" \
        2>"$DLG_TEMP" || ret=$?
    [[ $ret -ne $DIALOG_OK ]] && return

    local selected; selected=$(<"$DLG_TEMP")
    ret=0
    dialog --title "确认删除" --yesno "\n确定要删除规则 '${selected}' 吗？\n\n这会停止进程并抹除所有的 iptables 和配置文件。" 10 50 || ret=$?
    [[ $ret -ne $DIALOG_OK ]] && return

    local output; output=$(do_remove "$selected" 2>&1) || true
    dlg_msgbox "删除结果" "$output"
}

menu_uninstall() {
    local ret=0
    dialog --title "彻底卸载" \
        --yesno "\n此操作将：\n\n  - 停止并删除所有转发规则\n  - 删除 Phantun 内核\n  - 清理所有配置残留\n\n您确定要继续吗？" 14 50 || ret=$?
    [[ $ret -ne $DIALOG_OK ]] && return

    dialog --title "卸载中" --infobox "\n正在清除系统中的所有痕迹...\n请稍候..." 7 50
    local output; output=$(do_uninstall 2>&1) || true
    dlg_msgbox "卸载结果" "$output"
}

# ═══════════════════════════════════════════════════════════════════
#  CLI 纯命令模式支持
# ═══════════════════════════════════════════════════════════════════
cli_usage() {
    cat <<EOF

${BOLD}UoT-Forward${NC} v${SCRIPT_VERSION} - 基于 Phantun 的 UDP 伪装 TCP 穿透工具

${BOLD}交互式面板:${NC}
    sudo $(basename "$0")                    唤出图形化配置菜单

${BOLD}命令行快速调用:${NC}
    sudo $(basename "$0") <命令> [选项]

${BOLD}支持的命令:${NC}
    ${CYAN}install${NC}                           下载并安装 Phantun 内核
    ${CYAN}server add${NC} [选项]                添加 服务端(落地机) 规则
    ${CYAN}client add${NC} [选项]                添加 客户端(中转机) 规则
    ${CYAN}list${NC}                               列出所有转发规则
    ${CYAN}status${NC} [name]                      查看单条规则运行状态
    ${CYAN}remove${NC} <name>                      删除某条转发规则
    ${CYAN}uninstall${NC}                          彻底清理并卸载系统

${BOLD}服务端选项 (server add):${NC}
    --tcp-port <port>               本地监听的 TCP 端口
    --udp-target <host:port>        还原并转发到的本地 UDP 节点
    --name <name>                   [可选] 自定义规则名
    --iface <interface>             [可选] 绑定的物理网卡

${BOLD}客户端选项 (client add):${NC}
    --server-addr <address>         落地机 IP 地址
    --server-port <port>            落地机暴露的 TCP 端口
    --local-port <port>             本地想要暴露出来的 UDP 端口
    --name <name>                   [可选] 自定义规则名
    --iface <interface>             [可选] 绑定的物理网卡

${BOLD}全局参数:${NC}
    --cn                            强制使用国内镜像加速下载 (ghfast.top)

${BOLD}命令行示例:${NC}
    $(basename "$0") --cn install
    $(basename "$0") server add --tcp-port 1001 --udp-target 127.0.0.1:1002
    $(basename "$0") client add --server-addr 1.2.3.4 --server-port 1001 --local-port 1001
EOF
}

cli_server_add() {
    local tcp_port="" udp_target="" name="" iface=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tcp-port)   tcp_port="$2"; shift 2 ;;
            --udp-target) udp_target="$2"; shift 2 ;;
            --name)       name="$2"; shift 2 ;;
            --iface)      iface="$2"; shift 2 ;;
            *) die "未知选项: $1" ;;
        esac
    done
    [[ -n "$tcp_port" ]]   || die "缺少参数: --tcp-port"
    [[ -n "$udp_target" ]] || die "缺少参数: --udp-target"
    do_server_add "$tcp_port" "$udp_target" "$name" "$iface"
}

cli_client_add() {
    local server_addr="" server_port="" local_port="" name="" iface=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server-addr) server_addr="$2"; shift 2 ;;
            --server-port) server_port="$2"; shift 2 ;;
            --local-port)  local_port="$2"; shift 2 ;;
            --name)        name="$2"; shift 2 ;;
            --iface)       iface="$2"; shift 2 ;;
            *) die "未知选项: $1" ;;
        esac
    done
    [[ -n "$server_addr" ]] || die "缺少参数: --server-addr"
    [[ -n "$server_port" ]] || die "缺少参数: --server-port"
    [[ -n "$local_port" ]]  || die "缺少参数: --local-port"
    do_client_add "$server_addr" "$server_port" "$local_port" "$name" "$iface"
}

cli_dispatch() {
    require_root
    local cmd="$1"; shift
    case "$cmd" in
        install)   do_install ;;
        server)    [[ "${1:-}" == "add" ]] || die "用法: server add [选项]"; shift; cli_server_add "$@" ;;
        client)    [[ "${1:-}" == "add" ]] || die "用法: client add [选项]"; shift; cli_client_add "$@" ;;
        list)      build_status_text ;;
        status)    build_status_text "${1:-}" ;;
        remove)    do_remove "${1:-}" ;;
        uninstall)
            warn "此操作将清除所有配置。"
            echo -n "继续执行? [y/N] "
            read -r ans
            [[ "$ans" =~ ^[Yy] ]] || { info "已取消。"; exit 0; }
            do_uninstall
            ;;
        -h|--help|help) cli_usage ;;
        *) die "未知命令: $cmd。请使用 --help 查看帮助。" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════
#  入口函数
# ═══════════════════════════════════════════════════════════════════
main() {
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cn)     GITHUB_MIRROR="https://ghfast.top"; shift ;;
            *)        args+=("$1"); shift ;;
        esac
    done
    set -- "${args[@]}"

    if [[ $# -gt 0 ]]; then
        cli_dispatch "$@"
    else
        require_root
        ensure_dialog
        menu_main
    fi
}

main "$@"