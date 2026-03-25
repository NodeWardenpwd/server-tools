#!/bin/bash

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\1;33m'
NC='\033[0m'

# 错误处理函数
error_exit() {
    echo -e "\n${RED}[ERROR] 错误位置: $1${NC}"
    echo -e "${YELLOW}解决建议: $2${NC}"
    exit 1
}

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then 
    error_exit "权限不足" "请以 root 用户身份运行（或使用 sudo）。"
fi

# 交互输入函数，确保从终端读取
input() {
    read -p "$1" "$2" < /dev/tty
}

# 1. 创建用户阶段
echo -e "\n--- 用户创建 | User Creation ---"
input "请输入要创建的用户名 (Enter username): " username

if [ -z "$username" ]; then
    error_exit "用户名不能为空" "请输入有效的用户名后重试。"
fi

if id "$username" &>/dev/null; then
    echo -e "${GREEN}[INFO] 用户 $username 已存在，直接进入密码设置。${NC}"
else
    echo "正在创建系统用户 $username..."
    # --gecos "" 用于跳过复杂的个人信息填写
    if ! adduser --gecos "" "$username"; then
        error_exit "创建用户失败" "请检查磁盘空间(df -h)或系统是否锁定。"
    fi
fi

# 为用户设置密码 (交互式)
echo -e "\n${YELLOW}请为用户 $username 设置登录密码：${NC}"
if ! passwd "$username" < /dev/tty; then
    error_exit "密码设置失败" "两次输入不一致或密码太简单被系统拒绝。"
fi

# 2. 权限配置阶段
echo -e "\n--- 权限配置 | Privilege Setup ---"
if command -v usermod &>/dev/null; then
    if usermod -aG sudo "$username" 2>/dev/null; then
        echo "已成功将 $username 添加至 sudo 组。"
    elif usermod -aG wheel "$username" 2>/dev/null; then
        echo "已成功将 $username 添加至 wheel 组。"
    else
        echo -e "${YELLOW}[WARN] 未找到 sudo/wheel 组，该用户可能无法使用 sudo。${NC}"
    fi
else
    echo -e "${YELLOW}[WARN] 找不到 usermod 命令，跳过组配置。${NC}"
fi

# 3. SSH 密钥配置阶段
echo -e "\n--- SSH 公钥配置 | SSH Key Setup ---"
user_home="/home/$username"
mkdir -p "$user_home/.ssh" || error_exit "无法创建目录" "请检查磁盘空间。"

echo "请在此处粘贴您的 SSH 公钥 (Please paste your SSH Public Key):"
read -r public_key < /dev/tty

if [ -z "$public_key" ]; then
    error_exit "公钥为空" "必须提供公钥才能继续，否则禁用密码登录后您将无法进入。"
fi

echo "$public_key" > "$user_home/.ssh/authorized_keys"
chmod 700 "$user_home/.ssh"
chmod 600 "$user_home/.ssh/authorized_keys"
chown -R "$username:$username" "$user_home/.ssh"
echo -e "${GREEN}[OK] SSH 密钥及权限配置完成。${NC}"

# 4. SSH 安全设置
echo -e "\n--- SSH 安全设置选项 | SSH Configuration ---"
ssh_port=22; pwd_auth="yes"; permit_root="yes"; allow_users_line=""

input "是否修改默认 SSH 端口 22? (Change port? [y/n]): " c_port
if [[ "$c_port" =~ ^[Yy]$ ]]; then
    input "请输入新端口号 (1024-65535): " ssh_port
fi

input "是否禁用密码登录? (Disable password login? [y/n]): " c_pwd
[[ "$c_pwd" =~ ^[Yy]$ ]] && pwd_auth="no"

input "是否禁止 Root 登录? (Disable Root login? [y/n]): " c_root
[[ "$c_root" =~ ^[Yy]$ ]] && permit_root="no"

input "是否仅允许 $username 登录? (Only allow $username? [y/n]): " c_user
[[ "$c_user" =~ ^[Yy]$ ]] && allow_users_line="AllowUsers $username"

# 写入配置文件 (不直接修改主配置，使用 conf.d 模式)
mkdir -p /etc/ssh/sshd_config.d/
config_file="/etc/ssh/sshd_config.d/ssh.conf"

if ! cat <<EOF > $config_file
Port $ssh_port
PasswordAuthentication $pwd_auth
PermitRootLogin $permit_root
$allow_users_line
EOF
then
    error_exit "配置文件写入失败" "请检查磁盘是否已满。"
fi

# 5. 重启与终极警示
echo -e "\n${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo -e "关键警告 (CRITICAL WARNING):"
echo -e "1. 重启 SSHD 后，请【务必保留当前窗口】不要关闭！"
echo -e "2. 立即【新开一个终端窗口】尝试使用新端口和新用户登录。"
echo -e "3. 如果新窗口登录成功，再关闭此窗口。否则请在当前窗口修正配置！"
echo -e "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}\n"

input "是否立即重启 SSHD 以应用更改? (Restart SSHD now? [y/n]): " restart_sshd

if [[ "$restart_sshd" =~ ^[Yy]$ ]]; then
    if systemctl restart sshd; then
        echo -e "\n${GREEN}[✔] SSHD 已成功重启！${NC}"
        echo -e "请在新窗口运行此命令测试: ${YELLOW}ssh -p $ssh_port $username@$(curl -s ifconfig.me || echo '服务器IP')${NC}"
    else
        error_exit "SSHD 重启失败" "语法可能错误，请运行 'sshd -t' 检查。"
    fi
else
    echo -e "\n[!] 已跳过重启。手动重启请执行: systemctl restart sshd"
fi
