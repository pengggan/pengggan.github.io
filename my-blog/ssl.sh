#!/bin/bash

# ==============================================
# Certbot SSL证书自动化管理脚本 (Root用户专用版)
# 版本：2.2 (优化版)
# 最后更新：2024-05-01
# 项目地址：https://github.com/penggan00/my-blog
# ==============================================

# 初始化安全设置
set -o errexit
set -o nounset
set -o pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置参数
RENEW_THRESHOLD=30
CHECK_INTERVAL=7
LOG_FILE="/var/log/certbot_renew.log"
BACKUP_DIR="/etc/letsencrypt_backup"
CONFIG_DIR="/etc/letsencrypt"

# 初始化日志
init_log() {
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
    echo -e "\n$(date '+%Y-%m-%d %H:%M:%S') - 脚本启动" >> "$LOG_FILE"
}

# 日志记录函数
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "INFO") color="${BLUE}" ;;
        "SUCCESS") color="${GREEN}" ;;
        "WARNING") color="${YELLOW}" ;;
        "ERROR") color="${RED}" ;;
        *) color="${NC}" ;;
    esac
    
    echo -e "${color}[${timestamp}] [${level}] ${message}${NC}" | tee -a "$LOG_FILE"
}

# 错误处理函数
error_exit() {
    log "ERROR" "$1"
    exit 1
}

# 系统检查
check_system() {
    log "INFO" "正在检查系统环境..."
    
    # 检查架构
    ARCH=$(uname -m)
    log "INFO" "系统架构: $ARCH"
    
    # 检查Ubuntu版本
    if [ ! -f /etc/lsb-release ]; then
        error_exit "此脚本仅支持Ubuntu系统"
    fi
    
    source /etc/lsb-release
    UBUNTU_VERSION=${DISTRIB_RELEASE}
    
    if [[ $(echo "$UBUNTU_VERSION < 18.04" | bc) -eq 1 ]]; then
        error_exit "此脚本需要Ubuntu 18.04或更高版本"
    fi
    
    log "INFO" "Ubuntu版本: $DISTRIB_DESCRIPTION"
}

# 安装依赖
install_dependencies() {
    log "INFO" "正在安装依赖..."
    
    export DEBIAN_FRONTEND=noninteractive
    
    apt-get update > /dev/null 2>&1 || error_exit "apt更新失败"
    
    local dependencies=(
        "certbot"
        "python3-certbot-dns-cloudflare"
        "coreutils"
        "mailutils"
        "bc"
        "jq"
    )
    
    for pkg in "${dependencies[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            if ! apt-get install -y "$pkg" > /dev/null 2>&1; then
                log "ERROR" "安装 $pkg 失败，尝试从PPA安装..."
                add-apt-repository -y ppa:certbot/certbot > /dev/null 2>&1
                apt-get update > /dev/null 2>&1
                apt-get install -y "$pkg" || error_exit "安装 $pkg 失败"
            fi
            log "INFO" "已安装: $pkg"
        else
            log "INFO" "已存在: $pkg"
        fi
    done
}

# 加载配置
load_config() {
    log "INFO" "正在加载配置..."
    
    # 获取脚本所在目录
    local script_dir
    script_dir=$(dirname "$(readlink -f "$0")")
    local env_file="${script_dir}/.env"
    
    if [ -f "$env_file" ]; then
        log "INFO" "检测到本地.env文件，加载环境变量"
        set -o allexport
        source "$env_file" || log "WARNING" "加载.env文件时遇到错误，继续执行..."
        set +o allexport
    else
        log "WARNING" "未找到配置文件 ${env_file}，将使用手动输入"
    fi
    
    # 获取Cloudflare API Token
    while [ -z "${CFAPI:-}" ] || [ ${#CFAPI} -lt 40 ]; do
        read -sp "请输入Cloudflare API Token: " CFAPI
        echo ""
        [ ${#CFAPI} -lt 40 ] && log "WARNING" "Token长度不足40字符!"
    done
    
    # 获取邮箱
    while [[ ! "${EMAIL_USER:-}" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do
        read -p "请输入管理员邮箱: " EMAIL_USER
    done
    
    # 获取域名
    while [ -z "${DOMAINS:-}" ]; do
        read -p "请输入域名(多个用空格分隔): " DOMAINS
        [ -z "$DOMAINS" ] && log "WARNING" "域名不能为空!"
    done
}

# 备份配置
backup_config() {
    log "INFO" "正在备份现有证书配置..."
    
    mkdir -p "$BACKUP_DIR"
    local backup_name="letsencrypt_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    
    if [ -d "$CONFIG_DIR" ]; then
        if tar -czf "${BACKUP_DIR}/${backup_name}" -C /etc letsencrypt > /dev/null 2>&1; then
            log "SUCCESS" "配置已备份到: ${BACKUP_DIR}/${backup_name}"
        else
            log "WARNING" "配置备份失败"
        fi
    else
        log "INFO" "未找到现有证书配置，跳过备份"
    fi
}

# 申请证书
request_certificates() {
    log "INFO" "正在申请证书..."
    
    local cred_dir="/root/.secrets/certbot"
    local cred_file="${cred_dir}/cloudflare.ini"
    
    mkdir -p "$cred_dir"
    umask 077
    cat > "$cred_file" <<EOF
dns_cloudflare_api_token = ${CFAPI}
EOF
    
    IFS=' ' read -ra DOMAIN_ARRAY <<< "$DOMAINS"
    
    # 添加成功/失败计数器
    local success_count=0
    local fail_count=0
    
    for domain in "${DOMAIN_ARRAY[@]}"; do
        log "INFO" "正在处理域名: $domain"
        
        # 显示实时输出
        if certbot certonly \
            --dns-cloudflare \
            --dns-cloudflare-credentials "$cred_file" \
            --email "$EMAIL_USER" \
            --agree-tos \
            --non-interactive \
            --keep-until-expiring \
            -d "$domain"; then
            
            log "SUCCESS" "✓ $domain 证书申请成功"
            ((success_count++))
            
            # 显示证书详细信息
            local cert_dir="/etc/letsencrypt/live/$domain"
            if [ -d "$cert_dir" ]; then
                log "INFO" "证书保存路径: $cert_dir/"
                log "INFO" "包含以下文件:"
                ls -l "$cert_dir" | tee -a "$LOG_FILE"
                
                local cert_path="$cert_dir/cert.pem"
                if [ -f "$cert_path" ]; then
                    local expire_date=$(openssl x509 -in "$cert_path" -noout -enddate | cut -d= -f2)
                    log "INFO" "证书有效期至: $expire_date"
                fi
            else
                log "WARNING" "证书目录未生成: $cert_dir"
            fi
        else
            log "ERROR" "✗ $domain 证书申请失败！可能原因:"
            log "ERROR" "1. 域名DNS解析未指向本服务器"
            log "ERROR" "2. Cloudflare Token权限不足"
            log "ERROR" "3. 域名在Cloudflare未启用代理(橙色云图标)"
            log "ERROR" "4. 证书已达到每周申请限制"
            ((fail_count++))
        fi
    done
    
    shred -u "$cred_file" 2>/dev/null || rm -f "$cred_file"
    
    # 显示最终结果
    log "INFO" "--------------------------------------------"
    log "SUCCESS" "成功申请证书域名数: $success_count"
    [ $fail_count -gt 0 ] && log "ERROR" "失败域名数: $fail_count"
    log "INFO" "详细日志请查看: $LOG_FILE"
    
    # 如果全部失败则退出
    [ $fail_count -gt 0 ] && [ $success_count -eq 0 ] && error_exit "所有域名申请失败，请检查错误日志"
}

# 配置自动续签
setup_renewal() {
    log "INFO" "正在配置自动续签..."
    
    local renew_script="/usr/local/bin/certbot_renew.sh"
    
    cat > "$renew_script" <<EOF
#!/bin/bash
exec > >(tee -a "$LOG_FILE") 2>&1
if certbot renew --noninteractive --quiet; then
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - 证书续签成功"
else
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - 证书续签失败"
fi
EOF
    
    chmod 750 "$renew_script"
    local cron_job="0 3 */$CHECK_INTERVAL * * $renew_script"
    if ! crontab -l | grep -q "$renew_script"; then
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        log "SUCCESS" "自动续签已配置，计划任务: $cron_job"
    else
        log "INFO" "自动续签任务已存在，跳过配置"
    fi
}

# 主执行流程
main() {
    init_log
    check_system
    install_dependencies
    load_config
    backup_config
    request_certificates
    setup_renewal
    
    # 最终状态提示
    log "SUCCESS" "SSL证书管理完成！"
    echo -e "\n${GREEN}=== 操作结果 ===${NC}"
    echo -e "证书保存路径: /etc/letsencrypt/live/YOUR_DOMAIN/"
    echo -e "续签日志文件: $LOG_FILE"
    echo -e "手动测试续签: certbot renew --dry-run"
    echo -e "${GREEN}=================================${NC}"
}

if [ "$(id -u)" = "0" ]; then
    main "$@"
else
    echo -e "${RED}错误：必须使用root用户执行此脚本${NC}" >&2
    exit 1
fi