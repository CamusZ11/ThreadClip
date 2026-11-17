<p><img src="docs/images/icon.png" width="96" alt="ThreadClip 应用图标"></p>

# ThreadClip · 会话夹

[English](README.md) · [下载](https://github.com/CamusZ11/ThreadClip/releases/latest)

ThreadClip 把 Codex 会话挂在 Mac 屏幕上沿。鼠标移到上沿中央三分之一，就能看到哪些会话在运行、哪些需要你操作，以及最近对话。点卡片即可回到 Codex 的对应会话。

![ThreadClip 在 macOS 上显示运行中、远程待回答、已完成和最近对话四类卡片](docs/images/overview.png)

## 看懂卡片

| 图标 | 含义 |
| --- | --- |
| 转圈 | Codex 正在运行。 |
| 黄点 | Codex 正在等你选择、明确答复或处理支持的输入请求。 |
| 绿点 | 已跟踪的回合完成。点击绿卡并确认目标会话打开后，卡片会标为已读。 |
| 红点 | 已跟踪的回合失败。 |
| 灰点 | 最近对话。它们靠右显示，和状态卡片之间用细线隔开。 |

![原生悬挂条展开示例会话卡片，作答后黄卡转入最近对话](docs/images/hover.gif)

截图和动图使用示例会话，由 macOS 原生界面生成。当前应用界面为简体中文。

## 开始使用

1. 准备 macOS 14 或更新版本，以及 Codex 桌面应用。从 [Releases](https://github.com/CamusZ11/ThreadClip/releases) 下载应用 ZIP。公开 ZIP 使用临时签名，未通过 Apple 公证。如果 macOS 拒绝打开下载的副本，可以按照下文从源码构建。
2. 打开 `ThreadClip.app`，把鼠标悬停在主显示器上沿的中央三分之一。也可以从 ThreadClip 菜单栏图标选择「展开线程」。
3. 在菜单里打开「设置…」，调整最近对话数量、暂停自动弹出，或启用登录时启动。

<img src="docs/images/settings.png" width="460" alt="ThreadClip 的监控、自动弹出和最近对话数量设置">

## 本地和远程会话

- 本地会话通过只读方式读取 Codex 的 SQLite 元数据和近期会话事件。
- 远程会话使用已连接的 Codex 桌面应用共享的状态。在 Codex 打开远程会话后，ThreadClip 可通过本机进程间通信读取其状态，无需 SSH。
- 设备偏好、回合跟踪和未读提醒所需的最少标识保存在本机。ThreadClip 不修改 Codex 数据库，不提交答复或审批，也不把会话数据发送到 ThreadClip 服务器。
- 兼容性取决于 Codex 桌面应用的内部数据格式。本版已在 Apple 芯片上搭配桌面应用构建版本 `26.1111.21308` 验证。纯文字提问使用规则识别。本机审批检测仍待验证。

## 从源码构建

安装 Xcode 后运行以下命令。

```sh
git clone https://github.com/CamusZ11/ThreadClip.git
cd ThreadClip
swift test
./scripts/build-app.sh
open build/ThreadClip.app
```

构建默认使用临时签名。可以设置 `APPLE_SIGNING_IDENTITY` 使用自己的签名身份，或设置 `THREADCLIP_ARCH=universal` 构建同时支持 Apple 芯片和 Intel 的应用。

## 许可与致谢

ThreadClip 源码采用 [MIT 许可](LICENSE)。悬挂绳、夹子和原生浮窗行为改编自 Alejandro Buján 的 [Tendedero](https://github.com/alejandrobujan/tendedero/tree/e362da6d92e7ca9dd141de4017eae779dc1e4284)。ThreadClip 是适用于 Codex 的独立项目。
