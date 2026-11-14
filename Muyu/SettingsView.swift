import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = APIConfiguration()
    @State private var key = ""
    @State private var showKey = false
    @State private var error: String?
    @State private var loaded = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "sparkles").font(.title).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("连接你的 AI").font(.headline)
                            Text("文字与图片，都从这里开始").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }
                Section {
                    TextField("https://api.openai.com/v1", text: $configuration.baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("API Base URL")
                    TextField("模型名称，例如 gpt-4.1-mini", text: $configuration.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("模型名称")
                    Picker("接口格式", selection: $configuration.format) {
                        ForEach(APIFormat.allCases) { Text($0.title).tag($0) }
                    }
                } header: { Text("接口与模型") } footer: {
                    Text("官方地址已预填。第三方请填写服务商的完整 HTTPS Base URL 和支持图片的模型名称。兼容接口通常选择 Chat Completions。")
                }
                Section {
                    HStack {
                        Group {
                            if showKey { TextField("API Key", text: $key) }
                            else { SecureField("API Key", text: $key) }
                        }.textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless).accessibilityLabel(showKey ? "隐藏密钥" : "显示密钥")
                    }
                } header: { Text("密钥") } footer: {
                    Text("密钥仅存于本机系统钥匙串，发送请求时交给上方指定的服务器。更换服务器时请核对密钥。保存空值会移除已存密钥。")
                }
                Section("回答偏好") {
                    TextField("例如：请用中文简洁回答", text: $configuration.instruction, axis: .vertical).lineLimit(3...8)
                }
                Section {
                    LabeledContent("应用版本", value: "1.0.0")
                    Text("这是独立的 API 客户端。使用你配置的服务商和模型，不同步 ChatGPT 账号、本聊天记录或订阅。接口用量由服务商计费。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("聊天和压缩后的图片保存在手机本地。发送时会携带最近最多 40 条有效消息及其图片作为上下文；删除会话会删除对应本地图片。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("关于与数据") }
            }
            .navigationTitle("接口设置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do { try store.saveConfiguration(configuration, key: key); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.fontWeight(.semibold).disabled(!loaded)
                }
            }
            .onAppear {
                guard !loaded else { return }
                configuration = store.configuration
                do { key = try Keychain.read(); loaded = true }
                catch { self.error = error.localizedDescription }
            }
            .alert("无法保存设置", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var pendingDelete: Conversation?
    private var filtered: [Conversation] {
        store.conversations.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(search) } }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { conversation in
                    Button {
                        store.select(conversation.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(conversation.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                                Text(conversation.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if conversation.id == store.selectedID { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }.padding(.vertical, 6)
                    }.swipeActions {
                        Button("删除", role: .destructive) { pendingDelete = conversation }
                    }
                }
            }
            .overlay { if filtered.isEmpty { ContentUnavailableView.search(text: search) } }
            .searchable(text: $search, prompt: "搜索会话和内容")
            .navigationTitle("会话记录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.createConversation(); dismiss() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("新对话")
                }
            }
            .confirmationDialog("删除这个会话及其本地图片？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("删除会话", role: .destructive) {
                    if let conversation = pendingDelete { store.delete(conversation.id) }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            }
        }
    }
}
