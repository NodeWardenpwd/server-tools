#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error_exit() {
    echo -e "\n${RED}[错误] $1${NC}"
    echo -e "${YELLOW}建议: $2${NC}"
    exit 1
}

[[ "$EUID" -ne 0 ]] && error_exit "权限不足" "请以 root 身份运行。"

input() {
    read -p "$1" "$2" < /dev/tty
}

# --- 0. 环境预检与 sudo 安装 ---
echo -e "\n--- 0. 环境预检 | Environment Check ---"
if ! command -v sudo &>/dev/null; then
    echo -e "${YELLOW}[INFO] 正在安装 sudo...${NC}"
    apt-get update && apt-get install -y sudo || yum install -y sudo || error_exit "sudo 安装失败" "请手动安装后再运行。"
fi

# --- 1. 用户创建 ---
echo -e "\n--- 1. 用户创建 | User Creation ---"
input "请输入用户名: " username
[[ -z "$username" ]] && error_exit "用户名不能为空" ""

if id "$username" &>/dev/null; then
    echo -e "${GREEN}[INFO] 用户 $username 已存在。${NC}"
else
    useradd -m -s /bin/bash "$username" || error_exit "创建用户失败" ""
fi

echo -e "\n${YELLOW}>>> 请设置用户 $username 的密码:${NC}"
passwd "$username" < /dev/tty || error_exit "密码设置失败" ""

# --- 2. 核心权限注入 (关键修复) ---
echo -e "\n--- 2. 权限配置 | Privilege Setup ---"
# 方法 A: 加入标准管理组
ADMIN_GROUP="sudo"
grep -q "^wheel:" /etc/group && ADMIN_GROUP="wheel"
usermod -aG "$ADMIN_GROUP" "$username"

# 方法 B: 强制写入 sudoers.d (确保万无一失)
# 这样即使组没生效，用户也能提权
echo "$username ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/$username"
chmod 440 "/etc/sudoers.d/$username"

if sudo -u "$username" sudo -n true 2>/dev/null || [ -f "/etc/sudoers.d/$username" ]; then
    echo -e "${GREEN}[OK] 权限配置完成。用户 $username 已获得 sudo 权限。${NC}"
else
    error_exit "权限分配失败" "无法为 $username 分配 sudo 权限。"
fi

# --- 3. SSH 密钥配置 ---
echo -e "\n--- 3. SSH 公钥配置 | SSH Key Setup ---"
user_home="/home/$username"
mkdir -p "$user_home/.ssh"
chmod 700 "$user_home/.ssh"

echo -e "${YELLOW}请粘贴 SSH 公钥:${NC}"
read -r public_key < /dev/tty
[[ -z "$public_key" ]] && error_exit "公钥不能为空" ""

echo "$public_key" > "$user_home/.ssh/authorized_keys"
chmod 600 "$user_home/.ssh/authorized_keys"
chown -R "$username:$username" "$user_home/.ssh"

# --- 4. SSH 安全加固 ---
echo -e "\n--- 4. SSH 设置 ---"
ssh_port=22; pwd_auth="yes"; permit_root="yes"; allow_users=""

input "是否修改 SSH 端口? [y/n]: " c_port
[[ "$c_port" =~ ^[Yy]$ ]] && input "请输入新端口号: " ssh_port

input "是否禁用密码登录? [y/n]: " c_pwd
[[ "$c_pwd" =~ ^[Yy]$ ]] && pwd_auth="no"

input "是否禁止 Root 登录? [y/n]: " c_root
[[ "$c_root" =~ ^[Yy]$ ]] && permit_root="no"

input "是否仅允许 $username 登录? [y/n]: " c_user
[[ "$c_user" =~ ^[Yy]$ ]] && allow_users="AllowUsers $username"

mkdir -p /etc/ssh/sshd_config.d/
cat <<EOF > /etc/ssh/sshd_config.d/ssh.conf
Port $ssh_port
PasswordAuthentication $pwd_auth
PermitRootLogin $permit_root
$allow_users
EOF

# --- 5. 重启与指引 ---
echo -e "\n${RED}!!! 警示：重启后请开启新窗口，并使用 'sudo -i' 测试提权 !!!${NC}"
input "是否立即重启 SSHD? [y/n]: " res_sshd
if [[ "$res_sshd" =~ ^[Yy]$ ]]; then
    systemctl restart sshd
    echo -e "${GREEN}SSHD 已重启。${NC}"
fi
