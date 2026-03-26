#!/bin/bash

# =====================================
# 企业级服务器 SSH 安全初始化与加固脚本 
# =====================================

set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 错误处理
error_exit() {
    echo -e "\n${RED}[致命错误] $1${NC}"
    echo -e "${YELLOW}建议: $2${NC}"
    exit 1
}

# --- 1. 核心工具库 ---

# 增强型输入确认
input_confirm() {
    local prompt="$1" var_name="$2" res
    while true; do
        read -p "$prompt" res < /dev/tty || error_exit "输入中断" "操作已被用户终止"
        case "$res" in
            [Yy]* ) printf -v "$var_name" "%s" "y"; break;;
            [Nn]* ) printf -v "$var_name" "%s" "n"; break;;
            * ) echo -e "${RED}请输入 y 或 n${NC}";;
        esac
    done
}

# 精准端口监听检测 (适配 IPv4/IPv6 边界)
is_port_occupied() {
    local port=$1
    if command -v ss &>/dev/null; then
        ss -tuln | awk '{print $5}' | grep -qE "[:.]$port$" && return 0 || return 1
    fi
    return 1
}

# 跨平台获取家目录 (适配多发行版)
get_home_dir() {
    local user=$1
    if command -v getent &>/dev/null; then
        getent passwd "$user" | cut -d: -f6
    else
        grep "^${user}:" /etc/passwd | head -n1 | cut -d: -f6
    fi
}

# --- 2. 环境初始化 ---
[[ "$EUID" -ne 0 ]] && error_exit "权限不足" "请以 root 身份运行。"
echo -e "\n--- 0. 环境预检 | Environment Check ---"

# 2.1 修复 CentOS 8 停止维护导致的源失效问题
if [ -f /etc/redhat-release ] && grep -q "release 8" /etc/redhat-release; then
    echo -e "${YELLOW}[检测到 CentOS 8] 正在尝试修复失效的官方软件源...${NC}"
    sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
    sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.azure.cn|g' /etc/yum.repos.d/CentOS-*
    yum makecache || true
fi

# 2.2 自动补全必要组件
for pkg in ss:iproute2 sudo:sudo curl:curl ssh-keygen:openssh-client; do
    cmd=${pkg%%:*}; real_pkg=${pkg##*:}
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${YELLOW}[缺失] $cmd ($real_pkg)${NC}"
        if command -v apk &>/dev/null; then apk add --no-cache "$real_pkg"
        elif command -v apt-get &>/dev/null; then apt-get update && apt-get install -y "$real_pkg"
        elif command -v yum &>/dev/null; then yum install -y "$real_pkg"
        fi
    fi
done

# 2.3 OpenSSH 版本预检 (Include 语法需要 >= 7.3)
SSH_VER=$(ssh -V 2>&1 | grep -oP 'OpenSSH_\K[0-9.]+')
if [[ $(echo -e "$SSH_VER\n7.3" | sort -V | head -n1) != "7.3" ]]; then
    echo -e "${RED}[版本过低] 当前 OpenSSH 版本 ($SSH_VER) 不支持 Include 语法。${NC}"
    input_confirm "是否尝试自动升级 OpenSSH 以继续? [y/n]: " update_ssh
    if [[ "$update_ssh" == "y" ]]; then
        echo -e "${YELLOW}正在尝试升级 OpenSSH...${NC}"
        if command -v apt-get &>/dev/null; then apt-get update && apt-get install --only-upgrade -y openssh-server
        elif command -v yum &>/dev/null; then yum update -y openssh-server
        fi
        echo -e "${GREEN}升级完成，请重新运行此脚本以应用新版本。${NC}"
        exit 0
    else
        error_exit "环境不支持" "由于 OpenSSH 版本过低且未升级，脚本无法继续。"
    fi
fi

# --- 3. 用户与权限配置 ---
while true; do
    echo -e "\n${YELLOW}请输入创建的用户名 (仅限小写字母/数字/下划线):${NC}"
    read -r username < /dev/tty || error_exit "输入中断" "操作终止"
    [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] && { echo -e "${RED}用户名格式非法！${NC}"; continue; }
    
    if ! id "$username" &>/dev/null; then
        if command -v useradd &>/dev/null; then
            useradd -m -s /bin/bash "$username"
        else
            adduser -D -s /bin/bash "$username" # 适配 Alpine
        fi
    fi
    break
done

while true; do
    echo -e "\n${YELLOW}>>> 请为用户 $username 设置密码:${NC}"
    passwd "$username" < /dev/tty && break || echo -e "${RED}设置失败，请重试。${NC}"
done

# Sudoers 幂等写入
S_USER=$(echo "$username" | tr -cd 'a-zA-Z0-9_')
SUDO_CONF="/etc/sudoers.d/$S_USER"
echo "$username ALL=(ALL:ALL) ALL" > "$SUDO_CONF.tmp"
visudo -c -f "$SUDO_CONF.tmp" &>/dev/null \
    && mv "$SUDO_CONF.tmp" "$SUDO_CONF" && chmod 440 "$SUDO_CONF" \
    || { rm -f "$SUDO_CONF.tmp"; error_exit "Sudoers 校验失败" "生成的权限配置语法错误。"; }

# --- 4. SSH 公钥安全配置 ---
echo -e "\n--- 1. SSH 公钥配置 | SSH Key Setup ---"
user_home=$(get_home_dir "$username")
ssh_dir="$user_home/.ssh"
mkdir -p "$ssh_dir" && chmod 700 "$ssh_dir"

while true; do
    echo -e "${YELLOW}请粘贴 SSH 公钥 (ssh-ed25519 或 ssh-rsa):${NC}"
    read -r raw_key < /dev/tty || error_exit "输入中断" "操作终止"
    public_key=$(echo "$raw_key" | xargs)
    
    # 指纹合法性校验
    echo "$public_key" > "$ssh_dir/test_key.tmp"
    if ssh-keygen -l -f "$ssh_dir/test_key.tmp" &>/dev/null; then
        rm -f "$ssh_dir/test_key.tmp"; break
    else
        rm -f "$ssh_dir/test_key.tmp"
        echo -e "${RED}无效公钥格式！请确认复制了完整内容。${NC}"
    fi
done

auth_file="$ssh_dir/authorized_keys"
touch "$auth_file" && chmod 600 "$auth_file"
grep -qxF "$public_key" "$auth_file" || echo "$public_key" >> "$auth_file"
chown -R "$username:$username" "$ssh_dir"

[ -d "$ssh_dir" ] && command -v restorecon &>/dev/null && restorecon -R "$ssh_dir" 2>/dev/null || true

# --- 5. SSH 安全加固 (Include 隔离设计) ---
echo -e "\n--- 2. SSH 安全设置 | SSH Configuration ---"
ssh_port=22; pwd_auth="yes"; permit_root="yes"; allow_rule=""

input_confirm "是否修改 SSH 默认端口? [y/n]: " c_port
if [[ "$c_port" == "y" ]]; then
    while true; do
        read -p "请输入新端口 (1024-65535): " res < /dev/tty || true
        if [[ "$res" =~ ^[0-9]+$ ]] && [ "$res" -ge 1024 ] && [ "$res" -le 65535 ]; then
            is_port_occupied "$res" && echo -e "${RED}端口已占用！${NC}" || { ssh_port=$res; break; }
        fi
    done
fi

input_confirm "是否禁用密码登录? (请务必确保公钥已配好) [y/n]: " c_pwd
[[ "$c_pwd" == "y" ]] && pwd_auth="no"

input_confirm "是否禁止 Root 用户直接登录? [y/n]: " c_root
[[ "$c_root" == "y" ]] && permit_root="no"

echo -e "\n${RED}[安全警示] AllowUsers 会建立登录白名单。${NC}"
echo -e "${YELLOW}启用后，除了 $username 及其追加用户，所有其他现有账号将无法通过 SSH 登录。${NC}"
input_confirm "是否仅允许 $username 登录? [y/n]: " c_allow
[[ "$c_allow" == "y" ]] && allow_rule="AllowUsers $username"

# 写入隔离配置
CONF_D="/etc/ssh/sshd_config.d/ssh_harden.conf"
mkdir -p /etc/ssh/sshd_config.d/
[ -f "$CONF_D" ] && cp "$CONF_D" "$CONF_D.bak"

cat <<EOF > "$CONF_D"
Port $ssh_port
PasswordAuthentication $pwd_auth
PermitRootLogin $permit_root
$allow_rule
EOF

# 激活 Include
if ! grep -Eq "^\s*Include\s+/etc/ssh/sshd_config.d/\*\.conf" /etc/ssh/sshd_config; then
    sed -i "1i Include /etc/ssh/sshd_config.d/*.conf" /etc/ssh/sshd_config
fi

# 预检
if ! sshd -t; then
    [ -f "$CONF_D.bak" ] && mv "$CONF_D.bak" "$CONF_D" || rm -f "$CONF_D"
    error_exit "SSH 配置预检失败" "语法冲突，已自动回滚。"
fi

# --- 6. 服务重启与连通性验证 ---
echo -e "\n${RED}⚠️  注意：请务必在云服务器安全组放行 $ssh_port 端口！！${NC}"
input_confirm "是否立即重启服务? [y/n]: " res_sshd

if [[ "$res_sshd" == "y" ]]; then
    if command -v systemctl &>/dev/null; then
        systemctl disable --now ssh.socket 2>/dev/null || true
        systemctl restart ssh || systemctl restart sshd
    else
        rc-service sshd restart 2>/dev/null || /etc/init.d/ssh restart
    fi

    sleep 2
    if is_port_occupied "$ssh_port"; then
        IP=$(curl -4 -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 ifconfig.me || echo "服务器公网IP")
        echo -e "\n${GREEN}[✔] SSH 初始化加固成功！${NC}"
        echo -e "用户: ${YELLOW}$username${NC} | 端口: ${YELLOW}$ssh_port${NC}"
        echo -e "请在${RED}新终端${NC}测试: ${GREEN}ssh -p $ssh_port $username@$IP${NC}"
    else
        [ -f "$CONF_D.bak" ] && mv "$CONF_D.bak" "$CONF_D"
        error_exit "重启失败" "端口未监听，配置已自动回滚。"
    fi
fi
