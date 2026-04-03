#!/bin/bash

# =========================================================
# 企业级服务器 SSH 安全初始化与加固脚本
# Enterprise SSH Security Initialization & Hardening Script
# =========================================================

set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error_exit() {
    echo -e "\n${RED}[致命错误 | Fatal Error] $1${NC}"
    echo -e "${YELLOW}建议 | Suggestion: $2${NC}"
    exit 1
}

# --- 1. 核心工具库 | Core Utilities ---

input_confirm() {
    local prompt="$1" var_name="$2" res
    while true; do
        read -p "$prompt" res < /dev/tty || error_exit "输入中断 (Input interrupted)" "操作已被用户终止 (Operation terminated by user)"
        case "$res" in
            [Yy]* ) printf -v "$var_name" "%s" "y"; break;;
            [Nn]* ) printf -v "$var_name" "%s" "n"; break;;
            * ) echo -e "${RED}请输入 y 或 n (Please enter y or n)${NC}";;
        esac
    done
}

is_port_occupied() {
    local port=$1
    if command -v ss &>/dev/null; then
        ss -tuln | awk '{print $5}' | grep -qE "[:.]$port$" && return 0 || return 1
    fi
    return 1
}

get_home_dir() {
    local user=$1
    if command -v getent &>/dev/null; then
        getent passwd "$user" | cut -d: -f6
    else
        grep "^${user}:" /etc/passwd | head -n1 | cut -d: -f6
    fi
}

# --- 2. 环境初始化 | Environment Initialization ---
[[ "$EUID" -ne 0 ]] && error_exit "权限不足 (Inadequate privileges)" "请以 root 身份运行 (Please run as root)."
echo -e "\n--- 0. 环境预检 | Environment Check ---"

# 2.1 针对 CentOS 8 处理源问题 | Handle Repo issues for CentOS 8
if [ -f /etc/redhat-release ] && grep -q "release 8" /etc/redhat-release; then
    if ! grep -rq "mirrors.aliyun.com" /etc/yum.repos.d/ 2>/dev/null; then
        echo -e "${RED}[温馨提示 | Notice] CentOS 8 官方源已彻底停服 (Official repos EOL).${NC}"
        input_confirm "如果不切换至阿里云 Vault 源将无法安装组件，是否切换? (Switch to Aliyun Vault repo? [y/n]): " change_repo
        if [[ "$change_repo" == "y" ]]; then
            mkdir -p /etc/yum.repos.d/bak
            cp /etc/yum.repos.d/*.repo /etc/yum.repos.d/bak/ 2>/dev/null || true
            rm -f /etc/yum.repos.d/*.repo
            curl -s -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.aliyun.com/repo/Centos-vault-8.5.2111.repo
            yum clean all && yum makecache
        else
            error_exit "用户拒绝 (User denied)" "由于官方源失效且不选择换源，脚本无法继续 (Cannot proceed without valid repos)."
        fi
    fi
fi

# 2.2 补全组件 (全交互模式) | Install Components (Interactive)
for pkg in ss:iproute2 sudo:sudo curl:curl ssh-keygen:openssh-client; do
    cmd=${pkg%%:*}; real_pkg=${pkg##*:}
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${YELLOW}[缺失组件 | Missing] 系统未检测到 $cmd (${real_pkg})${NC}"
        input_confirm "是否现在安装该组件? (Install now? [y/n]): " do_install
        if [[ "$do_install" == "y" ]]; then
            if command -v apk &>/dev/null; then apk add --no-cache "$real_pkg"
            elif command -v apt-get &>/dev/null; then apt-get update && apt-get install -y "$real_pkg"
            elif command -v yum &>/dev/null; then yum install -y "$real_pkg"
            fi
        else
            error_exit "组件缺失 (Missing dependency)" "由于拒绝安装必要组件 $real_pkg，脚本无法继续运行 (Cannot proceed without $real_pkg)."
        fi
    fi
done

# --- 3. 用户与权限配置 | User & Privileges ---
while true; do
    echo -e "\n${YELLOW}请输入创建的用户名 (Enter username to create):${NC}"
    read -r username < /dev/tty || error_exit "输入中断 (Input interrupted)" "操作终止 (Terminated)"
    [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] && { echo -e "${RED}格式非法 (Invalid format)!${NC}"; continue; }
    
    if ! id "$username" &>/dev/null; then
        if command -v useradd &>/dev/null; then
            useradd -m -s /bin/bash "$username"
        else
            adduser -D -s /bin/bash "$username" 
        fi
    fi
    break
done

while true; do
    echo -e "\n${YELLOW}>>> 请为用户 $username 设置密码 (Set password for $username):${NC}"
    passwd "$username" < /dev/tty && break || echo -e "${RED}重试... (Try again...)${NC}"
done

S_USER=$(echo "$username" | tr -cd 'a-zA-Z0-9_')
SUDO_CONF="/etc/sudoers.d/$S_USER"
echo "$username ALL=(ALL:ALL) ALL" > "$SUDO_CONF.tmp"
visudo -c -f "$SUDO_CONF.tmp" &>/dev/null \
    && mv "$SUDO_CONF.tmp" "$SUDO_CONF" && chmod 440 "$SUDO_CONF" \
    || { rm -f "$SUDO_CONF.tmp"; error_exit "Sudoers 校验失败 (Sudoers validation failed)" "语法错误 (Syntax error)."; }

# --- 4. SSH 公钥配置 | SSH Key Setup ---
echo -e "\n--- 1. SSH 公钥配置 | SSH Key Setup ---"
user_home=$(get_home_dir "$username")
ssh_dir="$user_home/.ssh"
mkdir -p "$ssh_dir" && chmod 700 "$ssh_dir"

while true; do
    echo -e "${YELLOW}请粘贴 SSH 公钥 (Please paste your SSH Public Key):${NC}"
    read -r raw_key < /dev/tty || error_exit "输入中断 (Input interrupted)" "操作终止 (Terminated)"
    public_key=$(echo "$raw_key" | xargs)
    echo "$public_key" > "$ssh_dir/test_key.tmp"
    if ssh-keygen -l -f "$ssh_dir/test_key.tmp" &>/dev/null; then
        rm -f "$ssh_dir/test_key.tmp"; break
    else
        rm -f "$ssh_dir/test_key.tmp"
        echo -e "${RED}无效公钥格式 (Invalid SSH Key format)!${NC}"
    fi
done

auth_file="$ssh_dir/authorized_keys"
touch "$auth_file" && chmod 600 "$auth_file"
grep -qxF "$public_key" "$auth_file" || echo "$public_key" >> "$auth_file"
chown -R "$username:$username" "$ssh_dir"
[ -d "$ssh_dir" ] && command -v restorecon &>/dev/null && restorecon -R "$ssh_dir" 2>/dev/null || true

# --- 5. SSH 安全加固 | SSH Hardening ---
echo -e "\n--- 2. SSH 安全设置 | SSH Configuration ---"
ssh_port=22; pwd_auth="yes"; permit_root="yes"; allow_rule=""

input_confirm "是否修改 SSH 默认端口? (Change default SSH port? [y/n]): " c_port
if [[ "$c_port" == "y" ]]; then
    while true; do
        read -p "请输入新端口 (1024-65535) [Enter new port]: " res < /dev/tty || true
        if [[ "$res" =~ ^[0-9]+$ ]] && [ "$res" -ge 1024 ] && [ "$res" -le 65535 ]; then
            is_port_occupied "$res" && echo -e "${RED}端口已占用 (Port occupied)!${NC}" || { ssh_port=$res; break; }
        fi
    done
fi

input_confirm "是否禁用密码登录? (Disable password authentication? [y/n]): " c_pwd
[[ "$c_pwd" == "y" ]] && pwd_auth="no"

input_confirm "是否禁止 Root 用户直接登录? (Disable Direct Root Login? [y/n]): " c_root
[[ "$c_root" == "y" ]] && permit_root="no"

echo -e "\n${RED}[安全警示 | Security Warning] AllowUsers 会建立登录白名单 (Will create a login whitelist).${NC}"
echo -e "${YELLOW}启用后，除了 $username 及其追加用户，所有其他账号（包括 root）将无法通过 SSH 登录。${NC}"
echo -e "${YELLOW}(Once enabled, only $username can login via SSH; all others including root will be blocked.)${NC}"
input_confirm "是否仅允许 $username 登录? (Allow ONLY $username to login? [y/n]): " c_allow
[[ "$c_allow" == "y" ]] && allow_rule="AllowUsers $username"

CONF_D="/etc/ssh/sshd_config.d/ssh_harden.conf"
mkdir -p /etc/ssh/sshd_config.d/

cat <<EOF > "$CONF_D"
Port $ssh_port
PasswordAuthentication $pwd_auth
PermitRootLogin $permit_root
$allow_rule
EOF

sed -i '/^\s*Include\s*\/etc\/ssh\/sshd_config\.d\/\*\.conf/d' /etc/ssh/sshd_config
sed -i "1i Include /etc/ssh/sshd_config.d/*.conf" /etc/ssh/sshd_config

if ! sshd -t &>/dev/null; then
    echo -e "${YELLOW}[兼容模式 | Compatibility Mode] Include 语法不受支持，正在切换至直接配置模式...${NC}"
    echo -e "${YELLOW}(Include syntax not supported, switching to direct configuration mode...)${NC}"
    sed -i '/^\s*Include\s*\/etc\/ssh\/sshd_config\.d\/\*\.conf/d' /etc/ssh/sshd_config
    for key in "Port" "PasswordAuthentication" "PermitRootLogin" "AllowUsers"; do
        sed -i "/^\s*$key\s/d" /etc/ssh/sshd_config
    done
    {
        echo "Port $ssh_port"
        echo "PasswordAuthentication $pwd_auth"
        echo "PermitRootLogin $permit_root"
        [ -n "$allow_rule" ] && echo "$allow_rule"
    } >> /etc/ssh/sshd_config
fi

if ! sshd -t; then
    error_exit "SSH 配置预检失败 (SSH pre-check failed)" "语法冲突且无法自动修复 (Syntax conflict, unable to auto-repair)."
fi

# --- 6. 服务重启 | Service Restart ---
echo -e "\n${RED}⚠️  请务必确保在云安全组中放行 $ssh_port 端口！！${NC}"
echo -e "${RED}(Make sure to allow port $ssh_port in your cloud security group!!)${NC}"
input_confirm "是否立即应用并重启 SSH 服务? (Apply and restart SSH? [y/n]): " res_sshd

if [[ "$res_sshd" == "y" ]]; then
    if command -v systemctl &>/dev/null; then
        systemctl disable --now ssh.socket 2>/dev/null || true
        if systemctl list-unit-files | grep -q "^ssh.service"; then
            systemctl restart ssh
        elif systemctl list-unit-files | grep -q "^sshd.service"; then
            systemctl restart sshd
        fi
    else
        rc-service sshd restart 2>/dev/null || /etc/init.d/ssh restart
    fi

    sleep 2
    
    # 增加循环检测，最多等待 10 秒
    SUCCESS=0
    for i in {1..5}; do
        if is_port_occupied "$ssh_port"; then
            SUCCESS=1
            break
        fi
        echo -e "${YELLOW}等待服务监听端口 $ssh_port... (Attempt $i/5)${NC}"
        sleep 2
    done

    if [[ $SUCCESS -eq 1 ]]; then
        IP=$(curl -4 -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 ifconfig.me || echo "服务器公网IP")
        echo -e "\n${GREEN}[✔] 加固成功 (Hardening Successful)!${NC}"
        echo -e "用户 (User): ${YELLOW}$username${NC} | 端口 (Port): ${YELLOW}$ssh_port${NC}"
        echo -e "测试连接 (Test connection): ${GREEN}ssh -p $ssh_port $username@$IP${NC}"
    else
        # 最终失败才退出
        error_exit "重启失败 (Restart failed)" "端口 $ssh_port 未监听。请检查防火墙设置或运行 'systemctl status ssh'。 (Port not listening. Check firewall or run 'systemctl status ssh'.)"
    fi
fi
