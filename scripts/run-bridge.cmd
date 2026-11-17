@echo off
setlocal
where pwsh >nul 2>nul
if %ERRORLEVEL% equ 0 (
    set "PS_BIN=pwsh"
) else (
    set "PS_BIN=powershell"
)
%PS_BIN% -NoProfile -ExecutionPolicy Bypass -File "%~dp0bridge.ps1" -HookMode %*
