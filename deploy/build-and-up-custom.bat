@echo off
setlocal enabledelayedexpansion

rem =============================================================================
rem Sub2API custom Docker build/start helper for Windows.
rem
rem This script builds the application with Docker build containers, then starts
rem deploy/docker-compose-custom.yml, which mounts backend/bin/server into the
rem runtime container instead of packaging application code into an image.
rem
rem Usage:
rem   build-and-up-custom.bat             rem build frontend/backend and start
rem   build-and-up-custom.bat build       rem build only
rem   build-and-up-custom.bat up          rem start only
rem   build-and-up-custom.bat restart     rem build and restart sub2api only
rem   build-and-up-custom.bat down        rem stop services
rem   build-and-up-custom.bat logs        rem follow sub2api logs
rem
rem Optional env:
rem   NODE_IMAGE=node:24-alpine
rem   PNPM_VERSION=9
rem   GOLANG_IMAGE=golang:1.26.4-alpine
rem   GOOS=linux
rem   GOARCH=amd64
rem   GOPROXY=https://goproxy.cn,direct
rem   GOSUMDB=sum.golang.google.cn
rem =============================================================================

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..") do set "REPO_ROOT=%%~fI"
set "COMPOSE_FILE=%SCRIPT_DIR%docker-compose-custom.yml"
set "COMPOSE_PROJECT_NAME=sub2api-custom"
set "ACTION=%~1"
if "%ACTION%"=="" set "ACTION=all"

if "%NODE_IMAGE%"=="" set "NODE_IMAGE=node:24-alpine"
if "%PNPM_VERSION%"=="" set "PNPM_VERSION=9"
if "%GOLANG_IMAGE%"=="" set "GOLANG_IMAGE=golang:1.26.4-alpine"
if "%GOOS%"=="" set "GOOS=linux"
if "%GOARCH%"=="" set "GOARCH=amd64"
if "%GOPROXY%"=="" set "GOPROXY=https://goproxy.cn,direct"
if "%GOSUMDB%"=="" set "GOSUMDB=sum.golang.google.cn"

call :require docker || exit /b 1

if /i "%ACTION%"=="all" (
    call :build_all || exit /b 1
    call :compose_up || exit /b 1
    exit /b 0
)
if /i "%ACTION%"=="build" (
    call :build_all || exit /b 1
    exit /b 0
)
if /i "%ACTION%"=="up" (
    call :compose_up || exit /b 1
    exit /b 0
)
if /i "%ACTION%"=="restart" (
    call :build_all || exit /b 1
    call :compose_restart_app || exit /b 1
    exit /b 0
)
if /i "%ACTION%"=="down" (
    docker compose -f "%COMPOSE_FILE%" down
    exit /b %ERRORLEVEL%
)
if /i "%ACTION%"=="logs" (
    docker compose -f "%COMPOSE_FILE%" logs -f sub2api
    exit /b %ERRORLEVEL%
)

echo Unknown action: %ACTION%
echo Usage: %~nx0 [all^|build^|up^|restart^|down^|logs]
exit /b 1

:build_all
echo [INFO] Ensuring output/data directories exist...
if not exist "%REPO_ROOT%\backend\bin" mkdir "%REPO_ROOT%\backend\bin"
if not exist "%REPO_ROOT%\deploy\data" mkdir "%REPO_ROOT%\deploy\data"
if not exist "%REPO_ROOT%\deploy\postgres_data" mkdir "%REPO_ROOT%\deploy\postgres_data"
if not exist "%REPO_ROOT%\deploy\redis_data" mkdir "%REPO_ROOT%\deploy\redis_data"

call :build_frontend || exit /b 1
call :build_backend || exit /b 1

echo [SUCCESS] Build finished: backend\bin\server
exit /b 0

:build_frontend
echo [INFO] Building frontend with %NODE_IMAGE%...
docker run --rm ^
  -e "PNPM_VERSION=%PNPM_VERSION%" ^
  -v "%REPO_ROOT%:/workspace" ^
  -w /workspace/frontend ^
  "%NODE_IMAGE%" ^
  sh -lc "corepack enable && corepack prepare pnpm@${PNPM_VERSION} --activate && pnpm install --frozen-lockfile && pnpm run build"
if errorlevel 1 (
    echo [ERROR] Frontend build failed.
    exit /b 1
)
exit /b 0

:build_backend
echo [INFO] Building backend Linux binary with %GOLANG_IMAGE%...
docker run --rm ^
  -e "GOOS=%GOOS%" ^
  -e "GOARCH=%GOARCH%" ^
  -e "CGO_ENABLED=0" ^
  -e "GOPROXY=%GOPROXY%" ^
  -e "GOSUMDB=%GOSUMDB%" ^
  -v "%REPO_ROOT%:/workspace" ^
  -w /workspace/backend ^
  "%GOLANG_IMAGE%" ^
  sh -lc "go build -tags embed -trimpath -ldflags='-s -w' -o bin/server ./cmd/server && chmod +x bin/server"
if errorlevel 1 (
    echo [ERROR] Backend build failed.
    exit /b 1
)
exit /b 0

:compose_up
echo [INFO] Starting custom compose deployment...
docker compose -f "%COMPOSE_FILE%" up -d
if errorlevel 1 exit /b 1
echo [SUCCESS] Started. View logs with: %~nx0 logs
exit /b 0

:compose_restart_app
echo [INFO] Restarting sub2api service with the new mounted binary...
docker compose -f "%COMPOSE_FILE%" up -d postgres redis
if errorlevel 1 exit /b 1
docker compose -f "%COMPOSE_FILE%" up -d --force-recreate sub2api
if errorlevel 1 exit /b 1
echo [SUCCESS] Restarted sub2api. View logs with: %~nx0 logs
exit /b 0

:require
where %~1 >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Required command not found: %~1
    exit /b 1
)
exit /b 0
