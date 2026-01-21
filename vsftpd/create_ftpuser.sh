#!/bin/bash

set -e  # 遇到任何错误立即退出

# -------------------------- 变量定义 ---------------------------
# 定义FTP的根目录
FTP_BASE="/home/ftp"
# 定义共享用户组名，所有新建的FTP用户和work用户都会加入此组
SHARED_GROUP="ftp_shared_workgroup"
# 随机密码长度
PASSWORD_LENGTH=12
# 拥有特殊权限的work用户名
WORK_USER="work"
# 新用户名，通过脚本参数传入
NEW_USER="$1"
# 新用户密码，通过脚本参数传入
NEW_PASS="$2"
# 子目录列表（可选），通过逗号分隔
SUBDIRS="$3"

# vsftpd 配置文件路径
VSFTPD_CONF="/etc/vsftpd.conf"
# 用户禁锢列表文件路径
CHROOT_LIST_FILE="/etc/vsftpd.chroot_list"
# 修改pam严重，对于vsftpd只支持nologin的账号
PAM_FTPD_FILE='/etc/pam.d/vsftpd'

# -------------------------- 函数定义 ---------------------------
# 跟新pam的vsftpd配置
update_pam_vsftpd() {
    cat > "$PAM_FTPD_FILE" << 'EOF'
# Standard behaviour for ftpd(8).
auth	required	pam_listfile.so item=user sense=deny file=/etc/ftpusers onerr=succeed

# Note: vsftpd handles anonymous logins on its own. Do not enable pam_ftp.so.

# Standard pam includes
@include common-account
@include common-session
@include common-auth
# 重点参数: pam_nologin.so，而不是pam_shells.so
auth	required	pam_nologin.so
EOF
}

# 检查是否以root权限运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "错误：此脚本必须以 root 权限运行。请使用 sudo 执行。"
        exit 1
    fi
}

# 检查必要参数
check_arguments() {
    if [ $# -lt 2 ]; then
        echo "用法: $0 <新用户名> <密码> [目录列表(逗号分隔)]"
        exit 1
    fi
}

# 检查用户是否已存在
check_user_existence() {
    if id "$1" &>/dev/null; then
        echo "错误：用户 '$1' 已存在。"
        exit 1
    fi
}

# 检查依赖命令
check_dependencies() {
    if ! command -v openssl &> /dev/null; then
        echo "错误：未找到 'openssl' 命令。请先安装它。"
        exit 1
    fi
}

# 安装并配置vsftpd
setup_vsftpd() {
    # 检查vsftpd是否已安装
    if ! dpkg -l | grep -q vsftpd; then
        echo "正在安装 vsftpd..."
        apt-get update
        apt-get install -y vsftpd
    fi

    # 创建FTP根目录
    mkdir -p "$FTP_BASE"

    # 备份原始配置文件
    if [ ! -f "$VSFTPD_CONF.original" ]; then
        cp "$VSFTPD_CONF" "$VSFTPD_CONF.original"
    fi

    # 使用cat和EOF覆盖写入正确的配置
    cat > "$VSFTPD_CONF" << 'EOF'
# ===== 核心连接与模式配置 =====
# 以独立守护进程模式运行（关键设置）
listen=YES
listen_ipv6=NO

# ===== 登录与控制配置 =====
# 禁用匿名登录，更安全
anonymous_enable=NO
# 允许本地系统用户登录（必须为YES）
local_enable=YES
# 启用写权限（如上传、删除等）
write_enable=YES

# 禁止匿名用户登录
anonymous_enable=NO
# 允许本地用户登录
local_enable=YES
# 开启写权限
write_enable=YES
# 设置本地用户创建文件的默认权限掩码
local_umask=022
# 启用目录切换消息
dirmessage_enable=YES
# 启用传输日志
xferlog_enable=YES
# 确保使用20端口进行数据连接（主动模式）
connect_from_port_20=YES

# ===== 用户禁锢与目录限制（重要安全设置） =====
# 将所有本地用户限制在其家目录内（chroot）
chroot_local_user=YES
# 允许被chroot禁锢的目录具有写权限（关键参数）
allow_writeable_chroot=YES

# ===== 被动模式配置（适用于客户端在防火墙/NAT后的情况） =====
# 启用被动模式连接
pasv_enable=YES
# 设置被动模式使用的端口范围（建议设置并按需开放防火墙）
pasv_min_port=40000
pasv_max_port=50000

# ===== 用户列表访问控制 =====
# 启用用户列表功能
userlist_enable=NO
# 当为NO时，仅允许在user_list文件中的用户登录（白名单模式）

# 设置为标准日志格式
xferlog_std_format=YES

# ===== PAM认证服务名称（关键，与530错误密切相关） =====
# 指定PAM认证配置文件名[1,6](@ref)
pam_service_name=vsftpd

# ===== 其他安全与功能设置 =====
# 启用tcp包装器进行额外访问控制
tcp_wrappers=YES
EOF

    # 确保chroot列表文件存在
    touch "$CHROOT_LIST_FILE"

    # 配置防火墙规则 [2,8](@ref)
    echo "配置防火墙..."
    ufw allow 20/tcp > /dev/null 2>&1 || true
    ufw allow 21/tcp > /dev/null 2>&1 || true
    ufw allow 40000:50000/tcp > /dev/null 2>&1 || true

    # 重启vsftpd服务以使配置生效 [2,3](@ref)
    systemctl restart vsftpd
    echo "vsftpd 已安装并配置完成。"
}

# 创建共享用户组，并将work用户加入
create_shared_group() {
    if ! getent group "$SHARED_GROUP" > /dev/null; then
        groupadd "$SHARED_GROUP"
        echo "已创建共享用户组: $SHARED_GROUP"
    fi

    # 将work用户加入该组（如果work用户存在）
    if id "$WORK_USER" &>/dev/null; then
        usermod -aG "$SHARED_GROUP" "$WORK_USER"
        echo "已将用户 '$WORK_USER' 加入共享组 '$SHARED_GROUP'。"
    else
        echo "警告：系统内不存在用户 '$WORK_USER'，权限设置将不完整。"
    fi
}

# 创建FTP用户并设置指定密码
create_ftp_user() {
    local username=$1
    local password=$2

    # 创建用户，将其家目录设置为FTP根目录下的子目录，并禁止其登录shell [2,5](@ref)
    useradd -m -d "$FTP_BASE/$username" -s /sbin/nologin -G "$SHARED_GROUP" "$username"
    echo "已创建系统用户: $username"

    # 设置密码
    echo "$username:$password" | chpasswd
    echo "已为用户 '$username' 设置指定密码。"
}

# 设置FTP用户目录权限
setup_ftp_directory() {
    local username=$1
    local user_dir="$FTP_BASE/$username"

    # 确保目录存在
    mkdir -p "$user_dir"

    # 关键权限设置 [4](@ref)
    # 1. 目录所有者是新用户，所属组是共享组
    chown "$username:$SHARED_GROUP" "$user_dir"
    # 2. 设置目录权限：所有者有全部权限(7)，组用户有全部权限(7)，其他用户无权限(0)
    # 这使得新用户自己和同组（包括work）的成员都有读写执行的权限，而其他用户（包括其他FTP用户）无法访问。
    chmod 770 "$user_dir"

    echo "已设置目录权限: $user_dir (所有者: $username, 组: $SHARED_GROUP, 权限: 770)"
}

# 创建子目录
create_subdirectories() {
    local username=$1
    local user_dir="$FTP_BASE/$username"
    local subdirs_str=$2

    if [ -z "$subdirs_str" ]; then
        echo "未指定子目录，跳过创建。"
        return
    fi

    echo "正在创建子目录..."
    # 将逗号替换为空格，以便循环处理
    local IFS=','
    for subdir in $subdirs_str; do
        # 去除可能存在的空白字符（虽然通常参数传入不会有）
        subdir=$(echo "$subdir" | xargs)
        if [ -n "$subdir" ]; then
            local full_path="$user_dir/$subdir"
            mkdir -p "$full_path"
            # 继承父目录的权限设置
            chown "$username:$SHARED_GROUP" "$full_path"
            chmod 770 "$full_path"
            echo "  - 已创建子目录: $subdir"
        fi
    done
}

# 将用户添加到chroot例外列表（确保此用户不被禁锢）
# 注意：由于我们的配置是 chroot_local_user=YES，添加进这个列表的用户将“不受”禁锢，可以向上切换目录。
# 因此，我们不会将普通FTP用户添加进去，以确保他们被禁锢。work用户如果需要FTP登录并访问其他目录，则可以加入。
# 此脚本为演示，默认不将任何用户加入例外列表，确保所有新建用户都被隔离。
exempt_user_from_chroot() {
    local username=$1
    # 检查用户是否已在列表中
    if ! grep -q "^$username$" "$CHROOT_LIST_FILE"; then
        echo "$username" >> "$CHROOT_LIST_FILE"
        echo "注意：用户 '$username' 已被添加到chroot例外列表，将不受目录禁锢限制。"
    fi
}

# 打印创建结果
print_summary() {
    local username=$1
    local password=$2
    local user_dir="$FTP_BASE/$username"

    echo ""
    echo "================================================"
    echo "FTP 用户创建完成！"
    echo "================================================"
    echo "用户名: $username"
    echo "密码: $password"
    echo "用户目录: $user_dir"
    echo "共享用户组: $SHARED_GROUP"
    echo "具有特殊访问权限的用户: $WORK_USER"
    echo "------------------------------------------------"
    echo "用户隔离状态:"
    echo "  - 用户 '$username' 已被禁锢在自己的目录中，无法访问其他用户目录。"
    echo "  - 用户 '$WORK_USER' 对所有FTP用户目录拥有读写权限。"
    echo "------------------------------------------------"
    echo "FTP 连接信息:"
    echo "  主机: $(hostname -I | awk '{print $1}') 或您的服务器域名"
    echo "  端口: 21"
    echo "  协议: FTP (建议使用被动模式)"
    echo "================================================"
    echo "重要提示：请妥善保管以上密码信息。"
}

# -------------------------- 主程序 ---------------------------
main() {
    # 初始检查
    check_arguments "$@"
    check_root
    check_dependencies
    check_user_existence "$NEW_USER"

    # 执行流程
    setup_vsftpd
    # 更新pam vsftpd的配置，避免登陆530问题
    update_pam_vsftpd 
    create_shared_group
    create_ftp_user "$NEW_USER" "$NEW_PASS"
    setup_ftp_directory "$NEW_USER"
    # 创建子目录（如果提供了参数）
    create_subdirectories "$NEW_USER" "$SUBDIRS"
    # 注意：此处特意不调用 exempt_user_from_chroot，确保新用户被禁锢。
    print_summary "$NEW_USER" "$NEW_PASS"
}

# 启动主程序
main "$@"
