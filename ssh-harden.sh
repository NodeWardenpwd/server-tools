#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error_exit() {
    echo -e "\n${RED}[错误] $1${NC}"
    exit 1
}

# 检查 root
[[ "$EUID" -ne 0 ]] && error_exit "请用 root 运行"

# 强制从终端读取输入的函数
input() {
    read -p "$1" "$2" < /dev/tty
}

echo -e "\n--- 1. 用户创建 | User Creation ---"
input "请输入你要创建的用户名: " username
[[ -z "$username" ]] && error_exit "用户名不能为空"

if id "$username" &>/dev/null; then
    echo -e "${GREEN}用户 $username 已存在。${NC}"
else
    # 静默创建用户，不问废话
    useradd -m -s /bin/bash "$username" || error_exit "创建用户失败，请检查磁盘空间。"
    echo -e "${GREEN}用户 $username 创建成功。${NC}"
fi

# 关键点：这里会停下来让你设密码
echo -e "\n${YELLOW}>>> 请输入用户 $username 的新密码 (屏幕不会显示输入内容):${NC}"
passwd "$username" < /dev/tty || error_exit "密码设置失败"

echo -e "\n--- 2. SSH 密钥配置 | SSH Key Setup ---"
user_home="/home/$username"
mkdir -p "$user_home/.ssh"
chmod 700 "$user_home/.ssh"

echo -e "${YELLOW}请在此处粘贴你的 SSH 公钥 (id_rsa.pub 的内容):${NC}"
read -r public_key < /dev/tty
[[ -z "$public_key" ]] && error_exit "公钥不能为空"

echo "$public_key" > "$user_home/.ssh/authorized_keys"
chmod 600 "$user_home/.ssh/authorized_keys"
chown -R "$username:$username" "$user_home/.ssh"

echo -e "\n--- 3. SSH 安全加固 | SSH Hardening ---"
ssh_port=22; pwd_auth="yes"; permit_root="yes"; allow_users=""

input "是否修改 SSH 端口 (默认22)? [y/n]: " c_port
[[ "$c_port" =~ ^[Yy]$ ]] && input "请输入新端口号: " ssh_port

input "是否禁用密码登录? [y/n]: " c_pwd
[[ "$c_pwd" =~ ^[Yy]$ ]] && pwd_auth="no"

input "是否禁止 Root 登录? [y/n]: " c_root
[[ "$c_root" =~ ^[Yy]$ ]] && permit_root="no"

input "是否仅允许 $username 登录? [y/n]: " c_user
[[ "$c_user" =~ ^[Yy]$ ]] && allow_users="AllowUsers $username"

# 写入配置
mkdir -p /etc/ssh/sshd_config.d/
cat <<EOF > /etc/ssh/sshd_config.d/ssh.conf
Port $ssh_port
PasswordAuthentication $pwd_auth
PermitRootLogin $permit_root
$allow_users
EOF

echo -e "\n${RED}警告：重启后请务必先新开窗口测试，不要关闭当前窗口！${NC}"
input "是否立即重启 SSHD 生效? [y/n]: " res_sshd
if [[ "$res_sshd" =~ ^[Yy]$ ]]; then
    systemctl restart sshd
    echo -e "${GREEN}SSHD 已重启。测试命令: ssh -p $ssh_port $username@$(curl -s ifconfig.me)${NC}"
fi
