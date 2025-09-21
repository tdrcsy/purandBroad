#!/bin/bash
set -e

# ============================
# 交互输入
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

CUSTOM_WELCOME="Welcome back, this is your DevSpace, please enter your PASSWORD below to log in."
CODE_SERVER_IMAGE="codercom/code-server:latest"

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
chown -R 1000:1000 "$PROJECT_DIR" "$CONFIG_DIR"

# ============================
# 端口检查
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
      echo $port
      return 0
    fi
    echo "[WARN] 端口 $port 被占用，尝试下一个"
    port=$((port+1))
  done
  echo "[ERROR] 没有可用端口" >&2
  exit 1
}

HOST_PORT=$(check_port $DEFAULT_PORT)
echo "[INFO] 使用端口 $HOST_PORT"

# ============================
# 停止旧容器
# ============================
EXISTING=$(docker ps -a -q -f name=$CONTAINER_NAME)
if [ -n "$EXISTING" ]; then
  echo "[INFO] 停止并删除旧容器 $CONTAINER_NAME ..."
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
# Cloudflare Tunnel
# ============================
TUNNEL_FILE="/root/.cloudflared/$TUNNEL_NAME.json"
if [ ! -f "$TUNNEL_FILE" ]; then
  echo "[INFO] Cloudflare 隧道不存在，正在创建..."
  cloudflared tunnel create $TUNNEL_NAME
fi
echo "[INFO] 使用隧道: $TUNNEL_NAME ($TUNNEL_FILE)"

mkdir -p /etc/cloudflared
CONFIG_FILE="/etc/cloudflared/config.yml"
cat > $CONFIG_FILE <<EOF
tunnel: $TUNNEL_NAME
credentials-file: $TUNNEL_FILE

ingress:
  - hostname: $DOMAIN_NAME
    service: http://localhost:$HOST_PORT
  - service: http_status:404
EOF

# ============================
# 启动隧道
# ============================
if systemctl list-units --full -all | grep -q cloudflared; then
  systemctl restart cloudflared
  systemctl enable cloudflared
else
  nohup cloudflared tunnel run $TUNNEL_NAME >/var/log/cloudflared.log 2>&1 &
fi

# ============================
# 输出信息
# ============================
echo "========================================="
echo "✅ 部署完成!"
echo "容器名称: $CONTAINER_NAME"
echo "项目目录: $PROJECT_DIR"
echo "配置目录: $CONFIG_DIR"
echo "访问地址: https://$DOMAIN_NAME"
echo "宿主机端口: $HOST_PORT"
echo "Cloudflare 隧道: $TUNNEL_NAME"
echo "========================================="
