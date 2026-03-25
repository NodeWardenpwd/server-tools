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

# 检查 root 权限
[[ "$EUID" -ne 0 ]] && error_exit "权限不足" "请以 root 用户身份运行。"

# 交互输入函数
input() {
    read -p "$1" "$2" < /dev/tty
}

# --- 0. 环境预检与 sudo 安装询问 ---
echo -e "\n--- 0. 环境预检 | Environment Check ---"

if ! command -v sudo &>/dev/null; then
    echo -e "${YELLOW}[注意] 系统未安装 'sudo' 软件包。${NC}"
    echo -e "若不安装 sudo，新创建的普通用户将无法执行管理任务（提权）。"
    
    input "是否现在自动安装 sudo? (推荐安装) [y/n]: " install_sudo
    
    if [[ "$install_sudo" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}[INFO] 正在尝试安装 sudo...${NC}"
        if command -v apt-get &>/dev/null; then
            apt-get update && apt-get install -y sudo || error_exit "sudo 安装失败" "请检查网络或软件源。"
        elif command -v yum &>/dev/null; then
            yum install -y sudo || error_exit "sudo 安装失败" "请检查 yum 源。"
        else
            error_exit "未找到包管理器" "系统不支持 apt 或 yum，请手动安装 sudo。"
        fi
        echo -e "${GREEN}[OK] sudo 安装成功。${NC}"
    else
        echo -e "${RED}\n[终止] 用户拒绝安装 sudo。${NC}"
        echo -e "由于普通用户无法提权，继续配置将失去管理意义。脚本退出。"
        exit 1
    fi
else
    echo -e "${GREEN}[OK] 系统已安装 sudo。${NC}"
fi

# --- 1. 用户创建 ---
echo -e "\n--- 1. 用户创建 | User Creation ---"
input "请输入你要创建的用户名: " username
[[ -z "$username" ]] && error_exit "用户名不能为空" ""

if id "$username" &>/dev/null; then
    echo -e "${GREEN}[INFO] 用户 $username 已存在。${NC}"
else
    echo "正在创建系统用户 $username..."
    useradd -m -s /bin/bash "$username" || error_exit "创建用户失败" "检查磁盘空间。"
fi

echo -e "\n${YELLOW}>>> 请为新用户 $username 设置登录密码 (输入时不显示字符):${NC}"
passwd "$username" < /dev/tty || error_exit "密码设置失败" "两次输入不一致。"

# --- 2. 权限加固 (注入 sudoers) ---
echo -e "\n--- 2. 权限配置 | Privilege Setup ---"
# 直接写入 sudoers.d 确保提权 100% 成功
echo "$username ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/$username"
chmod 440 "/etc/sudoers.d/$username"
echo -e "${GREEN}[OK] 权限配置完成。用户 $username 已获得提权资格。${NC}"

# --- 3. SSH 密钥配置 ---
echo -e "\n--- 3. SSH 公钥配置 | SSH Key Setup ---"
user_home="/home/$username"
mkdir -p "$user_home/.ssh"
chmod 700 "$user_home/.ssh"

echo -e "${YELLOW}请粘贴您的 SSH 公钥 (id_rsa.pub 内容):${NC}"
read -r public_key < /dev/tty
[[ -z "$public_key" ]] && error_exit "公钥为空" "必须配置密钥登录。"

echo "$public_key" > "$user_home/.ssh/authorized_keys"
chmod 600 "$user_home/.ssh/authorized_keys"
chown -R "$username:$username" "$user_home/.ssh"
echo -e "${GREEN}[OK] 密钥配置完成。${NC}"

# --- 4. SSH 安全设置 ---
echo -e "\n--- 4. SSH 安全设置选项 | SSH Configuration ---"
ssh_port=22; pwd_auth="yes"; permit_root="yes"; allow_users=""

input "是否修改 SSH 默认端口 22? [y/n]: " c_port
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

# --- 5. 重启与指引 ---
echo -e "\n${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo -e "关键警告 (CRITICAL WARNING):"
echo -e "1. 重启后【务必保留当前窗口】不要关闭！"
echo -e "2. 立即【新开一个窗口】尝试新用户和新端口登录。"
echo -e "3. 登录后执行 'sudo -i' 测试提权是否成功。"
echo -e "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}\n"

input "是否立即重启 SSHD 生效? [y/n]: " res_sshd
if [[ "$res_sshd" =~ ^[Yy]$ ]]; then
    systemctl restart sshd
    echo -e "${GREEN}[✔] SSHD 已重启。测试命令: ssh -p $ssh_port $username@$(curl -s ifconfig.me || echo 'IP')${NC}"
fi
