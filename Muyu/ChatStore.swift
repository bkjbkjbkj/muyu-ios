import SwiftUI

@MainActor
final class ChatStore: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var selectedID: UUID?
    @Published var configuration = APIConfiguration()
    @Published var draft = ""
    @Published var attachments: [PhotoAttachment] = []
    @Published var isGenerating = false
    @Published var isImporting = false
    @Published var error: String?
    private(set) var storage: LocalStorage?
    private var task: Task<Void, Never>?
    private var generationID: UUID?
    private var activeConversation: UUID?
    private var activeAssistant: UUID?
    private var mayPersist = true
    private let client = APIClient()

    init() {
        if let data = UserDefaults.standard.data(forKey: "api-configuration"),
           let saved = try? JSONDecoder().decode(APIConfiguration.self, from: data) { configuration = saved }
        do {
            let disk = try LocalStorage()
            storage = disk
            conversations = try disk.load()
            for index in conversations.indices {
                for message in conversations[index].messages.indices where conversations[index].messages[message].state == .generating {
                    conversations[index].messages[message].state = .interrupted
                }
            }
            try disk.cleanUnusedImages(conversations: conversations)
        } catch {
            mayPersist = false
            self.error = "无法读取本地记录：\(error.localizedDescription)。为保护已有记录，已暂停写入，请重启 App 后重试。"
        }
        selectedID = conversations.sorted { $0.updatedAt > $1.updatedAt }.first?.id
        if selectedID == nil { createConversation() }
    }

    var current: Conversation? { conversations.first { $0.id == selectedID } }
    var canSend: Bool {
        mayPersist && !isGenerating && !isImporting && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }
    var canRetry: Bool {
        guard !isGenerating, let last = current?.messages.last else { return false }
        return last.role == "assistant" && (last.state == .failed || last.state == .interrupted)
    }

    func createConversation() {
        guard !isGenerating, !isImporting else { return }
        clearDraft()
        if let empty = conversations.first(where: { $0.messages.isEmpty }) { selectedID = empty.id; return }
        let conversation = Conversation()
        conversations.insert(conversation, at: 0)
        selectedID = conversation.id
        persist()
    }

    func select(_ id: UUID) {
        guard !isGenerating, !isImporting else { return }
        clearDraft()
        selectedID = id
    }

    func delete(_ id: UUID) {
        guard !isGenerating, !isImporting, mayPersist else { return }
        let previous = conversations
        conversations.removeAll { $0.id == id }
        do {
            try storage?.save(conversations)
        } catch {
            conversations = previous
            self.error = "删除失败：\(error.localizedDescription)"
            return
        }
        let removed = previous.first { $0.id == id }?.messages.flatMap(\.photos) ?? []
        storage?.remove(removed)
        if selectedID == id { selectedID = conversations.first?.id; clearDraft() }
        if selectedID == nil { createConversation() }
    }

    func imageURL(_ photo: PhotoAttachment) -> URL? { storage?.imageURL(photo) }

    func addImage(_ image: UIImage) {
        guard attachments.count < 4, let storage, mayPersist else { return }
        do { attachments.append(try storage.saveImage(image)) }
        catch { self.error = error.localizedDescription }
    }

    func removeAttachment(_ photo: PhotoAttachment) {
        storage?.remove([photo])
        attachments.removeAll { $0.id == photo.id }
    }

    private func clearDraft() {
        storage?.remove(attachments)
        attachments = []
        draft = ""
    }

    func saveConfiguration(_ value: APIConfiguration, key: String) throws {
        _ = try ChatPayload.endpoint(value)
        guard !value.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatError.missingModel }
        let data = try JSONEncoder().encode(value)
        try Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
        UserDefaults.standard.set(data, forKey: "api-configuration")
        configuration = value
    }

    func send() {
        guard canSend, let index = conversations.firstIndex(where: { $0.id == selectedID }) else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = ChatMessage(role: "user", text: text.isEmpty ? "请帮我分析这张图片。" : text, photos: attachments)
        do {
            let history = conversations[index].messages + [message]
            let request = try prepare(history)
            conversations[index].messages.append(message)
            if conversations[index].messages.filter({ $0.role == "user" }).count == 1 {
                conversations[index].title = String(message.text.prefix(24))
            }
            draft = ""
            attachments = []
            begin(request, conversation: conversations[index].id)
        } catch { self.error = error.localizedDescription }
    }

    func retry() {
        guard canRetry, mayPersist, let index = conversations.firstIndex(where: { $0.id == selectedID }) else { return }
        do {
            let history = Array(conversations[index].messages.dropLast())
            let request = try prepare(history)
            conversations[index].messages.removeLast()
            begin(request, conversation: conversations[index].id)
        } catch { self.error = error.localizedDescription }
    }

    private func prepare(_ messages: [ChatMessage]) throws -> URLRequest {
        guard let storage else { throw ChatError.remote("本地存储不可用。") }
        return try ChatPayload.request(configuration: configuration, key: Keychain.read(), messages: messages) { try storage.imageData($0) }
    }

    private func begin(_ request: URLRequest, conversation: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation }) else { return }
        let message = ChatMessage(role: "assistant", text: "", state: .generating)
        let token = UUID()
        conversations[index].messages.append(message)
        conversations[index].updatedAt = Date()
        activeConversation = conversation
        activeAssistant = message.id
        generationID = token
        isGenerating = true
        persist()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.reply(request: request) { [weak self] delta in
                    guard let self, self.generationID == token else { return }
                    self.update(conversation: conversation, message: message.id) { $0.text += delta }
                }
                guard self.generationID == token else { return }
                self.update(conversation: conversation, message: message.id) { $0.state = .complete }
            } catch {
                guard self.generationID == token else { return }
                let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled
                self.update(conversation: conversation, message: message.id) {
                    $0.state = cancelled ? .interrupted : .failed
                    $0.failure = cancelled ? nil : error.localizedDescription
                }
            }
            guard self.generationID == token else { return }
            self.isGenerating = false
            self.generationID = nil
            self.task = nil
            self.activeConversation = nil
            self.activeAssistant = nil
            self.persist()
        }
    }

    func stop() {
        guard isGenerating else { return }
        generationID = nil
        task?.cancel()
        task = nil
        if let conversation = activeConversation, let message = activeAssistant {
            update(conversation: conversation, message: message) { $0.state = .interrupted }
        }
        activeConversation = nil
        activeAssistant = nil
        isGenerating = false
        persist()
    }

    private func update(conversation: UUID, message: UUID, change: (inout ChatMessage) -> Void) {
        guard let i = conversations.firstIndex(where: { $0.id == conversation }),
              let j = conversations[i].messages.firstIndex(where: { $0.id == message }) else { return }
        change(&conversations[i].messages[j])
    }

    private func persist() {
        guard mayPersist else { return }
        do { try storage?.save(conversations) }
        catch { self.error = "保存记录失败：\(error.localizedDescription)" }
    }
}
