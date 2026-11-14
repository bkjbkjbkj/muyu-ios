import Foundation

final class APIClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // Never forward the user's Authorization header to a redirect target.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func reply(request: URLRequest, onDelta: @escaping @MainActor (String) -> Void) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ChatError.remote("服务端响应无效。") }
        guard (200..<300).contains(response.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 16_384 { break }
            }
            let value = try? ResponseParser.object(data)
            let detail = value.flatMap { ResponseParser.errorMessage($0) }
            throw ChatError.remote("HTTP \(response.statusCode)：\(detail ?? Self.hint(response.statusCode))")
        }
        let isJSON = response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true
        if isJSON {
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                data.append(byte)
                if data.count > 8_000_000 { throw ChatError.remote("接口返回内容过大。") }
            }
            let text = try ResponseParser.plain(data)
            guard !text.isEmpty else { throw ChatError.emptyResponse }
            await onDelta(text)
            return
        }
        var decoder = SSEByteDecoder()
        var completed = false
        var hasText = false
        var pending = ""
        var lastFlush = Date()
        var received = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            received += 1
            if received > 16_000_000 { throw ChatError.remote("回复过大，已停止接收。") }
            guard let payload = try decoder.consume(byte) else { continue }
            let event = try ResponseParser.event(payload)
            pending += event.text
            hasText = hasText || !event.text.isEmpty
            if !pending.isEmpty && (Date().timeIntervalSince(lastFlush) > 0.04 || event.completed || event.error != nil) {
                await onDelta(pending)
                pending = ""
                lastFlush = Date()
            }
            if let error = event.error { throw ChatError.remote(error) }
            if event.completed { completed = true; break }
        }
        if !pending.isEmpty { await onDelta(pending) }
        try Task.checkCancellation()
        guard completed else { throw ChatError.incompleteStream }
        guard hasText else { throw ChatError.emptyResponse }
    }

    private static func hint(_ code: Int) -> String {
        switch code {
        case 300..<400: return "接口发生重定向。请在设置中填写最终 HTTPS API 地址。"
        case 401, 403: return "请检查密钥及模型权限。"
        case 404: return "请检查 Base URL、模型名称和接口格式。"
        case 413: return "图片请求过大，请减少图片数量。"
        case 429: return "请求受限或余额不足，请稍后重试并检查账户。"
        default: return "请稍后重试，或检查服务商状态。"
        }
    }
}
