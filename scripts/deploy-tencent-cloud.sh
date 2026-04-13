#!/usr/bin/env bash
# ===================================
# 腾讯云 Docker 部署脚本
# ===================================
# 适用系统：Ubuntu 20.04+ / Debian 11+ / CentOS 7+
# 使用方式：
#   1. 将本仓库上传到服务器 /opt/daily_stock_analysis
#   2. bash scripts/deploy-tencent-cloud.sh
#
# 本脚本会自动完成：
#   - 安装 Docker & Docker Compose（如未安装）
#   - 创建 .env 配置文件（交互式引导）
#   - 构建 Docker 镜像
#   - 启动服务（定时分析 + Web UI）
# ===================================

set -euo pipefail

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
prompt() { echo -ne "${CYAN}[INPUT]${NC} $*"; }

# ---------- 项目路径 ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

info "项目目录: $PROJECT_DIR"

# ===================================
# 1. 检查操作系统
# ===================================
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    info "操作系统: $NAME $VERSION"
else
    warn "无法识别操作系统，继续执行..."
fi

# ===================================
# 2. 安装 Docker（如未安装）
# ===================================
install_docker() {
    if command -v docker &>/dev/null; then
        info "Docker 已安装: $(docker --version)"
        return
    fi

    warn "未检测到 Docker，开始安装..."

    # 使用国内镜像加速（腾讯云）
    if [[ "$ID" == "centos" ]]; then
        sudo yum install -y yum-utils
        sudo yum-config-manager --add-repo https://mirrors.cloud.tencent.com/docker-ce/linux/centos/docker-ce.repo
        sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        sudo apt-get update
        sudo apt-get install -y ca-certificates curl gnupg
        # 使用腾讯云镜像
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://mirrors.cloud.tencent.com/docker-ce/linux/ubuntu/gpg | \
            sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
            https://mirrors.cloud.tencent.com/docker-ce/linux/ubuntu \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
            sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    fi

    sudo systemctl start docker
    sudo systemctl enable docker
    info "Docker 安装完成: $(docker --version)"
}

install_docker

# 检查 docker compose 命令
if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    error "未找到 docker compose 或 docker-compose，请手动安装"
fi

info "使用 Compose 命令: $COMPOSE_CMD"

# ===================================
# 3. 配置 Docker 镜像加速（国内网络）
# ===================================
setup_docker_mirror() {
    local daemon_json="/etc/docker/daemon.json"
    if [[ -f "$daemon_json" ]] && grep -q "registry-mirrors" "$daemon_json"; then
        info "Docker 镜像加速已配置，跳过"
        return
    fi

    warn "配置 Docker 镜像加速（国内网络拉取更快）..."
    sudo mkdir -p /etc/docker
    sudo tee "$daemon_json" > /dev/null <<'EOF'
{
    "registry-mirrors": [
        "https://mirror.ccs.tencentyun.com"
    ],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    }
}
EOF
    sudo systemctl daemon-reload
    sudo systemctl restart docker
    info "Docker 镜像加速配置完成"
}

setup_docker_mirror

# ===================================
# 4. 交互式配置 .env
# ===================================
setup_env() {
    if [[ -f .env ]]; then
        warn "检测到已有 .env 文件"
        read -p "是否要重新配置？(y/N): " overwrite
        if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            info "保留现有 .env 配置"
            return
        fi
        cp .env ".env.bak.$(date +%Y%m%d%H%M%S)"
        info "已备份现有 .env"
    fi

    cp .env.example .env
    info "已从 .env.example 创建 .env"

    echo ""
    info "========== 开始配置 =========="
    echo ""

    # --- 自选股列表 ---
    prompt "请输入自选股列表（逗号分隔，如 600519,300750,002594）: "
    read -r stock_list
    if [[ -n "$stock_list" ]]; then
        sed -i.bak "s/^STOCK_LIST=.*/STOCK_LIST=$stock_list/" .env
    fi

    # --- 智谱 API ---
    echo ""
    info "--- 智谱 GLM 模型配置 ---"
    prompt "请输入智谱 API Key（从 https://open.bigmodel.cn 获取，留空跳过）: "
    read -r zhipu_key
    if [[ -n "$zhipu_key" ]]; then
        # 使用多渠道模式配置智谱
        sed -i.bak "s/^# LLM_CHANNELS=.*/LLM_CHANNELS=zhipu/" .env
        sed -i.bak "/^# LLM_CHANNELS=/a\\
LLM_ZHIPU_API_KEY=$zhipu_key\\
LLM_ZHIPU_BASE_URL=https://open.bigmodel.cn/api/paas/v4\\
LLM_ZHIPU_MODELS=glm-4-flash\\
LLM_ZHIPU_PROTOCOL=openai" .env
        info "智谱 GLM-4-Flash 已配置"

        prompt "是否使用 glm-4-plus（效果更好但更贵）？(y/N): "
        read -r use_plus
        if [[ "$use_plus" == "y" || "$use_plus" == "Y" ]]; then
            sed -i.bak "s/LLM_ZHIPU_MODELS=.*/LLM_ZHIPU_MODELS=glm-4-plus/" .env
            info "已切换为 glm-4-plus"
        fi
    fi

    # --- 搜索引擎 ---
    echo ""
    info "--- 搜索引擎配置（用于获取股票新闻）---"
    prompt "请输入搜索引擎 API Key（Tavily/Anspire 等，留空跳过）: "
    read -r search_key
    if [[ -n "$search_key" ]]; then
        prompt "是哪种搜索引擎？(1=Tavily 2=Anspire 3=SerpAPI): "
        read -r search_type
        case "$search_type" in
            1) sed -i.bak "s/^TAVILY_API_KEYS=.*/TAVILY_API_KEYS=$search_key/" .env ;;
            2) sed -i.bak "s/^ANSPIRE_API_KEYS=.*/ANSPIRE_API_KEYS=$search_key/" .env ;;
            3) sed -i.bak "s/^SERPAPI_API_KEYS=.*/SERPAPI_API_KEYS=$search_key/" .env ;;
            *) warn "未识别，跳过" ;;
        esac
    fi

    # --- 通知渠道 ---
    echo ""
    info "--- 通知渠道配置（可选）---"
    prompt "请输入企业微信 Webhook URL（留空跳过）: "
    read -r wechat_webhook
    if [[ -n "$wechat_webhook" ]]; then
        sed -i.bak "s|^# WECHAT_WEBHOOK_URL=.*|WECHAT_WEBHOOK_URL=$wechat_webhook|" .env
    fi

    prompt "请输入 Telegram Bot Token（留空跳过）: "
    read -r tg_token
    if [[ -n "$tg_token" ]]; then
        sed -i.bak "s/^# TELEGRAM_BOT_TOKEN=.*/TELEGRAM_BOT_TOKEN=$tg_token/" .env
        prompt "请输入 Telegram Chat ID: "
        read -r tg_chat
        sed -i.bak "s/^# TELEGRAM_CHAT_ID=.*/TELEGRAM_CHAT_ID=$tg_chat/" .env
    fi

    prompt "请输入 PushPlus Token（留空跳过）: "
    read -r pushplus_token
    if [[ -n "$pushplus_token" ]]; then
        sed -i.bak "s/^# PUSHPLUS_TOKEN=.*/PUSHPLUS_TOKEN=$pushplus_token/" .env
    fi

    # --- Web UI 配置 ---
    echo ""
    info "--- Web UI 配置 ---"

    prompt "是否开启登录密码保护？强烈建议公网部署开启 (Y/n): "
    read -r enable_auth
    if [[ "$enable_auth" != "n" && "$enable_auth" != "N" ]]; then
        sed -i.bak "s/^ADMIN_AUTH_ENABLED=.*/ADMIN_AUTH_ENABLED=true/" .env
        info "已开启登录密码保护（首次访问网页时设置密码）"
    fi

    prompt "API 端口（默认 8000，直接回车使用默认）: "
    read -r api_port
    if [[ -n "$api_port" ]]; then
        sed -i.bak "s/^WEBUI_PORT=.*/WEBUI_PORT=$api_port/" .env
        sed -i.bak "s/^# API_PORT=.*/API_PORT=$api_port/" .env
    fi

    # --- 定时任务 ---
    echo ""
    info "--- 定时分析配置 ---"
    sed -i.bak "s/^SCHEDULE_ENABLED=.*/SCHEDULE_ENABLED=true/" .env

    prompt "每日分析时间（默认 18:00，格式 HH:MM）: "
    read -r schedule_time
    if [[ -n "$schedule_time" ]]; then
        sed -i.bak "s/^SCHEDULE_TIME=.*/SCHEDULE_TIME=$schedule_time/" .env
    fi

    # 清理 .env.bak 文件
    rm -f .env.bak

    echo ""
    info "========== 配置完成 =========="
    echo ""
    warn "重要：请检查 .env 文件确认配置正确"
    warn "  cat $PROJECT_DIR/.env"
}

setup_env

# ===================================
# 5. 创建数据目录
# ===================================
mkdir -p data logs reports strategies
info "数据目录已就绪"

# ===================================
# 6. 构建 & 启动
# ===================================
echo ""
info "开始构建 Docker 镜像（首次构建约需 5-10 分钟）..."
$COMPOSE_CMD -f docker/docker-compose.yml build

echo ""
info "启动服务..."
$COMPOSE_CMD -f docker/docker-compose.yml up -d analyzer server

echo ""
info "等待服务启动..."
sleep 5

# ===================================
# 7. 检查服务状态
# ===================================
echo ""
info "========== 服务状态 =========="
$COMPOSE_CMD -f docker/docker-compose.yml ps

echo ""
info "========== 部署完成 =========="
echo ""
info "访问地址："
# 获取公网 IP
PUBLIC_IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo "<你的服务器公网IP>")
PORT=$(grep -E "^(API_PORT|WEBUI_PORT)=" .env 2>/dev/null | head -1 | cut -d= -f2)
PORT=${PORT:-8000}
echo "  Web UI:  http://$PUBLIC_IP:$PORT"
echo ""
info "常用管理命令："
echo "  查看日志:       $COMPOSE_CMD -f docker/docker-compose.yml logs -f"
echo "  查看分析日志:   tail -f logs/stock_analysis_*.log"
echo "  重启服务:       $COMPOSE_CMD -f docker/docker-compose.yml restart"
echo "  停止服务:       $COMPOSE_CMD -f docker/docker-compose.yml down"
echo "  重建镜像:       $COMPOSE_CMD -f docker/docker-compose.yml up -d --build"
echo ""
warn "部署后注意事项："
echo "  1. 腾讯云安全组需要放行 TCP $PORT 端口"
echo "  2. 服务器防火墙需要放行 $PORT 端口"
echo "  3. 建议开启 ADMIN_AUTH_ENABLED=true 保护 Web 界面"
echo "  4. 建议配置 Nginx 反向代理 + HTTPS"
echo ""
info "详细文档: docs/deploy-webui-cloud.md"
