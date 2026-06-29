@echo off
goto :fixed_script
chcp 65001 >nul
setlocal enabledelayedexpansion

echo ====================================
echo 启动 SuperBizAgent 服务
echo ====================================
echo.

REM 检查 uv 是否安装（可选，如果没有会使用 pip）
echo [1/6] 检查包管理器...
where uv >nul 2>&1
if errorlevel 1 (
    echo [信息] uv 未安装，将使用传统 pip 方式
    echo [提示] 安装 uv 可提升速度：pip install uv
    set USE_UV=0
) else (
    echo [成功] 检测到 uv 包管理器
    set USE_UV=1
)
echo.

REM 确保 Python 版本正确
echo [2/6] 配置 Python 版本...
if exist .python-version (
    set /p PYTHON_VERSION=<.python-version
    echo [信息] 当前配置版本: !PYTHON_VERSION!
    
    REM 检查是否为 3.10（不兼容）
    echo !PYTHON_VERSION! | findstr /C:"3.10" >nul
    if not errorlevel 1 (
        echo [警告] Python 3.10 不兼容，自动更新到 3.13...
        echo 3.13> .python-version
        echo [成功] 已更新到 Python 3.13
    )
) else (
    echo [信息] 创建 .python-version 文件...
    echo 3.13> .python-version
)
echo.

REM 创建或同步虚拟环境
echo [3/6] 创建/同步虚拟环境...
if exist .venv\Scripts\python.exe (
    echo [信息] 虚拟环境已存在，检查更新...
    
    REM 如果有 uv，尝试使用 uv sync
    if "%USE_UV%"=="1" (
        uv sync 2>nul
        if errorlevel 1 (
            echo [警告] uv sync 失败，使用 pip 更新...
            .venv\Scripts\python.exe -m pip install -e . -q
        ) else (
            echo [成功] 使用 uv 同步完成
        )
    ) else (
        echo [信息] 使用 pip 更新依赖...
        .venv\Scripts\python.exe -m pip install -e . -q
    )
) else (
    echo [信息] 创建新的虚拟环境...
    
    REM 如果有 uv，尝试使用 uv sync
    if "%USE_UV%"=="1" (
        echo [信息] 尝试使用 uv sync 创建...
        uv sync 2>nul
        if not errorlevel 1 (
            echo [成功] 使用 uv 创建完成
            goto :venv_created
        )
        echo [警告] uv sync 失败，回退到传统方式...
    )
    
    REM 使用传统 Python venv 创建
    echo [信息] 使用 python -m venv 创建...
    python -m venv .venv
    if errorlevel 1 (
        echo [错误] 虚拟环境创建失败
        echo [提示] 请确保已安装 Python 3.11+
        pause
        exit /b 1
    )
    
    REM 安装依赖
    echo [信息] 安装项目依赖（这可能需要几分钟）...
    .venv\Scripts\python.exe -m pip install --upgrade pip -q
    .venv\Scripts\python.exe -m pip install -e . -q
    if errorlevel 1 (
        echo [错误] 依赖安装失败
        pause
        exit /b 1
    )
    echo [成功] 虚拟环境创建完成
)

:venv_created
echo [成功] 虚拟环境就绪
echo.

REM 设置 Python 命令
set PYTHON_CMD=.venv\Scripts\python.exe

REM 启动 Docker Compose
echo [4/6] 启动 Milvus 向量数据库...
docker ps --format "{{.Names}}" | findstr "milvus-standalone" >nul 2>&1
if not errorlevel 1 (
    echo [信息] Milvus 容器已在运行
) else (
    docker compose -f vector-database.yml up -d
    if errorlevel 1 (
        echo [错误] Docker 启动失败，请确保 Docker Desktop 已启动
        pause
        exit /b 1
    )
    echo [信息] 等待 Milvus 启动（10秒）...
    timeout /t 10 /nobreak >nul
)
echo [成功] Milvus 数据库就绪
echo.

REM 启动 CLS MCP 服务
echo [5/6] 启动 CLS MCP 服务...
start "CLS MCP Server" /min %PYTHON_CMD% mcp_servers/cls_server.py
timeout /t 2 /nobreak >nul
echo [成功] CLS MCP 服务已启动
echo.

REM 启动 Monitor MCP 服务
echo [6/6] 启动 Monitor MCP 服务...
start "Monitor MCP Server" /min %PYTHON_CMD% mcp_servers/monitor_server.py
timeout /t 2 /nobreak >nul
echo [成功] Monitor MCP 服务已启动
echo.

REM 启动 FastAPI 服务
echo [7/8] 启动 FastAPI 服务...
start "SuperBizAgent API" %PYTHON_CMD% -m uvicorn app.main:app --host 0.0.0.0 --port 9900
echo [信息] 等待服务启动（15秒）...
timeout /t 15 /nobreak >nul
echo.

REM 检查服务状态并上传文档
echo.
echo [信息] 检查服务状态...
curl -s http://localhost:9900/health >nul 2>&1
if errorlevel 1 (
    echo [警告] 服务可能还未完全启动，请稍等片刻
) else (
    echo [成功] FastAPI 服务运行正常
    echo.
    
    REM 调用 API 上传 aiops-docs 文档到向量数据库
    echo [8/8] 上传文档到向量数据库...
    for %%f in (aiops-docs\*.md) do (
        echo   上传: %%~nxf
        curl -s -X POST http://localhost:9900/api/upload -F "file=@%%f" >nul 2>&1
    )
    echo [成功] 文档上传完成
)

echo.
echo ====================================
echo 服务启动完成！
echo ====================================
echo Web 界面: http://localhost:9900
echo API 文档: http://localhost:9900/docs
echo.
echo 查看日志:
echo   - FastAPI: logs\app_*.log（Loguru 日志，按天轮转）
echo   - CLS MCP: type mcp_cls.log
echo   - Monitor: type mcp_monitor.log
echo 停止服务: stop-windows.bat
echo ====================================
pause

:fixed_script
@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

echo ========================================
echo Starting SuperBizAgent
echo ========================================

echo [1/7] Checking Python...
where python >nul 2>&1
if errorlevel 1 (
    echo ERROR: Python was not found in PATH.
    exit /b 1
)
python --version

echo [2/7] Preparing the virtual environment...
if not exist ".venv\Scripts\python.exe" (
    python -m venv .venv
    if errorlevel 1 if not exist ".venv\Scripts\python.exe" (
        echo ERROR: Could not create .venv. Python 3.11-3.13 is required.
        exit /b 1
    )
)
set "PYTHON_CMD=%CD%\.venv\Scripts\python.exe"

"%PYTHON_CMD%" -c "import fastapi, uvicorn, pymilvus, fastmcp" >nul 2>&1
if errorlevel 1 (
    echo Installing project dependencies. This may take a few minutes...
    python -m pip --python .venv install -e .
    if errorlevel 1 (
        echo ERROR: Dependency installation failed.
        exit /b 1
    )
) else (
    echo Dependencies are ready.
)

echo [3/7] Checking Docker Desktop...
where docker >nul 2>&1
if errorlevel 1 (
    echo ERROR: Docker CLI was not found. Install or start Docker Desktop.
    exit /b 1
)
docker info >nul 2>&1
if errorlevel 1 (
    echo ERROR: Docker Desktop is not ready. Start or restart Docker Desktop.
    exit /b 1
)

echo [4/7] Starting Milvus, etcd, and MinIO...
docker compose -f vector-database.yml up -d etcd minio standalone
if errorlevel 1 (
    echo ERROR: Docker Compose failed. Check Docker Desktop and network access.
    exit /b 1
)

echo Waiting for Milvus to become healthy...
set "MILVUS_READY=0"
for /L %%i in (1,1,60) do (
    curl.exe -fsS http://127.0.0.1:9091/healthz >nul 2>&1
    if not errorlevel 1 (
        set "MILVUS_READY=1"
        goto :milvus_ready_fixed
    )
    timeout /t 3 /nobreak >nul
)

:milvus_ready_fixed
if "%MILVUS_READY%"=="0" (
    echo ERROR: Milvus did not become healthy within 3 minutes.
    echo Run: docker compose -f vector-database.yml ps
    exit /b 1
)
echo Milvus is healthy.

echo [5/7] Starting the CLS MCP server on port 8003...
powershell -NoProfile -Command "if (Get-NetTCPConnection -State Listen -LocalPort 8003 -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"
if errorlevel 1 start "CLS MCP Server" /min "%PYTHON_CMD%" mcp_servers\cls_server.py

echo [6/7] Starting the Monitor MCP server on port 8004...
powershell -NoProfile -Command "if (Get-NetTCPConnection -State Listen -LocalPort 8004 -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"
if errorlevel 1 start "Monitor MCP Server" /min "%PYTHON_CMD%" mcp_servers\monitor_server.py

echo [7/7] Starting the FastAPI service on port 9900...
powershell -NoProfile -Command "if (Get-NetTCPConnection -State Listen -LocalPort 9900 -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"
if errorlevel 1 start "SuperBizAgent API" "%PYTHON_CMD%" -m uvicorn app.main:app --host 0.0.0.0 --port 9900

echo Waiting for the web service...
set "API_READY=0"
for /L %%i in (1,1,45) do (
    curl.exe -fsS http://127.0.0.1:9900/health >nul 2>&1
    if not errorlevel 1 (
        set "API_READY=1"
        goto :api_ready_fixed
    )
    timeout /t 2 /nobreak >nul
)

:api_ready_fixed
if "%API_READY%"=="0" (
    echo ERROR: FastAPI did not start within 90 seconds.
    echo Check the SuperBizAgent API window for the Python error.
    exit /b 1
)

echo.
echo ========================================
echo SuperBizAgent is running
echo Web UI:   http://localhost:9900
echo API docs: http://localhost:9900/docs
echo ========================================
exit /b 0
