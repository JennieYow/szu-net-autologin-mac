#!/bin/bash
# ============================================================
# szu-net-autologin 用户配置模板
#
# 用法: 复制本文件为 config.sh(与 autologin.sh 同目录)后修改,
#       config.sh 中的值会覆盖 autologin.sh 内置的默认值。
#       config.sh 含个人环境信息,已被 .gitignore 排除,不会入库。
# ============================================================

# --- WiFi 名称(SSID) ---
# 注意: macOS 隐私保护可能让脚本读不到真实 SSID(见 README"已知坑"),
#       SSID 只是第一级快速判断,读不到时会自动退到 IP/服务器探测。
DORM_SSIDS=("SZU_CTC&CMCC")                 # 宿舍区 WiFi 名
TEACH_SSIDS=("SZU_WLAN" "SZU-WLAN")         # 教学区 WiFi 名(多种拼写都列出)

# --- 认证接口 ---
DORM_PORTAL_URL="http://172.30.255.42:801/eportal/portal/login"   # 宿舍区新版 eportal 接口
SRUN_BASE="https://net.szu.edu.cn"          # 教学区深澜(Srun)认证服务器
SRUN_AC_ID="12"                             # 深澜 ac_id 仅作兜底;v1.0.1 起登录前自动抓取真实值(实测 8)

# --- 区域识别辅助 ---
# IP 网段前缀是第二级快速判断;不确定就留空 "",会自动走第三级服务器探测。
TEACH_NET_PREFIX="172.26."                  # 教学区 IP 前缀(可能因楼栋而异)
DORM_NET_PREFIX=""                          # 宿舍区 IP 前缀(留空则每次探测识别)

# --- 行为参数 ---
WIRED_MODE=1                                # 1=插网线且未连WiFi时按宿舍区处理;0=仅WiFi
CHECK_URL="https://www.baidu.com"           # 公网在线检测地址(兜底探针)
LOGIN_COOLDOWN=100                          # 两次登录尝试的最小间隔(秒),防止频繁重试

# --- 文件位置 ---
KC_SERVICE="szu-portal"                     # 钥匙串凭据服务名(install.sh 与脚本需一致)
LOG_FILE="$HOME/Library/Logs/szu-autologin.log"
STATE_DIR="$HOME/Library/Application Support/SZUAutoLogin"

# --- 调试 ---
DEBUG_NET=0                                 # 1=每轮记录 ssid/ip/zone(排障用,平时 0)
