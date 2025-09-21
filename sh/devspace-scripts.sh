#!/bin/bash
set -e

# ============================
# 用户自定义变量
# ============================
CONTAINER_NAME="KalDev"
PASSWORD="Kal1349.."
DEFAULT_PORT=8080
PROJECT_DIR="/home/kal/dev"
CONFIG_DIR="/home/kal/dev-config"
CUSTOM_WELCOME="Welcome back Kal, this is your DevSpace, please enter your PASSWORD below to log in."
DOMAIN_NAME="dev.930009.xyz"
TUNNEL_NAME="KalDevTunnel"

CODE_SERVER_IMAGE="codercom/code-server:latest"

# ============================
# 1. 系统检查与依赖安装
# ============================
echo "[INFO] 检查系统依赖..."
for cmd in docker cloudflared lsof systemctl; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "[WARN] $cmd 未安装，正在安装..."
        if [ "$cmd" = "docker" ]; then
            curl -fsSL https://get.docker.com | sh
        elif [ "$cmd" = "cloudflared" ]; then
            wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /usr/local/bin/cloudflared
            chmod +x /usr/local/bin/cloudflared
        else
            apt-get update -qq
            apt-get install -y -qq $cmd
        fi
    fi
done

# ============================
# 2. 创建项目和配置目录
# ============================
echo "[INFO] 创建并设置项目/配置目录..."
mkdir -p "$PROJECT_DIR" "$CONFIG_DIR/share/code-server/extensions"
chmod -R 755 "$PROJECT_DIR" "$CONFIG_DIR"
touch "$CONFIG_DIR/share/code-server/extensions/extensions.json"
chown -R 1000:1000 "$PROJECT_DIR" "$CONFIG_DIR"

# ============================
# 3. 端口检测函数
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
        echo "[WARN] 端口 $port 被非 Docker 进程占用，尝试下一个端口"
        port=$((port+1))
    done
    echo "[ERROR] 没有可用端口" >&2
    exit 1
}

HOST_PORT=$(check_port $DEFAULT_PORT)
echo "[INFO] 使用端口 $HOST_PORT"

# ============================
# 4. 停止并删除旧容器
# ============================
EXISTING_CONTAINER=$(docker ps -a -q -f name=$CONTAINER_NAME)
if [ -n "$EXISTING_CONTAINER" ]; then
    echo "[INFO] 停止并删除已有容器 $CONTAINER_NAME ..."
    docker stop $CONTAINER_NAME
    docker rm $CONTAINER_NAME
fi

# ============================
# 5. 拉取最新 code-server 镜像
# ============================
echo "[INFO] 拉取最新 code-server 镜像..."
docker pull $CODE_SERVER_IMAGE

# ============================
# 6. 启动 code-server 容器
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
# 7. Cloudflare Tunnel
# ============================
TUNNEL_FILE="/root/.cloudflared/$TUNNEL_NAME.json"
if [ ! -f "$TUNNEL_FILE" ]; then
    echo "[INFO] 创建 Cloudflare 隧道 $TUNNEL_NAME ..."
    cloudflared tunnel create $TUNNEL_NAME
fi
echo "[INFO] 使用隧道: $TUNNEL_NAME ($TUNNEL_FILE)"

mkdir -p /etc/cloudflared
CONFIG_FILE="/etc/cloudflared/config.yml"
echo "[INFO] 更新 Cloudflare Tunnel 配置..."
cat > $CONFIG_FILE <<EOF
tunnel: $TUNNEL_NAME
credentials-file: $TUNNEL_FILE

ingress:
  - hostname: $DOMAIN_NAME
    service: http://localhost:$HOST_PORT
  - service: http_status:404
EOF

# ============================
# 8. 启动/重启 cloudflared 隧道
# ============================
if systemctl list-units --full -all | grep -q cloudflared; then
    echo "[INFO] 重启 cloudflared 服务..."
    systemctl restart cloudflared
    systemctl enable cloudflared
else
    echo "[INFO] 启动 cloudflared 隧道（nohup 后台运行）..."
    nohup cloudflared tunnel run $TUNNEL_NAME >/var/log/cloudflared.log 2>&1 &
fi

# ============================
# 9. 输出信息
# ============================
echo "========================================="
echo "✅ code-server 部署/升级完成!"
echo "容器名称: $CONTAINER_NAME"
echo "项目目录: $PROJECT_DIR"
echo "配置目录: $CONFIG_DIR"
echo "访问地址: https://$DOMAIN_NAME"
echo "宿主机端口: $HOST_PORT"
echo "欢迎信息: $CUSTOM_WELCOME"
echo "Cloudflare 隧道: $TUNNEL_NAME"
echo "========================================="
