@echo off
rem ===================================================================
rem  vmware-k8s 一键入口
rem
rem  用法:
rem    build.cmd                 全流程
rem    build.cmd -Stage preflight 只做环境体检
rem    build.cmd -Stage base      只做 k8s 基础镜像
rem    build.cmd -Stage k8s      只跑装集群
rem
rem  不需要管理员权限:节点的静态 IP 是 guest 自己写 netplan 配的,
rem  宿主机这边一个字的全局配置都不用改。
rem ===================================================================
setlocal

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
    echo [FAIL] 找不到 PowerShell: %PS%
    exit /b 1
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo [ok] 退出码 0
) else (
    echo [FAIL] 退出码 %RC%
)
exit /b %RC%
