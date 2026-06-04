#!/usr/bin/env bash
# realmctl —— realm 端口转发管理 + 自动保活
# 兼容 debian / alpine 128M 小容器，无 systemd 亦可
# 用法见 `realmctl help`
set -o pipefail

# ============================================================
# 全局配置（可用同名环境变量覆盖）
# ============================================================
: "${REALM_HOME:=/root/realm}"
: "${REALM_BIN:=$REALM_HOME/realm}"
: "${REALM_CONF:=$REALM_HOME/config.toml}"
: "${REALM_PID:=$REALM_HOME/realm.pid}"
: "${REALM_LOG_DIR:=$REALM_HOME/logs}"
: "${REALM_LOG:=$REALM_LOG_DIR/realm.log}"
: "${REALM_WATCHDOG_LOG:=$REALM_LOG_DIR/watchdog.log}"
: "${REALM_VERSION:=v2.9.3}"
: "${REALM_MIRROR:=https://ghfast.top/}"   # 置空则直连 github
: "${REALM_WATCHDOG_INTERVAL:=5}"          # watchdog 检查间隔（秒）
: "${REALM_SELF_PATH:=/usr/local/bin/realmctl}"

C_RED='\033[0;31m'; C_GRN='\033[0;32m'; C_YLW='\033[0;33m'; C_BLU='\033[0;34m'; C_RST='\033[0m'

# ============================================================
# 工具函数
# ============================================================
log()  { printf '%b\n' "$*"; }
info() { log "${C_BLU}[*]${C_RST} $*"; }
ok()   { log "${C_GRN}[+]${C_RST} $*"; }
warn() { log "${C_YLW}[!]${C_RST} $*" >&2; }
err()  { log "${C_RED}[x]${C_RST} $*" >&2; }
die()  { err "$*"; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "需要 root 权限"; }
has()  { command -v "$1" >/dev/null 2>&1; }
ts()   { date '+%Y-%m-%d %H:%M:%S'; }

ensure_dirs() {
    mkdir -p "$REALM_HOME" "$REALM_LOG_DIR"
}

# 探测 init 系统：systemd / openrc / none
detect_init() {
    if has systemctl && [ -d /run/systemd/system ]; then
        echo systemd
    elif has rc-service && has rc-update; then
        echo openrc
    else
        echo none
    fi
}

# 探测 cron 二进制名（debian=cron，alpine=crond）
detect_cron() {
    if has crontab; then
        # 尝试启动 daemon
        if pgrep -x crond >/dev/null 2>&1 || pgrep -x cron >/dev/null 2>&1; then
            echo running
        else
            echo installed
        fi
    else
        echo missing
    fi
}

# 探测 CPU 架构 + libc，决定下载哪个 realm 发布版
detect_target() {
    local arch libc
    case "$(uname -m)" in
        x86_64|amd64) arch=x86_64 ;;
        aarch64|arm64) arch=aarch64 ;;
        armv7l|armv7) arch=armv7 ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
    if ldd --version 2>&1 | grep -qi musl || [ -f /lib/ld-musl-${arch}.so.1 ]; then
        libc=musl
    else
        libc=gnu
    fi
    case "$arch-$libc" in
        x86_64-gnu)    echo "realm-x86_64-unknown-linux-gnu.tar.gz" ;;
        x86_64-musl)   echo "realm-x86_64-unknown-linux-musl.tar.gz" ;;
        aarch64-gnu)   echo "realm-aarch64-unknown-linux-gnu.tar.gz" ;;
        aarch64-musl)  echo "realm-aarch64-unknown-linux-musl.tar.gz" ;;
        armv7-gnu)     echo "realm-armv7-unknown-linux-gnueabihf.tar.gz" ;;
        armv7-musl)    echo "realm-armv7-unknown-linux-musleabihf.tar.gz" ;;
    esac
}

# 通用下载（curl/wget 哪个有用哪个）
fetch() {
    local url="$1" dst="$2"
    if has curl; then
        curl -fsSL --connect-timeout 15 -o "$dst" "$url"
    elif has wget; then
        wget -q --timeout=15 -O "$dst" "$url"
    else
        die "未找到 curl 或 wget，请先安装：alpine 用 'apk add curl'，debian 用 'apt install curl'"
    fi
}

# ============================================================
# realm 进程状态
# ============================================================
realm_pid() {
    # 优先用 pid 文件，pid 文件失效则 pgrep 兜底
    if [ -f "$REALM_PID" ]; then
        local p; p=$(cat "$REALM_PID" 2>/dev/null)
        if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
            echo "$p"; return 0
        fi
    fi
    if has pgrep; then
        pgrep -f "^$REALM_BIN" | head -n1
    else
        ps -e -o pid=,args= 2>/dev/null | awk -v b="$REALM_BIN" '$2==b{print $1; exit}'
    fi
}

realm_running() {
    [ -n "$(realm_pid)" ]
}

# ============================================================
# 安装 / 卸载
# ============================================================
cmd_install() {
    need_root
    ensure_dirs
    if [ -x "$REALM_BIN" ]; then
        info "realm 已存在于 $REALM_BIN，跳过下载（如需更新请先运行 realmctl uninstall）"
    else
        local pkg url tmp
        pkg=$(detect_target) || die "无法识别目标平台"
        url="${REALM_MIRROR}https://github.com/zhboner/realm/releases/download/${REALM_VERSION}/${pkg}"
        tmp=$(mktemp -d)
        info "下载 realm ${REALM_VERSION} (${pkg})"
        info "源: $url"
        fetch "$url" "$tmp/realm.tar.gz" || die "下载失败"
        tar -xzf "$tmp/realm.tar.gz" -C "$tmp" || die "解包失败"
        install -m 0755 "$tmp/realm" "$REALM_BIN" || die "无法写入 $REALM_BIN"
        rm -rf "$tmp"
        ok "realm 已安装到 $REALM_BIN"
    fi

    # 初始化 config.toml
    if [ ! -f "$REALM_CONF" ]; then
        cat >"$REALM_CONF" <<'EOF'
[network]
no_tcp = false
use_udp = true

EOF
        ok "已初始化 $REALM_CONF"
    fi

    # 自我安装到 PATH（便于以后直接敲 realmctl）
    if [ "$0" != "$REALM_SELF_PATH" ] && [ -w "$(dirname "$REALM_SELF_PATH")" ]; then
        install -m 0755 "$0" "$REALM_SELF_PATH" 2>/dev/null \
            && ok "realmctl 已链接到 $REALM_SELF_PATH" \
            || warn "无法写入 $REALM_SELF_PATH，可手动 cp"
    fi
    ok "安装完成。下一步：realmctl add <本地端口> <远端IP> <远端端口> [备注]"
}

cmd_uninstall() {
    need_root
    cmd_stop 2>/dev/null || true
    cmd_disable 2>/dev/null || true
    rm -rf "$REALM_HOME"
    rm -f "$REALM_SELF_PATH"
    ok "已卸载 realm 及 realmctl"
}

# ============================================================
# 进程管理（不走 systemctl，直接 fork）
# ============================================================
cmd_start() {
    need_root
    [ -x "$REALM_BIN" ] || die "realm 未安装，请先运行 realmctl install"
    [ -f "$REALM_CONF" ] || die "缺少 $REALM_CONF"
    if [ "$(rule_count)" -eq 0 ]; then
        warn "尚无转发规则，不启动 realm（realm 要求至少 1 条 endpoint）"
        warn "请先 realmctl add <本地端口> <远端IP> <远端端口>"
        return 1
    fi
    if realm_running; then
        info "realm 已在运行 (PID $(realm_pid))"
        return 0
    fi
    ensure_dirs
    # 后台启动，日志重定向到文件
    nohup "$REALM_BIN" -c "$REALM_CONF" >>"$REALM_LOG" 2>&1 &
    local pid=$!
    echo "$pid" >"$REALM_PID"
    # 等 1 秒确认活着
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        ok "realm 已启动 (PID $pid)，日志: $REALM_LOG"
    else
        rm -f "$REALM_PID"
        err "realm 启动后立即退出，请查看日志:"
        tail -n 20 "$REALM_LOG" >&2 || true
        return 1
    fi
}

cmd_stop() {
    need_root
    local pid; pid=$(realm_pid)
    if [ -z "$pid" ]; then
        info "realm 未在运行"
        rm -f "$REALM_PID"
        return 0
    fi
    kill "$pid" 2>/dev/null || true
    # 等最多 5 秒优雅退出
    local i=0
    while kill -0 "$pid" 2>/dev/null && [ $i -lt 5 ]; do
        sleep 1; i=$((i+1))
    done
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$REALM_PID"
    ok "realm 已停止"
}

cmd_restart() {
    cmd_stop || true
    cmd_start
}

cmd_status() {
    local pid; pid=$(realm_pid)
    if [ -n "$pid" ]; then
        local rss; rss=$(awk '/VmRSS/{print $2" "$3}' /proc/$pid/status 2>/dev/null)
        log "realm 状态: ${C_GRN}运行中${C_RST}  PID=$pid  内存=${rss:-未知}"
    else
        log "realm 状态: ${C_RED}未运行${C_RST}"
    fi
    log "规则数: $(rule_count)"
    log "配置: $REALM_CONF"
    log "日志: $REALM_LOG"

    # watchdog 状态
    local wpid; wpid=$(watchdog_pid)
    if [ -n "$wpid" ]; then
        log "watchdog: ${C_GRN}守护中${C_RST}  PID=$wpid"
    else
        log "watchdog: ${C_YLW}未启动${C_RST}（运行 realmctl enable 开启自动保活）"
    fi
}

# ============================================================
# 规则操作（config.toml 增删改查）
# ============================================================
rule_count() {
    local n
    n=$(grep -c '^\[\[endpoints\]\]' "$REALM_CONF" 2>/dev/null || true)
    echo "${n:-0}"
}

# 格式化远端地址（自动处理 IPv6）
format_remote() {
    local ip="$1" port="$2"
    if [[ "$ip" == \[*\]* ]]; then
        echo "$ip:$port"
    elif [[ "$ip" == *:*:* ]]; then
        echo "[$ip]:$port"
    else
        echo "$ip:$port"
    fi
}

# 检查本地端口是否已被规则占用
port_in_use() {
    local port="$1"
    grep -E "^listen *= *\"\[::\]:${port}\"" "$REALM_CONF" >/dev/null 2>&1
}

cmd_add() {
    need_root
    [ -f "$REALM_CONF" ] || die "请先运行 realmctl install"
    local lport="$1" rip="$2" rport="$3" remark="${4:-}"
    [ -n "$lport" ] && [ -n "$rip" ] && [ -n "$rport" ] \
        || die "用法: realmctl add <本地端口> <远端IP> <远端端口> [备注]"
    [[ "$lport" =~ ^[0-9]+$ ]] || die "本地端口必须是数字"
    [[ "$rport" =~ ^[0-9]+$ ]] || die "远端端口必须是数字"
    if port_in_use "$lport"; then
        die "本地端口 $lport 已存在规则，请先 del 或换端口"
    fi
    local remote; remote=$(format_remote "$rip" "$rport")
    cat >>"$REALM_CONF" <<EOF
[[endpoints]]
# 备注: $remark
listen = "[::]:$lport"
remote = "$remote"
EOF
    ok "已添加规则: [::]:$lport -> $remote  (备注: ${remark:-无})"
    if realm_running; then
        cmd_restart
    else
        info "realm 当前未运行，规则保存但未生效。运行 realmctl start 启动"
    fi
}

# 列出规则到标准输出（机器可读 + 人类可读混合）
cmd_list() {
    [ -f "$REALM_CONF" ] || { warn "无配置"; return 0; }
    local n; n=$(rule_count)
    if [ "$n" = 0 ]; then
        info "尚无转发规则"
        return 0
    fi
    printf '%-3s | %-12s | %-45s | %s\n' "序号" "本地" "远端" "备注"
    printf -- '---------------------------------------------------------------------------\n'
    local idx=0
    local in_block=0 remark='' listen='' remote=''
    while IFS= read -r line; do
        case "$line" in
            '[[endpoints]]')
                in_block=1; remark=''; listen=''; remote=''
                ;;
            '# 备注:'*)
                [ "$in_block" = 1 ] && remark=$(echo "$line" | sed 's/^# 备注: *//')
                ;;
            'listen ='*)
                [ "$in_block" = 1 ] && listen=$(echo "$line" | sed -E 's/^listen *= *"(.*)"$/\1/')
                ;;
            'remote ='*)
                [ "$in_block" = 1 ] && remote=$(echo "$line" | sed -E 's/^remote *= *"(.*)"$/\1/')
                if [ "$in_block" = 1 ] && [ -n "$listen" ] && [ -n "$remote" ]; then
                    idx=$((idx+1))
                    printf '%-3d | %-12s | %-45s | %s\n' "$idx" "$listen" "$remote" "$remark"
                    in_block=0
                fi
                ;;
        esac
    done <"$REALM_CONF"
}

# 删除规则：支持 序号 或 本地端口
cmd_del() {
    need_root
    local target="$1"
    [ -n "$target" ] || die "用法: realmctl del <序号|本地端口>"

    # 解析目标 → 要删除的 listen 字符串
    local match_listen=''
    if [[ "$target" =~ ^[0-9]+$ ]] && [ "$target" -lt 65536 ]; then
        # 优先按序号解析
        local idx=0 cur_listen=''
        while IFS= read -r line; do
            case "$line" in
                'listen ='*)
                    idx=$((idx+1))
                    cur_listen=$(echo "$line" | sed -E 's/^listen *= *"(.*)"$/\1/')
                    if [ "$idx" = "$target" ]; then
                        match_listen="$cur_listen"; break
                    fi
                    ;;
            esac
        done <"$REALM_CONF"

        # 如果按序号没找到，再尝试按本地端口
        if [ -z "$match_listen" ] && grep -E "^listen *= *\"\[::\]:${target}\"" "$REALM_CONF" >/dev/null 2>&1; then
            match_listen="[::]:$target"
        fi
    fi
    [ -n "$match_listen" ] || die "未找到匹配的规则: $target"

    # 用 awk 删除整个 [[endpoints]] 块（含 # 备注 / listen / remote）
    local tmp; tmp=$(mktemp)
    awk -v target_listen="$match_listen" '
        BEGIN { buf=""; in_block=0 }
        /^\[\[endpoints\]\]/ {
            if (in_block) printf "%s", buf
            buf=$0 ORS; in_block=1; matched=0; next
        }
        in_block {
            buf = buf $0 ORS
            if ($0 ~ /^listen[[:space:]]*=/) {
                # 提取 listen 值，与 target_listen 比较
                line=$0
                sub(/^listen[[:space:]]*=[[:space:]]*"/, "", line)
                sub(/".*$/, "", line)
                if (line == target_listen) matched=1
            }
            if ($0 ~ /^remote[[:space:]]*=/) {
                # block 结束
                if (!matched) printf "%s", buf
                buf=""; in_block=0
            }
            next
        }
        { print }
        END { if (in_block && !matched) printf "%s", buf }
    ' "$REALM_CONF" >"$tmp" && mv "$tmp" "$REALM_CONF"
    ok "已删除规则: $match_listen"
    if realm_running; then
        if [ "$(rule_count)" -gt 0 ]; then
            cmd_restart
        else
            info "已无转发规则，停止 realm"
            cmd_stop
        fi
    fi
}

# ============================================================
# 保活：watchdog + 注册到 init / cron
# ============================================================
WATCHDOG_PID_FILE="$REALM_HOME/watchdog.pid"

watchdog_pid() {
    if [ -f "$WATCHDOG_PID_FILE" ]; then
        local p; p=$(cat "$WATCHDOG_PID_FILE" 2>/dev/null)
        if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
            echo "$p"; return 0
        fi
    fi
    # systemd 接管时，pid 文件由 systemd 持有
    if has systemctl && systemctl is-active --quiet realm-watchdog 2>/dev/null; then
        local mp; mp=$(systemctl show -p MainPID --value realm-watchdog 2>/dev/null)
        [ -n "$mp" ] && [ "$mp" != 0 ] && { echo "$mp"; return 0; }
    fi
    # pgrep 兜底（匹配命令行包含 "watchdog" 的 realmctl）
    if has pgrep; then
        pgrep -f 'realmctl.*watchdog' 2>/dev/null | grep -v "^$$\$" | head -n1
    fi
}

# 前台循环：被 systemd/openrc/nohup 拉起
cmd_watchdog() {
    ensure_dirs
    echo $$ >"$WATCHDOG_PID_FILE"
    trap 'rm -f "$WATCHDOG_PID_FILE"; exit 0' INT TERM EXIT
    echo "[$(ts)] watchdog 启动 (interval=${REALM_WATCHDOG_INTERVAL}s)" >>"$REALM_WATCHDOG_LOG"
    while true; do
        if ! realm_running; then
            if [ "$(rule_count)" -eq 0 ]; then
                # 没规则就别瞎拉，realm 会立即 panic
                sleep "$REALM_WATCHDOG_INTERVAL"
                continue
            fi
            echo "[$(ts)] realm 不在运行，尝试拉起" >>"$REALM_WATCHDOG_LOG"
            nohup "$REALM_BIN" -c "$REALM_CONF" >>"$REALM_LOG" 2>&1 &
            local pid=$!
            echo "$pid" >"$REALM_PID"
            sleep 2
            if kill -0 "$pid" 2>/dev/null; then
                echo "[$(ts)] realm 已拉起 PID=$pid" >>"$REALM_WATCHDOG_LOG"
            else
                echo "[$(ts)] realm 拉起后立即退出，${REALM_WATCHDOG_INTERVAL}s 后重试" >>"$REALM_WATCHDOG_LOG"
                rm -f "$REALM_PID"
            fi
        fi
        sleep "$REALM_WATCHDOG_INTERVAL"
    done
}

# 启用自动保活：根据环境选 systemd/openrc/cron+nohup
cmd_enable() {
    need_root
    [ -x "$REALM_BIN" ] || die "请先运行 realmctl install"
    local init; init=$(detect_init)
    local self="$REALM_SELF_PATH"
    [ -x "$self" ] || self="$0"

    case "$init" in
        systemd)
            info "检测到 systemd，注册 service"
            # 把当前的 REALM_* 环境变量固化到 unit，避免被 systemd 默认值覆盖
            cat >/etc/systemd/system/realm-watchdog.service <<EOF
[Unit]
Description=realm watchdog (auto-keepalive)
After=network.target

[Service]
Type=simple
Environment=REALM_HOME=$REALM_HOME
Environment=REALM_BIN=$REALM_BIN
Environment=REALM_CONF=$REALM_CONF
Environment=REALM_PID=$REALM_PID
Environment=REALM_LOG_DIR=$REALM_LOG_DIR
Environment=REALM_LOG=$REALM_LOG
Environment=REALM_WATCHDOG_LOG=$REALM_WATCHDOG_LOG
Environment=REALM_WATCHDOG_INTERVAL=$REALM_WATCHDOG_INTERVAL
ExecStart=$self watchdog
Restart=always
RestartSec=3s
StandardOutput=append:$REALM_WATCHDOG_LOG
StandardError=append:$REALM_WATCHDOG_LOG

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable --now realm-watchdog.service
            ok "systemd 服务 realm-watchdog 已启动并设为开机自启"
            ;;
        openrc)
            info "检测到 openrc，注册 init.d 脚本"
            cat >/etc/init.d/realm-watchdog <<EOF
#!/sbin/openrc-run
name="realm-watchdog"
command="$self"
command_args="watchdog"
command_background=true
pidfile="$WATCHDOG_PID_FILE"
output_log="$REALM_WATCHDOG_LOG"
error_log="$REALM_WATCHDOG_LOG"
depend() { need net; }
EOF
            chmod +x /etc/init.d/realm-watchdog
            rc-update add realm-watchdog default
            rc-service realm-watchdog restart
            ok "openrc 服务 realm-watchdog 已启动并设为开机自启"
            ;;
        none)
            info "未检测到 init 系统，使用 nohup + cron 兜底方案"
            # 1. 先 nohup 拉起 watchdog
            if [ -z "$(watchdog_pid)" ]; then
                nohup "$self" watchdog >>"$REALM_WATCHDOG_LOG" 2>&1 &
                ok "watchdog 已后台启动 PID=$!"
            else
                info "watchdog 已在运行 PID=$(watchdog_pid)"
            fi
            # 2. cron 每分钟兜底：watchdog 挂了就重新拉
            local cron_state; cron_state=$(detect_cron)
            if [ "$cron_state" = missing ]; then
                warn "未检测到 cron，无法注册兜底任务。建议安装：alpine 'apk add dcron && rc-update add dcron && rc-service dcron start'，debian 'apt install cron'"
            else
                local cron_line="* * * * * pgrep -f 'realmctl watchdog' >/dev/null 2>&1 || $self watchdog >>$REALM_WATCHDOG_LOG 2>&1 &"
                # 幂等添加
                ( crontab -l 2>/dev/null | grep -v 'realmctl watchdog'; echo "$cron_line" ) | crontab -
                ok "cron 兜底已注册（每分钟检查 watchdog 自身）"
                if [ "$cron_state" = installed ]; then
                    warn "cron daemon 未运行，请手动启动：alpine 'rc-service dcron start'，debian 'service cron start'"
                fi
            fi
            # 3. 写一个 @reboot 兜底
            ( crontab -l 2>/dev/null | grep -v "@reboot $self watchdog"; echo "@reboot $self watchdog >>$REALM_WATCHDOG_LOG 2>&1 &" ) | crontab -
            info "已写入 @reboot 启动项"
            ;;
    esac
}

cmd_disable() {
    need_root
    local init; init=$(detect_init)
    case "$init" in
        systemd)
            systemctl disable --now realm-watchdog.service 2>/dev/null || true
            rm -f /etc/systemd/system/realm-watchdog.service
            systemctl daemon-reload
            ;;
        openrc)
            rc-service realm-watchdog stop 2>/dev/null || true
            rc-update del realm-watchdog default 2>/dev/null || true
            rm -f /etc/init.d/realm-watchdog
            ;;
    esac
    # 清理 cron + 杀掉 watchdog
    crontab -l 2>/dev/null | grep -v 'realmctl watchdog' | crontab - 2>/dev/null || true
    local wpid; wpid=$(watchdog_pid)
    [ -n "$wpid" ] && kill "$wpid" 2>/dev/null || true
    rm -f "$WATCHDOG_PID_FILE"
    ok "自动保活已停用"
}

# ============================================================
# 交互菜单（保留 EZRealm 风格）
# ============================================================
menu_header() {
    clear
    local rs rscol n
    if [ -x "$REALM_BIN" ]; then rs="已安装"; rscol="$C_GRN"; else rs="未安装"; rscol="$C_RED"; fi
    n=$(rule_count)
    local run_state run_col
    if realm_running; then run_state="运行中 (PID $(realm_pid))"; run_col="$C_GRN"
    else run_state="未运行"; run_col="$C_RED"; fi
    local wd_state wd_col
    if [ -n "$(watchdog_pid)" ]; then wd_state="守护中"; wd_col="$C_GRN"
    else wd_state="未启用"; wd_col="$C_YLW"; fi
    cat <<EOF

     realmctl —— realm 端口转发管理 + 自动保活
 ─────────────────────────────────────────
  realm:    ${rscol}${rs}${C_RST}    转发规则: ${n} 条
  进程:     ${run_col}${run_state}${C_RST}
  watchdog: ${wd_col}${wd_state}${C_RST}
 ─────────────────────────────────────────

  [1]  安装 realm
  [2]  添加转发规则
  [3]  查看转发规则
  [4]  删除转发规则
 ─────────────────────────────────────────
  [5]  启动 realm
  [6]  停止 realm
  [7]  重启 realm
  [8]  状态详情
 ─────────────────────────────────────────
  [9]  启用自动保活 (watchdog)
  [10] 停用自动保活
  [11] 查看 watchdog 日志
  [12] 查看 realm 日志
 ─────────────────────────────────────────
  [99] 卸载
  [0]  退出
 ─────────────────────────────────────────
EOF
}

menu_pause() { read -r -p "按回车返回菜单..." _; }

cmd_menu() {
    while true; do
        menu_header
        read -r -p "请选择: " c
        case "$c" in
            1) cmd_install; menu_pause ;;
            2)
                read -r -p "本地端口: " lp
                [ -z "$lp" ] && continue
                read -r -p "远端 IP : " rip
                [ -z "$rip" ] && continue
                read -r -p "远端端口: " rp
                [ -z "$rp" ] && continue
                read -r -p "备注(可空): " rm
                cmd_add "$lp" "$rip" "$rp" "$rm" || true
                menu_pause ;;
            3) cmd_list; menu_pause ;;
            4)
                cmd_list
                echo
                read -r -p "请输入要删除的 序号 或 本地端口: " t
                [ -z "$t" ] && continue
                cmd_del "$t" || true
                menu_pause ;;
            5) cmd_start; menu_pause ;;
            6) cmd_stop; menu_pause ;;
            7) cmd_restart; menu_pause ;;
            8) cmd_status; menu_pause ;;
            9) cmd_enable; menu_pause ;;
            10) cmd_disable; menu_pause ;;
            11)
                if [ -f "$REALM_WATCHDOG_LOG" ]; then
                    tail -n 50 "$REALM_WATCHDOG_LOG"
                else
                    info "暂无 watchdog 日志"
                fi
                menu_pause ;;
            12)
                if [ -f "$REALM_LOG" ]; then
                    tail -n 50 "$REALM_LOG"
                else
                    info "暂无 realm 日志"
                fi
                menu_pause ;;
            99)
                read -r -p "确认卸载 realm 与 realmctl? (y/N): " yn
                [ "$yn" = y ] || [ "$yn" = Y ] && cmd_uninstall
                menu_pause ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

# ============================================================
# 帮助
# ============================================================
cmd_help() {
    cat <<'EOF'
realmctl —— realm 端口转发管理 + 自动保活

用法:
  realmctl                                  进入交互菜单
  realmctl install                          下载并安装 realm
  realmctl add  <本地端口> <远端IP> <端口> [备注]  添加规则（自动重启 realm）
  realmctl del  <序号|本地端口>             删除规则
  realmctl list                             列出规则
  realmctl start | stop | restart | status  进程管理
  realmctl enable                           启用自动保活（watchdog）
  realmctl disable                          停用自动保活
  realmctl watchdog                         前台运行 watchdog（被 init/cron 调用，一般不用直接跑）
  realmctl uninstall                        卸载
  realmctl help                             本帮助

环境变量:
  REALM_HOME=/root/realm          安装目录
  REALM_VERSION=v2.9.3            realm 版本
  REALM_MIRROR=https://ghfast.top/  github 加速前缀（置空=直连）
  REALM_WATCHDOG_INTERVAL=5       watchdog 检测间隔（秒）

示例:
  realmctl install
  realmctl add 8080 1.2.3.4 80 香港中转
  realmctl add 9000 '[2001:db8::1]' 443 IPv6
  realmctl enable
  realmctl list
EOF
}

# ============================================================
# 命令分派
# ============================================================
main() {
    case "${1:-}" in
        ''|menu)     cmd_menu ;;
        install)     cmd_install ;;
        uninstall)   cmd_uninstall ;;
        add)         shift; cmd_add "$@" ;;
        del|rm)      shift; cmd_del "$@" ;;
        list|ls)     cmd_list ;;
        start)       cmd_start ;;
        stop)        cmd_stop ;;
        restart)     cmd_restart ;;
        status)      cmd_status ;;
        enable)      cmd_enable ;;
        disable)     cmd_disable ;;
        watchdog)    cmd_watchdog ;;
        help|-h|--help) cmd_help ;;
        *) err "未知命令: $1"; cmd_help; exit 2 ;;
    esac
}

main "$@"
