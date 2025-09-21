#!/bin/bash
set -e

# ============================
# 配置区（可修改）
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
CLOUDFLARED_SERVICE="/etc/systemd/system/cloudflared.service"

# ============================
# 检查依赖
# ============================
echo "[INFO] 检查系统依赖..."
for cmd in docker cloudflared lsof; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "[ERROR] 未找到 $cmd，请先安装"
        exit 1
    fi
done

# ============================
# 创建目录 + 权限
# ============================
echo "[INFO] 创建并设置项目/配置目录..."
mkdir -p "$PROJECT_DIR" "$CONFIG_DIR"
chown -R 1000:1000 "$PROJECT_DIR" "$CONFIG_DIR"

# ============================
# 检查磁盘空间
# ============================
AVAILABLE=$(df "$PROJECT_DIR" | tail -1 | awk '{print $4}')
if [ "$AVAILABLE" -lt 1048576 ]; then
    echo "[WARN] 磁盘剩余空间 < 1GB，可能导致失败"
fi

# ============================
# 端口检测与释放
# ============================
check_port() {
    local port=$1
    local max_port=$((port+100))
    while [ $port -le $max_port ]; do
        OCCUPIED=$(lsof -i:$port -t || true)
        if [ -z "$OCCUPIED" ]; then
            echo $port
            return
        fi
        # 检查是否 Docker 容器占用
        DOCKER_CONTAINER=$(docker ps --filter "publish=$port" --format "{{.Names}}")
        if [ -n "$DOCKER_CONTAINER" ]; then
            echo "[INFO] 端口 $port 被容器 $DOCKER_CONTAINER 占用，正在停止并删除..."
            docker stop $DOCKER_CONTAINER >/dev/null 2>&1 || true
            docker rm $DOCKER_CONTAINER >/dev/null 2>&1 || true
            echo $port
            return
        fi
        port=$((port+1))
    done
    echo "[ERROR] 未找到可用端口"
    exit 1
}
HOST_PORT=$(check_port $DEFAULT_PORT)
echo "[INFO] 使用端口: $HOST_PORT"

# ============================
# 停止旧容器
# ============================
if docker ps -a --format "{{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
    echo "[INFO] 删除已有容器 $CONTAINER_NAME ..."
    docker rm -f $CONTAINER_NAME >/dev/null 2>&1 || true
fi

# ============================
# 拉取镜像并启动容器
# ============================
echo "[INFO] 拉取最新镜像..."
docker pull $CODE_SERVER_IMAGE

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
# 配置 Cloudflare Tunnel
# ============================
TUNNEL_ID_FILE="/root/.cloudflared/${TUNNEL_NAME}.json"
if [ ! -f "$TUNNEL_ID_FILE" ]; then
    echo "[INFO] 创建 Cloudflare Tunnel $TUNNEL_NAME ..."
    cloudflared tunnel create $TUNNEL_NAME
    TUNNEL_ID_FILE=$(ls /root/.cloudflared/*.json | grep $TUNNEL_NAME | head -n 1)
fi
TUNNEL_ID=$(basename "$TUNNEL_ID_FILE" .json)

CONFIG_FILE="/etc/cloudflared/config.yml"
echo "[INFO] 生成 Cloudflare 配置文件..."
mkdir -p /etc/cloudflared
cat > $CONFIG_FILE <<EOF
tunnel: $TUNNEL_ID
credentials-file: $TUNNEL_ID_FILE

ingress:
  - hostname: $DOMAIN_NAME
    service: http://localhost:$HOST_PORT
  - service: http_status:404
EOF

# ============================
# 配置 systemd 自启动
# ============================
if [ ! -f "$CLOUDFLARED_SERVICE" ]; then
    echo "[INFO] 配置 cloudflared systemd 服务..."
    cat > $CLOUDFLARED_SERVICE <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
TimeoutStartSec=0
Type=notify
ExecStart=/usr/bin/cloudflared --config $CONFIG_FILE --no-autoupdate tunnel run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reexec
    systemctl enable cloudflared
fi

echo "[INFO] 重启 cloudflared ..."
systemctl restart cloudflared

# ============================
# 输出结果
# ============================
echo "====================================================="
echo " ✅ DevSpace 部署完成!"
echo " 容器名称: $CONTAINER_NAME"
echo " 项目目录: $PROJECT_DIR"
echo " 配置目录: $CONFIG_DIR"
echo " 访问地址: https://$DOMAIN_NAME"
echo " 宿主机端口: $HOST_PORT"
echo "====================================================="
