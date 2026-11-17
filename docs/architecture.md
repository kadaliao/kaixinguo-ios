# 架构

这份文档讲开心果 iOS 的代码是怎么组织的、各部分怎么配合，以及几处不太显然的设计为什么这样做。它是 [macOS 版](https://github.com/kadaliao/kaixinguo)的移植，两边的概念一一对应，读过 macOS 版的 `docs/architecture.md` 会更快上手。

## 总览

```mermaid
flowchart LR
    subgraph App[开心果进程]
        Views[SwiftUI 视图<br>Kaixinguo/] <--> Model[AppModel<br>主线程]
        Model --> Feed[Feed<br>分页加载]
        Model --> Player[Player<br>播放流程]
        Model --> Covers[CoverStore]
        Model --> Store[History / Favorites]
        Player --> AV[AVPlayer]
        AV -- kaixinguo-stream:// 的字节区间 --> Loader[StreamLoader]
        Loader --> CENC[CENC]
    end
    Feed -- openhongguo Swift 包 --> API[(红果接口)]
    Player -- openhongguo Swift 包 --> API
    Loader -- 按区间下载 --> CDN[(视频 CDN)]
    Covers -- HEIC --> CDN2[(封面 CDN)]
    Store --> Disk[(Application Support)]
    Covers --> Cache[(Caches)]
```

工程分这几部分：

- **`KaixinguoKit/`**：一个 Swift 包，装着除视图以外的一切。iPhone、iPad 和 Apple TV 共用；它同时能在 macOS 上编译，所以 `swift test` 直接在 Mac 上跑，不需要模拟器。
- **`Kaixinguo/`**：iPhone 和 iPad 的 App target，只有 SwiftUI 视图、路由和入口。
- **`KaixinguoTV/`**：Apple TV 的 App target，视图为遥控器重写，见「Apple TV」一节。
- **`Shared/`**：两个 App target 都编进去的代码：标签页和导航的 `Router`，以及几个视图（海报、封面、列表的加载状态、榜单名次、弹幕）。

`Kaixinguo.xcodeproj` 由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成，增删文件或改设置后运行 `xcodegen`。

## 代码地图

| 文件 | 负责什么 | 对应 macOS 版 |
| --- | --- | --- |
| `KaixinguoKit/Sources/CENC/CENC.swift` | 把 CENC 加密的 MP4 按字节区间还原成明文 | `internal/cenc` |
| `KaixinguoKit/…/StreamLoader.swift` | AVFoundation 的资源加载器：按区间下载、解密、交给播放器 | `proxy.go` |
| `KaixinguoKit/…/Player.swift` | 播放流程：解析播放地址、预取下一集、选流、连播、记录进度 | `play.go` |
| `KaixinguoKit/…/Danmaku.swift` | 弹幕：读一集的弹幕、分配轨道、算出每条此刻的位置 | 无 |
| `KaixinguoKit/…/AppModel.swift` | 全部状态、各页的 fetcher、热搜、首页缓存 | `main.go`、`data.go` |
| `KaixinguoKit/…/Feed.swift` | 分页加载的列表，去重、自动重试、下拉刷新 | `data.go` 的 `feed` |
| `KaixinguoKit/…/SeriesPage.swift` | 剧集详情：分集、选季、分段、续播位置、连播的下一集 | `data.go`、`play.go` |
| `KaixinguoKit/…/Seasons.swift` | 季的编号和排序 | `data.go` |
| `KaixinguoKit/…/Card.swift` | 卡片和各种文案（集数、热度、日期） | `data.go`、`view_series.go` |
| `KaixinguoKit/…/Store.swift` | JSON 存储（文件，或 tvOS 上的 UserDefaults）、观看记录、收藏 | `store.go`、`history.go`、`favorites.go` |
| `KaixinguoKit/…/Session.swift` | 上次停在哪儿：标签、页面、搜索、播放器开着的那一集 | 无 |
| `KaixinguoKit/…/CoverStore.swift` | 封面：下载、缩小、磁盘缓存、内存缓存 | `covers.go`、`internal/imageio` |
| `KaixinguoKit/…/Catalog.swift` | 对 SDK 的抽象（测试里换成假的）、错误文案 | `data.go` 的 `friendly` |
| `Kaixinguo/KaixinguoApp.swift` | 入口、音频会话、退到后台时写盘、回到上次的地方、`kaixinguo://` 链接 | `main.go` |
| `Kaixinguo/RootView.swift` | 标签页（iPhone 底栏、iPad 侧栏）和每个标签的导航栈 | `view.go` 的侧栏 |
| `Shared/Router.swift` | 在哪个标签、每个标签推进了哪些页，它们和 `Session` 的互转、随改随存，以及 `kaixinguo://` 链接；iOS 和 tvOS 共用 | `view.go` 的路由 |
| `Kaixinguo/Views/Grid.swift` | 海报网格、卡片、选择用的胶囊 | `view.go` |
| `Shared/SharedViews.swift` | 海报、封面、列表还空着时的加载和出错状态、榜单名次、弹幕层，以及倍速和定时关闭的文字；iOS 和 tvOS 共用 | `view.go` |
| `Kaixinguo/Views/CatalogViews.swift` | 推荐、排行榜、新剧上线、搜索、热搜、我的 | `view.go` |
| `Kaixinguo/Views/SeriesView.swift` | 剧集详情 | `view_series.go` |
| `Kaixinguo/Views/PlayerScreen.swift` | 播放页（顶栏、进度条、手势、播放页里的搜索）、选集面板、画中画 | `view_player.go` |
| `KaixinguoTV/KaixinguoTVApp.swift` | Apple TV 版的入口、顶部的标签页和各自的导航栈，以及盖在上面的播放器 | 无 |
| `KaixinguoTV/TVCatalogViews.swift` | Apple TV 的推荐、排行榜、新剧、搜索和「我的」：海报墙、横排的货架、选榜单和日期的按钮 | 无 |
| `KaixinguoTV/TVSeriesView.swift` | Apple TV 的剧集详情、选季和选集 | 无 |
| `KaixinguoTV/TVPlayerView.swift` | Apple TV 的播放：系统播放器和它自带的控件，外加弹幕、控制栏里的菜单、信息面板里的「选集」和「下一集」 | 无 |

## 线程模型

**`AppModel`、`Feed`、`SeriesPage`、`Player`、`DanmakuReel`、`History`、`Favorites` 都属于主线程**（`@MainActor @Observable`）。工程用 Swift 6 语言模式，编译器会检查这条约定。

- 视图直接读这些对象的属性，SwiftUI 的 Observation 据此决定重绘哪些视图。
- 网络请求用 `Task { … }` 发起：`await` SDK 时让出主线程，结果回来后在主线程上改状态。
- 视图的 `body` 会反复执行。`model.seriesPage(id)`、`model.rankFeed` 这类在 `body` 里调用的方法要能重复调用：它们缓存在标记了 `@ObservationIgnored` 的字典里，加载前先检查 `loading` 等标记，只发一次请求。
- 不属于主线程的部件各有自己的同步方式：`StreamLoader` 的状态只在它自己的串行队列上读写；`JSONStore` 和 `CoverStore` 用 `Mutex`；解密用的 `Layout` 是不可变的值类型。

## 列表：`Feed`

和 macOS 版一样，推荐、排行榜、新剧上线和搜索都是一个 `Feed` 配一个 fetcher：

- 网格滚到距末尾 9 张卡片时调用 `loadMore`。卡片按 ID 去重；一页里没有新卡片就视为到底，否则搜索会无限请求。
- 列表还是空的时候失败，会在 2、4、8、16 秒后自动重试，之后显示「重试」按钮。
- 推荐页的第一页缓存在 `Caches/home.json`。启动时先显示缓存（`stale`），新数据到了排在前面、缓存排在后面，网格只增不减。下拉刷新用的也是这个办法。
- 排行榜、新剧上线和搜索的 `Feed` 按「榜单 / 日期 / 关键词」缓存，切回来时不用重新加载。

## 播放

剧集是 CENC（AES-CTR，ISO/IEC 23001-7）加密的 HEVC MP4。AVPlayer 不能直接播，开心果给它一个自定义协议的地址，自己当资源加载器：

1. **解析**（`Player.resolve`）：通过 SDK 取这一集的播放模型和内容密钥。正在播的时候会预取下一集；CDN 地址一分钟内过期的模型会重新取。
2. **选流**（`pickStream`）：默认选分辨率最高、码率最高的一路；看的人在「更多 › 清晰度」里选过的话，选不高于它的最高一路。分段的 HLS/DASH 和音视频分离的流目前不支持，直接提示。
3. **登记**：为这一集建一个 `StreamLoader`（主地址、备用地址和密钥），换回一个 `kaixinguo-stream://episode/<随机 ID>.mp4` 的 `AVURLAsset`。`Player` 只保留最近 3 个加载器。
4. **播放**：AVPlayer 向加载器要内容信息和一个个字节区间。加载器第一次被问到时读文件头 64 KB，用 `Layout.open` 找到 `moov`，算出每个样本的位置和 IV；之后每个区间都从 CDN 取同一区间，边收边原地解密，再交给播放器。下载断开时从断点接着取，换另一个 CDN 地址，最多两次。
5. **回报**：`Player` 用 KVO 和通知观察播放器：开始播放、缓冲、出错、播完，每 3 秒和暂停时记录进度，播完自动连播下一集或下一季。

`CENC` 是 macOS 版 `internal/cenc` 的逐行移植，关键同样是**解密不改变任何字节的位置**：样本原地解密，标记加密的盒子改名成同样长度的明文盒子（`encv` → `hvc1`、`sinf` → `free` 等）。所以明文文件的任意区间就是密文文件同一区间解密后的结果，播放器可以随意拖动。它的输出和 Go 版逐字节一致，见 `CENCTests` 里的 `decryptsRealEpisode`。

和 macOS 版用本机 HTTP 代理 + WebView 相比，资源加载器不开端口，播放器是系统的 `AVPlayerViewController`，画中画和锁屏控制都是现成的；它自带的控件藏了起来，播放页用自己的顶栏、进度条和手势（点按暂停、上下滑换集、长按倍速，都挂在它的视图上）。代价是 AirPlay 投屏拿不到解密后的视频，所以 `allowsExternalPlayback` 是关着的。

### 画中画

`PlayerHost` 全程只用一个 `AVPlayerViewController`。画中画开始时关掉播放页（视频留在小窗里），控制器还被 `PlayerHost` 持有，所以画中画不会断；在小窗里点还原时重新打开播放页，把同一个控制器放回去，视频飞回原处。

### 弹幕

播放页要显示弹幕时调用 `Player.danmaku()`，它通过 SDK 的 `listDanmaku` 从这一集的开头一页页读，直到 `hasMore` 为假。一页是服务端划出的一段播放时间（约 30 秒），没人发弹幕的那段是空页，后面可能还有。服务端只下发精选的几十到几百条，所以一次读完，拖动进度时不用从新位置重读；只留最近一集的，换集时停掉上一集还没读完的。

- **轨道**：弹幕在视频上方的 4 条轨道里从右往左飞，速度都一样，所以后一条追不上前一条。每条放进它出现时最上面有空的轨道，前一条的尾巴进场、再空出 2 个字宽才算有空；轨道都满时，等最先空出来的那条，1.5 秒内等不到就不显示，免得挤在一起或者远远落后于画面。字宽按字符估算（汉字 1 个字宽，字母数字 0.6，emoji 1.25）。
- **位置只看视频时间**：每条弹幕的位置由视频当前的时间算出来，播放页逐帧重画（暂停时每 0.25 秒一次）。所以暂停时弹幕停住，拖动、倍速、换集都不用另外处理。
- 白字黑边，不支持颜色和位置；只能看不能发（不提供登录）。画中画里是系统播放器的窗口，叠不上去，所以不显示。
- 开关在「⋯」里，默认开，存在 `UserDefaults` 里；关着时不读弹幕。

## 回到上次的地方

App 退出或被系统关掉后再打开，回到上次的样子。`Session` 记着：

- 所在的标签，每个标签里打开的剧集页（只记剧集 ID，页面打开时重新加载），搜索框里的字和正在显示的搜索；
- 排行榜选的类型和榜单、新剧上线选的日子；
- 播放器开着的话（全屏或画中画），是哪部剧的第几集。

几处做法：

- **随改随存**：`Router.keep` 用 `withObservationTracking` 盯着 `Router` 和 `AppModel` 里这些属性，一变就存到 `session.json`（和上次一样就不写）。不等退到后台再存，因为从多任务界面划掉 App 时不一定有机会；画中画在后台连播下一集时也能记下来。
- **播放位置从观看记录里取**：`Session` 只记第几集，秒数用 `history.json` 里这一集的位置。播放器暂停时会记一次进度，App 离开前台（`scenePhase` 不是 `.active`）时也补记一次，所以能精确到秒。
- **暂停着回来**：`Player.play(…, paused: true)` 加载这一集、跳到那一秒（`seek` 的容差是零，不会落到几秒外的关键帧），但不播放，画面上显示暂停图标，点一下接着放。看完的那一集从头开始。
- **直接出现**：启动时播放页不做上滑动画，避免先闪一下下面的页面（`RootView` 第一帧之前关掉过渡动画）。
- **过期的选择不恢复**：新剧上线的日历只有今天前后各一周，选的日子已经不在里面的话回到今天。
- 用 `kaixinguo://` 链接打开 App 时，先恢复再打开链接；链接要去某个页面的话，会先关掉恢复出来的播放页。

## 封面

封面 CDN 只给 HEIC，ImageIO 直接能解。`CoverStore` 解码时缩小到最长边 600 像素（3 倍屏上网格里的海报），以 JPEG 存到 `Caches/covers/`，内存里用 `NSCache` 保留解码后的位图，内存紧张时系统会自动清掉。

- 缓存的键是去掉查询参数的 URL 的 SHA-1，因为签名参数每次都变。
- 同一张封面同时被多处请求时只下载一次。
- 视图先同步查内存缓存，有就直接显示，没有才异步加载并淡入，滚动时不闪。

## 本地数据

| 文件 | 内容 | 写入方 |
| --- | --- | --- |
| `Application Support/history.json` | 观看记录，最近的在前，最多 200 部；每部记着看到哪里和看完了哪几集 | `History` |
| `Application Support/favorites.json` | 收藏，最近收藏的在前 | `Favorites` |
| `Application Support/session.json` | 上次停在哪儿，见「回到上次的地方」 | `AppModel.save` |
| `Application Support/openhongguo/anonymous.json` | SDK 注册的匿名设备，不参与备份 | openhongguo |
| `Caches/home.json` | 推荐页第一页 | `AppModel` |
| `Caches/covers/` | 封面 JPEG | `CoverStore` |

Apple TV 版不用 Application Support：观看记录、收藏和上次停在哪儿在 UserDefaults 里，匿名设备在 `Caches/openhongguo/anonymous.json`，见「Apple TV」一节。

`history.json` 和 `favorites.json` 的格式与 macOS 版相同（字段名一样，时间是 RFC 3339），两边的文件可以互相读。`JSONStore` 的规则也一样：

- 主线程改完列表调用 `save`，后台队列写盘；还没来得及写的旧快照直接丢弃，只写最新的。
- 原子写入，中途崩溃也不会留下半个文件。
- 文件不存在或读不出来时当作空列表。
- `JSONStore` 也可以把列表存进 UserDefaults 的一个键（`Place.defaults`），并设字节上限：编码后超过上限时，从列表末尾（最旧的）开始丢，直到放得下。只有 tvOS 用这种方式。
- 退到后台时（`scenePhase == .background`）调用 `flush`，等最后一次写入落盘。

字段一旦发布就要保持兼容：只能加字段，不能改名或删除，新字段解码时要有默认值。

`history.json` 里的 `watched` 是 iOS 版加的字段：这一季看完的集号，从小到大。一集播完，或播过九成（常有人跳过最后几秒直接看下一集），就记进去；`History.record` 把新记录和旧记录的 `watched` 合并，所以每 3 秒一次的进度记录不会把它冲掉。macOS 版还不认这个字段，读到会忽略。

## Apple TV

`KaixinguoTV` 和 iOS 版共用 KaixinguoKit：列表、剧集、播放流程、解密和观看记录都是同一份代码；标签页、导航、回到上次的地方（`Router`）和弹幕层也和 iOS 共用（`Shared/`），只有视图另写。功能和 iPhone 版对齐：推荐、排行榜、新剧、我的、搜索五个标签在顶部，剧集页能选季、选集、收藏，播放有弹幕、倍速、清晰度、定时关闭和选集。电视上没有触摸，靠遥控器移动焦点，所以：

- 海报用 `.buttonStyle(.card)`，焦点落上去时浮起来；按住确认键弹出菜单（收藏；最近观看里还有继续播放、移除），相当于 iOS 上的长按。推荐、排行榜、新剧和搜索结果是六列的海报墙，热搜和最近观看是横排的货架。
- 选榜单、日期和季的按钮用自己的 `TVChoiceStyle`：系统的 `bordered`、`borderedProminent` 在电视上只有焦点在时才显示颜色，看不出选的是哪个。这里选中的填绿色，焦点在时变白放大。选集的数字按钮也用它，正在看的那集是绿的。
- 搜索用 `.searchable`，电视上是一排字母键盘（中文系统是拼音），也能用 Siri 听写或 iPhone 输入。遥控器打字慢，也没有「搜索」键，所以停顿 0.6 秒就按输入的词出结果，联想词列在键盘旁边。
- 播放用系统的 `AVPlayerViewController`，**留着它自带的控件**：遥控器拖进度、暂停都是现成的。iOS 版的手势、旋转、长按倍速在电视上都用不上。App 自己加的有四处：
  - **弹幕**：共用的 `DanmakuLayer` 放进 `contentOverlayView`，在视频之上、控件之下，字号 40。
  - **控制栏菜单**（`transportBarCustomMenuItems`）：倍速、清晰度、定时关闭和弹幕开关，按一下遥控器出现在进度条右上方。系统自带的倍速菜单用 `speeds = []` 关掉了，因为 App 的倍速要延续到后面的集（`Player.setSpeed` 设的是 `defaultRate`）。
  - **选集**（`customInfoViewControllers`）：从控制栏往下按，是信息面板的标签：系统的「简介」（剧名、集数和封面来自 `Player` 设置的 `externalMetadata`，和 iOS 锁屏用的是同一份），然后是「选集」。面板里有上一集、下一集、收藏、选季，和一整排集数；进来时焦点落在正在播的那集（`defaultFocus` 的 `userInitiated` 优先级）。选了别的集，系统会把面板收起来。
  - **下一集**：`contextualActions` 在画面右下角放一个「下一集」按钮；一集放完照样自动连播。
- openhongguo 的 xcframework 从 fork 的 `v0.3.1-kx.2` 起才有 tvOS 部分。官方 gomobile 编不了 tvOS，这两个部分是 fork 里的 `bindings/mobile/add-tvos.sh` 用 sagernet 的 gomobile 编出来再合进去的。
- **不碰 Application Support**。Apple TV 上的 App 只能往 `Caches` 和 `tmp` 里写文件，建 `Library/Application Support` 会被拒（「你没有将文件“Application Support”存储到文件夹“Library”中的权限」），App 一启动就打不开。模拟器不拦，只有真机才会出这个错。这两个目录在存储空间紧张时还会被系统清空，只有 UserDefaults 里 500 KB 以内的数据一定留着。所以 `AppModel.live()` 在 tvOS 上：
  - 把 `History`、`Favorites` 和会话放进 UserDefaults 的 `history`、`favorites`、`session` 三个键，前两个各给 200 KB。一部剧的记录约 0.5 KB，200 部也只有 100 KB 左右，上限只是兜底。
  - 把 SDK 的匿名设备放在 `Caches/openhongguo/anonymous.json`（`OpenhongguoClient.app(profile:)`）。SDK 默认放在 Application Support，在电视上建不了。
  - 首页缓存和封面本来就在 `Caches` 里。这些文件被清掉了，也只是重新注册设备、重新下载。
- **图标**是分层的 5:3 横版：后层是渐变底和壳的阴影，中层是果壳，前层是播放键，焦点移上去时各层错开。顶部货架是一张开心果加「开心果 / 无广告、不烧心」的横幅。这些都由 `scripts/tv-icons.py` 从 `resources/icon.svg` 里同样的形状画出来，改图标后重跑一次就行（需要 `rsvg-convert` 和 ImageMagick）。
- 隐私清单 `Shared/PrivacyInfo.xcprivacy` 两个 App 共用。

还没做的：顶部货架只有静态图，不会显示最近观看；没有下拉刷新（电视上没有这个手势），推荐页每次启动时刷新。

## 测试

```sh
(cd KaixinguoKit && swift test)
```

- **逻辑测试**（`KaixinguoKitTests`）用 `FakeCatalog` 代替 SDK，不联网：分页和去重、缓存合并、自动重试、搜索回退和补封面、选季和续播、播放状态、弹幕的分页和轨道、观看记录和收藏的读写（包括 Go 写的文件）。
- **解密测试**（`CENCTests`）在测试里从零拼出加密的 MP4（用 CommonCrypto 自己的 CTR 模式加密，不拿解密器验证自己），覆盖 senc、子样本、saiz/saio、moov 在文件末尾等情况，整段和任意切片解密结果必须一致。

两个可选的测试需要真实数据：

```sh
# 拿一集真实的加密剧集：和 Go 版的输出逐字节比较，并经 StreamLoader 交给 AVFoundation 解码、播放、拖动
CENC_SAMPLE=enc.mp4 CENC_KEY=<密钥> CENC_CLEAR=clear.mp4 swift test --filter "decryptsRealEpisode|playsEncryptedEpisode"

# 联网：从注册匿名设备到播放推荐的第一部剧，读完它的弹幕，再下载一张封面
KX_ONLINE=1 swift test --filter playsOnline
```

**界面冒烟测试**（`KaixinguoUITests`）在模拟器里像用户一样操作：打开推荐的第一部剧、收藏、在「我的」里找到它、播放、下一集、退出后看到「继续看第 2 集」；播放几秒暂停、关掉 App 再打开，回到同一集的同一秒，退出播放页后是那部剧的详情页。它用真实接口，需要网络。Debug 构建启动时认 `-KXFresh YES`，像第一次打开那样不恢复上次的地方，测试用它保证每次从推荐页开始。

**Apple TV 冒烟测试**（`KaixinguoTVUITests`）用虚拟遥控器（`XCUIRemote`）走一遍：打开推荐的第一部剧、收藏、播放，检查控制栏里有倍速、定时关闭和弹幕开关，下滑到「选集」播下一集，退出后焦点落在「继续看第 n 集」上，再依次切到排行榜、新剧、我的和搜索。每一步都截图存进测试结果，`xcrun xcresulttool export attachments` 能导出来看：

```sh
xcodebuild test -project Kaixinguo.xcodeproj -scheme KaixinguoTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' -resultBundlePath build/tv.xcresult
```

**截图**：Debug 构建启动时认 `-KXOpen <链接>` 参数，直接打开 `kaixinguo://` 链接，不弹系统的确认框；这时也不恢复上次的地方。`scripts/shoot.sh` 用它构建、启动并截图：

```sh
scripts/shoot.sh "iPhone Air" kaixinguo://series/<剧集 ID> /tmp/series.png
```

## 已知限制

- 不支持分段（DASH/HLS）和音视频分离的流。
- 需要登录才能看的集数不能播放，应用不提供登录。
- AirPlay 只能屏幕镜像，不能把视频投给 Apple TV 单独播放。
