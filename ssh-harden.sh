#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 错误处理函数
error_exit() {
    echo -e "\n${RED}[错误] $1${NC}"
    echo -e "${YELLOW}解决建议: $2${NC}"
    exit 1
}

# 检查 root 权限
[[ "$EUID" -ne 0 ]] && error_exit "权限不足" "请以 root 用户身份运行。"

# 交互输入函数
input() {
    read -p "$1" "$2" < /dev/tty
}

# --- 0. 环境预检与 sudo 安装 ---
echo -e "\n--- 0. 环境预检 | Environment Check ---"

# 检查磁盘空间
FREE_SPACE=$(df /etc | awk 'NR==2 {print $4}')
if [ "$FREE_SPACE" -lt 10240 ]; then
    error_exit "磁盘空间不足" "剩余空间少于 10MB，请先清理磁盘 (df -h)。"
fi

if ! command -v sudo &>/dev/null; then
    echo -e "${YELLOW}[INFO] 正在尝试安装 sudo...${NC}"
    if command -v apt-get &>/dev/null; then
        # 针对你遇到的 404 错误，先执行 update
        apt-get update && apt-get install -y sudo || error_exit "sudo 安装失败" "请检查网络或运行 apt-get update"
    elif command -v yum &>/dev/null; then
        yum install -y sudo || error_exit "sudo 安装失败" "请检查 yum 源。"
    fi
    echo -e "${GREEN}[OK] sudo 安装成功。${NC}"
fi

# --- 1. 用户创建 | User Creation ---
echo -e "\n--- 1. 用户创建 | User Creation ---"
input "请输入你要创建的用户名: " username
[[ -z "$username" ]] && error_exit "用户名不能为空" "请输入有效的用户名。"

if id "$username" &>/dev/null; then
    echo -e "${GREEN}[INFO] 用户 $username 已存在。${NC}"
else
    echo "正在创建系统用户 $username..."
    useradd -m -s /bin/bash "$username" || error_exit "创建用户失败" "请检查系统用户数限制或磁盘。"
fi

# 强制触发密码设置 (会有明确提示)
echo -e "\n${YELLOW}>>> 请为用户 $username 设置登录密码 (输入时屏幕不会显示字符)：${NC}"
passwd "$username" < /dev/tty || error_exit "密码设置失败" "两次输入不一致。"

# --- 2. 权限加固 (解决 sudoers file 报错) ---
echo -e "\n--- 2. 权限配置 | Privilege Setup ---"
# 方法：直接写入 sudoers.d，这是最稳妥的提权方式
echo "$username ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/$username"
chmod 440 "/etc/sudoers.d/$username"

# 检查权限文件是否写入成功
if [ -f "/etc/sudoers.d/$username" ]; then
    echo -e "${GREEN}[OK] 权限配置完成。用户 $username 已获得 sudo 权限。${NC}"
else
    error_exit "权限配置失败" "无法写入 /etc/sudoers.d/"
fi

# --- 3. SSH 密钥配置 | SSH Key Setup ---
echo -e "\n--- 3. SSH 公钥配置 | SSH Key Setup ---"
user_home="/home/$username"
mkdir -p "$user_home/.ssh"
chmod 700 "$user_home/.ssh"

echo -e "${YELLOW}请粘贴您的 SSH 公钥 (id_rsa.pub 内容):${NC}"
read -r public_key < /dev/tty
[[ -z "$public_key" ]] && error_exit "公钥不能为空" "必须配置密钥登录。"

echo "$public_key" > "$user_home/.ssh/authorized_keys"
chmod 600 "$user_home/.ssh/authorized_keys"
chown -R "$username:$username" "$user_home/.ssh"
echo -e "${GREEN}[OK] SSH 密钥及目录权限配置完成。${NC}"

# --- 4. SSH 安全设置 ---
echo -e "\n--- 4. SSH 安全设置选项 | SSH Configuration ---"
ssh_port=22; pwd_auth="yes"; permit_root="yes"; allow_users=""

input "是否修改默认 SSH 端口 22? [y/n]: " c_port
[[ "$c_port" =~ ^[Yy]$ ]] && input "请输入新端口号 (1024-65535): " ssh_port

input "是否禁用密码登录? [y/n]: " c_pwd
[[ "$c_pwd" =~ ^[Yy]$ ]] && pwd_auth="no"

input "是否禁止 Root 登录? [y/n]: " c_root
[[ "$c_root" =~ ^[Yy]$ ]] && permit_root="no"

input "是否仅允许 $username 登录? [y/n]: " c_user
[[ "$c_user" =~ ^[Yy]$ ]] && allow_users="AllowUsers $username"

# 写入配置到 conf.d
mkdir -p /etc/ssh/sshd_config.d/
cat <<EOF > /etc/ssh/sshd_config.d/ssh.conf
Port $ssh_port
PasswordAuthentication $pwd_auth
PermitRootLogin $permit_root
$allow_users
EOF

# --- 5. 重启与指引 ---
echo -e "\n${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo -e "关键警告 (CRITICAL WARNING):"
echo -e "1. 重启 SSHD 后，请【务必保留当前窗口】不要关闭！"
echo -e "2. 立即【新开一个终端窗口】尝试使用新用户和新端口登录。"
echo -e "3. 登录后测试提权：执行 'sudo -i'，看是否能变回 root。"
echo -e "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}\n"

input "是否立即重启 SSHD 生效? [y/n]: " res_sshd
if [[ "$res_sshd" =~ ^[Yy]$ ]]; then
    if systemctl restart sshd; then
        echo -e "${GREEN}[✔] SSHD 已重启。${NC}"
        echo -e "测试命令: ${YELLOW}ssh -p $ssh_port $username@$(curl -s ifconfig.me || echo '服务器IP')${NC}"
    else
        error_exit "SSHD 重启失败" "请手动检查配置语法。"
    fi
fi
