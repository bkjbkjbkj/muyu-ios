import SwiftUI
import PhotosUI
import AVFoundation

struct ChatView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []
    @FocusState private var isTyping: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if store.current?.messages.isEmpty != false { welcome }
                else { messages }
            }
            .navigationTitle("幕语")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { isTyping = false; showHistory = true } label: { Image(systemName: "sidebar.left") }
                        .accessibilityLabel("会话记录")
                        .disabled(store.isGenerating || store.isImporting)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { store.createConversation() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("新对话").disabled(store.isGenerating || store.isImporting)
                    Button { isTyping = false; showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("接口设置").disabled(store.isGenerating)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
            .sheet(isPresented: $showHistory) { HistoryView().environmentObject(store) }
            .sheet(isPresented: $showCamera) {
                CameraPicker { image in
                    if let image { store.addImage(image) }
                    showCamera = false
                }.ignoresSafeArea()
            }
            .alert("提示", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("知道了", role: .cancel) { store.error = nil }
                Button("接口设置") { store.error = nil; showSettings = true }
            } message: { Text(store.error ?? "") }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                store.isImporting = true
                Task { @MainActor in
                    defer { photoItems = []; store.isImporting = false }
                    for item in items.prefix(max(0, 4 - store.attachments.count)) {
                        do {
                            guard let data = try await item.loadTransferable(type: Data.self),
                                  let image = UIImage(data: data) else { throw ChatError.remote("无法读取所选图片。") }
                            store.addImage(image)
                        } catch { store.error = "图片导入失败：\(error.localizedDescription)" }
                    }
                }
            }
        }
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 7) {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    Text("留一点空间，给好奇心").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }.padding(.top, 38)
                Image(systemName: "sparkles").font(.system(size: 38, weight: .light))
                    .foregroundStyle(Theme.accent).padding(18)
                    .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 26))
                VStack(alignment: .leading, spacing: 12) {
                    Text("想问什么，\n都可以聊聊。")
                        .font(.system(size: 37, weight: .semibold, design: .rounded)).tracking(-1)
                    Text("记录一个想法，解答一个疑问，\n或者发张图片，一起看看。")
                        .font(.subheadline).foregroundStyle(.secondary).lineSpacing(5)
                }
                VStack(spacing: 10) {
                    suggestion("lightbulb", title: "把问题想清楚", detail: "一起分析，让思路更有条理", prompt: "我有一个问题，想请你帮我梳理思路。")
                    suggestion("text.alignleft", title: "帮我写点什么", detail: "写作、润色，找到合适的表达", prompt: "请帮我写一段文字，先问我需要什么主题和风格。")
                    suggestion("photo.on.rectangle.angled", title: "从一张图片开始", detail: "点输入框下方的相册或相机", prompt: "我准备发一张图片，请根据我的问题帮我分析。")
                }
                Button("首次使用？配置你的 AI 接口") { showSettings = true }
                    .font(.footnote).padding(.bottom, 14)
            }.padding(.horizontal, 26).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }.scrollDismissesKeyboard(.interactively)
    }

    private func suggestion(_ icon: String, title: String, detail: String, prompt: String) -> some View {
        Button { store.draft = prompt; isTyping = true } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3).frame(width: 28).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
            }.padding(17).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    Text(store.configuration.model).font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 8)
                    ForEach(store.current?.messages ?? []) { message in
                        MessageView(message: message).environmentObject(store)
                    }
                    if store.canRetry {
                        Button { store.retry() } label: { Label("重新生成最后一条回复", systemImage: "arrow.clockwise") }
                            .font(.footnote).padding(.leading, 38)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .overlay(alignment: .bottomTrailing) {
                Button { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                    Image(systemName: "arrow.down").font(.footnote.weight(.semibold)).padding(12)
                        .background(.regularMaterial, in: Circle()).shadow(color: .black.opacity(0.07), radius: 5, y: 2)
                }.accessibilityLabel("滚动到最新回复").padding(14)
            }
            .onChange(of: store.current?.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 9) {
            VStack(spacing: 12) {
                if !store.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(store.attachments) { photo in
                                AttachmentThumbnail(photo: photo)
                                    .overlay(alignment: .topTrailing) {
                                        Button { store.removeAttachment(photo) } label: {
                                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, Color.black.opacity(0.65))
                                        }.accessibilityLabel("移除图片").offset(x: 5, y: -5)
                                    }.padding(.top, 5)
                            }
                        }.padding(.trailing, 8)
                    }
                }
                TextField("发送消息，或添加图片…", text: $store.draft, axis: .vertical)
                    .font(.body).lineLimit(1...6).focused($isTyping)
                    .disabled(store.isGenerating)
                    .accessibilityLabel("消息内容")
                HStack(spacing: 18) {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: max(1, 4 - store.attachments.count), matching: .images) {
                        Image(systemName: "photo").font(.system(size: 20))
                    }.accessibilityLabel("从相册选择图片")
                        .disabled(store.isGenerating || store.isImporting || store.attachments.count >= 4)
                    Button { openCamera() } label: { Image(systemName: "camera").font(.system(size: 20)) }
                        .accessibilityLabel("拍照提问")
                        .disabled(store.isGenerating || store.isImporting || store.attachments.count >= 4)
                    if store.isImporting { ProgressView().controlSize(.small) }
                    Spacer()
                    if store.isGenerating {
                        Button { store.stop() } label: {
                            Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white).frame(width: 36, height: 36).background(Theme.accent, in: Circle())
                        }.accessibilityLabel("停止生成")
                    } else {
                        Button { isTyping = false; store.send() } label: {
                            Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white).frame(width: 36, height: 36)
                                .background(store.canSend ? Theme.accent : Color.gray.opacity(0.4), in: Circle())
                        }.disabled(!store.canSend).accessibilityLabel("发送消息")
                    }
                }.foregroundStyle(.secondary)
            }.padding(16).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(.primary.opacity(0.06), lineWidth: 1))
            Text("AI 回复可能有误，请核实重要信息").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 5)
            .frame(maxWidth: 760).frame(maxWidth: .infinity).background(.ultraThinMaterial)
    }

    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { store.error = "当前设备没有可用相机，请从相册添加图片。"; return }
        Task { @MainActor in
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            if allowed { isTyping = false; showCamera = true }
            else { store.error = "请到 iPhone 的「设置 → 幕语」中允许访问相机。" }
        }
    }
}

struct AttachmentThumbnail: View {
    @EnvironmentObject private var store: ChatStore
    let photo: PhotoAttachment
    var body: some View {
        Group {
            if let url = store.imageURL(photo), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
        }.frame(width: 74, height: 74).clipShape(RoundedRectangle(cornerRadius: 13))
    }
}

struct MessageView: View {
    @EnvironmentObject private var store: ChatStore
    let message: ChatMessage
    @State private var selectedPhoto: PhotoAttachment?
    private var isUser: Bool { message.role == "user" }
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            if !isUser {
                Image(systemName: "sparkles").font(.system(size: 15)).foregroundStyle(Theme.accent)
                    .frame(width: 28, height: 30)
            } else { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 10) {
                if !isUser { Text("幕语").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent) }
                if !message.photos.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(message.photos) { photo in
                                Button { selectedPhoto = photo } label: { AttachmentThumbnail(photo: photo) }
                                    .accessibilityLabel("查看图片")
                            }
                        }
                    }
                }
                if !message.text.isEmpty {
                    Text((try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text))
                        .font(.body).lineSpacing(6).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if message.state == .generating {
                    HStack(spacing: 9) { ProgressView().controlSize(.small); Text("正在思考…").font(.subheadline).foregroundStyle(.secondary) }
                }
                if message.state == .generating && !message.text.isEmpty {
                    ProgressView().controlSize(.mini).accessibilityLabel("正在生成回复")
                }
                if let failure = message.failure { Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                if message.state == .interrupted { Text("已停止 · 可重新生成").font(.caption).foregroundStyle(.secondary) }
                if !isUser && !message.text.isEmpty && message.state != .generating {
                    ShareLink(item: message.text) { Image(systemName: "square.and.arrow.up").font(.caption) }
                        .accessibilityLabel("分享回答").foregroundStyle(.secondary)
                }
            }
            .padding(isUser ? 16 : 0)
            .background(isUser ? Theme.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 20))
            .contextMenu {
                if !message.text.isEmpty { Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text } }
            }
            if !isUser { Spacer(minLength: 0) }
        }
        .sheet(item: $selectedPhoto) { photo in
            NavigationStack {
                ZStack {
                    Color.black.ignoresSafeArea()
                    if let url = store.imageURL(photo), let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                }.toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { selectedPhoto = nil } } }
            }
        }
    }
}
