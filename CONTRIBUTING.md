# 参与开发

谢谢你愿意帮忙。开心果 iOS 和 macOS 版一样，目标是**一直简单、一直快**：几页列表、一个详情页、一个播放器。新增功能之前请先想想它是否值得多出来的那份复杂度。

## 开始之前

- **报告问题**：附上设备型号、系统版本和 `KX_DEBUG=1` 的日志（见 README 的常见问题）。
- **接口失效**（列表全空、所有剧都播不了）：多半是红果接口变了，先看看 [openhongguo](https://github.com/beilunyang/openhongguo/issues) 有没有人报过。
- **和 macOS 版共有的逻辑**（分页、选季、续播、解密）：两边要保持一致，改一边时看看另一边要不要跟着改。

## 开发环境

- macOS 和 Xcode 26 或更新的版本
- XcodeGen：`brew install xcodegen`

```sh
xcodegen                          # 生成 Kaixinguo.xcodeproj
open Kaixinguo.xcodeproj
(cd KaixinguoKit && swift test)   # 逻辑测试，不需要模拟器和网络
```

先读 [docs/architecture.md](docs/architecture.md)，尤其是「线程模型」一节。

## 提交前检查

```sh
(cd KaixinguoKit && swift test)
xcodebuild build -project Kaixinguo.xcodeproj -scheme Kaixinguo \
  -destination 'platform=iOS Simulator,name=iPhone Air'    # 不能有警告
```

改了界面的话，在 iPhone 和 iPad 模拟器上都实际点一遍，浅色和深色外观都看看；改了播放，再跑一次 `xcodebuild test`（界面冒烟测试）和 `KX_ONLINE=1 swift test --filter playsOnline`。

## 代码约定

- **逻辑放进 KaixinguoKit**：能不依赖 UIKit 的都放在包里，好在 Mac 上测试。App target 只放视图。
- **主线程独占状态**：模型都是 `@MainActor`，后台工作做完回到主线程再改状态。Swift 6 的并发检查要保持零警告。
- **视图里没有副作用**：`body` 会反复执行，加载数据要有防重复的标记。
- **新功能配测试**：逻辑用 `FakeCatalog` 写单元测试，参考 `CatalogTests.swift`。
- **注释**：用英文写完整的句子，说清楚一个东西**是什么**或**为什么**这样做，而不是复述代码。照着已有代码的口吻写。
- **界面文字**用简体中文，标点用全角。
- **依赖**：除了 openhongguo，不加第三方依赖。
- **本地数据格式**：`history.json`、`favorites.json` 和 macOS 版共用格式，只能加字段，不能改名或删除。
- **工程文件**：改 `project.yml`，再运行 `xcodegen`；不要直接在 Xcode 里改工程设置。

## 提交信息

用中文，一行概括改了什么，必要时空一行再写原因，和 macOS 版一样。

## 更新日志

用户能感知到的改动，请在 [CHANGELOG.md](CHANGELOG.md) 的「未发布」下面加一行。纯重构和测试不用写。

## 许可证

提交的代码以 [MIT](LICENSE) 许可证发布。
