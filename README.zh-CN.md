[English](README.md) · [简体中文](README.zh-CN.md)

<p align="center">
  <img src="Resources/app_icon.png" width="128" height="128" alt="CellDock 图标">
</p>

<h1 align="center">CellDock</h1>

<p align="center">
  在 Mac 上使用蜂窝网络、短信和电话。
</p>

<p align="center">
  <sub>界面预览 · 点击图片查看原图</sub>
</p>

| 短信 | 电话 |
| :---: | :---: |
| <a href="screenshot/1. sms.png"><img src="screenshot/1. sms.png" width="320" alt="短信"></a> | <a href="screenshot/2. call.png"><img src="screenshot/2. call.png" width="320" alt="电话"></a> |

| 录音 | 代理 |
| :---: | :---: |
| <a href="screenshot/3.records.png"><img src="screenshot/3.records.png" width="320" alt="录音"></a> | <a href="screenshot/4. proxy.png"><img src="screenshot/4. proxy.png" width="320" alt="代理"></a> |

| 设置 |
| :---: |
| <a href="screenshot/6. settings.png"><img src="screenshot/6. settings.png" width="320" alt="设置"></a> |

CellDock 是一款原生 macOS 菜单栏应用，用于连接 QDC507 蜂窝模组。插入模组后，
你可以直接在 Mac 上使用蜂窝网络、收发短信、管理通讯录、拨打电话、保存通话录音，
或把指定模组的蜂窝连接作为 SOCKS5 代理共享，无需浏览器服务或额外的通信软件。

## 主要功能

### 多模组与蜂窝网络

- 同时发现并监测多个受支持的 USB 蜂窝模组。
- 通信模组和上网模组可分别选择；同一时间只有一个模组作为系统的蜂窝优先出口。
- 每个模组可设为“蜂窝优先”“保持连接”或“关闭”；保持连接的模组可继续供绑定的
  SOCKS5 代理使用，但不会成为 macOS 的默认网络出口。
- 开启后自动让蜂窝网络优先于 Wi-Fi。
- 关闭后恢复原来的网络顺序，不影响短信和来电接收。
- 每个模组分别保存蜂窝网络开关状态；同一模组重新连接时恢复之前的选择。
- ECM 链路、DHCP 或模组重启异常时执行有边界的自动恢复。
- 实时显示运营商、网络制式、信号强度、IP 地址和连接阶段。
- 可选在菜单栏以固定宽度、上下两行显示实时下载和上传速度，默认关闭。

### SOCKS5 代理

- 为不同模组分别创建 SOCKS5 代理，让应用或局域网设备选择具体的蜂窝出口。
- 可仅监听本机，也可监听局域网；端口从 `1080` 起自动分配并可修改。
- 支持无认证和用户名/密码认证；局域网监听必须配置认证。
- 每个代理可独立启停，并显示连接数、模组离线、蜂窝网络关闭、链路中断或端口占用等
  运行状态。
- 代理绑定稳定的模组身份；模组重新插入后会重新解析网络接口。认证密码保存在 macOS
  钥匙串中。

> 局域网代理会把蜂窝出口开放给同一网络中的其他设备。请使用强密码，并确认本机防火墙
> 和所处网络可信。

### 短信

- 后台接收短信并发送 macOS 通知。
- 按会话查看完整短信，复制正文、回复或新建短信。
- 发送中文短信和长短信。
- 自动识别验证码，点击即可复制并标记已读。
- 短信记录标注来源模组；可在不同可用模组之间选择发送目标。
- 删除后不再出现在 CellDock；如果短信仍保存在模组中，CellDock 会同时尝试清理。
- 可选在验证码短信已读 30 分钟后自动删除。

### 电话与录音

- 拨号、接听、拒接、静音和挂断。
- 来电时显示带“接听”和“拒接”按钮的通知与浮窗。
- 通话中提供数字拨号盘，可操作客服语音菜单。
- 使用 Mac 的麦克风和扬声器进行通话。
- 保存最近通话与未接来电，并记录通话所使用的模组。
- 支持手动录音和经用户确认后自动录音，录制双方声道并保存为 M4A。
- 录音库支持波形、播放、跳转、倍速、音量、重命名、导出和在访达中显示。

> 使用通话录音前，请先取得通话参与者同意，并遵守所在地法律法规。

### SIM、eSIM 与通讯录

- 查看 SIM 状态、ICCID、IMSI、本机号码、运营商、网络制式和信号信息。
- 分别配置每个模组是否接收来电；需要重启模组的操作会明确提示。
- 自动识别物理 SIM 与 eUICC。
- 对受支持的 eUICC 查看 EID 和套餐，并可下载、启用、停用、重命名或删除 eSIM 套餐。
- 读取 macOS 系统通讯录，匹配短信与来电姓名。
- 在 CellDock 中新建、编辑、删除联系人和管理联系人分组。

### 菜单栏、声音与界面

- 支持模组热插拔，无需重启应用。
- 菜单栏图标显示通话、未接来电、未读短信、当前上网模组或可通话模组状态。
- 菜单栏面板按模组显示未读短信和未接来电；没有待处理内容时自动隐藏对应区块。
- 可自定义短信提示音和来电铃声；默认使用 `bleeps.wav` 与 `ring.mp3`。
- 支持简体中文、English、日本語和 Français，可在设置中即时切换。
- 支持跟随系统、浅色和深色主题。
- 演示隐私保护可隐藏联系人、号码、短信正文、验证码和录音标题。
- 可打开标准主窗口；关闭窗口后继续在菜单栏运行。
- 可选择模组未插入时隐藏菜单栏图标。
- 可选择登录 Mac 时自动启动，默认关闭。
- 内置稳定版和测试版更新频道，可自动检查或手动检查更新。

### USB 模式、恢复与诊断

- 修改前读取并校验 QDC507 USB composition。
- 支持 Mac Mode（开启 USB Audio）与 iPhone Mode（关闭 USB Audio）切换，同时保留
  诊断、NMEA、AT、Modem、网络和 ADB 等未被本次操作指定的字段。
- 保存切换前配置，并能恢复中断的 USB 转换；不会静默执行持久化恢复出厂操作。
- 对冷插入、AT 或注册延迟、模组重启、USB 重插、ECM/DHCP 异常和 macOS 睡眠唤醒
  进行有界恢复。
- 记录恢复次数、失败阶段、耗时、CFUN 电源切换、模组重新发现、AT 恢复和网络恢复。
- 设置中的“复制连接诊断报告”覆盖 USB、AT、SIM 就绪状态、运营商/RAT/信号、网络
  接口与连通性、恢复历史、睡眠唤醒和电源管理状态。
- 诊断报告明确排除 ICCID、IMSI、IMEI 和电话号码。当前可复制到剪贴板，尚未提供
  独立文件导出。
- USB 模式测试页通过现有 ModemService 执行用户明确输入的诊断 AT 命令，不会另开
  第二条 USB 或串口连接。

### 远程与 Agent Bridge

- 本地 WebSocket Bridge 使用令牌认证，向 `ios/CellDockRemote` 实验性 iOS 伴侣提供
  脱敏设备状态和受限通话控制。
- `NeedleBridge` 提供可选的状态、通话和短信工具路由进程，通过 `NEEDLE_PYTHON` 或
  标准 Python 路径启动，并有独立测试。

## 开始使用

要求：

- Apple Silicon Mac，macOS 14 或更高版本
- Xcode 16 或更高版本，支持 Swift 6
- 真实模组功能需要受支持的 QDC507/DJI 4G USB 模组和兼容 SIM

Clone 后运行离线验证：

```sh
git clone https://github.com/perry421/CellDock.git
cd CellDock
zsh scripts/run_tests.sh
swift build -c release
```

开发运行使用 `swift run CellDock`。通话、短信、USB composition、网络恢复和 Remote
Bridge 真机检查需要连接模组；默认自测使用匿名 fixture，不会发起真实拨号。

签名 App 归档脚本为 `scripts/build_app.sh`，必须提供 Apple Development 或 Developer ID
Application 证书。脚本会拒绝 ad-hoc 归档，避免破坏钥匙串与 helper 身份连续性。

## 项目结构

- `Sources/CellDock`：macOS SwiftUI App、ModemService、短信/电话/网络状态、恢复、USB 模式和诊断界面。
- `Sources/CModemBridge`：ModemService 使用的单一 IOKit/USB bridge。
- `Sources/CellDockNetworkHelper`：网络顺序和接口操作 helper。
- `Sources/NeedleBridge`、`Sources/NeedleLibrary`：可选本地 Agent bridge。
- `ThirdParty`：按原许可证保留的电话与 eSIM 第三方组件。
- `Tests`、`scripts/run_tests.sh`：确定性自测和匿名 fixture。
- `ios/CellDockRemote`：实验性 iOS 伴侣 package。

## 已知限制与 Roadmap

- 硬件支持目前以 QDC507/DJI 4G 模组和 macOS 14+ 为主。
- 运营商固件、SIM 开通状态、USB 拓扑和 macOS 网络策略会影响数据、短信、通话和 eSIM。
- iOS 伴侣和 Needle bridge 仍属于实验性开发界面。
- Diagnostics 当前可复制到剪贴板，尚未导出为独立文件包。
- 后续计划包括更多模组验证、打包式诊断归档和更完整的真机恢复覆盖。

## 鸣谢

特别感谢 [moluncn/mavo](https://github.com/moluncn/mavo) 项目。CellDock 在界面与功能设计上参考了 mavo，得益于原作者的开源工作，特此鸣谢。

## 免责声明

- CellDock 按“现状”提供，不附带任何明示或默示的担保，作者不对其适用性或特定用途表现作任何保证。
- 本软件会修改 macOS 的网络配置（例如将蜂窝网络设为优先出口、安装网络辅助组件），可能影响既有网络连接，使用前请确认了解相关功能。
- 蜂窝网络、短信、电话与 eSIM 等功能的可用性受模组固件、SIM 卡、运营商及当地网络环境影响，作者不保证其在所有环境下的可用性或表现。
- 将蜂窝连接通过 SOCKS5 代理共享给局域网设备，会将该网络出口暴露给同一网络中的其他设备，请自行评估安全风险并妥善配置认证。
- 通话录音前请取得通话参与者的同意，并遵守所在地法律法规；使用蜂窝共享等功能时也请遵守运营商的服务条款。
- 因使用或无法使用本软件而造成的任何直接或间接损失，作者均不承担责任。

## 许可证

CellDock 应用代码使用[非商业使用许可](LICENSE)：个人和非商业用途可免费使用、
修改与分发；**禁止任何形式的商业使用**，商业使用需另行获得作者书面授权。
第三方组件及其许可证说明见 [THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md)。
