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
            echo -e "${RED}错误：请输入 1 到 65535 之间的有效数字！${NC}"
            continue
        fi

        local current_ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -n1)
        if [ "$res" == "$current_ssh_port" ]; then
            echo -e "${GREEN}此端口正是当前 SSH 正在使用的端口，无需修改。${NC}"
            eval "$var_name='$res'"; break
        fi

        if ss -tln | grep -q ":$res "; then
            local p_info=$(ss -tlnp | grep ":$res " | awk '{print $6}' | cut -d'"' -f2 | head -n1)
            echo -e "${RED}错误：端口 $res 已被占用！${NC}"
            echo -e "${RED}占用程序: [${p_info:-未知}]${NC}"
            echo -e "${YELLOW}请尝试使用其他端口。${NC}"
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

if grep -q "buster" /etc/debian_version 2>/dev/null; then
    if ! apt update &>/dev/null; then
        echo -e "${YELLOW}[修复] 检测到 Debian 10 官方源已失效，正在切换至归档源...${NC}"
        sed -i 's/deb.debian.org/archive.debian.org/g' /etc/apt/sources.list
        sed -i 's/security.debian.org/archive.debian.org/g' /etc/apt/sources.list
        sed -i '/-updates/d' /etc/apt/sources.list
        echo "Acquire::Check-Valid-Until \"false\";" > /etc/apt/apt.conf.d/99no-check-valid-until
        apt update
    fi
fi

if ! command -v ss &>/dev/null; then
    apt-get update && apt-get install -y iproute2 || yum install -y iproute
fi

if ! command -v sudo &>/dev/null; then
    echo -e "${YELLOW}[注意] 系统未安装 'sudo'。${NC}"
    input_confirm "是否现在安装 sudo? [y/n]: " do_install
    if [ "$do_install" == "y" ]; then
        apt-get update && apt-get install -y sudo || yum install -y sudo
    else
        echo -e "${RED}用户拒绝安装 sudo，脚本终止。${NC}"; exit 1
    fi
fi

# --- 1. 用户创建 ---
echo -e "\n--- 1. 用户创建 | User Creation ---"
while true; do
    read -p "请输入你要创建的用户名: " username < /dev/tty
    if [[ -z "$username" ]]; then
        echo -e "${RED}用户名不能为空！${NC}"
    elif id "$username" &>/dev/null; then
        echo -e "${YELLOW}用户 $username 已存在，更新其配置。${NC}"; break
    else
        useradd -m -s /bin/bash "$username" || error_exit "创建失败" "检查磁盘。"
        break
    fi
done

echo -e "\n${YELLOW}>>> 请为用户 $username 设置密码:${NC}"
passwd "$username" < /dev/tty || error_exit "密码设置失败" "请重试。"

# --- 2. 权限注入 ---
mkdir -p /etc/sudoers.d/
echo "$username ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/$username"
chmod 440 "/etc/sudoers.d/$username"

# --- 3. SSH 密钥配置 ---
echo -e "\n--- 3. SSH 公钥配置 | SSH Key Setup ---"
user_home="/home/$username"
mkdir -p "$user_home/.ssh" && chmod 700 "$user_home/.ssh"
while true; do
    echo -e "${YELLOW}请粘贴您的 SSH 公钥:${NC}"
    read -r public_key < /dev/tty
    [[ -n "$public_key" ]] && break || echo -e "${RED}公钥不能为空！${NC}"
done
echo "$public_key" > "$user_home/.ssh/authorized_keys"
chmod 600 "$user_home/.ssh/authorized_keys"
chown -R "$username:$username" "$user_home/.ssh"

# --- 4. SSH 安全设置 ---
echo -e "\n--- 4. SSH 安全设置选项 | SSH Configuration ---"
ssh_port=22; pwd_auth="yes"; permit_root="yes"; allow_users=""

input_confirm "是否修改 SSH 默认端口 22? [y/n]: " c_port
[[ "$c_port" == "y" ]] && input_port ssh_port
input_confirm "是否禁用密码登录? [y/n]: " c_pwd
[[ "$c_pwd" == "y" ]] && pwd_auth="no"
input_confirm "是否禁止 Root 登录? [y/n]: " c_root
[[ "$c_root" == "y" ]] && permit_root="no"
input_confirm "是否仅允许 $username 登录? [y/n]: " c_user
[[ "$c_user" == "y" ]] && allow_users="AllowUsers $username"

# 1. 【核心修复】注释掉主配置中的 Port 定义，防止新旧端口同时并存
# 这行命令会把主配置文件里所有以 Port 开头的行都加上 # 注释掉
sed -i 's/^Port /#Port /g' /etc/ssh/sshd_config

# 2. 确保主配置文件包含 Include 路径（放在第一行）
if ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config; then
    sed -i "1i Include /etc/ssh/sshd_config.d/*.conf" /etc/ssh/sshd_config
fi

# 3. 写入子配置 (在这里定义新的 Port)
mkdir -p /etc/ssh/sshd_config.d/
cat <<EOF > /etc/ssh/sshd_config.d/ssh.conf
Port $ssh_port
PasswordAuthentication $pwd_auth
PermitRootLogin $permit_root
$allow_users
EOF

# --- 5. 重启与指引 ---
echo -e "\n${RED}!!! 警示：重启后请开启新窗口测试，不要关闭当前窗口 !!!${NC}"
input_confirm "是否立即重启 SSHD 生效? [y/n]: " res_sshd
if [ "$res_sshd" == "y" ]; then
    # 暴力兼容 Debian 12/Ubuntu 的 Socket 激活机制
    systemctl stop ssh.socket 2>/dev/null
    systemctl disable ssh.socket 2>/dev/null
    systemctl mask ssh.socket 2>/dev/null

    # 尝试重启服务（兼容不同发行版名称）
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null

    SERVER_IP=$(curl -s6 ifconfig.me || curl -s4 ifconfig.me || echo "您的服务器IP")
    echo -e "${GREEN}SSHD 已重启。监听端口: $ssh_port${NC}"
    echo -e "测试命令: ${YELLOW}ssh -p $ssh_port $username@$SERVER_IP${NC}"
    
    # 最后打印一次实际端口监听情况确认
    echo -e "\n当前系统实际监听端口状态:"
    ss -tlnp | grep -E "ssh|sshd"
fi
