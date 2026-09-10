#!/bin/bash
# ============================================================
# szu-net-autologin 卸载脚本
# 停止定时服务 → 删除 LaunchAgent 与安装目录 → 可选删除钥匙串凭据
# ============================================================
set -u

SERVICE_LABEL="com.szu.autologin"
KC_SERVICE="szu-portal"
INSTALL_DIR="$HOME/Library/Application Support/SZUAutoLogin"
PLIST_PATH="$HOME/Library/LaunchAgents/${SERVICE_LABEL}.plist"
LOG_FILE="$HOME/Library/Logs/szu-autologin.log"

echo "==== szu-net-autologin 卸载程序 ===="

launchctl bootout "gui/$(id -u)/${SERVICE_LABEL}" 2>/dev/null && echo "✓ 定时服务已停止" || echo "· 服务未在运行"
if [[ -f "$PLIST_PATH" ]]; then rm "$PLIST_PATH" && echo "✓ 已删除 $PLIST_PATH"; fi
if [[ -d "$INSTALL_DIR" ]]; then rm -r "$INSTALL_DIR" && echo "✓ 已删除 $INSTALL_DIR"; fi

read -rs -n1 -p "是否同时删除钥匙串中保存的校园网账号密码? [y/N]: " ans; echo ""
if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
  security delete-generic-password -s "$KC_SERVICE" 2>/dev/null && echo "✓ 钥匙串凭据已删除" || echo "· 未找到凭据(可能已删除)"
fi

echo ""
echo "日志文件保留在 $LOG_FILE,确认不再需要可手动删除。"
echo "==== 卸载完成 ===="
