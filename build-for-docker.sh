#!/bin/bash
# Sub2API 本地编译脚本 - 用于 Docker 纯运行时部署
# 功能: 在本地编译后端和前端，输出可直接在 Docker 中运行的文件
#
# 使用方式:
#   ./build-for-docker.sh              # 编译后端+前端
#   ./build-for-docker.sh backend     # 仅编译后端
#   ./build-for-docker.sh frontend    # 仅编译前端
#   ./build-for-docker.sh clean       # 清理编译产物

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build"
BINARY_NAME="sub2api"
TARGET_OS="${TARGET_OS:-linux}"
TARGET_ARCH="${TARGET_ARCH:-amd64}"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 创建编译输出目录
create_build_dir() {
    log_info "创建编译输出目录: ${BUILD_DIR}"
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}/data/public"
}

# 编译后端 (带前端嵌入)
build_backend() {
    log_info "开始编译后端 (目标: ${TARGET_OS}/${TARGET_ARCH})"
    
    cd "${PROJECT_ROOT}/backend"
    
    # 检查 Go 是否安装
    if ! command -v go &> /dev/null; then
        log_error "Go 未安装或不在 PATH 中"
        log_info "请安装 Go 1.21+ 或从 https://golang.org/dl/ 下载"
        exit 1
    fi
    
    # 检查 Go 版本
    GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
    log_info "Go 版本: ${GO_VERSION}"
    
    # 编译 (启用 embed，将前端嵌入二进制)
    log_info "编译中... (这可能需要几分钟)"
    GOOS=${TARGET_OS} GOARCH=${TARGET_ARCH} go build \
        -tags embed \
        -ldflags="-w -s" \
        -o "${BUILD_DIR}/${BINARY_NAME}" \
        ./cmd/server
    
    if [ -f "${BUILD_DIR}/${BINARY_NAME}" ]; then
        local size=$(du -h "${BUILD_DIR}/${BINARY_NAME}" | cut -f1)
        log_info "✅ 后端编译成功: ${BUILD_DIR}/${BINARY_NAME} (${size})"
    else
        log_error "后端编译失败"
        exit 1
    fi
    
    cd "${PROJECT_ROOT}"
}

# 编译前端
build_frontend() {
    log_info "开始编译前端"
    
    cd "${PROJECT_ROOT}/frontend"
    
    # 检查 pnpm 是否安装
    if ! command -v pnpm &> /dev/null; then
        log_warn "pnpm 未安装，尝试使用 npm"
        if ! command -v npm &> /dev/null; then
            log_error "npm 也未安装，请安装 Node.js 18+"
            exit 1
        fi
        PACKAGE_MANAGER="npm"
        INSTALL_CMD="npm install"
        BUILD_CMD="npm run build"
    else
        PACKAGE_MANAGER="pnpm"
        INSTALL_CMD="pnpm install"
        BUILD_CMD="pnpm run build"
    fi
    
    log_info "使用 ${PACKAGE_MANAGER} 作为包管理器"
    
    # 安装依赖
    if [ ! -d "node_modules" ]; then
        log_info "安装前端依赖 (这可能需要几分钟)..."
        ${INSTALL_CMD}
    else
        log_info "前端依赖已存在，跳过安装"
    fi
    
    # 编译
    log_info "编译前端中..."
    ${BUILD_CMD}
    
    # 复制到编译输出目录
    if [ -d "dist" ]; then
        cp -r dist/* "${BUILD_DIR}/data/public/"
        local file_count=$(find "${BUILD_DIR}/data/public" -type f | wc -l)
        log_info "✅ 前端编译成功: ${file_count} 个文件已复制到 ${BUILD_DIR}/data/public/"
    else
        log_error "前端编译失败: dist/ 目录不存在"
        exit 1
    fi
    
    cd "${PROJECT_ROOT}"
}

# 创建 Docker 相关文件
create_docker_files() {
    log_info "创建 Docker 运行时文件..."
    
    # 创建最小 Dockerfile
    cat > "${BUILD_DIR}/Dockerfile" << 'EOF'
# Sub2API 最小运行时 Dockerfile
# 仅用于运行预编译的二进制文件
FROM alpine:3.20

# 安装运行时依赖
RUN apk add --no-cache \
    ca-certificates \
    tzdata \
    libstdc++

# 设置时区
ENV TZ=Asia/Shanghai

# 创建非 root 用户
RUN addgroup -g 1000 sub2api && \
    adduser -D -u 1000 -G sub2api sub2api

WORKDIR /app

# 复制预编译的二进制文件
COPY sub2api /app/sub2api
RUN chmod +x /app/sub2api

# 创建数据目录
RUN mkdir -p /app/data && \
    chown -R sub2api:sub2api /app

USER sub2api

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q -T 5 -O /dev/null http://localhost:8080/health || exit 1

ENTRYPOINT ["/app/sub2api"]
EOF
    
    # 创建 .dockerignore
    cat > "${BUILD_DIR}/.dockerignore" << 'EOF'
*.md
*.log
.git
.gitignore
node_modules
*.sh
Dockerfile.goreleaser
EOF
    
    # 创建 docker-compose.yml
    cat > "${BUILD_DIR}/docker-compose.yml" << 'EOF'
version: '3.8'

services:
  sub2api:
    build: .
    container_name: sub2api-local
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - ./data:/app/data
    environment:
      - TZ=Asia/Shanghai
      - SERVER_MODE=release
      - DATABASE_HOST=postgres
      - DATABASE_PORT=5432
      - DATABASE_USER=sub2api
      - DATABASE_PASSWORD=changeme
      - DATABASE_DBNAME=sub2api
      - REDIS_HOST=redis
      - REDIS_PORT=6379
    networks:
      - sub2api-net
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
    healthcheck:
      test: ["CMD", "wget", "-q", "-T", "5", "-O", "/dev/null", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  postgres:
    image: pgvector/pgvector:pg17-v0.8.0
    container_name: sub2api-postgres
    restart: unless-stopped
    ports:
      - "5432:5432"
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
    environment:
      - POSTGRES_USER=sub2api
      - POSTGRES_PASSWORD=changeme
      - POSTGRES_DB=sub2api
      - TZ=Asia/Shanghai
    networks:
      - sub2api-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U sub2api"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:8-alpine
    container_name: sub2api-redis
    restart: unless-stopped
    ports:
      - "6379:6379"
    volumes:
      - ./redis_data:/data
    networks:
      - sub2api-net
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5

networks:
  sub2api-net:
    driver: bridge

volumes:
  postgres_data:
  redis_data:
EOF
    
    # 创建快速启动脚本 (不使用 Docker 编译，直接用本地二进制)
    cat > "${BUILD_DIR}/quick-start.yml" << 'EOF'
# 快速启动配置 - 直接使用本地编译的二进制，无需重新构建 Docker 镜像
version: '3.8'

services:
  sub2api:
    image: alpine:3.20
    container_name: sub2api-local
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - ./sub2api:/app/sub2api:ro
      - ./data:/app/data
    environment:
      - TZ=Asia/Shanghai
      - SERVER_MODE=release
      - DATABASE_HOST=postgres
      - DATABASE_PORT=5432
      - DATABASE_USER=sub2api
      - DATABASE_PASSWORD=changeme
      - DATABASE_DBNAME=sub2api
      - REDIS_HOST=redis
      - REDIS_PORT=6379
    networks:
      - sub2api-net
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
    command: ["/app/sub2api"]
    # 使用自定义入口点，安装依赖并运行
    entrypoint: ["/bin/sh", "-c"]
    command: >
      apk add --no-cache ca-certificates tzdata &&
      /app/sub2api

  postgres:
    image: pgvector/pgvector:pg17-v0.8.0
    container_name: sub2api-postgres
    restart: unless-stopped
    ports:
      - "5432:5432"
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
    environment:
      - POSTGRES_USER=sub2api
      - POSTGRES_PASSWORD=changeme
      - POSTGRES_DB=sub2api
    networks:
      - sub2api-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U sub2api"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:8-alpine
    container_name: sub2api-redis
    restart: unless-stopped
    ports:
      - "6379:6379"
    volumes:
      - ./redis_data:/data
    networks:
      - sub2api-net

networks:
  sub2api-net:
    driver: bridge
EOF
    
    log_info "✅ Docker 文件已创建"
}

# 显示使用说明
show_usage() {
    echo ""
    log_info "===== 编译完成 ====="
    echo ""
    echo "编译输出目录: ${BUILD_DIR}"
    echo ""
    echo "📦 包含文件:"
    echo "  - sub2api           (后端二进制文件)"
    echo "  - data/public/       (前端静态文件)"
    echo "  - Dockerfile         (最小运行时镜像)"
    echo "  - docker-compose.yml (完整三服务配置)"
    echo "  - quick-start.yml    (快速启动配置)"
    echo ""
    echo "🚀 启动方式:"
    echo ""
    echo "方式 1: 使用 docker-compose (推荐)"
    echo "  cd ${BUILD_DIR}"
    echo "  docker compose up -d"
    echo ""
    echo "方式 2: 直接使用本地二进制 (无需 Docker 构建)"
    echo "  cd ${BUILD_DIR}"
    echo "  docker compose -f quick-start.yml up -d"
    echo ""
    echo "方式 3: 手动运行二进制 (开发调试)"
    echo "  cd ${BUILD_DIR}"
    echo "  ./sub2api"
    echo ""
    echo "📋 查看日志:"
    echo "  docker compose -f ${BUILD_DIR}/docker-compose.yml logs -f"
    echo ""
}

# 清理编译产物
clean_build() {
    log_info "清理编译产物..."
    rm -rf "${BUILD_DIR}"
    log_info "✅ 清理完成"
}

# 主函数
main() {
    local action="${1:-all}"
    
    case "${action}" in
        all)
            log_info "开始完整编译 (后端 + 前端)..."
            create_build_dir
            build_backend
            build_frontend
            create_docker_files
            show_usage
            ;;
        backend)
            log_info "仅编译后端..."
            create_build_dir
            build_backend
            create_docker_files
            show_usage
            ;;
        frontend)
            log_info "仅编译前端..."
            create_build_dir
            build_frontend
            show_usage
            ;;
        clean)
            clean_build
            ;;
        *)
            log_error "未知命令: ${action}"
            echo "用法: $0 [all|backend|frontend|clean]"
            exit 1
            ;;
    esac
}

main "$@"
