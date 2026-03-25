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

# 验证 y/n 输入
input_confirm() {
    local prompt="$1"
    local var_name="$2"
    while true; do
        read -p "$prompt" res < /dev/tty
        case "$res" in
            [Yy]* ) eval "$var_name='y'"; break;;
            [Nn]* ) eval "$var_name='n'"; break;;
            * ) echo -e "${RED}输入错误！请输入 y 或 n (Invalid input! Please enter y or n)${NC}";;
        esac
    done
}

# 验证端口号输入 (1-65535)
input_port() {
    local var_name="$1"
    while true; do
        read -p "请输入新端口号 (1024-65535): " res < /dev/tty
        if [[ "$res" =~ ^[0-9]+$ ]] && [ "$res" -ge 1 ] && [ "$res" -le 65535 ]; then
            eval "$var_name='$res'"
            break
        else
            echo -e "${RED}错误：端口号必须是 1-65535 之间的数字！${NC}"
        fi
    done
}

# 检查 root 权限
[[ "$EUID" -ne 0 ]] && error_exit "权限不足" "请以 root 用户身份运行。"

# --- 0. 环境预检 ---
echo -e "\n--- 0. 环境预检 | Environment Check ---"
if ! command -v sudo &>/dev/null; then
    echo -e "${YELLOW}[注意] 系统未安装 'sudo'。没有它，新用户将无法提权。${NC}"
    input_confirm "是否现在安装 sudo? [y/n]: " do_install
    if [ "$do_install" == "y" ]; then
        apt-get update && apt-get install -y sudo || yum install -y sudo || error_exit "安装失败" "请检查网络。"
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
    else
        break
    fi
done

if id "$username" &>/dev/null; then
    echo -e "${GREEN}[INFO] 用户 $username 已存在。${NC}"
else
    useradd -m -s /bin/bash "$username" || error_exit "创建失败" "磁盘空间可能已满。"
fi

echo -e "\n${YELLOW}>>> 请为新用户 $username 设置密码 (屏幕不显示字符):${NC}"
passwd "$username" < /dev/tty || error_exit "密码设置失败" "请重试。"

# --- 2. 权限注入 ---
echo "$username ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/$username"
chmod 440 "/etc/sudoers.d/$username"

# --- 3. SSH 密钥配置 ---
echo -e "\n--- 3. SSH 公钥配置 | SSH Key Setup ---"
user_home="/home/$username"
mkdir -p "$user_home/.ssh" && chmod 700 "$user_home/.ssh"

while true; do
    echo -e "${YELLOW}请粘贴您的 SSH 公钥 (id_rsa.pub 内容):${NC}"
    read -r public_key < /dev/tty
    if [[ -z "$public_key" ]]; then
        echo -e "${RED}公钥不能为空！${NC}"
    else
        break
    fi
done
echo "$public_key" > "$user_home/.ssh/authorized_keys"
chmod 600 "$user_home/.ssh/authorized_keys"
chown -R "$username:$username" "$user_home/.ssh"

# --- 4. SSH 安全设置 (严格检查输入) ---
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

# 写入配置
mkdir -p /etc/ssh/sshd_config.d/
cat <<EOF > /etc/ssh/sshd_config.d/ssh.conf
Port $ssh_port
PasswordAuthentication $pwd_auth
PermitRootLogin $permit_root
$allow_users
EOF

# --- 5. 重启与指引 ---
echo -e "\n${RED}!!! 警示：重启后请开启新窗口，并使用 'sudo -i' 测试提权 !!!${NC}"
input_confirm "是否立即重启 SSHD 生效? [y/n]: " res_sshd
if [ "$res_sshd" == "y" ]; then
    systemctl restart sshd
    echo -e "${GREEN}SSHD 已重启。测试端口: $ssh_port${NC}"
fi
