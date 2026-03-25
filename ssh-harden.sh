#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 错误处理函数
error_exit() {
    echo -e "\n${RED}[错误] $1${NC}"
    echo -e "${YELLOW}建议: $2${NC}"
    exit 1
}

# --- 自动安装工具函数 (支持 Alpine/Debian/CentOS) ---
install_pkg() {
    local pkg=$1
    if command -v apk &>/dev/null; then
        apk add --no-cache "$pkg"
    elif command -v apt-get &>/dev/null; then
        apt-get update && apt-get install -y "$pkg"
    elif command -v yum &>/dev/null; then
        yum install -y "$pkg"
    fi
}

# --- 验证函数库 ---
input_confirm() {
    local prompt="$1"
    local var_name="$2"
    while true; do
        read -p "$prompt" res < /dev/tty
        case "$res" in
            [Yy]* ) eval "$var_name='y'"; break;;
            [Nn]* ) eval "$var_name='n'"; break;;
            * ) echo -e "${RED}输入错误！请输入 y 或 n${NC}";;
        esac
    done
}

input_port() {
    local var_name="$1"
    while true; do
        read -p "请输入新端口号 (1024-65535): " res < /dev/tty
        if [[ ! "$res" =~ ^[0-9]+$ ]] || [ "$res" -lt 1 ] || [ "$res" -gt 65535 ]; then
            echo -e "${RED}错误：请输入有效数字！${NC}"; continue
        fi
        # 兼容 Alpine 的 ss 工具位置
        if ss -tln | grep -q ":$res "; then
            echo -e "${RED}错误：端口 $res 已被占用！${NC}"
        else
            echo -e "${GREEN}端口 $res 可用。${NC}"
            eval "$var_name='$res'"; break
        fi
    done
}

# 检查 root 权限
[[ "$EUID" -ne 0 ]] && error_exit "权限不足" "请以 root 用户身份运行。"

# --- 0. 环境预检 ---
echo -e "\n--- 0. 环境预检 | Environment Check ---"

# 安装必要组件 (ss 工具、sudo、curl)
command -v ss &>/dev/null || install_pkg iproute2
command -v sudo &>/dev/null || install_pkg sudo
command -v curl &>/dev/null || install_pkg curl

# --- 1. 用户创建 ---
echo -e "\n--- 1. 用户创建 | User Creation ---"
while true; do
    read -p "请输入你要创建的用户名: " username < /dev/tty
    if [[ -z "$username" ]]; then
        echo -e "${RED}用户名不能为空！${NC}"
    elif id "$username" &>/dev/null; then
        echo -e "${YELLOW}用户 $username 已存在。${NC}"; break
    else
        # 兼容 Alpine 的用户创建命令
        if command -v useradd &>/dev/null; then
            useradd -m -s /bin/bash "$username"
        else
            adduser -D -s /bin/bash "$username"
        fi
        [[ $? -eq 0 ]] && break || error_exit "创建失败" "检查权限或系统状态。"
    fi
done

echo -e "\n${YELLOW}>>> 请设置用户 $username 的密码:${NC}"
passwd "$username" < /dev/tty

# --- 2. 权限注入 ---
mkdir -p /etc/sudoers.d/
echo "$username ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/$username"
chmod 440 "/etc/sudoers.d/$username"

# --- 3. SSH 密钥配置 ---
echo -e "\n--- 3. SSH 公钥配置 | SSH Key Setup ---"
user_home=$(eval echo "~$username")
mkdir -p "$user_home/.ssh" && chmod 700 "$user_home/.ssh"
while true; do
    echo -e "${YELLOW}请粘贴您的 SSH 公钥:${NC}"
    read -r public_key < /dev/tty
    [[ -n "$public_key" ]] && break || echo -e "${RED}不能为空！${NC}"
done
echo "$public_key" > "$user_home/.ssh/authorized_keys"
chmod 600 "$user_home/.ssh/authorized_keys"
chown -R "$username:$username" "$user_home/.ssh"

# --- 4. SSH 设置 ---
echo -e "\n--- 4. SSH 安全设置 ---"
ssh_port=22; pwd_auth="yes"; permit_root="yes"; allow_users=""

input_confirm "修改端口? [y/n]: " c_port
[[ "$c_port" == "y" ]] && input_port ssh_port
input_confirm "禁用密码登录? [y/n]: " c_pwd
[[ "$c_pwd" == "y" ]] && pwd_auth="no"
input_confirm "禁止 Root 登录? [y/n]: " c_root
[[ "$c_root" == "y" ]] && permit_root="no"
input_confirm "仅允许 $username 登录? [y/n]: " c_user
[[ "$c_user" == "y" ]] && allow_users="AllowUsers $username"

# 清理主配置端口并确保 Include 开启
sed -i 's/^Port /#Port /g' /etc/ssh/sshd_config
if ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config; then
    sed -i "1i Include /etc/ssh/sshd_config.d/*.conf" /etc/ssh/sshd_config
fi

mkdir -p /etc/ssh/sshd_config.d/
cat <<EOF > /etc/ssh/sshd_config.d/ssh.conf
Port $ssh_port
PasswordAuthentication $pwd_auth
PermitRootLogin $permit_root
$allow_users
EOF

# --- 5. 重启 (兼容 Alpine OpenRC 和 Systemd) ---
echo -e "\n${RED}!!! 警示：请开启新窗口测试后再退出当前窗口 !!!${NC}"
input_confirm "是否立即重启 SSH 服务? [y/n]: " res_sshd
if [ "$res_sshd" == "y" ]; then
    # 处理 Debian 12/Ubuntu 的 Socket 问题
    systemctl stop ssh.socket 2>/dev/null
    systemctl disable ssh.socket 2>/dev/null
    systemctl mask ssh.socket 2>/dev/null

    # 兼容多发行版重启命令
    if command -v rc-service &>/dev/null; then
        rc-service sshd restart
    else
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    fi

    SERVER_IP=$(curl -s6 ifconfig.me || curl -s4 ifconfig.me || echo "IP")
    echo -e "${GREEN}SSHD 已重启。监听端口: $ssh_port${NC}"
    echo -e "测试命令: ${YELLOW}ssh -p $ssh_port $username@$SERVER_IP${NC}"
fi
