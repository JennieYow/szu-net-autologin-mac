# szu-net-autologin-mac

**macOS 校园网断网自动重连工具(深圳大学宿舍区 + 教学区双区适配)**

合盖再开、睡眠唤醒、会话超时后,**无需打开浏览器、无需输入账号密码**,后台自动完成校园网网页认证,1 分钟内恢复上网。

> 一句话原理:一个小脚本定期检查网络(默认 15 秒,可在 plist 中按需调整),发现掉线就替你向认证服务器"点一次登录按钮"——账号密码只存在你本机的钥匙串里。

---

## ✨ 功能特性

- 🔄 **全自动重连**:断网后自动模拟网页登录,无需任何手动操作
- 🧭 **双区智能识别**:自动判断你在宿舍区还是教学区,走对应的认证协议
- 🔐 **凭据零落盘**:账号密码只存 macOS 钥匙串(系统级加密),脚本文件里没有任何敏感信息
- 🤫 **零打扰**:不弹窗、不开浏览器、不启动任何 GUI 程序;连非校园网 WiFi(热点/家庭网络)时自动静默
- 🛡️ **礼貌且安全**:登录失败有 100 秒冷却,不会疯狂重试骚扰认证服务器
- ⚡ **几乎零开销**:每轮检测耗时约 0.1~0.3 秒,睡眠期间完全不运行

## 🎯 解决什么问题

深大宿舍区(`SZU_CTC&CMCC`)采用 Dr.COM eportal 网页认证:连上 WiFi 后必须打开浏览器输入账号密码,而且**会话很脆弱**——合盖睡眠、长时间无流量、IP 租约到期都会让会话失效,于是每次开盖都要重新登录一遍。

本工具让这件事彻底消失:合盖 → 开盖 → 直接上网。

## 🧭 工作原理

```
launchd 定时器(每 15 秒)
   └─> autologin.sh
         ├─ ① 认区:我现在在宿舍区还是教学区?
         │     三级判断(由快到慢):
         │     a. 读 SSID 比对          (零开销)
         │     b. 按 IP 网段比对         (零开销)
         │     c. 探测认证服务器谁应答   (约 1~3 秒,永不失效)
         ├─ ② 探在线:按区域询问各自的认证服务器/公网探针
         └─ ③ 在线 → 退出;离线 → 冷却检查 → 从钥匙串取凭据 → 模拟网页登录
```

两个区域使用不同的认证协议(均已内置):

| 区域 | WiFi | 认证系统 | 协议 |
|---|---|---|---|
| 宿舍区 | `SZU_CTC&CMCC` | Dr.COM(新版 eportal) | 一个 GET 请求(JSONP) |
| 教学区 | `SZU_WLAN` | 深澜 Srun(2025-01 起) | challenge → HMAC-MD5 → XXTEA 加密 → 自定义 base64 → SHA1 校验和,五道工序 |

教学区还有两处自适应设计(v1.1.0):

- **ac_id 动态获取**:深澜的 `ac_id` 会随接入控制器/楼栋变化(实测见过 8、12、18),脚本登录前先抓登录页解析当次真实值,抓不到才回落配置值;
- **门户入口自适应**:注销后学校控制器会丢弃发往认证服务器的直连请求(见"已知坑"第 6 条),脚本会像浏览器一样从网关的 302 重定向中探测真实可用的门户入口,再走完整登录流程。

## 📦 安装

### 方式一:一键安装(推荐)

```bash
git clone https://github.com/JennieYow/szu-net-autologin.git
cd szu-net-autologin
chmod +x install.sh
./install.sh
```

安装程序会依次:保存账号密码到钥匙串 → 复制脚本 → 注册定时服务 → 自检。**深圳大学用户无需任何额外配置。**

### 方式二:手动安装

```bash
# ① 保存凭据到钥匙串(把引号内换成你的账号密码)
security add-generic-password -U -s szu-portal -a "6位校园卡号" -w "统一身份认证密码"

# ② 安装脚本
mkdir -p "$HOME/Library/Application Support/SZUAutoLogin"
cp autologin.sh config.example.sh "$HOME/Library/Application Support/SZUAutoLogin/"
mv "$HOME/Library/Application Support/SZUAutoLogin/config.example.sh" \
   "$HOME/Library/Application Support/SZUAutoLogin/config.sh"
chmod +x "$HOME/Library/Application Support/SZUAutoLogin/autologin.sh"

# ③ 注册定时服务(每 15 秒检测一次)
cp com.autologin.plist.template ~/Library/LaunchAgents/com.szu.autologin.plist  # 并按文件内注释修改路径
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.szu.autologin.plist
```

### 其他学校适配

只要你的学校用的是同类认证系统,改 `config.sh` 即可:

- **新版 Dr.COM eportal**(登录 URL 含 `:801/eportal/portal/login`):改 `DORM_PORTAL_URL` 与 `DORM_SSIDS`;
- **深澜 Srun**(登录页一般为 `xxx.edu.cn`,带 srun_portal 接口):改 `SRUN_BASE`、`SRUN_AC_ID`(用浏览器 F12 抓登录请求里的 `ac_id`)与 `TEACH_SSIDS`;
- 详见 `config.example.sh` 内注释。

## 🔍 日常使用

```bash
# 看实时日志(自动重连时会滚动显示)
tail -f ~/Library/Logs/szu-autologin.log

# 修改密码后重新保存凭据(覆盖旧的)
security add-generic-password -U -s szu-portal -a "卡号" -w "新密码"

# 临时停用 / 恢复
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.szu.autologin.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.szu.autologin.plist

# 调整自查间隔(默认 15 秒;若想更省电可调回 30~45 秒)
plutil -replace StartInterval -integer 15 ~/Library/LaunchAgents/com.szu.autologin.plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.szu.autologin.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.szu.autologin.plist
```

成功时日志形如:

```
2026-09-08 17:15:02 检测到断网(区域: teach),尝试网页自动登录 ...
2026-09-08 17:15:03 网页自动登录成功(教学区)
```

## 🗑️ 卸载

```bash
./uninstall.sh
```

会停止服务、删除所有文件,并询问是否连钥匙串凭据一起删除。

## ⚠️ 已知坑(实战踩出来的,macOS 用户必读)

1. **macOS 隐私保护会隐藏 WiFi 名**。没有"定位服务"权限的程序读取 SSID 时,`ipconfig getsummary` 返回字面量 `<redacted>`,`networksetup -getairportnetwork` 则谎称"未连接"。所以本脚本**不依赖 SSID 存活**——SSID 只是第一级快速判断,读不到会自动退到 IP 网段和服务器探测。这也是网上同类脚本"时灵时不灵"的最常见原因。
2. **`networksetup` 输出随系统语言变化**。中文系统输出"当前 Wi-Fi 网络: xxx"而非英文前缀,按英文格式解析会失败。本脚本用键名固定的 `ipconfig getsummary` 作主读取方式,并用兼容中英文的解析兜底。
3. **IP 网段因楼栋而异**。同一 SSID 在不同教学楼可能分配不同网段,不要只依赖单一 IP 前缀判断区域——本脚本因此内置了"探测认证服务器"这一级兜底(两台认证服务器仅校内可达,谁应答就能定位区域)。
4. **客户端与网页会话互斥**。若同时运行 Dr.COM 客户端,可能与网页登录互相踢下线,请二选一(本方案请卸载/退出客户端)。
5. **LaunchAgent 解释器必须写 `/bin/bash`**。加密函数依赖 bash 数组语义,写成 `/bin/zsh` 会导致教学区(深澜协议)登录异常。
6. **注销后认证服务器会"拒收"直连请求(教学区实测)**。主动注销下线后,控制器会丢弃未认证设备发往认证服务器(HTTP/HTTPS)的直连请求——表现为接口超时无响应;而浏览器能打开登录页,是因为它走网关的透明 302 重定向通道。v1.1.0 起脚本会在直连超时后自动探测网关重定向入口,用浏览器同款路径完成登录。另外深澜对在线设备有"会话保持"(IP 不变则合盖重连不掉线),日常不主动注销基本用不到重新认证。
7. **macOS 自带 `openssl` 输出无前缀、GNU 版 `expr` 不支持 `index`**。老教程里的 `awk '{print $2}'` 取 HMAC 结果、`expr index` 做 base64 映射在当代 macOS 上都会静默失败(返回空),导致登录参数残缺、服务器回空。本脚本已用 `$NF` 取列 + `tr` 映射修正,自己移植深澜协议时务必注意这两处。

## ❓ FAQ

<details>
<summary>弹出"xxx 想访问钥匙串"怎么办?</summary>

点「始终允许」。这是因为钥匙串条目的访问控制列表(ACL)里没有当前读取者,授权一次后即恢复正常。
</details>

<details>
<summary>日志提示"账号或密码错误"?</summary>

密码打错或改过密码。重新执行安装程序(或单跑 `security add-generic-password -U ...`),`-U` 参数会覆盖旧凭据。
</details>

<details>
<summary>教学区登录一直失败:"无返回信息"/"无法获得 challenge"?</summary>

v1.1.0 起脚本失败时会把服务器原始返回、DNS 解析、本次使用的 ac_id 一并写入日志,先看日志再对症下药:

- `challenge原始返回` 有内容但不是 JSON → 学校可能调整了认证接口,浏览器 F12 核对 `srun_portal` 请求参数,改 `config.sh` 中的 `SRUN_AC_ID`;
- 显示"账号或密码错误" → 重新保存钥匙串凭据(注意 `-U` 覆盖);
- 仍无法定位 → 开 `DEBUG_NET=1` 抓几轮日志提 issue。
</details>

<details>
<summary>插网线能用吗?</summary>

可以。保持 `WIRED_MODE=1`(默认),未连 WiFi 但有网络连接时按宿舍区处理。
</details>

<details>
<summary>耗电吗?</summary>

可忽略。每 15 秒一轮、每轮约 0.1~0.3 秒 CPU 轻载;合盖睡眠期间 launchd 定时器不会触发,零开销。
</details>

## 🔒 安全与隐私

- 账号密码**只存本机钥匙串**,由 macOS 全盘加密保护;脚本、配置、日志中均无明文密码;
- 脚本只在检测到断网时向**你自己学校的认证服务器**发起登录,不连接任何第三方服务器;
- 日志仅记录区域与结果,不含账号密码。

## 📜 免责声明

本项目仅供个人学习与本人在校园网内的便利使用,请遵守所在学校的网络使用规定。因使用本工具产生的任何后果由使用者自行承担。

## 🙏 致谢

- [ceynri/szu-network-connecter](https://github.com/ceynri/szu-network-connecter) —— 宿舍区新版 eportal 协议实现参考(MIT)
- [SoY0ung/SZU-SRUN](https://github.com/SoY0ung/SZU-SRUN) —— 教学区深澜(Srun)协议 Shell 实现参考

## 📜 版本历史

- **v1.1.2**(2026-09-10):默认自查间隔 45 → 15 秒(实测开销可忽略,开机/唤醒后联网更快;安装程序与 plist 模板同步)
- **v1.1.1**(2026-09-10):补充自查间隔调优指引(15 秒实测开销可忽略,开机/唤醒恢复更快);plist 模板补充重载说明
- **v1.1.0**(2026-09-09)
  - 修复教学区两个致命加密 bug:macOS LibreSSL `openssl md5/sha1` 输出无前缀导致取列得空、GNU 版 `expr` 不支持 `index` 导致 base64 映射失效(教学区登录失败的真凶);
  - 教学区 ac_id 动态获取 + 兜底值修正(12 → 18);
  - 新增门户入口自适应:注销后直连被控制器丢弃时,自动探测网关 302 重定向的真实门户入口完成登录;
  - 区域识别防抖:实测宿舍网可同时到达两台认证服务器,新增"网关未变沿用上次区域"缓存防误判;
  - 失败日志增强:记录服务器原始返回 / DNS 解析 / 本次 ac_id,排障不再靠猜。
- **v1.0.1**(2026-09-09):教学区 ac_id 动态获取、区域识别防抖、补宿舍网段实测值
- **v1.0.0**(2026-09-08):首次发布,宿舍区 + 教学区双区适配

## 📄 许可证

[MIT](LICENSE)
