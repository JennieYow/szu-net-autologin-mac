#!/bin/bash
# ============================================================
# szu-net-autologin 一键安装脚本(macOS)
# 做四件事: ① 保存凭据到钥匙串 ② 复制脚本与配置到安装目录
#           ③ 生成并注册 LaunchAgent 定时服务 ④ 自检
# ============================================================
set -u

SERVICE_LABEL="com.szu.autologin"
KC_SERVICE="szu-portal"
INSTALL_DIR="$HOME/Library/Application Support/SZUAutoLogin"
PLIST_PATH="$HOME/Library/LaunchAgents/${SERVICE_LABEL}.plist"
LOG_FILE="$HOME/Library/Logs/szu-autologin.log"
INTERVAL=15                      # 检测间隔(秒)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==== szu-net-autologin 安装程序 ===="

# 0. 环境检查
if [[ "$(uname)" != "Darwin" ]]; then
  echo "✗ 本工具仅支持 macOS"; exit 1
fi
for cmd in curl security launchctl ipconfig; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "✗ 缺少系统命令: $cmd"; exit 1; }
done
[[ -f "$SCRIPT_DIR/autologin.sh" ]] || { echo "✗ 未找到 autologin.sh,请在项目目录内运行本脚本"; exit 1; }

# 1. 凭据 → 钥匙串
echo ""
echo "① 保存校园网账号密码到钥匙串(仅存本机,加密保管)"
read -r -p "  账号(如 6 位校园卡号): " ACCT
if [[ -z "$ACCT" ]]; then echo "✗ 账号不能为空"; exit 1; fi
read -rs -p "  密码(输入不回显): " PASS; echo ""
if [[ -z "$PASS" ]]; then echo "✗ 密码不能为空"; exit 1; fi
security add-generic-password -U -s "$KC_SERVICE" -a "$ACCT" -w "$PASS" \
  && echo "  ✓ 已存入钥匙串(服务名: $KC_SERVICE)" \
  || { echo "✗ 写入钥匙串失败"; exit 1; }
unset ACCT PASS

# 2. 复制脚本 + 生成配置
echo ""
echo "② 安装脚本到 $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/autologin.sh" "$INSTALL_DIR/autologin.sh"
chmod +x "$INSTALL_DIR/autologin.sh"
if [[ ! -f "$INSTALL_DIR/config.sh" ]]; then
  if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
    cp "$SCRIPT_DIR/config.sh" "$INSTALL_DIR/config.sh"      # 用户已自备配置
  else
    cp "$SCRIPT_DIR/config.example.sh" "$INSTALL_DIR/config.sh"
    echo "  · 已生成默认配置 config.sh(默认适配深圳大学,其他学校请编辑后重跑安装)"
  fi
else
  echo "  · 检测到已有 config.sh,保留你的自定义配置"
fi

# 3. 生成 LaunchAgent 并注册
echo ""
echo "③ 注册定时服务(每 ${INTERVAL} 秒检测一次)"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${SERVICE_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${INSTALL_DIR}/autologin.sh</string>
	</array>
	<key>StartInterval</key>
	<integer>${INTERVAL}</integer>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/${SERVICE_LABEL}" 2>/dev/null
if launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null; then
  echo "  ✓ 服务已注册并启动"
elif launchctl load -w "$PLIST_PATH" 2>/dev/null; then
  echo "  ✓ 服务已注册并启动(legacy 方式)"
else
  echo "  ⚠ 自动注册失败,请在终端手动执行这一条:"
  echo "    launchctl bootstrap gui/\$(id -u) \"$PLIST_PATH\""
fi

# 4. 自检
echo ""
echo "④ 自检: 试运行一次脚本"
"$INSTALL_DIR/autologin.sh"; rc=$?
if [[ $rc -eq 0 ]]; then
  echo "  ✓ 脚本运行正常(退出码 0)"
else
  echo "  ⚠ 脚本退出码 $rc,请查看日志: tail -n 20 \"$LOG_FILE\""
fi

echo ""
echo "==== 安装完成 ===="
echo "日志: $LOG_FILE      查看实时日志: tail -f \"$LOG_FILE\""
echo "卸载: 运行项目目录中的 uninstall.sh"
