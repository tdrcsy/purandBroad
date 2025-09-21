#!/bin/bash
set -e

# ============================
# 交互式参数
# ============================
read -p "输入容器名称 (默认 KalDev): " CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-KalDev}

read -p "输入 code-server 密码 (默认 Kal1349..): " PASSWORD
PASSWORD=${PASSWORD:-Kal1349..}

read -p "输入宿主机端口 (默认 8080): " DEFAULT_PORT
DEFAULT_PORT=${DEFAULT_PORT:-8080}

read -p "输入项目目录 (默认 /home/kal/dev): " PROJECT_DIR
PROJECT_DIR=${PROJECT_DIR:-/home/kal/dev}

read -p "输入配置目录 (默认 /home/kal/dev-config): " CONFIG_DIR
CONFIG_DIR=${CONFIG_DIR:-/home/kal/dev-config}

read -p "输入域名 (默认 dev.930009.xyz): " DOMAIN_NAME
DOMAIN_NAME=${DOMAIN_NAME:-dev.930009.xyz}

read -p "输入 Cloudflare 隧道名称 (默认 KalDevTunnel): " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME:-KalDevTunnel}

TUNNEL_DIR="/root/.cloudflared"
TUNNEL_FILE="$TUNNEL_DIR/$TUNNEL_NAME.json"
CONFIG_FILE="/etc/cloudflared/config.yml"
CODE_SERVER_IMAGE="codercom/code-server:latest"
CUSTOM_WELCOME="Welcome back $CONTAINER_NAME, enter your PASSWORD to log in."

# ============================
# 依赖检查
# ============================
echo "[INFO] 检查依赖..."
for cmd in docker cloudflared lsof; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "[ERROR] $cmd 未安装，请先安装"
        exit 1
    fi
done

# ============================
# 创建目录并处理权限
# ============================
echo "[INFO] 创建目录..."
mkdir -p "$PROJECT_DIR" "$CONFIG_DIR/share/code-server/extensions"
chmod -R 755 "$PROJECT_DIR" "$CONFIG_DIR"
touch "$CONFIG_DIR/share/code-server/extensions/extensions.json"

# ============================
# 检查端口
# ============================
check_port() {
    local port=$1
    local max_port=$((port+100))
    while [ $port -le $max_port ]; do
        OCCUPIED=$(lsof -i:$port -t || true)
        if [ -z "$OCCUPIED" ]; then
            echo $port
            return 0
        fi

        DOCKER_CONTAINER=$(docker ps --filter "publish=$port" --format "{{.Names}}")
        if [ -n "$DOCKER_CONTAINER" ]; then
            echo "[INFO] 停止并删除占用端口 $port 的 Docker 容器 $DOCKER_CONTAINER ..."
            docker stop $DOCKER_CONTAINER
            docker rm $DOCKER_CONTAINER
            echo "[INFO] 端口 $port 已释放"
            echo $port
            return 0
        fi

        echo "[WARN] 端口 $port 被非 Docker 进程占用，尝试下一个端口"
        port=$((port+1))
    done
    echo "[ERROR] 没有可用端口" >&2
    exit 1
}

HOST_PORT=$(check_port $DEFAULT_PORT)
echo "[INFO] 使用端口 $HOST_PORT"

# ============================
# 停止并删除旧容器
# ============================
EXISTING_CONTAINER=$(docker ps -a -q -f name=$CONTAINER_NAME)
if [ -n "$EXISTING_CONTAINER" ]; then
    echo "[INFO] 停止并删除已有容器 $CONTAINER_NAME ..."
    docker stop $CONTAINER_NAME
    docker rm $CONTAINER_NAME
fi

# ============================
# 拉取镜像
# ============================
echo "[INFO] 拉取最新 code-server 镜像..."
docker pull $CODE_SERVER_IMAGE

# ============================
# 启动容器
# ============================
echo "[INFO] 启动容器 $CONTAINER_NAME ..."
docker run -d \
  --name $CONTAINER_NAME \
  --restart unless-stopped \
  -p $HOST_PORT:8080 \
  -e PASSWORD="$PASSWORD" \
  -e CUSTOM_WELCOME_MESSAGE="$CUSTOM_WELCOME" \
  -v "$PROJECT_DIR":/home/coder/projects \
  -v "$CONFIG_DIR":/home/coder/.local \
  $CODE_SERVER_IMAGE

# ============================
# Cloudflare 隧道
# ============================
mkdir -p "$TUNNEL_DIR"
if [ ! -f "$TUNNEL_FILE" ]; then
    echo "[INFO] Tunnel 文件不存在，创建隧道 $TUNNEL_NAME ..."
    cloudflared tunnel create $TUNNEL_NAME
else
    echo "[INFO] 使用隧道: $(basename $TUNNEL_FILE .json) ($TUNNEL_FILE)"
fi

# 创建 config.yml
mkdir -p "$(dirname $CONFIG_FILE)"
cat > $CONFIG_FILE <<EOF
tunnel: $(basename $TUNNEL_FILE .json)
credentials-file: $TUNNEL_FILE

ingress:
  - hostname: $DOMAIN_NAME
    service: http://localhost:$HOST_PORT
  - service: http_status:404
EOF

# 重启隧道服务
if systemctl list-unit-files | grep -q cloudflared; then
    echo "[INFO] 重启 cloudflared 隧道服务..."
    systemctl restart cloudflared
    systemctl enable cloudflared
else
    echo "[WARN] cloudflared systemd 服务未安装，跳过重启"
fi

# ============================
# 完成信息
# ============================
echo "========================================="
echo "✅ code-server 部署/升级完成!"
echo "容器名称: $CONTAINER_NAME"
echo "项目目录: $PROJECT_DIR"
echo "配置目录: $CONFIG_DIR"
echo "访问地址: https://$DOMAIN_NAME"
echo "宿主机端口: $HOST_PORT"
echo "欢迎信息: $CUSTOM_WELCOME"
echo "========================================="
