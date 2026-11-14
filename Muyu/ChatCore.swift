import Foundation

enum APIFormat: String, Codable, CaseIterable, Identifiable {
    case chatCompletions, responses
    var id: String { rawValue }
    var title: String { self == .responses ? "Responses" : "Chat Completions" }
}

struct APIConfiguration: Codable, Equatable {
    var baseURL = "https://api.openai.com/v1"
    var model = "gpt-4.1-mini"
    var format: APIFormat = .chatCompletions
    var instruction = "请用中文自然、准确地回答。图片中无法确定的内容请说明，不要编造。"
}

struct PhotoAttachment: Codable, Identifiable, Equatable {
    var id: UUID
    var filename: String
    init(id: UUID = UUID(), filename: String) { self.id = id; self.filename = filename }
}

enum MessageState: String, Codable { case complete, generating, interrupted, failed }

struct ChatMessage: Codable, Identifiable {
    var id = UUID()
    var role: String
    var text: String
    var photos: [PhotoAttachment] = []
    var state: MessageState = .complete
    var failure: String? = nil
}

struct Conversation: Codable, Identifiable {
    var id = UUID()
    var title = "新对话"
    var updatedAt = Date()
    var messages: [ChatMessage] = []
}

enum ChatError: LocalizedError {
    case invalidURL, missingKey, missingModel, emptyResponse, incompleteStream, remote(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请填写有效的 HTTPS 接口地址，地址中不能含账号、密码、查询参数或锚点。"
        case .missingKey: return "请先在设置中填写 API Key。"
        case .missingModel: return "请先填写支持图片的模型名称。"
        case .emptyResponse: return "接口未返回文字，请检查模型和接口格式。"
        case .incompleteStream: return "连接已结束，但服务端未确认回复完成。已有内容已保留，可手动重试。"
        case .remote(let message): return message
        }
    }
}

enum ChatPayload {
    static func endpoint(_ configuration: APIConfiguration) throws -> URL {
        let input = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: input), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw ChatError.invalidURL }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/chat/completions", "/responses"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        parts.path = path + (configuration.format == .responses ? "/responses" : "/chat/completions")
        guard let url = parts.url else { throw ChatError.invalidURL }
        return url
    }

    static func request(configuration: APIConfiguration, key: String, messages: [ChatMessage],
                        imageData: (PhotoAttachment) throws -> Data) throws -> URLRequest {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatError.missingKey }
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatError.missingModel }
        var request = URLRequest(url: try endpoint(configuration))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(key.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        var history = Array(messages.filter { $0.state == .complete && ($0.role == "user" || $0.role == "assistant") }.suffix(40))
        while history.first?.role == "assistant" { history.removeFirst() }
        let input: [[String: Any]] = try history.map { message in
            if configuration.format == .chatCompletions {
                if message.photos.isEmpty { return ["role": message.role, "content": message.text] }
                var content: [[String: Any]] = [["type": "text", "text": message.text]]
                for photo in message.photos {
                    content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(try imageData(photo).base64EncodedString())"]])
                }
                return ["role": message.role, "content": content]
            }
            let textType = message.role == "assistant" ? "output_text" : "input_text"
            var content: [[String: Any]] = [["type": textType, "text": message.text]]
            for photo in message.photos {
                content.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(try imageData(photo).base64EncodedString())"])
            }
            return ["role": message.role, "content": content]
        }
        var body: [String: Any] = ["model": configuration.model, "stream": true]
        if configuration.format == .responses {
            body["input"] = input
            body["store"] = false
            if !configuration.instruction.isEmpty { body["instructions"] = configuration.instruction }
        } else {
            var conversation = input
            if !configuration.instruction.isEmpty {
                conversation.insert(["role": "system", "content": configuration.instruction], at: 0)
            }
            body["messages"] = conversation
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

struct StreamEvent {
    var text = ""
    var completed = false
    var error: String? = nil
}

struct SSEDecoder {
    private var dataLines: [String] = []
    mutating func consume(_ line: String) -> String? {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            let data = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            return data
        }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            dataLines.append(value)
        }
        return nil
    }
}

// Decode bytes ourselves: the blank line separating SSE events must survive.
// UTF-8 is decoded only after a complete line, so split Chinese characters work.
struct SSEByteDecoder {
    private var line = Data()
    private var decoder = SSEDecoder()
    private var skipLF = false
    mutating func consume(_ byte: UInt8) throws -> String? {
        if skipLF {
            skipLF = false
            if byte == 10 { return nil }
        }
        if byte == 10 || byte == 13 {
            skipLF = byte == 13
            guard let string = String(data: line, encoding: .utf8) else { throw ChatError.remote("服务端返回的文字编码无效。") }
            line.removeAll(keepingCapacity: true)
            return decoder.consume(string)
        }
        line.append(byte)
        if line.count > 1_000_000 { throw ChatError.remote("服务端单条事件过大。") }
        return nil
    }
}

enum ResponseParser {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatError.remote("服务端返回了无法识别的数据。")
        }
        return value
    }

    static func errorMessage(_ value: [String: Any]) -> String? {
        if let error = value["error"] as? [String: Any] { return error["message"] as? String ?? "服务端返回错误。" }
        if let error = value["error"] as? String { return error }
        return nil
    }

    static func event(_ string: String) throws -> StreamEvent {
        if string.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { return StreamEvent(completed: true) }
        let value = try object(Data(string.utf8))
        if let error = errorMessage(value) { return StreamEvent(error: error) }
        let type = value["type"] as? String ?? ""
        if type == "error" { return StreamEvent(error: value["message"] as? String ?? "服务端返回错误。") }
        if type == "response.output_text.delta" || type == "response.refusal.delta" {
            return StreamEvent(text: value["delta"] as? String ?? "")
        }
        if type == "response.completed" { return StreamEvent(completed: true) }
        if type == "response.failed" || type == "response.incomplete" {
            let response = value["response"] as? [String: Any] ?? [:]
            return StreamEvent(error: errorMessage(response) ?? "服务端未能完成回复，请检查模型限制后重试。")
        }
        guard let choice = (value["choices"] as? [[String: Any]])?.first else { return StreamEvent() }
        let delta = choice["delta"] as? [String: Any] ?? [:]
        let reason = choice["finish_reason"] as? String
        if let reason, reason != "stop" {
            return StreamEvent(text: delta["content"] as? String ?? "", error: "回复提前结束（\(reason)），已有内容已保留。")
        }
        return StreamEvent(text: (delta["content"] as? String) ?? (delta["refusal"] as? String) ?? "", completed: reason == "stop")
    }

    static func plain(_ data: Data) throws -> String {
        let value = try object(data)
        if let error = errorMessage(value) { throw ChatError.remote(error) }
        if let status = value["status"] as? String, ["failed", "incomplete", "cancelled"].contains(status) {
            throw ChatError.remote("服务端返回了未完成的回复（\(status)）。")
        }
        if let choice = (value["choices"] as? [[String: Any]])?.first,
           let message = choice["message"] as? [String: Any] {
            let reason = choice["finish_reason"] as? String
            if let reason, reason != "stop" { throw ChatError.remote("回复未完整完成（\(reason)）。") }
            return message["content"] as? String ?? message["refusal"] as? String ?? ""
        }
        return (value["output"] as? [[String: Any]] ?? []).flatMap { item in
            (item["content"] as? [[String: Any]] ?? []).compactMap { ($0["text"] as? String) ?? ($0["refusal"] as? String) }
        }.joined()
    }
}
