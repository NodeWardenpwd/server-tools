#!/bin/bash

# 1. 颜色定义 (修正后的引导符)
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

# --- 2. 验证与交互函数库 ---

# 验证 y/n 输入
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

# 自动安装工具函数 (带交互确认)
install_pkg_confirm() {
    local pkg=$1
    local msg=$2
    local internal_pkg=$3 # 某些系统包名不同，如 iproute2
    
    echo -e "${YELLOW}[缺失] 系统未安装 '$pkg' ($msg)。${NC}"
    input_confirm "是否现在安装 $pkg? [y/n]: " do_inst
    
    if [ "$do_inst" == "y" ]; then
        if command -v apk &>/dev/null; then
            apk add --no-cache "${internal_pkg:-$pkg}"
        elif command -v apt-get &>/dev/null; then
            apt-get update && apt-get install -y "${internal_pkg:-$pkg}"
        elif command -v yum &>/dev/null; then
            yum install -y "${internal_pkg:-$pkg}"
        fi
    else
        echo -e "${RED}警告：缺少 $pkg 可能会导致脚本部分功能失效。${NC}"
        # 如果是 sudo，不安装则无法提权，强制退出
        [[ "$pkg" == "sudo" ]] && error_exit "提权工具缺失" "请安装 sudo 以便新用户能够执行 root 操作。"
    fi
}

# 验证端口号输入
input_port() {
    local var_name="$1"
    while true; do
        read -p "请输入新端口号 (1024-65535): " res < /dev/tty
        if [[ ! "$res" =~ ^[0-9]+$ ]] || [ "$res" -lt 1 ] || [ "$res" -gt 65535 ]; then
            echo -e "${RED}错误：请输入 1 到 65535 之间的数字！${NC}"; continue
        fi

        # 检查端口占用
        if command -v ss &>/dev/null; then
            if ss -tln | grep -q ":$res "; then
                local p_info=$(ss -tlnp | grep ":$res " | awk '{print $6}' | cut -d'"' -f2 | head -n1)
                echo -e "${RED}错误：端口 $res 已被占用！ [${p_info:-未知程序}]${NC}"
                continue
            fi
        fi
        echo -e "${GREEN}端口 $res 可用。${NC}"
        eval "$var_name='$res'"; break
    done
}

# --- 3. 环境预检 ---
[[ "$EUID" -ne 0 ]] && error_exit "权限不足" "请以 root 用户身份运行。"

echo -e "\n--- 0. 环境预检 | Environment Check ---"

# Debian 10 救急逻辑
if [ -f /etc/debian_version ] && grep -q "^10" /etc/debian_version; then
    if ! apt update &>/dev/null; then
        echo -e "${YELLOW}[检测] 发现 Debian 10，正在修复过期软件源...${NC}"
        sed -i 's/deb.debian.org/archive.debian.org/g' /etc/apt/sources.list
        sed -i 's/security.debian.org/archive.debian.org/g' /etc/apt/sources.list
        sed -i '/-updates/d' /etc/apt/sources.list
        echo "Acquire::Check-Valid-Until \"false\";" > /etc/apt/apt.conf.d/99no-check-valid-until
        apt update
    fi
fi

# 检查必要组件
command -v ss &>/dev/null || install_pkg_confirm "ss工具" "用于检测端口占用" "iproute2"
command -v sudo &>/dev/null || install_pkg_confirm "sudo" "用于新用户提权"
command -v curl &>/dev/null || install_pkg_confirm "curl" "用于获取公网IP"

# --- 4. 用户创建 ---
echo -e "\n--- 1. 用户创建 | User Creation ---"
while true; do
    read -p "请输入你要创建的用户名: " username < /dev/tty
    if [[ -z "$username" ]]; then
        echo -e "${RED}用户名不能为空！${NC}"
    elif id "$username" &>/dev/null; then
        echo -e "${YELLOW}用户 $username 已存在，更新配置。${NC}"; break
    else
        # 兼容不同系统的创建命令
        if command -v useradd &>/dev/null; then
            useradd -m -s /bin/bash "$username"
        else
            adduser -D -s /bin/bash "$username"
        fi
        [[ $? -eq 0 ]] && break || error_exit "创建用户失败" "请检查系统权限。"
    fi
done

echo -e "\n${YELLOW}>>> 请为 $username 设置密码:${NC}"
passwd "$username" < /dev/tty

# 权限注入
mkdir -p /etc/sudoers.d/
echo "$username ALL=(ALL:ALL) ALL" > "/etc/sudoers.d/$username"
chmod 440 "/etc/sudoers.d/$username"

# --- 5. SSH 密钥配置 ---
# --- 3. SSH 密钥配置 (全平台适配版) ---
echo -e "\n--- 3. SSH 公钥配置 | SSH Key Setup ---"

# 动态获取用户家目录，解决 root 运行脚本时 ~ 指向错误的问题
user_home=$(eval echo "~$username")

# 1. 创建目录并赋予 700 权限 (只有用户自己可读写)
mkdir -p "$user_home/.ssh"
chmod 700 "$user_home/.ssh"

while true; do
    echo -e "${YELLOW}请粘贴 SSH 公钥 (ssh-rsa...):${NC}"
    read -r raw_key < /dev/tty
    # 自动修剪空格，防止粘贴时产生干扰
    public_key=$(echo "$raw_key" | xargs)
    [[ -n "$public_key" ]] && break || echo -e "${RED}公钥不能为空！${NC}"
done

# 2. 写入公钥并强制 600 权限
# 使用 printf 避免 echo 可能产生的换行符问题
printf "%s\n" "$public_key" > "$user_home/.ssh/authorized_keys"
chmod 600 "$user_home/.ssh/authorized_keys"

# 3. 【最关键】修正所有权，否则 SSH 会因为 root 拥有该文件而拒绝登录
chown -R "$username:$username" "$user_home/.ssh"

echo -e "${GREEN}公钥配置完成，权限已校验。${NC}"

# --- 6. SSH 安全加固 ---
echo -e "\n--- 3. SSH 安全设置 | SSH Configuration ---"
ssh_port=22; pwd_auth="yes"; permit_root="yes"; allow_users=""

input_confirm "是否修改 SSH 默认端口 22? [y/n]: " c_port
[[ "$c_port" == "y" ]] && input_port ssh_port
input_confirm "是否禁用密码登录? [y/n]: " c_pwd
[[ "$c_pwd" == "y" ]] && pwd_auth="no"
input_confirm "是否禁止 Root 登录? [y/n]: " c_root
[[ "$c_root" == "y" ]] && permit_root="no"
input_confirm "是否仅允许 $username 登录? [y/n]: " c_user
[[ "$c_user" == "y" ]] && allow_users="AllowUsers $username"

# 【关键】清理主配置中的端口，开启 Include
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

# --- 7. 重启与指引 ---
echo -e "\n${RED}!!! 警示：重启后请开启新窗口测试，不要关闭当前窗口 !!!${NC}"
input_confirm "是否立即重启 SSH 服务? [y/n]: " res_sshd

if [ "$res_sshd" == "y" ]; then
    # 彻底禁用 Debian 12/Ubuntu 的 Socket 激活模式
    systemctl stop ssh.socket 2>/dev/null
    systemctl disable ssh.socket 2>/dev/null
    systemctl mask ssh.socket 2>/dev/null

    # 兼容各发行版的重启命令 (Alpine/Debian/CentOS)
    if command -v rc-service &>/dev/null; then
        rc-service sshd restart
    else
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    fi

    # 获取 IP 并打印结果
    SERVER_IP=$(curl -s6 ifconfig.me || curl -s4 ifconfig.me || echo "服务器IP")
    echo -e "\n${GREEN}[✔] 配置已生效！${NC}"
    echo -e "监听端口: ${YELLOW}$ssh_port${NC}"
    echo -e "测试命令: ${YELLOW}ssh -p $ssh_port $username@$SERVER_IP${NC}"
    
    echo -e "\n当前监听状态:"
    ss -tlnp | grep -E "ssh|sshd"
fi
