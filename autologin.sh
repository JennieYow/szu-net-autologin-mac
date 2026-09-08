#!/bin/bash
# ============================================================
# szu-net-autologin · 深大校园网断网自动重连脚本 v1.0.0
# https://github.com/<你的用户名>/szu-net-autologin
#
# 由 macOS LaunchAgent 定时调度(默认每 45 秒);检测到断网时
# 按当前所在区域自动选择认证接口,模拟网页登录。全程不依赖
# 任何客户端、不打开任何窗口;凭据存放在 macOS 钥匙串。
#
# 区域识别(三级,由快到慢,见 zone_detect 函数):
#   ① SSID 匹配      → 直接认区(零开销)
#   ② IP 网段匹配    → 认区(零开销,覆盖已知网段)
#   ③ 探测认证服务器 → 谁应答就是哪个区(约 1~3 秒,
#      不依赖 SSID/IP/楼栋位置;两台服务器均仅校内可达)
#
# 为什么不只用 SSID?两个 macOS 的坑(详见 README"已知坑"):
#   · 隐私保护:无定位权限的程序读 SSID 会得到假数据
#     (ipconfig 返回字面量 <redacted>,networksetup 谎称未连接);
#   · networksetup 输出随系统语言变化(中文系统输出
#     "当前 Wi-Fi 网络"),精确匹配英文前缀会解析失败。
#
# 区域路由(默认适配深圳大学,可在 config.sh 中覆盖全部参数):
#   宿舍区  SZU_CTC&CMCC(或有线) → 新版 eportal 接口
#           (GET http://172.30.255.42:801/eportal/portal/login)
#   教学区  SZU_WLAN / SZU-WLAN   → 深澜 Srun 接口
#           (https://net.szu.edu.cn/cgi-bin/srun_portal)
#           注: 深大教学区 2025 年 1 月起为深澜系统,登录需
#               challenge + HMAC-MD5 + XXTEA + 自定义 base64
#               + SHA1 五道工序,本文件已内置完整实现。
#   其他网络 → 不动作
#
# 解释器说明: 必须以 /bin/bash(macOS 自带 3.2 版)运行——
#   加密函数依赖 bash 数组语义;LaunchAgent 的
#   ProgramArguments 也应写 /bin/bash 而非 /bin/zsh。
#
# 致谢: 教学区深澜协议实现参考 SoY0ung/SZU-SRUN (GitHub);
#       宿舍区 eportal 协议参考 ceynri/szu-network-connecter (MIT)。
# ============================================================

# ---- 可调参数(均可在脚本同目录的 config.sh 中覆盖,勿直接改本文件) ----
DORM_SSIDS=("SZU_CTC&CMCC")                 # 宿舍区 WiFi 名(按实际显示名修改)
TEACH_SSIDS=("SZU_WLAN" "SZU-WLAN")         # 教学区 WiFi 名(两种常见拼写都试)
WIRED_MODE=1                                # 1=插网线(未连WiFi)时按宿舍区处理;0=仅WiFi
CHECK_URL="https://www.baidu.com"           # 在线检测地址
DORM_PORTAL_URL="http://172.30.255.42:801/eportal/portal/login"   # 宿舍区新版认证接口
SRUN_BASE="https://net.szu.edu.cn"          # 教学区深澜认证服务器
SRUN_AC_ID="12"                             # 教学区接入控制器 id(社区实测值;若登录失败可抓包核对)
KC_SERVICE="szu-portal"                     # 钥匙串凭据服务名(勿改)
LOG_FILE="$HOME/Library/Logs/szu-autologin.log"
STATE_DIR="$HOME/Library/Application Support/SZUAutoLogin"
LOGIN_COOLDOWN=100                          # 两次登录尝试最小间隔(秒)
TEACH_NET_PREFIX="172.26."                  # 教学区 IP 网段前缀(实测值)
DORM_NET_PREFIX=""                          # 宿舍区 IP 网段前缀(待回宿舍采集后填写)
DEBUG_NET=0                                 # 1=每轮记录 ssid/ip/zone 调试日志(排障用,平时保持 0)

# ---- 可选配置文件 ----
# 安装目录下的 config.sh 可覆盖以上任何参数(格式见 config.example.sh),
# 升级脚本时替换 autologin.sh 即可,你的自定义配置不受影响。
CONFIG_FILE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/config.sh"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ---- 基础函数 ----
log_line() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

wifi_ssid() {
  # v2.3 修复: networksetup 的输出随系统语言变化(中文系统显示
  # "当前 Wi-Fi 网络"),导致解析失败→误判区域。改用 ipconfig
  # getsummary —— 数据键固定为英文,不受系统语言影响;失败时
  # 再用 networksetup 兼容中英文前缀兜底。
  local s
  s="$(ipconfig getsummary en0 2>/dev/null | awk -F' : ' '/^[[:space:]]*SSID/{print $2; exit}')"
  if [[ -n "$s" ]]; then
    echo "$s"
    return
  fi
  networksetup -getairportnetwork en0 2>/dev/null | sed -n -e 's/^Current Wi-Fi Network: //p' -e 's/^当前 Wi-Fi 网络: //p' | head -1
}

has_default_route() {
  route -n get default >/dev/null 2>&1
}

in_list() {
  local item="$1"; shift
  local t
  for t in "$@"; do [[ "$item" == "$t" ]] && return 0; done
  return 1
}

# 判断当前所在区域: dorm / teach / none
# 三级判断(由快到慢):
#   ① SSID 能读到且匹配 → 直接认区(零开销)
#   ② IP 网段前缀匹配   → 认区(零开销,覆盖已知网段)
#   ③ 探测认证服务器    → 谁应答就是哪个区(约 1~3 秒,
#      不依赖 IP/SSID/楼栋位置,v2.5 新增的兜底)
zone_detect() {
  local ssid ip
  ssid="$(wifi_ssid)"
  # macOS 隐私保护会把 SSID 替换为 <redacted>,视同"读不到"
  [[ "$ssid" == *edacted* ]] && ssid=""
  if [[ -n "$ssid" ]]; then
    in_list "$ssid" "${DORM_SSIDS[@]}" && { echo "dorm"; return; }
    in_list "$ssid" "${TEACH_SSIDS[@]}" && { echo "teach"; return; }
  fi
  ip="$(ipconfig getifaddr en0 2>/dev/null)"
  if [[ -n "$ip" ]]; then
    [[ -n "$TEACH_NET_PREFIX" && "$ip" == "$TEACH_NET_PREFIX"* ]] && { echo "teach"; return; }
    [[ -n "$DORM_NET_PREFIX" && "$ip" == "$DORM_NET_PREFIX"* ]] && { echo "dorm"; return; }
  fi
  # ③ 探测兜底(v2.5): 依次询问两台认证服务器(仅校内可达,
  #    校外/热点环境两者都不应答,不会误判)
  local state
  state="$(curl -sk -m 3 "$SRUN_BASE/cgi-bin/rad_user_info" 2>/dev/null)"
  [[ -n "$state" ]] && { echo "teach"; return; }
  if curl -s -m 3 -o /dev/null "http://172.30.255.42:801/" 2>/dev/null; then
    echo "dorm"; return
  fi
  [[ "${DEBUG_NET:-0}" == "1" && -n "$ip" ]] && \
    log_line "DEBUG 三级探测均未应答,判定不在校园网 ip=[${ip}]"
  if [[ "$WIRED_MODE" == "1" ]] && has_default_route; then
    echo "dorm"; return    # 有线按宿舍区处理(教学区有线属教工区,不在本脚本范围)
  fi
  echo "none"
}

# ---- 在线探针(区域化) ----
# 公网探针: 作为兜底使用
online() {
  curl -sS -m 8 -o /dev/null "$CHECK_URL" >/dev/null 2>&1
}

# 宿舍区认证服务器可达性(不登录,只确认"还在校园网内、服务器活着")
dorm_portal_reachable() {
  curl -s -m 5 -o /dev/null "http://172.30.255.42:801/" 2>/dev/null
}

# 教学区深澜状态接口: 返回原始应答
#   - 含 not_online_error → 确认离线
#   - 其他非空内容        → 确认在线
#   - 空                  → 接口不可达(需调用方兜底)
teach_online_state() {
  curl -sk -m 6 "$SRUN_BASE/cgi-bin/rad_user_info" 2>/dev/null
}

# 从钥匙串读取账号与密码
read_credentials() {
  cid="$(security find-generic-password -s "$KC_SERVICE" 2>/dev/null | awk -F'"' '/"acct"/{print $4}')"
  pass="$(security find-generic-password -s "$KC_SERVICE" -w 2>/dev/null)"
  [[ -n "$cid" && -n "$pass" ]]
}

# 宿舍区: 新版 eportal 协议(GET + JSONP)
login_dorm() {
  local resp
  resp="$(curl -s -m 8 -G "$DORM_PORTAL_URL" \
    --data-urlencode "callback=dr1003" \
    --data-urlencode "login_method=1" \
    --data-urlencode "user_account=,0,${cid}" \
    --data-urlencode "user_password=${pass}" \
    --data-urlencode "wlan_user_ip=" \
    --data-urlencode "wlan_user_ipv6=" \
    --data-urlencode "wlan_user_mac=000000000000" \
    --data-urlencode "wlan_ac_ip=" \
    --data-urlencode "wlan_ac_name=" \
    --data-urlencode "jsVersion=4.1.3" \
    --data-urlencode "terminal_type=1" \
    --data-urlencode "lang=zh-cn" \
    --data-urlencode "v=10353" 2>/dev/null)"
  if printf '%s' "$resp" | grep -qE '"result"[[:space:]]*:[[:space:]]*1|已经在线|认证成功'; then
    log_line "网页自动登录成功(宿舍区)"
    return 0
  else
    log_line "网页自动登录失败(宿舍区): $(printf '%s' "$resp" | tr -d '\n' | head -c 200)"
    return 1
  fi
}

# ========== 教学区: 深澜(Srun)协议 ==========
# 流程: ① 查在线状态 → ② 取 challenge(令牌+本机IP) →
#       ③ 密码 HMAC-MD5 → ④ 登录信息 XXTEA 加密 + 自定义 base64 →
#       ⑤ 全参数 SHA1 校验和 → ⑥ 提交登录

sr_md5() {  # $1=内容 $2=密钥 → HMAC-MD5
  echo -n "$1" | openssl md5 -hmac "$2" | awk '{print $2}'
}

sr_sha1() { # $1=内容 → SHA1
  echo -n "$1" | openssl sha1 | awk '{print $2}'
}

# 字符串 → 32 位整数数组(每 4 字节合并,小端;addLen=true 时末尾附加长度)
sr_s() {
  local original_string="$1"
  local addLen="$2"
  local a=()
  local i char ascii_code
  for ((i = 0; i < ${#original_string}; i++)); do
    char=${original_string:$i:1}
    ascii_code=$(( $(printf '%d' "'$char") ))
    a+=("$ascii_code")
  done
  local combined_array=()
  local j num result
  for (( i = 0; i < ${#a[@]}; i += 4 )); do
    result=0
    local local_elements=("${a[@]:i:4}")
    for (( j = 0; j < ${#local_elements[@]}; j++ )); do
      num=${local_elements[j]}
      if (( num > 255 )); then
        num=$((num & 255))
      fi
      result=$((result | num * 256 ** j))
    done
    combined_array+=("$result")
  done
  if [ "$addLen" = "true" ]; then
    combined_array+=("${#original_string}")
  fi
  echo "${combined_array[*]}"
}

# 32 位整数数组 → 字节数组(小端展开;末元素为 true 时先去掉长度标志)
sr_l() {
  local a=("$@")
  local withLen=${a[${#a[@]}-1]}
  a=("${a[@]:0:${#a[@]}-1}")
  local result=()
  local num i shifted byte
  for num in "${a[@]}"; do
    for (( i = 0; i < 4; i++ )); do
      shifted=$((num >> (8 * i)))
      byte=$((shifted & 255))
      result+=("$byte")
    done
  done
  if [ "$withLen" = "true" ]; then
    result=("${result[@]:0:${#result[@]}-1}")
  fi
  echo "${result[*]}"
}

# XXTEA 加密(深澜前端 js 版算法的 bash 移植)
sr_encode() {
  local str="$1"
  local key="$2"
  local strArr=($(sr_s "$str" true))
  local keyArr=($(sr_s "$key" false))

  local n=$((${#strArr[@]} - 1))
  local z=${strArr[n]}
  local y=${strArr[0]}
  local c=$((0x86014019 | 0x183639A0))
  local m=0
  local p=0
  local iter=$((6 + 52 / (n + 1)))
  local d=0
  local e=0

  while true; do
    iter=$((iter - 1))
    d=$(((d + c) & 4294967295))
    e=$((d >> 2 & 3))
    for (( p = 0; p < n; p++ )); do
      y=${strArr[p + 1]}
      m=$(( ((z >> 5 & 4294967295) ^ ((y << 2 & 4294967295))) & 4294967295 ))
      m=$(( ((m + (((y >> 3) ^ ((z << 4 & 4294967295))) ^ (d ^ y & 4294967295)) )) & 4294967295 ))
      m=$(( (m + (keyArr[((p & 3) ^ e)] ^ z)) & 4294967295 ))
      strArr[p]=$((strArr[p] + m & 4294967295))
      z=${strArr[p]}
    done
    y=${strArr[0]}
    m=$(( ((z >> 5 & 4294967295) ^ ((y << 2 & 4294967295))) & 4294967295 ))
    m=$(( ((m + (((y >> 3) ^ ((z << 4 & 4294967295))) ^ (d ^ y & 4294967295)) )) & 4294967295 ))
    m=$(( (m + (keyArr[((n & 3) ^ e)] ^ z)) & 4294967295 ))
    strArr[n]=$((strArr[n] + m & 4294967295))
    z=${strArr[n]}
    if ((0 >= iter)); then
      break
    fi
  done

  echo $(sr_l ${strArr[*]} false)
}

# 自定义字母表 base64(深澜前端同款乱序字母表)
sr_base64() {
  local byte_array=("$@")
  local hex_string
  hex_string=$(printf "%02x" "${byte_array[@]}" | tr -d ' ')
  local base64_encoded
  base64_encoded=$(echo -n "$hex_string" | xxd -r -p | base64 | tr -d '\n')
  local mapping="LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA="
  local original="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
  local output_string=""
  local i char index new_char
  for (( i = 0; i < ${#base64_encoded}; i++ )); do
    char="${base64_encoded:$i:1}"
    index=$(expr index "$original" "$char")
    new_char="${mapping:index-1:1}"
    output_string+="$new_char"
  done
  echo "$output_string"
}

login_teach() {
  # ① 深澜自带的在线状态接口:not_online_error 才需要登录
  local state
  state="$(curl -sk -m 8 "$SRUN_BASE/cgi-bin/rad_user_info" 2>/dev/null)"
  if [[ "$state" != "not_online_error" ]]; then
    log_line "教学区检测显示已在线(可能仅外网检测误报),跳过登录"
    return 0
  fi

  # ② 取 challenge(加密令牌 + 本机 IP)
  local callback token ip_addr res
  callback="$(date +%Y%m%d_%H%M%S)"
  local challenge
  challenge="$(curl -sk -m 8 -G "$SRUN_BASE/cgi-bin/get_challenge" \
    --data-urlencode "callback=$callback" \
    -d "username=${cid}" 2>/dev/null)"
  token="$(echo "$challenge" | grep -o '"challenge":"[^"]*' | awk -F'"' '{print $4}')"
  ip_addr="$(echo "$challenge" | grep -o '"client_ip":"[^"]*' | awk -F'"' '{print $4}')"
  res="$(echo "$challenge" | grep -o '"res":"[^"]*' | awk -F'"' '{print $4}')"
  if [[ "$res" != "ok" || -z "$token" ]]; then
    log_line "网页自动登录失败(教学区): 无法获得 challenge -> ${res:-无响应}"
    return 1
  fi

  # ③④⑤ 按深澜协议构造加密参数
  local enc_pwd info chkstr
  enc_pwd="$(sr_md5 "$pass" "$token")"
  info="{\"username\":\"${cid}\",\"password\":\"${pass}\",\"ip\":\"${ip_addr}\",\"acid\":\"${SRUN_AC_ID}\",\"enc_ver\":\"srun_bx1\"}"
  info="{SRBX1}$(sr_base64 $(sr_encode "$info" "$token"))"
  chkstr="$(sr_sha1 "${token}${cid}${token}${enc_pwd}${token}${SRUN_AC_ID}${token}${ip_addr}${token}200${token}1${token}${info}")"

  # ⑥ 提交登录
  local resp
  resp="$(curl -sk -m 8 -G "$SRUN_BASE/cgi-bin/srun_portal" \
    --data-urlencode "callback=$callback" \
    -d "action=login" \
    -d "username=${cid}" \
    -d "password={MD5}${enc_pwd}" \
    -d "chksum=${chkstr}" \
    --data-urlencode "info=${info}" \
    -d "ac_id=${SRUN_AC_ID}" \
    -d "ip=${ip_addr}" \
    -d "n=200" \
    -d "type=1" 2>/dev/null)"
  res="$(echo "$resp" | grep -o '"res":"[^"]*' | awk -F'"' '{print $4}')"
  if [[ "$res" == "ok" ]]; then
    log_line "网页自动登录成功(教学区)"
    return 0
  fi
  local errmsg
  case "$res" in
    "auth_error"|"password_error") errmsg="账号或密码错误" ;;
    "login_error")                 errmsg="登录被拒绝(可能已在线或参数异常)" ;;
    "")                            errmsg="无返回信息,可能认证系统已变更" ;;
    *)                             errmsg="$res" ;;
  esac
  log_line "网页自动登录失败(教学区): ${errmsg}"
  return 1
}

# ---- 主流程 ----
zone="$(zone_detect)"
if [[ "${DEBUG_NET:-0}" == "1" && "$zone" != "none" ]]; then
  log_line "DEBUG ssid=[$(wifi_ssid)] ip=[$(ipconfig getifaddr en0 2>/dev/null)] zone=${zone}"
fi
[[ "$zone" == "none" ]] && exit 0   # 不在校园网环境 → 不动作

# 区域化在线检测
if [[ "$zone" == "dorm" ]]; then
  if online; then
    exit 0                          # 外网通 → 在线
  fi
  if ! dorm_portal_reachable; then
    log_line "外网检测失败且无法连接宿舍认证服务器,疑似网络未就绪,跳过本轮"
    exit 0
  fi                                # 服务器可达而外网不通 → 会话失效,继续登录
else
  state="$(teach_online_state)"
  if [[ -n "$state" && "$state" != "not_online_error" ]]; then
    exit 0                          # 深澜确认在线
  fi
  if [[ -z "$state" ]]; then
    online && exit 0                # 状态接口不可达 → 公网探针兜底确认
  fi                                # not_online_error 或兜底也失败 → 继续登录
fi

# 断网: 冷却时间内不重复尝试
LAST_FILE="$STATE_DIR/.last_login"
now=$(date +%s)
if [[ -f "$LAST_FILE" ]]; then
  last=$(cat "$LAST_FILE" 2>/dev/null)
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if (( now - last < LOGIN_COOLDOWN )); then
    exit 0
  fi
fi

if ! read_credentials; then
  log_line "未在钥匙串中找到凭据(服务: ${KC_SERVICE}),请先执行 security add-generic-password 保存账号密码"
  exit 0
fi

mkdir -p "$STATE_DIR"
printf '%s' "$now" > "$LAST_FILE"

log_line "检测到断网(区域: ${zone}),尝试网页自动登录 ..."
if [[ "$zone" == "dorm" ]]; then
  login_dorm
else
  login_teach
fi
exit 0
