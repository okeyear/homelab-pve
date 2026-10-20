@echo off
rem ===================================================================
rem  vmware-k8s 一键入口
rem
rem  用法:
rem    build.cmd                 全流程
rem    build.cmd -Stage preflight 只做环境体检
rem    build.cmd -Stage k8s      只跑装集群
rem
rem  需要管理员权限(写静态 DHCP 租约 + 重启 VMnetDHCP 服务)。
rem ===================================================================
setlocal

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
    echo [FAIL] 找不到 PowerShell: %PS%
    exit /b 1
)

rem 管理员检查。net session 是最省事的一个判断:普通用户会返回错误。
net session >nul 2>&1
if errorlevel 1 (
    echo.
    echo [FAIL] 需要管理员权限。
    echo        右键本文件 -^> 以管理员身份运行。
    echo.
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
