# Tiwut AirBridge Pro

AirBridge Pro 是一款原生、高性能、超轻量的 macOS 桌面应用，使用 **Swift** 与 **SwiftUI** 编写。它是一套网络控制仪表盘、可视化工具与 Wi-Fi 中继桥接管理器——**完全在客户端运行，无后台服务器、Node.js 节点或 Web 包装层**。

应用实时运行，默认打开 **`860x640` 毛玻璃风格窗口**，并支持**自由缩放**以适应更大显示器、避免裁切。构建时自动打包自定义应用图标，以及面向 **Tiwut** 的开发者资料页。

界面语言跟随系统首选语言：任意 `zh*` 区域使用简体中文，否则为英文（`L10n.swift` / `AppLanguage.resolve`）。

---

## 功能

AirBridge Pro 在安全的管理员权限管理器中封装了底层 macOS 系统诊断与数据包守护进程（`pfctl`、`dnctl`、`tcpdump`、`defaults`）：

1. **一键集成热点开关：** 动态写入 `/Library/Preferences/SystemConfiguration/com.apple.nat.plist`，将入站网络（如 `en0`）桥接到副 AP 适配器（如 `en1`），一次安全提示即可加载共享守护进程。
2. **WLAN 遥测与信道分析：** 通过原生 `CoreWLAN` 显示 RSSI（dBm）、噪声（dBm）、SNR、实时链路发送速率（Mbps）、无线信道与 PHY 模式（如 Wi-Fi 6）。
3. **活动客户端防火墙屏蔽：** 向 macOS 数据包过滤器（`pfctl`）锚点插入 drop 规则，即时屏蔽或踢出桥接网络中的设备。
4. **数据测速与流量统计：** 通过 `getifaddrs` 字节计数计算实时上下行速度（KB/s）并累计流量（MB）。
5. **快速 DNS 重定向：** 通过动态更新 `bootpd.plist`，在系统默认、Cloudflare、Google 公共 DNS 或 AdGuard（广告拦截）DNS 之间切换共享客户端 DNS。
6. **端口转发管理：** 使用自定义 `pfctl` NAT 重定向，将 Mac 外部端口映射到内部客户端 IP。
7. **本地抓包终端控制台：** 通过 `tcpdump` 在桥接接口上捕获活动 IP 通信的实时缓冲控制台。
8. **带宽限速与流量限制：** 使用 macOS `dnctl`（dummynet）将客户端带宽限制为不限速、2、5 或 10 Mbps。
9. **延迟质量诊断：** 主动 RTT Ping 延迟与丢包检测工具。
10. **DHCP 静态 IP 预留：** 在 `/etc/bootpd.plist` 中将客户端 MAC 永久绑定到指定私有 IP。

---

## 项目结构

* **`main.swift`：** AppKit 外壳、CLI 解析、AppleScript 提权与 SwiftUI 仪表盘。
* **`L10n.swift`：** 双语界面字符串（英文 / 简体中文），通过 `L10n.text` / `L10n.format` 访问。
* **`PhyModeLabel.swift`：** CoreWLAN PHY 模式 → 标签映射（基于 rawValue，无需 SDK `.mode11be`）。
* **`IfconfigParser.swift`：** `ifconfig` 纯解析器与 `getifaddrs` 字节计数（含单测）。
* **`build.sh`：** 可移植构建（脚本相对路径）、图标打包、`Info.plist`，以及面向本机 `arm64`/`x86_64`、macOS **15.0** 的 `swiftc`。
* **`tests/test_compat.sh`：** 兼容性与性能守卫（离主线程刷新、开发者视图不 shell 等）。
* **`AirBridge.app`：** 生成的独立应用包。

---

## 构建与运行

### 1. 编译应用
请在将要运行该应用的 Mac 上重新构建（仓库内二进制可能面向更新的 macOS）。进入目录后执行：
```bash
./build.sh
./tests/test_compat.sh   # 可选：路径/SDK/PHY 模式兼容性检查
```
需要 Xcode Command Line Tools / macOS SDK。构建目标为本机架构、macOS 15.0。

### 2. 启动应用
打开**本目录下的** `AirBridge.app`（不要用 Downloads/DMG 里的旧副本——macOS App Translocation 可能继续启动陈旧包）：
```bash
open "$(pwd)/AirBridge.app"
```

若 Finder 提示应用已损坏（常见于下载/复制后），用 `./build.sh` 重建，或清除隔离属性：
```bash
xattr -cr AirBridge.app
codesign --force --deep --sign - AirBridge.app
```

---

## 安全说明
修改系统接口、路由表以及启动抓包引擎（如 `tcpdump` 与 `pfctl`）需要 macOS 高等级权限，因此在启动热点、屏蔽设备或限制带宽时会出现标准系统凭证对话框。**管理员凭据不会被保存或传输。**
