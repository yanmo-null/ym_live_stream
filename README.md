# YM Live Stream

一个基于 Flutter 的多平台直播聚合客户端，支持**哔哩哔哩**、**斗鱼**、**抖音** 三个平台的直播间观看，并附带实时弹幕。

跨平台：Windows / Linux 桌面端，Android 手机端。

![应用图标](assets/icon/ymlive_logo.png)

---

## 目录

- [YM Live Stream](#ym-live-stream)
  - [目录](#目录)
  - [功能特性](#功能特性)
  - [平台支持情况](#平台支持情况)
    - [操作系统](#操作系统)
    - [直播平台](#直播平台)
    - [房间号规则](#房间号规则)
  - [各平台检索范例](#各平台检索范例)
    - [哔哩哔哩](#哔哩哔哩)
    - [斗鱼](#斗鱼)
    - [抖音](#抖音)
  - [构建与运行](#构建与运行)
    - [环境要求](#环境要求)
    - [拉取依赖](#拉取依赖)
    - [运行](#运行)
    - [打包](#打包)
  - [TODO 计划](#todo-计划)
    - [近期](#近期)
    - [中期](#中期)
    - [长期](#长期)
  - [关于](#关于)
  - [免责声明](#免责声明)
  - [致谢](#致谢)

---

## 功能特性

- **三平台直播观看**：哔哩哔哩、斗鱼、抖音，一个应用全搞定
- **多种清晰度切换**：从标清到蓝光/原画，按平台自动展示可用档位
- **线路切换**：同一清晰度下有多条流时（FLV / HLS，H.264 / H.265）可手动切换
- **实时弹幕**：右侧弹幕栏滚动显示，全屏时可叠加到画面上
- **分享链接直接粘贴**：从手机 App 复制的整段分享文本，粘进搜索框就能看
- **关注列表**：收藏常看的直播间，主页单独展示「特别关注」
- **全屏 / 适配窗口**：桌面端可窗口全屏，也可只让画面铺满窗口不动窗口本身
- **本地存储**：关注列表存在本地 Hive 数据库，不联网、不上传

---

## 平台支持情况

### 操作系统

| 平台 | 状态 | 说明 |
|---|---|---|
| Android | ✅ 已支持 | 所有功能 |
| Windows | ✅ 已支持 | 所有功能完整可用 |
| Linux | ✅ 已支持 | 同 Windows，实机充分验证 |
| macOS | ❌ 未适配 | 暂无设备后期适配|
| iOS | ❌ 未适配 | 暂无设备后期适配 |

### 直播平台

| 平台 | 直播观看 | 清晰度切换 | 线路切换 | 实时弹幕 | 分享链接解析 |
|---|---|---|---|---|---|
| 哔哩哔哩 | ✅ | ✅ 原画/蓝光/超清/2K/4K/杜比 | ✅ | ✅ | ✅ `b23.tv` 短链 |
| 斗鱼 | ✅ | ✅ 原画/蓝光/超清/高清 | ✅ | ✅ | ✅ 直播间链接 |
| 抖音 | ✅ | ✅ 原画/蓝光/超清/高清/标清 | ✅ | ✅ | ✅ `v.douyin.com` 短链 |

> 清晰度的实际可用档位由主播的推流设置决定，应用只展示该房间真实存在的档位。

### 房间号规则

| 平台 | 房间号长度 | 说明 |
|---|---|---|
| 哔哩哔哩 | 3 ~ 12 位数字 | 短号可只有 3 位（如 `732`） |
| 斗鱼 | 3 ~ 12 位数字 | 常见 3 ~ 8 位 |
| 抖音 | 6 ~ 20 位数字 | 实际使用的是 `web_rid`（通常 12 位） |

---
## 各平台检索范例

### 哔哩哔哩

**可用输入**：

```
732                                    ← 纯数字短号
440006                                 ← 纯数字房间号
https://live.bilibili.com/440006       ← 直播间链接
live.bilibili.com/440006               ← 省略协议
https://b23.tv/8P8sN3S                 ← 分享短链
【闲聊-哔哩哔哩直播】 https://b23.tv/8P8sN3S   ← 完整分享文本
```


**清晰度档位**（按主播推流实际存在的显示）：

| 档位 | 说明 |
|---|---|
| 杜比 | 需要登录且有对应权限 |
| 4K / 2K | 高码率，带宽要求高 |
| 原画 | 主播原始画质 |
| 蓝光 / 超清 / 高清 | 降级档位 |

> 部分房间需要登录才能获取某些清晰度，可在设置页扫码登录哔哩哔哩账号。

### 斗鱼

**可用输入**：

```
71415
https://www.douyu.com/71415
www.douyu.com/71415
```

**清晰度档位**：原画 / 蓝光 / 超清 / 高清

### 抖音

**可用输入**：

```
932584152016                                  ← web_rid（推荐）
https://live.douyin.com/932584152016          ← 直播间链接
https://v.douyin.com/l_VT4cS1IM8/             ← 分享短链
1- #在抖音，记录美好生活#【三桥qzg】正在直播... https://v.douyin.com/l_VT4cS1IM8/ 7@0.com :9pm   ← 完整分享文本
```

**清晰度档位**：原画 / 蓝光 / 超清 / 高清 / 标清

---

## 构建与运行
**注意：因为不想引起不必要的法务麻烦，所以此开源版本不包含后端的网络交互和逆向源码，如有确切需求，可以邮件联系我本人。感谢体谅**

### 环境要求

- Flutter SDK `^3.12.2`（Dart `^3.12.2`）
- Android 构建：Android SDK，`minSdk 21`
- Windows 构建：Visual Studio 2022（含 C++ 桌面开发）

### 拉取依赖

```bash
flutter pub get
```

### 运行

```bash
# 桌面端
flutter run -d windows    # 或 macos / linux

# Android
flutter run -d <device-id>
```

### 打包

```bash
# Android
flutter build apk --release

# Windows
flutter build windows --release
```

## TODO 计划

### 近期

- [ ] 增加快手和虎牙平台支持
- [ ] 增加弹幕横屏滚动模式

### 中期

- [ ] 增加海外平台Youtube、Twitch等平台支持
- [ ] 直播录制（保存为 FLV / MP4）

### 长期
- [ ] 增加录播功能，保存为 FLV / MP4，方便切片
- [ ] iOS 及 MacOS适配

## 关于

| 项 | 内容 |
|---|---|
| 应用名 | `YM Live Stream` |
| 创作者 | `YanMo` |
| GitHub | `https://github.com/yanmo/ym_live_stream` <!-- TODO: 确认真实仓库地址 --> |
| Telegram 讨论组 | `https://t.me/your_group` <!-- TODO: 替换成真实链接 --> |
| Discord 服务器 | `https://discord.gg/your_invite` <!-- TODO: 替换成真实邀请链接 --> |
| 问题反馈 | `https://github.com/yanmo/ym_live_stream/issues` <!-- TODO --> |
| Android 包名 | `io.github.yanmo.ymlivestream` |
| 版权 | Copyright © 2026 YanMo |

---

## 免责声明

本项目仅供**个人学习与技术研究**使用，不提供、不存储、不托管任何直播内容。

- 所有直播流、房间信息均来自各平台公开接口，版权归各平台及主播所有
- 请勿将本项目用于商业用途，或任何侵犯平台权益的行为
- 使用本项目可能违反某些平台的服务条款，请自行评估风险
- 因使用本项目产生的一切后果由使用者自行承担

本项目与哔哩哔哩、斗鱼、抖音均无关联，未获官方授权。

---

## 致谢

- [media_kit](https://github.com/media-kit/media-kit) —— 跨平台视频播放
- [Flutter](https://flutter.dev/) —— 跨平台 UI 框架
- [GetX](https://github.com/jonataslaw/getx) —— 状态管理与路由
- [Hive](https://github.com/isar/hive) —— 本地键值存储

---

<!--
给维护者的备注（发布前删除本段）：

1. 还剩 `your_group` / `your_invite` 两处占位（Telegram、Discord），
   以及 GitHub 仓库地址需要与真实仓库核对一次
2. 「关于」页的信息在 lib/presentation/home_page.dart 顶部的 _kApp* 常量里，
   改这里时记得和本文档的「关于」表格同步
3. 升版本号要同时改两处：
   - pubspec.yaml 的 version
   - home_page.dart 的 _kAppVersion
4. TODO 里带 [x] 的已完成项记得更新
5. 应用图标是 assets/icon/ymlive_logo.png，改完跑 dart run flutter_launcher_icons

【包名】io.github.yanmo.ymlivestream —— 已经定死，不要在发布后修改。
改它等于换一个新应用，老用户收不到更新。涉及三处：
   - android/app/build.gradle.kts 的 namespace / applicationId
   - android/app/src/main/kotlin/io/github/yanmo/ymlivestream/MainActivity.kt
   - macos/Runner/Configs/AppInfo.xcconfig 的 PRODUCT_BUNDLE_IDENTIFIER
-->
