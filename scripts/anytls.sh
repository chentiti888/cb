#!/bin/bash

# AnyTLS 协议安装与管理模块 (基于 sing-box 的 anytls 入站，需要 sing-box >= 1.12.0)
#
# 说明：
#   - 本文件会被 hy2-manager.sh 通过 source 加载。主脚本带有 ERR trap，
#     所以这里不使用 set -e，所有可能返回非 0 的命令都自行兜底。
#   - AnyTLS 走 TCP，Hysteria2 走 UDP，两者互不冲突，可以同时运行。
#   - 与 hy2 完全独立：独立目录 /etc/anytls，独立服务 anytls-server.service，
#     卸载 AnyTLS 不会影响 hy2。

# 颜色（主脚本已定义；单独运行时给个兜底）
: "${RED:=\033[0;31m}"
: "${GREEN:=\033[0;32m}"
: "${YELLOW:=\033[1;33m}"
: "${BLUE:=\033[0;34m}"
: "${CYAN:=\033[0;36m}"
: "${NC:=\033[0m}"

ANYTLS_DIR="${ANYTLS_DIR:-/etc/anytls}"
ANYTLS_CONF="$ANYTLS_DIR/anytls.conf"
ANYTLS_JSON="$ANYTLS_DIR/config.json"
ANYTLS_INFO="$ANYTLS_DIR/node-info.txt"
ANYTLS_BIN="${ANYTLS_BIN:-/usr/local/bin/sing-box-anytls}"
ANYTLS_SERVICE="anytls-server.service"
ANYTLS_UNIT="/etc/systemd/system/$ANYTLS_SERVICE"
ANYTLS_FALLBACK_VER="1.12.0"   # GitHub API 查询失败时使用的版本
ANYTLS_DEFAULT_PORT=8443
ANYTLS_DEFAULT_SNI="cdn.jsdelivr.net"

# 当前配置（由 anytls_load_conf 读取）
AT_PORT=""
AT_PASSWORD=""
AT_CERT_MODE=""   # self | hy2 | custom
AT_CERT_FILE=""
AT_KEY_FILE=""
AT_DOMAIN=""      # hy2/custom 模式下的真实域名
AT_SNI=""         # self 模式下的伪装 SNI

# ---------------------------------------------------------------- 基础工具

anytls_pause() {
    echo ""
    read -r -p "按回车键继续..." _ || true
}

anytls_installed() { [[ -x "$ANYTLS_BIN" ]]; }
anytls_configured() { [[ -f "$ANYTLS_CONF" && -f "$ANYTLS_JSON" ]]; }

anytls_status_text() {
    if ! anytls_installed; then
        echo -e "${RED}❌ 未安装${NC}"
    elif systemctl is-active --quiet "$ANYTLS_SERVICE" 2>/dev/null; then
        echo -e "${GREEN}✅ 运行中${NC}"
    elif [[ -f "$ANYTLS_UNIT" ]]; then
        echo -e "${YELLOW}⏸️  已安装但未运行${NC}"
    else
        echo -e "${YELLOW}⚠️  已安装内核，尚未配置${NC}"
    fi
}

anytls_get_ip() {
    local ip="" u
    for u in ipv4.icanhazip.com ifconfig.me ip.sb checkip.amazonaws.com; do
        ip=$(curl -s --connect-timeout 5 "$u" 2>/dev/null | tr -d '[:space:]') || ip=""
        if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    ip=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -1) || ip=""
    echo "${ip:-127.0.0.1}"
}

anytls_rand_password() {
    local p=""
    p=$(openssl rand -base64 24 2>/dev/null | tr -d '=+/\n' | cut -c1-16) || p=""
    if [[ -z "$p" ]]; then
        p=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-16) || p="anytls$RANDOM$RANDOM"
    fi
    echo "$p"
}

# URL 编码（按字节处理，密码里有特殊字符时链接也能用）
anytls_urlencode() {
    local LC_ALL=C
    local s="$1" out="" i c
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) out+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    echo "$out"
}

anytls_valid_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

anytls_port_in_use() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        [[ -n "$(ss -tln 2>/dev/null | awk -v re=":${p}\$" 'NR>1 && $4 ~ re {print 1; exit}')" ]]
    elif command -v netstat >/dev/null 2>&1; then
        [[ -n "$(netstat -tln 2>/dev/null | awk -v re=":${p}\$" '$4 ~ re {print 1; exit}')" ]]
    else
        return 1
    fi
}

# ---------------------------------------------------------------- 防火墙 (TCP)

anytls_open_port() {
    local p="$1"
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        echo "Firewalld: 已放行 ${p}/tcp"
    elif command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; then
        ufw allow "${p}/tcp" >/dev/null 2>&1 || true
        echo "UFW: 已放行 ${p}/tcp"
    elif command -v iptables >/dev/null 2>&1; then
        if ! iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
        fi
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 || true
        fi
        echo "iptables: 已放行 ${p}/tcp"
    fi
}

anytls_close_port() {
    local p="$1"
    [[ -n "$p" ]] || return 0
    # 80/443 可能还被 nginx 或 hy2 的证书验证使用，不关闭
    if [[ "$p" == "80" || "$p" == "443" ]]; then
        return 0
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --remove-port="${p}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    elif command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; then
        ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true
    elif command -v iptables >/dev/null 2>&1; then
        while iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; do :; done
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 || true
        fi
    fi
}

# ---------------------------------------------------------------- 内核安装

anytls_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo "amd64" ;;
        aarch64 | arm64) echo "arm64" ;;
        armv7l | armv7) echo "armv7" ;;
        i386 | i686) echo "386" ;;
        *) echo "" ;;
    esac
}

anytls_latest_version() {
    local v=""
    v=$(curl -fsSL --connect-timeout 8 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
        | grep -oP '"tag_name":\s*"v\K[0-9][^"]*' | head -1) || v=""
    echo "$v"
}

# 下载并安装 sing-box 内核到 $ANYTLS_BIN（不会动系统里可能已有的 sing-box）
anytls_install_core() {
    local arch ver tmp url bin
    arch=$(anytls_arch)
    if [[ -z "$arch" ]]; then
        echo -e "${RED}不支持的 CPU 架构: $(uname -m)${NC}"
        return 1
    fi

    local dep
    for dep in curl tar; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo -e "${RED}缺少依赖: $dep，请先安装${NC}"
            return 1
        fi
    done

    ver="${ANYTLS_SINGBOX_VERSION:-}"
    if [[ -z "$ver" ]]; then
        echo -e "${BLUE}正在查询 sing-box 最新版本...${NC}"
        ver=$(anytls_latest_version)
    fi
    if [[ -z "$ver" ]]; then
        echo -e "${YELLOW}无法获取最新版本，使用 $ANYTLS_FALLBACK_VER${NC}"
        ver="$ANYTLS_FALLBACK_VER"
    fi

    url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}.tar.gz"
    echo -e "${BLUE}正在下载 sing-box v${ver} (${arch})...${NC}"

    tmp=$(mktemp -d) || return 1
    if ! curl -fL --retry 3 --connect-timeout 15 -# -o "$tmp/sing-box.tar.gz" "$url"; then
        echo -e "${RED}下载失败: $url${NC}"
        echo "请检查 VPS 是否能访问 github.com，或设置 ANYTLS_SINGBOX_VERSION 指定版本后重试"
        rm -rf "$tmp"
        return 1
    fi
    if ! tar -xzf "$tmp/sing-box.tar.gz" -C "$tmp"; then
        echo -e "${RED}解压失败${NC}"
        rm -rf "$tmp"
        return 1
    fi

    bin=$(find "$tmp" -type f -name sing-box 2>/dev/null | head -1) || bin=""
    if [[ -z "$bin" ]]; then
        echo -e "${RED}安装包中未找到 sing-box 可执行文件${NC}"
        rm -rf "$tmp"
        return 1
    fi

    if ! install -m 755 "$bin" "$ANYTLS_BIN"; then
        echo -e "${RED}安装内核失败: $ANYTLS_BIN${NC}"
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"

    echo -e "${GREEN}内核安装完成: $("$ANYTLS_BIN" version 2>/dev/null | head -1)${NC}"
    return 0
}

# ---------------------------------------------------------------- 配置读写

anytls_save_conf() {
    mkdir -p "$ANYTLS_DIR"
    chmod 700 "$ANYTLS_DIR" 2>/dev/null || true
    {
        echo "AT_PORT='$AT_PORT'"
        echo "AT_PASSWORD='$AT_PASSWORD'"
        echo "AT_CERT_MODE='$AT_CERT_MODE'"
        echo "AT_CERT_FILE='$AT_CERT_FILE'"
        echo "AT_KEY_FILE='$AT_KEY_FILE'"
        echo "AT_DOMAIN='$AT_DOMAIN'"
        echo "AT_SNI='$AT_SNI'"
    } > "$ANYTLS_CONF"
    chmod 600 "$ANYTLS_CONF" 2>/dev/null || true
}

anytls_load_conf() {
    [[ -f "$ANYTLS_CONF" ]] || return 1
    AT_PORT=""; AT_PASSWORD=""; AT_CERT_MODE=""; AT_CERT_FILE=""; AT_KEY_FILE=""; AT_DOMAIN=""; AT_SNI=""
    # shellcheck source=/dev/null
    source "$ANYTLS_CONF" 2>/dev/null || return 1
    [[ -n "$AT_PORT" && -n "$AT_PASSWORD" ]]
}

# 根据 AT_* 变量生成 sing-box 配置并校验
anytls_write_config() {
    mkdir -p "$ANYTLS_DIR"
    chmod 700 "$ANYTLS_DIR" 2>/dev/null || true
    local server_name="${AT_DOMAIN:-$AT_SNI}"

    local new_json="$ANYTLS_DIR/config.new.json"
    cat > "$new_json" << EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $AT_PORT,
      "users": [
        {
          "name": "user",
          "password": "$AT_PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$server_name",
        "certificate_path": "$AT_CERT_FILE",
        "key_path": "$AT_KEY_FILE"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    chmod 600 "$new_json" 2>/dev/null || true

    local out
    if ! out=$("$ANYTLS_BIN" check -c "$new_json" 2>&1); then
        rm -f "$new_json"
        echo -e "${RED}配置校验失败:${NC}"
        echo "$out"
        echo -e "${YELLOW}如果提示不认识 anytls，说明 sing-box 版本过低 (需要 >= 1.12.0)，可在菜单里更新内核${NC}"
        return 1
    fi
    # 校验通过才替换正式配置，失败时旧配置原样保留
    mv -f "$new_json" "$ANYTLS_JSON"
    return 0
}

anytls_write_service() {
    cat > "$ANYTLS_UNIT" << EOF
[Unit]
Description=AnyTLS Server (sing-box)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$ANYTLS_BIN run -c $ANYTLS_JSON
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "$ANYTLS_SERVICE" >/dev/null 2>&1 || true
}

# 重启并确认服务确实起来了
anytls_restart() {
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart "$ANYTLS_SERVICE" 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet "$ANYTLS_SERVICE" 2>/dev/null; then
        return 0
    fi
    echo -e "${RED}AnyTLS 服务启动失败，最近日志:${NC}"
    journalctl -u "$ANYTLS_SERVICE" --no-pager -n 20 2>/dev/null || true
    return 1
}

# ---------------------------------------------------------------- 交互：端口 / 密码 / 证书

anytls_ask_port() {
    local default="$1" input
    while true; do
        echo -n -e "${BLUE}请输入 AnyTLS 监听端口 (TCP) [默认 ${default}]: ${NC}"
        read -r input || input=""
        input="${input:-$default}"
        if ! [[ "$input" =~ ^[0-9]{1,5}$ ]]; then
            echo -e "${RED}端口无效，请输入 1-65535${NC}"
            continue
        fi
        input=$((10#$input))
        if ((input < 1 || input > 65535)); then
            echo -e "${RED}端口无效，请输入 1-65535${NC}"
            continue
        fi
        if [[ "$input" != "${AT_PORT:-}" ]] && anytls_port_in_use "$input"; then
            echo -e "${RED}TCP 端口 $input 已被占用，请换一个${NC}"
            continue
        fi
        AT_PORT="$input"
        return 0
    done
}

anytls_ask_password() {
    local input
    while true; do
        echo -n -e "${BLUE}请输入连接密码 (直接回车 = 随机生成): ${NC}"
        read -r input || input=""
        if [[ -z "$input" ]]; then
            AT_PASSWORD=$(anytls_rand_password)
            echo "已生成随机密码: $AT_PASSWORD"
            return 0
        fi
        if [[ "$input" =~ ^[A-Za-z0-9._~!@#%^*+=-]{6,64}$ ]]; then
            AT_PASSWORD="$input"
            return 0
        fi
        echo -e "${RED}密码需 6-64 位，只能包含字母数字和 . _ ~ ! @ # % ^ * + = -${NC}"
    done
}

# 探测 hy2 的 ACME 证书（成功时设置 AT_HY2_DOMAIN/AT_HY2_CRT/AT_HY2_KEY）
anytls_detect_hy2_cert() {
    AT_HY2_DOMAIN=""; AT_HY2_CRT=""; AT_HY2_KEY=""
    local d="" crt=""

    if [[ -f /etc/hysteria/server-domain.conf ]]; then
        d=$(head -1 /etc/hysteria/server-domain.conf 2>/dev/null | tr -d '[:space:]') || d=""
    fi
    if [[ -z "$d" && -f /etc/hysteria/config.yaml ]]; then
        d=$(awk '/^acme:/{f=1;next} f&&/^[^ \t#]/{f=0} f&&/^[ \t]*-[ \t]*/{sub(/^[ \t]*-[ \t]*/,""); sub(/[ \t]*#.*$/,""); print; exit}' \
            /etc/hysteria/config.yaml 2>/dev/null | tr -d '[:space:]"'"'"'') || d=""
    fi
    [[ -n "$d" ]] || return 1

    if [[ -d /var/lib/hysteria/acme ]]; then
        crt=$(find /var/lib/hysteria/acme -type f -name "${d}.crt" 2>/dev/null | head -1) || crt=""
    fi
    [[ -n "$crt" && -f "${crt%.crt}.key" ]] || return 1

    AT_HY2_DOMAIN="$d"
    AT_HY2_CRT="$crt"
    AT_HY2_KEY="${crt%.crt}.key"
    return 0
}

anytls_gen_selfsigned() {
    local sni="$1"
    mkdir -p "$ANYTLS_DIR"
    if ! openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$ANYTLS_DIR/server.key" -out "$ANYTLS_DIR/server.crt" \
        -subj "/CN=$sni" -addext "subjectAltName=DNS:$sni" -days 3650 >/dev/null 2>&1; then
        echo -e "${RED}自签名证书生成失败 (需要 openssl)${NC}"
        return 1
    fi
    chmod 600 "$ANYTLS_DIR/server.key" 2>/dev/null || true
    return 0
}

anytls_ask_cert() {
    local has_hy2=false choice default_choice="1" input
    if anytls_detect_hy2_cert; then
        has_hy2=true
        default_choice="2"
    fi

    echo ""
    echo -e "${YELLOW}请选择证书方式:${NC}"
    echo -e "${GREEN} 1.${NC} 自签名证书 (最简单，客户端需开启\"允许不安全\")"
    if $has_hy2; then
        echo -e "${GREEN} 2.${NC} 复用 Hysteria2 的域名证书 [检测到: $AT_HY2_DOMAIN] (推荐，无需\"允许不安全\"，自动续期)"
    else
        echo -e "${CYAN} 2.${NC} 复用 Hysteria2 的域名证书 (未检测到，不可用)"
    fi
    echo -e "${GREEN} 3.${NC} 使用自己的证书文件"

    while true; do
        echo -n -e "${BLUE}请选择 [1-3，默认 ${default_choice}]: ${NC}"
        read -r choice || choice=""
        choice="${choice:-$default_choice}"
        case "$choice" in
            1)
                while true; do
                    echo -n -e "${BLUE}请输入伪装 SNI 域名 [默认 ${ANYTLS_DEFAULT_SNI}]: ${NC}"
                    read -r input || input=""
                    input="${input:-$ANYTLS_DEFAULT_SNI}"
                    if anytls_valid_domain "$input"; then
                        break
                    fi
                    echo -e "${RED}域名格式无效${NC}"
                done
                AT_SNI="$input"
                AT_DOMAIN=""
                echo -e "${BLUE}正在生成自签名证书...${NC}"
                anytls_gen_selfsigned "$AT_SNI" || return 1
                AT_CERT_MODE="self"
                AT_CERT_FILE="$ANYTLS_DIR/server.crt"
                AT_KEY_FILE="$ANYTLS_DIR/server.key"
                return 0
                ;;
            2)
                if ! $has_hy2; then
                    echo -e "${RED}没有检测到 Hysteria2 的域名证书，请选其他方式${NC}"
                    continue
                fi
                AT_CERT_MODE="hy2"
                AT_DOMAIN="$AT_HY2_DOMAIN"
                AT_SNI=""
                AT_CERT_FILE="$AT_HY2_CRT"
                AT_KEY_FILE="$AT_HY2_KEY"
                local end
                end=$(openssl x509 -in "$AT_CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2) || end=""
                echo -e "${GREEN}将使用 $AT_DOMAIN 的证书${end:+ (到期: $end)}${NC}"
                echo "证书由 Hysteria2 自动续期，sing-box 检测到文件变化会自动重新加载"
                return 0
                ;;
            3)
                while true; do
                    echo -n -e "${BLUE}证书对应的域名: ${NC}"
                    read -r input || input=""
                    if anytls_valid_domain "$input"; then
                        AT_DOMAIN="$input"
                        break
                    fi
                    echo -e "${RED}域名格式无效${NC}"
                done
                while true; do
                    echo -n -e "${BLUE}证书文件路径 (crt/pem，含完整链): ${NC}"
                    read -r AT_CERT_FILE || AT_CERT_FILE=""
                    echo -n -e "${BLUE}私钥文件路径 (key): ${NC}"
                    read -r AT_KEY_FILE || AT_KEY_FILE=""
                    if [[ -f "$AT_CERT_FILE" && -f "$AT_KEY_FILE" ]] \
                        && openssl x509 -in "$AT_CERT_FILE" -noout >/dev/null 2>&1; then
                        break
                    fi
                    echo -e "${RED}文件不存在或不是有效证书，请重新输入${NC}"
                done
                AT_CERT_MODE="custom"
                AT_SNI=""
                return 0
                ;;
            *)
                echo -e "${RED}请输入 1-3${NC}"
                ;;
        esac
    done
}

# ---------------------------------------------------------------- 节点信息

anytls_build_link() {
    local host sni insecure pw_enc
    if [[ "$AT_CERT_MODE" == "self" ]]; then
        host=$(anytls_get_ip)
        sni="$AT_SNI"
        insecure=1
    else
        host="$AT_DOMAIN"
        sni="$AT_DOMAIN"
        insecure=0
    fi
    pw_enc=$(anytls_urlencode "$AT_PASSWORD")
    ANYTLS_LINK_HOST="$host"
    ANYTLS_LINK_SNI="$sni"
    ANYTLS_LINK_INSECURE="$insecure"
    ANYTLS_LINK="anytls://${pw_enc}@${host}:${AT_PORT}/?sni=${sni}&insecure=${insecure}#AnyTLS-${host}"
}

anytls_print_info() {
    anytls_build_link
    local skip_verify="false"
    [[ "$ANYTLS_LINK_INSECURE" == "1" ]] && skip_verify="true"

    echo -e "${CYAN}=== AnyTLS 节点信息 ===${NC}"
    echo ""
    echo "服务器地址: $ANYTLS_LINK_HOST"
    echo "端口 (TCP): $AT_PORT"
    echo "密码: $AT_PASSWORD"
    echo "SNI: $ANYTLS_LINK_SNI"
    if [[ "$skip_verify" == "true" ]]; then
        echo "证书验证: 需开启\"允许不安全\" (自签名证书)"
    else
        echo "证书验证: 正常验证 (真实域名证书)"
    fi
    echo ""
    echo -e "${YELLOW}节点链接 (AnyTLS):${NC}"
    echo "$ANYTLS_LINK"
    echo ""
    echo -e "${YELLOW}Clash Meta (mihomo) 配置片段:${NC}"
    cat << EOF
  - name: AnyTLS-${ANYTLS_LINK_HOST}
    type: anytls
    server: ${ANYTLS_LINK_HOST}
    port: ${AT_PORT}
    password: "${AT_PASSWORD}"
    sni: ${ANYTLS_LINK_SNI}
    skip-cert-verify: ${skip_verify}
    udp: true
EOF
    echo ""
}

anytls_save_info() {
    anytls_print_info 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' > "$ANYTLS_INFO" || true
    chmod 600 "$ANYTLS_INFO" 2>/dev/null || true
}

anytls_show_info() {
    if ! anytls_load_conf; then
        echo -e "${RED}AnyTLS 尚未配置，请先安装${NC}"
        return 1
    fi
    anytls_print_info
}

# ---------------------------------------------------------------- 主流程

# 安装 / 重新配置
anytls_install_flow() {
    echo -e "${CYAN}=== 安装 AnyTLS ===${NC}"
    echo ""

    if ! anytls_installed; then
        anytls_install_core || return 1
    else
        echo -e "${GREEN}已检测到内核: $("$ANYTLS_BIN" version 2>/dev/null | head -1)${NC}"
    fi

    local old_port=""
    if anytls_load_conf; then
        old_port="$AT_PORT"
        echo ""
        echo -e "${YELLOW}检测到已有 AnyTLS 配置 (端口 $AT_PORT)${NC}"
        echo -n -e "${BLUE}是否重新配置并覆盖? [y/N]: ${NC}"
        local ow
        read -r ow || ow=""
        if [[ ! "$ow" =~ ^[Yy]$ ]]; then
            echo "已取消"
            return 0
        fi
        if [[ -f "$ANYTLS_JSON" ]]; then
            cp "$ANYTLS_JSON" "$ANYTLS_JSON.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        fi
    fi

    echo ""
    echo -e "${BLUE}步骤 1/4: 端口${NC}"
    echo "AnyTLS 走 TCP，和 Hysteria2 的 UDP 443 不冲突。默认用 ${ANYTLS_DEFAULT_PORT}，也可以填 443。"
    anytls_ask_port "${old_port:-$ANYTLS_DEFAULT_PORT}"

    echo ""
    echo -e "${BLUE}步骤 2/4: 密码${NC}"
    anytls_ask_password

    echo ""
    echo -e "${BLUE}步骤 3/4: 证书${NC}"
    anytls_ask_cert || return 1

    echo ""
    echo -e "${BLUE}步骤 4/4: 生成配置并启动服务...${NC}"
    anytls_write_config || return 1
    anytls_save_conf
    anytls_write_service
    anytls_open_port "$AT_PORT"
    if [[ -n "$old_port" && "$old_port" != "$AT_PORT" ]]; then
        anytls_close_port "$old_port"
    fi

    if anytls_restart; then
        echo -e "${GREEN}AnyTLS 服务已启动，并已设置开机自启${NC}"
        echo ""
        anytls_save_info
        anytls_print_info
        echo -e "${BLUE}节点信息已保存到: $ANYTLS_INFO${NC}"
    else
        return 1
    fi
}

anytls_change_port() {
    if ! anytls_load_conf; then
        echo -e "${RED}AnyTLS 尚未配置，请先安装${NC}"
        return 1
    fi
    local old_port="$AT_PORT"
    anytls_ask_port "$old_port"
    if [[ "$AT_PORT" == "$old_port" ]]; then
        echo "端口未变化"
        return 0
    fi
    anytls_write_config || { AT_PORT="$old_port"; return 1; }
    anytls_save_conf
    anytls_open_port "$AT_PORT"
    anytls_close_port "$old_port"
    if anytls_restart; then
        anytls_save_info
        echo -e "${GREEN}端口已修改为 $AT_PORT${NC}"
        echo ""
        anytls_print_info
    fi
}

anytls_change_password() {
    if ! anytls_load_conf; then
        echo -e "${RED}AnyTLS 尚未配置，请先安装${NC}"
        return 1
    fi
    anytls_ask_password
    anytls_write_config || return 1
    anytls_save_conf
    if anytls_restart; then
        anytls_save_info
        echo -e "${GREEN}密码已修改${NC}"
        echo ""
        anytls_print_info
    fi
}

anytls_update_core() {
    if ! anytls_installed; then
        echo -e "${RED}尚未安装 AnyTLS${NC}"
        return 1
    fi
    anytls_install_core || return 1
    if [[ -f "$ANYTLS_UNIT" ]]; then
        if anytls_restart; then
            echo -e "${GREEN}内核已更新并重启服务${NC}"
        fi
    fi
}

anytls_service_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}=== AnyTLS 服务管理 ===${NC}"
        echo -e "${GREEN}1.${NC} 启动    ${GREEN}2.${NC} 停止    ${GREEN}3.${NC} 重启"
        echo -e "${GREEN}4.${NC} 查看状态    ${GREEN}5.${NC} 查看日志    ${RED}0.${NC} 返回"
        echo -n -e "${BLUE}请选择 [0-5]: ${NC}"
        local c
        read -r c || c="0"
        case "$c" in
            1) systemctl start "$ANYTLS_SERVICE" 2>/dev/null || true; sleep 1; echo -n "状态: "; anytls_status_text ;;
            2) systemctl stop "$ANYTLS_SERVICE" 2>/dev/null || true; echo -n "状态: "; anytls_status_text ;;
            3) if anytls_restart; then echo -e "${GREEN}已重启${NC}"; fi ;;
            4) systemctl status "$ANYTLS_SERVICE" --no-pager -l 2>/dev/null || true ;;
            5) journalctl -u "$ANYTLS_SERVICE" --no-pager -n 40 2>/dev/null || true ;;
            0) return 0 ;;
            *) echo -e "${RED}请输入 0-5${NC}" ;;
        esac
    done
}

anytls_uninstall() {
    echo -e "${YELLOW}即将卸载 AnyTLS (不会影响 Hysteria2)${NC}"
    echo -n -e "${RED}确认卸载? [y/N]: ${NC}"
    local c
    read -r c || c=""
    if [[ ! "$c" =~ ^[Yy]$ ]]; then
        echo "已取消"
        return 0
    fi

    local port=""
    if anytls_load_conf; then
        port="$AT_PORT"
    fi

    systemctl disable --now "$ANYTLS_SERVICE" >/dev/null 2>&1 || true
    rm -f "$ANYTLS_UNIT"
    systemctl daemon-reload 2>/dev/null || true
    anytls_close_port "$port"
    rm -f "$ANYTLS_BIN"
    rm -rf "$ANYTLS_DIR"
    echo -e "${GREEN}AnyTLS 已卸载${NC}"
}

# 入口：AnyTLS 管理菜单
anytls_menu() {
    while true; do
        clear
        echo -e "${CYAN}================================================${NC}"
        echo -e "${CYAN}              AnyTLS 协议管理${NC}"
        echo -e "${CYAN}================================================${NC}"
        echo ""
        echo -n "服务状态: "
        anytls_status_text
        if anytls_load_conf; then
            echo "监听端口: TCP $AT_PORT"
        fi
        echo ""
        echo -e "${GREEN}1.${NC} 安装 / 重新配置 AnyTLS"
        echo -e "${GREEN}2.${NC} 查看节点链接"
        echo -e "${GREEN}3.${NC} 修改端口"
        echo -e "${GREEN}4.${NC} 修改密码"
        echo -e "${GREEN}5.${NC} 服务管理"
        echo -e "${GREEN}6.${NC} 更新内核 (sing-box)"
        echo -e "${GREEN}7.${NC} 卸载 AnyTLS"
        echo -e "${RED}0.${NC} 返回主菜单"
        echo ""
        echo -n -e "${BLUE}请输入选项 [0-7]: ${NC}"
        local choice
        read -r choice || choice="0"

        case "$choice" in
            1) anytls_install_flow || true; anytls_pause ;;
            2) anytls_show_info || true; anytls_pause ;;
            3) anytls_change_port || true; anytls_pause ;;
            4) anytls_change_password || true; anytls_pause ;;
            5)
                if anytls_installed; then
                    anytls_service_menu
                else
                    echo -e "${RED}尚未安装 AnyTLS${NC}"
                    anytls_pause
                fi
                ;;
            6) anytls_update_core || true; anytls_pause ;;
            7) anytls_uninstall || true; anytls_pause ;;
            0) return 0 ;;
            *) echo -e "${RED}请输入 0-7${NC}"; sleep 1 ;;
        esac
    done
}
