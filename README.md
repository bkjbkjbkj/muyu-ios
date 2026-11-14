# 幕语 · 原生 iPhone AI 对话

SwiftUI 原生应用，最低 iOS 17。支持文字和多图提问、拍照、流式回复、本机会话记录、复制回答、中断生成、失败重试和自定义接口。

## 先在 GitHub 云端生成 IPA

1. 登录 `bkjbkjbkj`，新建仓库，例如 `muyu-ios`。建议设为 Private。
2. 解压交付的 ZIP，将 **Muyu 文件夹内部所有文件和目录**上传到仓库根目录，务必包含 `.github/workflows/ios.yml`。不要只上传 ZIP，也不要多套一层 Muyu 目录。
3. 仓库根目录应该能看到 `Muyu.xcodeproj`、`Muyu`、`scripts` 和 `.github`。
4. 点击仓库 **Actions → Build unsigned iPhone IPA → Run workflow**。默认 Bundle ID 为 `com.bkjbkjbkj.muyu`；需要时可在启动页面修改。
5. 构建成功后打开该次运行，在 **Artifacts** 下载 `Muyu-unsigned-ipa`，解压得到 `Muyu-unsigned.ipa`。
6. 用你自己的证书和描述文件重新签名，然后安装。该 IPA 未签名，不能直接安装。签名工具、设备授权和证书有效期由你使用的签名方式决定。

首次上传若看不到 Actions：检查 `.github/workflows/ios.yml` 是否在正确位置，并在仓库 Actions 页面启用 Actions。GitHub 私有仓库的 macOS 构建额度及费用以账号实际显示为准。

**交付状态：** 此项目在 Windows 上编写；交付包不是已编译 IPA。真正的 Swift 编译、核心校验和 IPA 打包由上述 macOS 工作流执行。尚未完成云端实跑时，不应把源码检查视为构建通过。

## 在手机上连接 AI

打开 App → 右上角设置。

| 设置 | OpenAI 官方 | 第三方兼容服务 |
|---|---|---|
| Base URL | `https://api.openai.com/v1` | 服务商提供的 HTTPS API 地址，通常以 `/v1` 结尾 |
| 接口格式 | Chat Completions（默认）或 Responses | 优先使用 Chat Completions，需服务商支持 |
| 模型 | 默认 `gpt-4.1-mini`，可自行更改 | 填写服务商提供且支持图片的模型名称 |
| API Key | 你的 OpenAI API 密钥 | 该服务商的 API 密钥 |

`OPENAI` 是提供商名称，不是完整 Base URL 或模型名称。应用先预填官方地址，不内置任何密钥。ChatGPT 的网页登录状态不会被这个独立 App 使用；对话由你配置的 API 和模型提供，不会自动同步本聊天或 ChatGPT 历史。

Base URL 可以是 API 根地址，也可以直接包含 `/chat/completions` 或 `/responses`，应用会按所选格式规范化。仅支持 HTTPS；更换域名时请确认密钥属于该服务商。密钥保存于 iOS Keychain，聊天和图片只写入应用自己的本地目录；发送时会将本轮及最近的对话内容和相关图片提交到你选定的服务商。

每次最多选 4 张图片。发送前自动缩放到最长边 1600 像素并转为 JPEG。相册使用系统选择器，拍照需相机权限。单次请求最多包含最近 40 条有效消息；长期对话超出模型上下文时可新建会话。

支持标准 SSE 流式响应，也兼容返回普通 JSON 的服务。不支持图像输入或不兼容标准接口的供应商需要调整服务端或选择其他模型。未完成的回复会保留并标记状态，不会自动重复收费请求。

## 工程与验证

- `Muyu.xcodeproj`：可直接在 Xcode 16 及以上版本打开，无需 CocoaPods、SPM 或第三方依赖。
- `.github/workflows/ios.yml`：macOS runner，执行 Swift 核心校验，构建 `iphoneos` Release，关闭签名，打包 `Payload/Muyu.app` 并上传 IPA。
- `Muyu/ChatCore.swift`：请求构造、URL 校验、SSE 解析，独立于 UI。
- `scripts/CoreChecks.swift`：验证两种接口的图片请求、地址规范化、消息筛选、SSE、错误处理和普通 JSON 响应。
- `scripts/check-project.ps1`：Windows 上检查工程引用、图标、JSON、工作流与签名设置。
- `scripts/build-unsigned.sh`：与云端使用相同的无签名构建与打包脚本。

macOS 本地构建：

```sh
bash scripts/build-unsigned.sh com.bkjbkjbkj.muyu
```

核心校验：

```sh
mkdir -p build
swiftc Muyu/ChatCore.swift scripts/CoreChecks.swift -o build/core-checks
build/core-checks
```

## 官方资料

- 图片输入：https://platform.openai.com/docs/guides/images-vision
- Chat Completions：https://platform.openai.com/docs/api-reference/chat/create
- Responses：https://platform.openai.com/docs/api-reference/responses/create
- Apple PhotosPicker：https://developer.apple.com/documentation/photosui/photospicker
- GitHub Actions：https://docs.github.com/en/actions

应用是独立的个人 API 客户端，不是 OpenAI 官方 ChatGPT 应用。
