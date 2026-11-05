# 更新日志

这里记录每个版本用户能感知到的变化。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

## [0.2.0] - 2026-11-05

### 新增

- 看完的集在选集里打勾、数字变淡，剧集页和播放页的选集面板都有

### 修复

- 搜索联想显示成一串数字（剧集 ID），现在显示剧名

## [0.1.0] - 2026-11-05

第一个版本，发到 TestFlight 内部测试。

### 新增

- 开心果 macOS 版的 iPhone 和 iPad 移植
- 推荐、排行榜（按类型和榜单）、新剧上线（前后两周的日历）、热搜，下拉刷新
- 搜索短剧，输入时有联想词，同一部剧的各季按顺序列出
- 收藏：剧集页点「收藏」，或在列表里长按海报；「我的」页列出最近观看和收藏
- 详情页选季、选集，记住看到哪里，可以继续播放
- 播放时自动连播下一集，一季看完接下一季
- 系统播放器：画中画、锁屏和控制中心、倍速
- iPad：侧栏、播放页右侧的选集面板、外接键盘快捷键
- `kaixinguo://` 链接，可以直接打开剧集、播放、搜索或切换标签页
- 跟随系统的浅色和深色外观

### 已知限制

- 暂不支持分段（DASH/HLS）的长视频
- AirPlay 只能屏幕镜像
- 第一次启动要注册匿名设备，网络慢时列表可能要等十几秒才出来；之后启动会先显示缓存

[未发布]: https://github.com/kadaliao/kaixinguo-ios/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/kadaliao/kaixinguo-ios/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/kadaliao/kaixinguo-ios/releases/tag/v0.1.0
