#!/usr/bin/env bash
# pg-dev-server —— Ubuntu 主机安全加固：sshd 只密钥 + ufw 只放 22 + fail2ban + 自动安全更新。
# 与装机脚本共用同一份 env（SSH_ALLOW_FROM 决定 22 的来源白名单）。幂等：重跑按 env 重建规则。
# 云安全组不在本脚本范围（在云控制台配，要求见 /opt/pg-ops/handover.md 第 4 节）。
# 两种用法：
#   1) 渲染版（推荐）：scripts/render.sh pg-dev-server.env build/harden.sh harden → 上服务器 sudo bash harden.sh
#   2) 直接版：sudo bash harden-ubuntu.sh /path/to/pg-dev-server.env
set -euo pipefail

die()  { echo "problem: $*" >&2; exit 1; }
info() { echo "[*] $*"; }
ok()   { echo "[✓] $*"; }
apt-get() { DEBIAN_FRONTEND=noninteractive command apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Use-Pty=0 "$@"; }

if [[ -z "${PG_OPS_RENDERED:-}" ]]; then
    ENV_FILE="${1:?用法: sudo bash harden-ubuntu.sh <pg-dev-server.env>（或先用 render.sh 渲染）}"
    [[ -r "${ENV_FILE}" ]] || die "读不到 ${ENV_FILE}"
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
fi

# ---- 守卫 --------------------------------------------------------------------------
[[ "${PG_OPS_ROLE:-}" == "dev" ]] || die "PG_OPS_ROLE 不是 dev（当前: ${PG_OPS_ROLE:-<空>}）。本脚本只允许在开发机执行"
[[ -r /etc/os-release ]] && . /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "只支持 Ubuntu（检测到 ID=${ID:-unknown}）"
[[ "$(id -u)" -eq 0 ]] || die "需要 root（sudo）"
: "${SSH_ALLOW_FROM:=}"
PG_OPS_DIR=/opt/pg-ops
[[ -d "${PG_OPS_DIR}/bin" ]] || die "${PG_OPS_DIR} 不存在：请先跑装机脚本（pg-dev-server-install.sh）"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"; SELF_DEST="${PG_OPS_DIR}/bin/pg-dev-server-harden.sh"
[[ "${SELF}" == "${SELF_DEST}" ]] || install -m 700 "${SELF}" "${SELF_DEST}"

# 锁外防线：关密码登录之前，执行者（sudo 的那个用户，或 root）必须已有可用公钥，否则拒绝
LOGIN_USER="${SUDO_USER:-}"
[[ -n "${LOGIN_USER}" && "${LOGIN_USER}" != "root" ]] || die "请以带 sudo 的普通用户执行（sudo bash ...），root 登录将被禁用，直接以 root 跑会把自己锁在外面"
LOGIN_HOME="$(getent passwd "${LOGIN_USER}" | cut -d: -f6)"
AUTH_KEYS="${LOGIN_HOME}/.ssh/authorized_keys"
[[ -s "${AUTH_KEYS}" ]] && grep -qE '^(ssh-|ecdsa-|sk-)' "${AUTH_KEYS}" \
    || die "${LOGIN_USER} 没有 authorized_keys（${AUTH_KEYS}）。关掉密码登录会把你锁在外面，先放公钥再来"
ok "锁外防线：${LOGIN_USER} 已有公钥（$(grep -cE '^(ssh-|ecdsa-|sk-)' "${AUTH_KEYS}") 条）"

# ---- 1. sshd：只密钥、root 禁止登录（日常用带 sudo 的普通用户）、限制尝试 ----------------------------------------------
# 文件名用 10- 前缀：sshd 取首个出现的值，Include 在主配置最前，10- 早于云镜像常见的 50-cloud-init.conf
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-pg-ops.conf
mkdir -p /etc/ssh/sshd_config.d
cat > "${SSHD_DROPIN}" <<CONF
# managed by pg-ops/pg-dev-server harden —— 手改会被下次加固重写
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding yes
ClientAliveInterval 60
ClientAliveCountMax 3
CONF
sshd -t || { rm -f "${SSHD_DROPIN}"; die "sshd 配置校验失败，已回滚 ${SSHD_DROPIN}"; }
systemctl reload ssh 2>/dev/null || systemctl reload sshd
EFFECTIVE="$(sshd -T 2>/dev/null | grep -E '^(passwordauthentication|permitrootlogin) ' | tr '\n' ' ')"
[[ "${EFFECTIVE}" == *"passwordauthentication no"* && "${EFFECTIVE}" == *"permitrootlogin no"* ]] \
    || die "sshd 生效值不符（${EFFECTIVE}），检查 /etc/ssh/sshd_config.d/ 里是否有更早的文件覆盖"
ok "sshd：${EFFECTIVE}（${SSHD_DROPIN}）"

# ---- 2. ufw：默认拒入、只放 22（来源按 SSH_ALLOW_FROM）---------------------------------
# 用 reset 重建而不是逐条增删：规则集只有本脚本一个来源，reset 后再加才能保证去掉白名单里删掉的 IP
command -v ufw >/dev/null || apt-get install -y -qq ufw
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
if [[ -n "${SSH_ALLOW_FROM}" ]]; then
    for cidr in ${SSH_ALLOW_FROM}; do
        ufw allow from "${cidr}" to any port 22 proto tcp comment 'pg-ops ssh' >/dev/null
    done
    SSH_SCOPE="仅 ${SSH_ALLOW_FROM}"
else
    ufw allow 22/tcp comment 'pg-ops ssh' >/dev/null
    SSH_SCOPE="任意来源（靠密钥 + fail2ban）"
fi
ufw --force enable >/dev/null
ufw status | grep -q "^Status: active" || die "ufw 未激活"
ok "ufw：默认拒入，22/tcp 放行 ${SSH_SCOPE}"

# ---- 3. fail2ban：sshd jail，systemd 后端（不依赖 /var/log/auth.log 是否存在）---------------
command -v fail2ban-client >/dev/null || apt-get install -y -qq fail2ban
cat > /etc/fail2ban/jail.local <<CONF
# managed by pg-ops/pg-dev-server harden —— 手改会被下次加固重写
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 ${SSH_ALLOW_FROM}
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
CONF
systemctl enable --now fail2ban >/dev/null 2>&1
systemctl restart fail2ban
sleep 1
fail2ban-client status sshd >/dev/null 2>&1 || die "fail2ban sshd jail 未起来（fail2ban-client status sshd）"
ok "fail2ban：sshd jail 已启用（5 次 / 10 分钟 → 封 1 小时）"

# ---- 4. 自动安全更新 --------------------------------------------------------------------
command -v unattended-upgrade >/dev/null || apt-get install -y -qq unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<CONF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
ok "unattended-upgrades：已启用（只装安全更新，Ubuntu 默认策略）"

# ---- 5. 回写交接文档：层状态两行 + 「主机加固状态」块写成实际生效值 --------------------------
HANDOVER="${PG_OPS_DIR}/handover.md"
if [[ -f "${HANDOVER}" ]]; then
    NOW="$(date '+%F %T')"
    STAMP="已完成（harden ${NOW}，状态见下）"
    sed -i -E "s#^(\| ② 主机防火墙 ufw \| 服务器 \| ).*( \|)\$#\1${STAMP}\2#; s#^(\| ④ sshd 加固 \| 服务器 \| ).*( \|)\$#\1${STAMP}\2#" "${HANDOVER}"
    SSHD_ROWS="$(sshd -T 2>/dev/null | grep -E '^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin|maxauthtries|logingracetime) ' | awk '{printf "%s=%s · ", $1, $2}' | sed 's/ · $//')"
    UFW_ROWS="$(ufw status 2>/dev/null | grep ALLOW | sed -E 's/ *#.*//; s/ {2,}/ /g' | paste -sd ';' - | sed 's/;/；/g')"
    UFW_DEF="$(ufw status verbose 2>/dev/null | sed -n 's/^Default: //p')"
    F2B_ROWS="$(fail2ban-client status sshd 2>/dev/null | grep -E 'Currently (failed|banned)|Total banned' | awk -F: '{gsub(/^[ |`-]+/,"",$1); gsub(/^[ \t]+/,"",$2); printf "%s=%s · ", $1, $2}' | sed 's/ · $//')"
    LISTEN="$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E ":(5432|${PGB_PORT:-6432}|${PGB_SESSION_PORT:-7432}|${REDIS_PORT:-6379})$" | sort -u | tr '\n' ' ')"
    UU="$(systemctl is-enabled unattended-upgrades 2>/dev/null || echo unknown)"
    BLOCK="$(cat <<BLK
<!-- harden:start -->
### ②③④ 主机侧加固状态（pg-dev-server-harden.sh 于 ${NOW} 执行，以下为当时实际生效值）

| 项 | 状态 |
|---|---|
| sshd | ${SSHD_ROWS}（配置 ${SSHD_DROPIN}） |
| ufw | ${UFW_DEF}；放行：${UFW_ROWS:-无} |
| SSH 来源 | ${SSH_SCOPE} |
| fail2ban | sshd jail 启用，5 次 / 10 分钟 → 封 1 小时；${F2B_ROWS} |
| 自动安全更新 | unattended-upgrades ${UU} |
| 服务监听 | ${LISTEN:-<未检测到>} |

重跑 / 改白名单：开发机项目仓改 \`.pg-ops/pg-dev-server.env\` 的 \`SSH_ALLOW_FROM\` → 渲染 harden → 上传执行；或原地 \`sudo bash ${PG_OPS_DIR}/bin/pg-dev-server-harden.sh\`。
回滚 sshd：\`sudo rm ${SSHD_DROPIN} && sudo systemctl reload ssh\`。
<!-- harden:end -->
BLK
)"
    if grep -q '<!-- harden:start -->' "${HANDOVER}"; then
        BLOCK="${BLOCK}" perl -0pi -e 's/<!-- harden:start -->.*?<!-- harden:end -->/$ENV{BLOCK}/s' "${HANDOVER}"
    else
        printf '\n%s\n' "${BLOCK}" >> "${HANDOVER}"
    fi
    # 第 0 节「主机加固」待办行同步改为已执行
    sed -i -E "s#^- \[[ x]\] (\*\*主机加固\*\*：).*#- [x] \1已执行（harden ${NOW}，状态见第 4 节）。改 SSH 白名单或想复核时重跑 \`sudo bash ${PG_OPS_DIR}/bin/pg-dev-server-harden.sh\`。#" "${HANDOVER}"
    ok "交接文档已回写主机加固状态（${HANDOVER}）"
fi

cat <<SUMMARY

=== 加固完成。现在做两件事 ===
1. **不要关当前会话**，另开一个终端 ssh 进来确认能登录；不能就在当前会话 sudo rm ${SSHD_DROPIN} && sudo systemctl reload ssh。
2. 云安全组还没配（脚本不碰）：按 sudo cat ${PG_OPS_DIR}/handover.md 第 4 节 ① 配置，入方向只留 22。
状态：sudo ufw status verbose · sudo fail2ban-client status sshd · sudo sshd -T | grep -E 'passwordauthentication|permitrootlogin'
SUMMARY
