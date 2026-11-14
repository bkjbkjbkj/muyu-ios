import Foundation

@main
struct CoreChecks {
    static var count = 0
    static func check(_ condition: Bool, _ name: String) {
        guard condition else { fatalError("FAIL: \(name)") }
        count += 1
    }
    static func rejects(_ name: String, _ action: () throws -> Void) {
        do { try action(); fatalError("FAIL: expected rejection: \(name)") }
        catch { count += 1 }
    }
    static func main() throws {
        var config = APIConfiguration()
        check(tryURL(config) == "https://api.openai.com/v1/chat/completions", "default endpoint")
        config.baseURL = "https://example.com/proxy/v1/chat/completions/"
        check(tryURL(config) == "https://example.com/proxy/v1/chat/completions", "no duplicated endpoint")
        config.format = .responses
        check(tryURL(config) == "https://example.com/proxy/v1/responses", "format changes endpoint")
        config.baseURL = " https://example.com/v1/responses/ "
        check(tryURL(config) == "https://example.com/v1/responses", "trim slash and whitespace")
        for url in ["http://example.com", "not a url", "https://user:password@example.com/v1", "https://example.com?key=secret", "https://example.com/#fragment"] {
            config.baseURL = url
            rejects("invalid URL \(url)") { _ = try ChatPayload.endpoint(config) }
        }
        config = APIConfiguration()
        let photo = PhotoAttachment(filename: "test.jpg")
        let user = ChatMessage(role: "user", text: "看看这张图", photos: [photo])
        let assistant = ChatMessage(role: "assistant", text: "这是一张图片。")
        let failed = ChatMessage(role: "assistant", text: "partial", state: .failed)
        let request = try ChatPayload.request(configuration: config, key: " test ", messages: [user, assistant, failed]) { _ in Data([1, 2, 3]) }
        check(request.httpMethod == "POST", "POST request")
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test", "trimmed credential")
        let chat = try ResponseParser.object(request.httpBody!)
        check(chat["stream"] as? Bool == true, "stream enabled")
        let messages = chat["messages"] as! [[String: Any]]
        check(messages.count == 3, "failed reply excluded; system included")
        let image = (messages[1]["content"] as! [[String: Any]])[1]
        check((image["image_url"] as? [String: String])?["url"] == "data:image/jpeg;base64,AQID", "chat image encoding")
        config.format = .responses
        let responseRequest = try ChatPayload.request(configuration: config, key: "test", messages: [user, assistant]) { _ in Data([1, 2, 3]) }
        let body = try ResponseParser.object(responseRequest.httpBody!)
        let input = body["input"] as! [[String: Any]]
        check(body["store"] as? Bool == false, "Responses server storage disabled")
        check((input[0]["content"] as! [[String: Any]])[1]["type"] as? String == "input_image", "Responses image type")
        check((input[1]["content"] as! [[String: Any]])[0]["type"] as? String == "output_text", "assistant history type")
        rejects("missing key") { _ = try ChatPayload.request(configuration: config, key: " ", messages: []) { _ in Data() } }
        config.model = " "
        rejects("missing model") { _ = try ChatPayload.request(configuration: config, key: "test", messages: []) { _ in Data() } }
        config = APIConfiguration()
        config.instruction = ""
        let longHistory = (0..<60).map { ChatMessage(role: $0.isMultiple(of: 2) ? "assistant" : "user", text: "\($0)") }
        let capped = try ChatPayload.request(configuration: config, key: "test", messages: longHistory) { _ in Data() }
        let cappedMessages = try ResponseParser.object(capped.httpBody!)["messages"] as! [[String: Any]]
        check(cappedMessages.count == 39, "history limit strips leading assistant")
        check(cappedMessages[0]["role"] as? String == "user", "history starts with user")

        let delta = #"{"choices":[{"delta":{"content":"你好"},"finish_reason":null}]}"#
        let finish = #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
        check(try ResponseParser.event(delta).text == "你好", "chat delta")
        check(try ResponseParser.event(finish).completed, "chat completion")
        check(try ResponseParser.event("[DONE]").completed, "DONE completion")
        check(try ResponseParser.event(#"{"type":"response.output_text.delta","delta":"你好"}"#).text == "你好", "Responses delta")
        check(try ResponseParser.event(#"{"type":"response.completed"}"#).completed, "Responses completion")
        check(try ResponseParser.event(#"{"type":"response.incomplete"}"#).error != nil, "incomplete response error")
        check(try ResponseParser.event(#"{"choices":[{"delta":{},"finish_reason":"length"}]}"#).error != nil, "truncated chat error")
        check(try ResponseParser.event(#"{"error":{"message":"no quota"}}"#).error == "no quota", "stream server error")
        rejects("invalid JSON") { _ = try ResponseParser.event("not JSON") }

        var lineDecoder = SSEDecoder()
        check(lineDecoder.consume(": heartbeat") == nil, "SSE comment ignored")
        check(lineDecoder.consume("event: message") == nil, "SSE event metadata ignored")
        check(lineDecoder.consume("data: first") == nil, "SSE data buffered")
        check(lineDecoder.consume("data: second") == nil, "SSE continuation buffered")
        check(lineDecoder.consume("") == "first\nsecond", "SSE multiline joined")
        check(lineDecoder.consume("") == nil, "SSE empty separator ignored")
        for newline in ["\n", "\r\n", "\r"] {
            var bytes = SSEByteDecoder()
            let stream = ": keepalive\(newline)\(newline)data: \(delta)\(newline)\(newline)data: [DONE]\(newline)\(newline)"
            var events: [String] = []
            for byte in stream.utf8 { if let event = try bytes.consume(byte) { events.append(event) } }
            check(events == [delta, "[DONE]"], "UTF-8 and line endings \(newline.debugDescription)")
        }
        let json = Data(#"{"choices":[{"message":{"content":"普通响应"},"finish_reason":"stop"}]}"#.utf8)
        check(try ResponseParser.plain(json) == "普通响应", "nonstream chat response")
        let responseJSON = Data(#"{"output":[{"content":[{"type":"output_text","text":"回答"}]}]}"#.utf8)
        check(try ResponseParser.plain(responseJSON) == "回答", "nonstream Responses response")
        rejects("nonstream error") { _ = try ResponseParser.plain(Data(#"{"error":{"message":"denied"}}"#.utf8)) }
        let roundTrip = Conversation(messages: [user, assistant, failed])
        let decoded = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(roundTrip))
        check(decoded.messages[0].photos[0] == photo && decoded.messages[2].state == .failed, "chat persistence roundtrip")
        print("PASS: \(count) core checks")
    }
    static func tryURL(_ config: APIConfiguration) -> String { (try? ChatPayload.endpoint(config).absoluteString) ?? "INVALID" }
}
