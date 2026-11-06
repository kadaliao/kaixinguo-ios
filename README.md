<p align="center">
  <img src="Kaixinguo/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="128" height="128" alt="开心果">
</p>

<h1 align="center">开心果 iOS</h1>

<p align="center">
  <b>无广告、不烧心</b><br>
  红果短剧的极简 iPhone / iPad 客户端
</p>

![iPhone 上的推荐、剧集详情和播放](docs/screenshots/iphone.webp)

开心果 iOS 是 [开心果](https://github.com/kadaliao/kaixinguo)（macOS）的 iPhone 和 iPad 版：没有广告、没有弹窗，打开就是剧。界面用 SwiftUI 写成，播放用系统播放器，支持画中画和锁屏控制。

## 功能

- **发现**：推荐、排行榜（按类型和榜单）、新剧上线（前后两周的日历）、热搜榜，下拉刷新
- **搜索**：边输入边联想，同一部剧的各季按顺序排好
- **收藏**：剧集页点「收藏」，或在任意列表里长按海报
- **续播**：记住每部剧看到第几集、第几秒，「我的 › 最近观看」一点就接着看；看完的集在选集里打勾
- **连播**：一集放完自动下一集，一季看完接下一季
- **选集**：长剧每 100 集一段，多季的剧一键切换
- **画中画**：播放时回到主屏幕或点画中画按钮，视频缩到小窗里继续放；在小窗里点还原，回到播放页
- **长按倍速**：按住画面 2 倍速播放，松手恢复；按住时下滑锁定 2 倍速，之后再按住上滑取消
- **锁屏和控制中心**：显示剧名、集数和封面，可以暂停、拖动、换集
- **iPad**：侧栏或顶部标签栏随意切换，播放页右边是选集面板，支持外接键盘
- 跟随系统的浅色和深色外观

![iPad 上的剧集详情和播放](docs/screenshots/ipad.webp)

## 安装

开心果 iOS 不在 App Store 上架，需要用 Xcode 装到自己的设备上：

1. 需要一台 Mac，装好 Xcode 26 或更新的版本，以及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。
2. 克隆仓库，生成并打开工程：

   ```sh
   git clone https://github.com/kadaliao/kaixinguo-ios.git
   cd kaixinguo-ios
   xcodegen
   open Kaixinguo.xcodeproj
   ```

3. 在 Kaixinguo target 的 Signing & Capabilities 里选择自己的开发团队（工程里默认是维护者的团队），连上 iPhone 或 iPad，点运行。

需要 iOS / iPadOS 18 或更高版本。第一次打开工程时，Xcode 会从 GitHub 下载 openhongguo 的 Swift 包（约 17 MB）。用免费的 Apple ID 签名的应用 7 天后需要重新安装。

## 使用

| 操作 | 作用 |
| --- | --- |
| 长按海报 | 收藏 / 取消收藏 |
| 长按「最近观看」里的剧 | 继续播放，或从最近观看中移除 |
| 点简介 | 展开 / 收起 |
| 播放页「选集」 | iPhone 上从底部弹出选集面板 |
| 按住播放画面 | 2 倍速播放，松手恢复原来的倍速 |
| 按住画面再下滑 | 锁定 2 倍速 |
| 锁定后按住画面再上滑 | 取消 2 倍速，恢复原来的倍速 |
| 横过来 | iPhone 横屏时只显示视频 |

iPad 接上键盘时：

| 快捷键 | 作用 |
| --- | --- |
| ⌘F | 搜索 |
| ⌘[ | 返回 |
| ↑ ↓ | 上一集 / 下一集（播放时） |
| Esc | 退出播放 |
| 空格、← → | 播放 / 暂停、快退 / 快进（系统播放器自带） |

开心果也认 `kaixinguo://` 链接，可以在「快捷指令」或别的应用里用：

| 链接 | 打开 |
| --- | --- |
| `kaixinguo://series/<剧集 ID>` | 剧集详情 |
| `kaixinguo://play/<剧集 ID>?episode=3` | 播放第 3 集；不带 `episode` 时从上次看到的地方接着放 |
| `kaixinguo://search?q=<关键词>` | 搜索 |
| `kaixinguo://discover`、`rank`、`new`、`mine` | 对应的标签页 |

观看记录和收藏只存在设备上，不会上传，删除应用时一并删除。文件格式和 macOS 版相同：

| 内容 | 位置（应用沙盒内） |
| --- | --- |
| 观看记录 | `Library/Application Support/history.json` |
| 收藏 | `Library/Application Support/favorites.json` |
| 匿名设备 | `Library/Application Support/openhongguo/anonymous.json`，不参与 iCloud 备份 |
| 封面和推荐缓存 | `Library/Caches/` |

## 常见问题

**第一次打开，列表很久才出来？**
第一次启动要注册一个匿名设备，网络慢时可能要等十几秒。之后启动会先显示上次的推荐。

**某些剧提示「暂不支持这种视频格式」？**
目前只支持整段的 MP4，分段（DASH/HLS）的长视频还不能播放。

**有的集数带一把锁？**
那一集需要登录红果账号才能看，开心果不提供登录。

**能投屏到 Apple TV 吗？**
视频是在手机上边下边解密的，Apple TV 拿不到解密后的地址，所以 AirPlay 只能用控制中心的「屏幕镜像」。

**加载失败或者播放卡住？**
在 Xcode 里编辑 Kaixinguo scheme，在 Run › Arguments › Environment Variables 里加上 `KX_DEBUG=1`，再从 Xcode 运行，控制台会打印每个请求，提 issue 时附上。

## 开发

```sh
xcodegen                          # 改了 project.yml、增删了文件之后重新生成工程
(cd KaixinguoKit && swift test)   # 逻辑测试：在 Mac 上直接跑，不需要模拟器和网络
xcodebuild test -project Kaixinguo.xcodeproj -scheme Kaixinguo \
  -destination 'platform=iOS Simulator,name=iPhone Air'   # 界面冒烟测试，需要网络
```

动手之前先读 [docs/architecture.md](docs/architecture.md) 和 [CONTRIBUTING.md](CONTRIBUTING.md)。发到 TestFlight 的流程见 [docs/releasing.md](docs/releasing.md)。

一句话概括实现：剧集是 CENC（AES-CTR）加密的 HEVC MP4，`KaixinguoKit/Sources/CENC` 按需原地解密任意字节区间，`StreamLoader` 作为 AVFoundation 的资源加载器，边从 CDN 下载边解密交给系统播放器，可以随意拖动进度；数据来自 openhongguo 的 Swift 包。

## 致谢

- [openhongguo](https://github.com/beilunyang/openhongguo)：红果短剧的 SDK，开心果的全部数据都来自它
- [开心果](https://github.com/kadaliao/kaixinguo)：macOS 版，本项目的界面和解密逻辑都照着它移植
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：从 `project.yml` 生成 Xcode 工程

## 许可证

[MIT](LICENSE)

## 免责声明

本项目仅供学习和研究，与红果短剧及其运营方无关。请遵守 openhongguo 的[免责声明](https://github.com/beilunyang/openhongguo#免责声明)，内容版权归原权利人所有。
