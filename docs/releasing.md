# 发版到 TestFlight

发版只能在维护者的 Mac 上做：需要团队的 App Store Connect API 密钥。

## 第一次之前

1. **接受协议**：团队的 Account Holder 在 [Apple Developer](https://developer.apple.com/account) 接受最新的 Program License Agreement。没接受时，API 会报 `PLA_NOT_ACCEPTED`，注册 Bundle ID、生成描述文件都会失败。
2. **API 密钥**：放在 `~/.appstoreconnect/private_keys/AuthKey_<密钥 ID>.p8`，角色要能管理证书和描述文件（Admin 或 App Manager）。密钥 ID 和 Issuer ID 通过环境变量传给脚本，不要写进仓库。
3. **Bundle ID**：`com.kadaliao.kaixinguo`，已经注册。
4. **App 记录**：已经建好，App Store Connect 里的名称是「开心果短剧」（「开心果」已被别的 App 占用），App ID `6831169843`。内部测试组「内部测试」会自动拿到每个新构建。要重建的话，只能在网页上建（API 做不到）：[App Store Connect](https://appstoreconnect.apple.com/apps) › 我的 App › ＋ › 新建 App：

   | 字段 | 填写 |
   | --- | --- |
   | 平台 | iOS |
   | 名称 | 开心果短剧（全局唯一，可以和主屏幕上显示的「开心果」不同） |
   | 主要语言 | 简体中文 |
   | 套装 ID | com.kadaliao.kaixinguo |
   | SKU | kaixinguo-ios |

5. **外部测试组**：「朋友」开着公开链接，谁拿到链接都能装，不用逐个添加测试员，最多 1 万人。链接在 App Store Connect › TestFlight › 朋友，`scripts/beta-review.sh` 跑完也会打印出来。给外部测试员的构建要先过 TestFlight 审核，审核要的测试信息（Beta 版描述、反馈邮箱、审核联系人）已经填好，改的话在 App Store Connect › TestFlight › 测试信息。要重建这个组：

   ```sh
   scripts/asc.sh POST /v1/betaGroups '{"data":{"type":"betaGroups","attributes":{"name":"朋友","publicLinkEnabled":true,"feedbackEnabled":true},"relationships":{"app":{"data":{"type":"apps","id":"6831169843"}}}}}'
   ```

## 每次发版

1. 在 `project.yml` 里把 `CURRENT_PROJECT_VERSION` 加一：同一个版本号下，每次上传的构建号都要比上一次大。用户看到的版本号是 `MARKETING_VERSION`。也可以不改文件，运行时传 `BUILD_NUMBER=<n>`。
2. 在 `CHANGELOG.md` 里把「未发布」改成版本号和日期。这一节会原样填进 TestFlight 的「测试内容」，测试员在 TestFlight 里能看到。
3. 运行：

   ```sh
   ASC_KEY_ID=<密钥 ID> ASC_ISSUER_ID=<Issuer ID> scripts/testflight.sh
   ```

   脚本依次归档、导出、上传，然后交给 `scripts/beta-review.sh`：等 Apple 处理完构建（5 到 15 分钟），填好「测试内容」，加进「朋友」，提交 TestFlight 审核。签名用 Xcode 的自动签名，证书和描述文件由 API 密钥按需生成。
4. 处理完以后，内部测试员不用审核就能安装。外部测试员（公开链接）要等审核通过，一般一天以内；同一个版本号后面的构建，审核通常更快。中途断了，或者想重新填「测试内容」，就再运行一次 `scripts/beta-review.sh`，已经做完的步骤会跳过。
5. 提交，打上标签：`git tag v<版本号> && git push --tags`。
6. 在 GitHub 上建 Release，说明就是 `CHANGELOG.md` 里这个版本的那一节：`gh release create v<版本号> --verify-tag --title <版本号> --notes-file <这一节的内容>`。

## 邀请别人测试

把公开链接发给对方。对方在 iPhone 或 iPad 上打开链接，按提示装好 TestFlight，再点「接受」「安装」就行，不用你在后台添加，也不用问对方要 Apple ID。之后的新版本会出现在对方的 TestFlight 里。

想按邮箱发邀请也行：`scripts/invite.sh <邮箱>...` 把对方加进「朋友」。有构建审核通过后，TestFlight 会给对方发邮件；同一个邮箱再运行一次，会重发邀请邮件。

## 说明

- **出口合规**：`Info.plist` 里声明了 `ITSAppUsesNonExemptEncryption = NO`。应用只用系统自带的 HTTPS，以及 CommonCrypto 解码视频，上传后不用再逐个回答出口合规问题。
- **隐私清单**：`Kaixinguo/Resources/PrivacyInfo.xcprivacy` 声明了用到的「需要说明理由的 API」，主要来自 SDK 里的 Go 运行时（读文件元数据、计时）。新增这类 API 时记得补上。
- **调 API**：`scripts/asc.sh <方法> <路径> [JSON]` 用同一把 API 密钥调 App Store Connect API，`beta-review.sh` 就是用它写的。例如看各测试组：`scripts/asc.sh GET /v1/apps/6831169843/betaGroups`。
- **上传报 TLS 错误**：开着代理或 VPN 时，`altool` 可能报 `-9816`，内部重试后常常仍会成功。重传之前先到 App Store Connect 看看构建是不是已经在了，避免浪费构建号。
