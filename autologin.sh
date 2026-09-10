#!/bin/bash
# ============================================================
# 深大校园网网页自动登录脚本 v2.8(宿舍区 + 教学区双区通用版)
# 由 LaunchAgent 定时调度(间隔在 plist 中设置,默认 15 秒;检测到
# 断网时按当前所在区域自动选择对应认证接口,模拟网页登录。全程不
# 依赖任何客户端、不打开任何窗口;凭据存放在 macOS 钥匙串。
#
# v2.8 变更(2026-09-09 晚实测定论"注销后登录失败"根因):
#   注销后接入控制器会丢弃发往认证服务器(172.31.63.36)的直连
#   请求(HTTP 80 / HTTPS 443 双双超时返回空,诊断日志实测),而
#   浏览器能打开登录页是因为走了网关的透明 302 重定向通道。现让
#   脚本模仿浏览器: HTTPS 直连失败时,先向公网 HTTP 地址发探测,
#   从网关返回的 Location 头提取真实可用的门户入口,再用该入口
#   完成 challenge + 登录(入口全程一致)。v2.7.1/v2.7.2 的诊断
#   日志(原始返回/DNS/ac_id)保留。
# v2.7 变更(2026-09-09 实测定位"无返回信息"真凶):
#   ① 修复 sr_md5/sr_sha1 取列错误: macOS LibreSSL 的 openssl
#      md5/sha1 直接输出纯哈希(无 "(stdin)= " 前缀),原 awk
#      '{print $2}' 取不到 → 密码摘要与校验和恒为空 → 服务器
#      收到空参数直接返回 0 字节(即长期以来的"无返回信息")。
#      改为 awk '{print $NF}' 兼容两种输出格式。
#   ② 修复 sr_base64 映射失效: 原逐字符用 expr index 查表,
#      但本机 expr 为 GNU 版(不支持 index)→ 映射全部失败、
#      info 密文恒为 "====…"。改为 tr 双字符集整串映射。
#   ③ login_teach 状态判定放宽: 状态接口空响应(接口抽风但外网
#      已确认不通)时不再误判"已在线跳过",而是尝试登录兜底。
# v2.6 变更(2026-09-09 实测修复):
#   ① ac_id 动态获取: 教学区登录前先抓真实登录页解析当次 ac_id
#      (实测深大当前为 8,旧版写死社区值 12 → 服务器回空、反复
#      "无返回信息");解析失败才回落配置值。
#   ② 区域识别防"翻烙饼": 实测宿舍网络能同时访问教学+宿舍两台
#      认证服务器,且深澜状态接口离线时也返回 not_online_error
#      (非空)→ v2.5 探测法把宿舍误判教学区(15:47 dorm ↔ 15:48
#      teach)。现修正判定顺序,并新增"网关未变沿用上次区域"缓存;
#   ③ 补宿舍网段实测值 172.24.*(网关 172.24.0.1)。
# v2.5 变更(服务器探测兜底): v2.4 依赖单一 IP 网段(172.26.*)
#   识别教学区,但不同教学楼/汇聚区可能分配不同网段,换楼即失灵。
#   现增加第三级判断: IP 网段不匹配时,直接探测"哪台认证服务器
#   应答"(教学 net.szu.edu.cn / 宿舍 172.30.255.42,均仅校内可达)
#   —— 与所在楼栋、IP 段无关,任何位置都能正确认区。
# v2.4 变更(IP 网段识别区域): macOS 隐私保护会向无定位权限的
#   程序隐藏 WiFi 名(SSID 返回字面量 <redacted>,networksetup
#   则谎称未连接),导致 v2.2/v2.3 均无法识别区域。现改为:
#   ① SSID 能读到且匹配 → 仍按 SSID 判断;
#   ② SSID 被脱敏/读不到 → 按 IP 网段判断(教学区 172.26.*,
#      宿舍区网段待回家后从日志采集再补充 DORM_NET_PREFIX);
#   ③ 仍判不出 → 有线兜底(按宿舍区)。
# v2.3 变更(SSID 读取加固): 修复中文系统下 networksetup 输出
#   为"当前 Wi-Fi 网络"导致 SSID 解析失败、区域误判为宿舍区的
#   bug —— 改以 ipconfig getsummary 读取(键名固定英文),并以
#   兼容中英文的 networksetup 解析兜底。
# v2.2 变更(区域化探针): 在线检测不再一律访问公网(百度),
#   改为按区域询问各自的认证服务器——更快、不占公网出口、更准:
#   宿舍区  外网探针失败时,先确认能连通宿舍认证服务器再登录,
#           避免认证服务器临时不可达时做无意义的登录尝试;
#   教学区  直接用深澜自带状态接口 rad_user_info 判断在线与否,
#           仅当该接口连不上时才退回公网探针作为兜底。
#
# 区域路由:
#   宿舍区  SZU_CTC&CMCC(或有线) → 新版 eportal 接口
#           (GET http://172.30.255.42:801/eportal/portal/login)
#   教学区  SZU_WLAN / SZU-WLAN   → 深澜 Srun 接口
#           (https://net.szu.edu.cn/cgi-bin/srun_portal)
#           注: 教学区 2025 年 1 月已由旧版 Dr.COM 升级为深澜系统,
#               登录需 challenge + HMAC-MD5 + XXTEA + 自定义 base64
#               + SHA1 五道工序,本文件已内置完整实现。
#   其他网络 → 不动作
#
# 解释器说明: 使用 /bin/bash(macOS 自带 3.2 版),因为加密函数
#   依赖 bash 数组语义;请勿改回 zsh。
#
# 致谢: 教学区深澜协议实现参考 SoY0ung/SZU-SRUN (GitHub);
#       宿舍区 eportal 协议参考 ceynri/szu-network-connecter (MIT)。
# ============================================================

# ---- 可调参数 ----
DORM_SSIDS=("SZU_CTC&CMCC")                 # 宿舍区 WiFi 名(按实际显示名修改)
TEACH_SSIDS=("SZU_WLAN" "SZU-WLAN")         # 教学区 WiFi 名(两种常见拼写都试)
WIRED_MODE=1                                # 1=插网线(未连WiFi)时按宿舍区处理;0=仅WiFi
CHECK_URL="https://www.baidu.com"           # 在线检测地址
DORM_PORTAL_URL="http://172.30.255.42:801/eportal/portal/login"   # 宿舍区新版认证接口
SRUN_BASE="https://net.szu.edu.cn"          # 教学区深澜认证服务器
SRUN_AC_ID="18"                              # 教学区接入控制器 id(仅作解析失败的兜底;
                                             # 实测当前为 18,该值可能随接入控制器变化)
KC_SERVICE="szu-portal"                     # 钥匙串凭据服务名(勿改)
LOG_FILE="$HOME/Library/Logs/szu-autologin.log"
STATE_DIR="$HOME/Library/Application Support/SZUAutoLogin"
LOGIN_COOLDOWN=100                          # 两次登录尝试最小间隔(秒)
TEACH_NET_PREFIX="172.26."                  # 教学区 IP 网段前缀(实测:图书馆 172.26.*)
DORM_NET_PREFIX="172.24."                   # 宿舍区 IP 网段前缀(实测:宿舍 172.24.*,网关 .0.1)
DEBUG_NET=1                                 # 1=在校园网时每轮记录 ssid/ip/zone 调试日志(排障完改 0)

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
# 四级判断(由快到慢,前三级零网络开销):
#   ① SSID 能读到且匹配   → 直接认区
#   ② IP 网段前缀匹配     → 直接认区(实测: 宿舍 172.24.* / 教学 172.26.*)
#   ③ 区域缓存(v2.6)     → 网关没变,沿用上次认出的区,防止探测"翻烙饼"
#   ④ 探测认证服务器      → 见函数内注释(v2.6 修正判定顺序,见下)
gw_addr() {
  route -n get default 2>/dev/null | awk '/gateway/{print $2; exit}'
}

zone_cache_save() {  # $1=dorm|teach,连同当前网关写入缓存
  local gw; gw="$(gw_addr)"
  [[ -z "$gw" || -z "$1" ]] && return 1
  printf '%s\n%s\n' "$1" "$gw" > "$STATE_DIR/.zone_cache" 2>/dev/null
}

zone_cache_get() {   # 网关未变且缓存有效 → 回显缓存区域;否则无输出
  local gw cur
  gw="$(gw_addr)"; [[ -z "$gw" ]] && return 1
  cur="$(sed -n 1p "$STATE_DIR/.zone_cache" 2>/dev/null)"
  if [[ "$(sed -n 2p "$STATE_DIR/.zone_cache" 2>/dev/null)" == "$gw" ]] \
     && { [[ "$cur" == "dorm" || "$cur" == "teach" ]]; }; then
    echo "$cur"; return 0
  fi
  return 1
}

zone_detect() {
  local ssid ip zone state dormok teachok
  ssid="$(wifi_ssid)"
  # macOS 隐私保护会把 SSID 替换为 <redacted>,视同"读不到"
  [[ "$ssid" == *edacted* ]] && ssid=""
  if [[ -n "$ssid" ]]; then
    in_list "$ssid" "${DORM_SSIDS[@]}" && { zone_cache_save dorm; echo "dorm"; return; }
    in_list "$ssid" "${TEACH_SSIDS[@]}" && { zone_cache_save teach; echo "teach"; return; }
  fi
  ip="$(ipconfig getifaddr en0 2>/dev/null)"
  if [[ -n "$ip" ]]; then
    [[ -n "$DORM_NET_PREFIX" && "$ip" == "$DORM_NET_PREFIX"* ]] && { zone_cache_save dorm; echo "dorm"; return; }
    [[ -n "$TEACH_NET_PREFIX" && "$ip" == "$TEACH_NET_PREFIX"* ]] && { zone_cache_save teach; echo "teach"; return; }
  fi
  zone="$(zone_cache_get)"
  [[ -n "$zone" ]] && { echo "$zone"; return; }
  # ④ 探测兜底(v2.6 修正): 实测宿舍网络能同时访问两台认证服务器,
  #    且深澜状态接口在"未登录"时也返回 not_online_error(非空),
  #    v2.5 把"任何应答都当教学区"→ 宿舍被误判教学区。修正顺序:
  #    a. 深澜返回的是在线会话内容(非空且非 not_online_error)
  #       → 教学区(只有教学 NAS 上才有会话);
  #    b. 宿舍认证服务器可达且深澜不可达 → 宿舍区;
  #    c. 深澜可达且宿舍不可达          → 教学区;
  #    d. 两者都可达 → 按宿舍区处理(实测宿舍网内两台都通);
  #    e. 都不可达   → 不在校园网(有线场景按 WIRED_MODE 兜底)。
  state="$(curl -sk -m 4 "$SRUN_BASE/cgi-bin/rad_user_info" 2>/dev/null)"
  if [[ -n "$state" && "$state" != *not_online_error* ]]; then
    zone_cache_save teach; echo "teach"; return
  fi
  teachok=0; [[ -n "$state" ]] && teachok=1
  if curl -s -m 4 -o /dev/null "http://172.30.255.42:801/" 2>/dev/null; then
    dormok=1; else dormok=0
  fi
  if [[ "$dormok" == 1 && "$teachok" == 0 ]]; then
    zone_cache_save dorm; echo "dorm"; return
  fi
  if [[ "$dormok" == 0 && "$teachok" == 1 ]]; then
    zone_cache_save teach; echo "teach"; return
  fi
  if [[ "$dormok" == 1 ]]; then
    echo "dorm"; return
  fi
  if [[ "$WIRED_MODE" == "1" ]] && has_default_route; then
    echo "dorm"; return    # 有线按宿舍区处理(教学区有线属教工区,不在本脚本范围)
  fi
  [[ "${DEBUG_NET:-0}" == "1" && -n "$ip" ]] && \
    log_line "DEBUG 区域探测未决 ip=[${ip}]"
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
    zone_cache_save dorm
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
  echo -n "$1" | openssl md5 -hmac "$2" | awk '{print $NF}'
}

sr_sha1() { # $1=内容 → SHA1
  echo -n "$1" | openssl sha1 | awk '{print $NF}'
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
  # v2.7 修复: 原逐字符 expr index 查表在本机 GNU expr 不可用,
  # 映射全部失效(密文变 "====…")。改 tr 双字符集整串映射。
  echo "$base64_encoded" | tr "$original" "$mapping"
}

# v2.8: 动态获取教学区当次 ac_id(不同区域/接入控制器值可能不同,
# 实测当前为 18;登录页通常带 ac_id=N,抓不到才回落配置默认值)。
# 可传入门户入口 $1:注销后直连 SRUN_BASE 被控制器丢弃时,改从
# 网关重定向探测到的真实入口抓取。
teach_ac_id() {
  local base="${1:-$SRUN_BASE}" ac
  ac="$(curl -sk -L -m 6 "$base/" 2>/dev/null | grep -oE 'ac_id=[0-9]+' | head -1 | cut -d= -f2)"
  [[ -z "$ac" ]] && \
    ac="$(curl -sk -L -m 6 "$base/index_8.html" 2>/dev/null | grep -oE 'ac_id=[0-9]+' | head -1 | cut -d= -f2)"
  [[ -z "$ac" ]] && ac="$SRUN_AC_ID"
  echo "$ac"
}

login_teach() {
  # ① 深澜自带的在线状态接口:not_online_error 才需要登录;
  #    v2.7: 状态接口空响应(接口抽风)但能走到这里=外网已确认
  #    不通,同样值得尝试登录,不再误判"已在线"漏登。
  local state
  state="$(curl -sk -m 8 "$SRUN_BASE/cgi-bin/rad_user_info" 2>/dev/null)"
  if [[ -n "$state" && "$state" != "not_online_error" ]]; then
    log_line "教学区检测显示已在线(可能仅外网检测误报),跳过登录"
    return 0
  fi

  # ② 取 challenge(加密令牌 + 本机 IP)
  # v2.8: 注销后控制器丢弃发往认证服务器的直连请求(HTTP/HTTPS 双
  # 超时,2026-09-09 实测),但浏览器靠网关透明 302 重定向到达门户。
  # 脚本照搬浏览器: HTTPS 直连失败 → 向公网 HTTP 地址发探测 → 从
  # Location 头提取真实可用门户入口 → 用该入口完成后续登录。
  local callback token ip_addr res
  callback="$(date +%Y%m%d_%H%M%S)"
  local challenge portal_origin="$SRUN_BASE"
  challenge="$(curl -sk -m 6 -G "$portal_origin/cgi-bin/get_challenge" \
    --data-urlencode "callback=$callback" \
    -d "username=${cid}" 2>/dev/null)"
  if [[ -z "$challenge" ]]; then
    # 网关重定向探测: 未认证时任意 HTTP 请求会被 302 到门户
    local loc portal_new
    loc="$(curl -s -m 6 -D - -o /dev/null 'http://www.msftconnecttest.com/connecttest.txt' 2>/dev/null \
      | grep -i '^location:' | head -1 | awk '{print $2}' | tr -d '\r')"
    portal_new="$(echo "$loc" | grep -oE '^https?://[^/]+' | head -1)"
    if [[ -n "$portal_new" && "$portal_new" != "$portal_origin" ]]; then
      portal_origin="$portal_new"
    else
      portal_origin="http://net.szu.edu.cn"
    fi
    log_line "  [门户探测] 直连超时,改用网关重定向入口: ${portal_origin:-未获取到}"
    challenge="$(curl -sk -m 8 -G "$portal_origin/cgi-bin/get_challenge" \
      --data-urlencode "callback=$callback" \
      -d "username=${cid}" 2>/dev/null)"
  fi
  token="$(echo "$challenge" | grep -o '"challenge":"[^"]*' | awk -F'"' '{print $4}')"
  ip_addr="$(echo "$challenge" | grep -o '"client_ip":"[^"]*' | awk -F'"' '{print $4}')"
  res="$(echo "$challenge" | grep -o '"res":"[^"]*' | awk -F'"' '{print $4}')"
  if [[ "$res" != "ok" || -z "$token" ]]; then
    log_line "网页自动登录失败(教学区): 无法获得 challenge -> ${res:-无响应}"
    # v2.7.1 诊断: 记录服务器原始返回,用于精确定位
    log_line "  [challenge原始返回] 入口=${portal_origin} 内容=${challenge:0:300}"
    # v2.7.2 诊断: 记录 DNS 解析结果(排查注销后 DNS 劫持)
    log_line "  [DNS解析] $(dscacheutil -q host -a name net.szu.edu.cn 2>/dev/null | grep ip_address | head -3 | tr '\n' ' ')"
    return 1
  fi

  # ③④⑤ 按深澜协议构造加密参数(v2.8: ac_id 从实际门户入口抓取)
  local enc_pwd info chkstr ac_id
  ac_id="$(teach_ac_id "$portal_origin")"
  enc_pwd="$(sr_md5 "$pass" "$token")"
  info="{\"username\":\"${cid}\",\"password\":\"${pass}\",\"ip\":\"${ip_addr}\",\"acid\":\"${ac_id}\",\"enc_ver\":\"srun_bx1\"}"
  info="{SRBX1}$(sr_base64 $(sr_encode "$info" "$token"))"
  chkstr="$(sr_sha1 "${token}${cid}${token}${enc_pwd}${token}${ac_id}${token}${ip_addr}${token}200${token}1${token}${info}")"

  # ⑥ 提交登录(v2.8: 与 challenge 同一门户入口)
  local resp
  resp="$(curl -sk -m 8 -G "$portal_origin/cgi-bin/srun_portal" \
    --data-urlencode "callback=$callback" \
    -d "action=login" \
    -d "username=${cid}" \
    -d "password={MD5}${enc_pwd}" \
    -d "chksum=${chkstr}" \
    --data-urlencode "info=${info}" \
    -d "ac_id=${ac_id}" \
    -d "ip=${ip_addr}" \
    -d "n=200" \
    -d "type=1" 2>/dev/null)"
  res="$(echo "$resp" | grep -o '"res":"[^"]*' | awk -F'"' '{print $4}')"
  if [[ "$res" == "ok" ]]; then
    log_line "网页自动登录成功(教学区)"
    zone_cache_save teach
    return 0
  fi
  local errmsg
  case "$res" in
    "auth_error"|"password_error") errmsg="账号或密码错误" ;;
    "login_error")                 errmsg="登录被拒绝(可能已在线或参数异常)" ;;
    "")                            errmsg="无返回信息,可能认证系统已变更" ;;
    *)                             errmsg="$res" ;;
  esac
  log_line "网页自动登录失败(教学区): ${errmsg} [本次ac_id=${ac_id}]"
  # v2.7.1 诊断: 记录服务器原始返回中的 error_msg/error 字段
  local srvmsg
  srvmsg="$(echo "$resp" | grep -oE '"error(_msg)?":"[^"]*' | head -2 | cut -d'"' -f4 | tr '\n' ' ')"
  log_line "  [login原始返回] ${srvmsg:-空} | resp头200字: ${resp:0:200}"
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
