import Foundation
import Security
import UIKit

enum Keychain {
    private static let service = "com.bkjbkjbkj.muyu.api-key"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "api-key"]
    }
    static func read() throws -> String {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw keyError(status) }
        return key
    }
    static func save(_ key: String) throws {
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw keyError(status) }
            return
        }
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let inserted = SecItemAdd(item as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw keyError(inserted) }
        } else if status != errSecSuccess { throw keyError(status) }
    }
    private static func keyError(_ status: OSStatus) -> ChatError {
        .remote("无法访问系统钥匙串（\(status)），请解锁设备后重试。")
    }
}

struct LocalStorage {
    let root: URL
    init() throws {
        root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: true).appendingPathComponent("Muyu", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Images"), withIntermediateDirectories: true)
    }
    func load() throws -> [Conversation] {
        let file = root.appendingPathComponent("conversations.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([Conversation].self, from: Data(contentsOf: file))
    }
    func save(_ conversations: [Conversation]) throws {
        try JSONEncoder().encode(conversations).write(to: root.appendingPathComponent("conversations.json"),
                                                   options: [.atomic, .completeFileProtection])
    }
    func imageURL(_ photo: PhotoAttachment) -> URL {
        root.appendingPathComponent("Images").appendingPathComponent(URL(fileURLWithPath: photo.filename).lastPathComponent)
    }
    func imageData(_ photo: PhotoAttachment) throws -> Data { try Data(contentsOf: imageURL(photo)) }
    func saveImage(_ image: UIImage) throws -> PhotoAttachment {
        let maxSide: CGFloat = 1600
        guard image.size.width > 0, image.size.height > 0 else { throw ChatError.remote("无法读取这张图片。") }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = normalized.jpegData(compressionQuality: 0.82) else { throw ChatError.remote("图片压缩失败。") }
        let photo = PhotoAttachment(filename: UUID().uuidString + ".jpg")
        try data.write(to: imageURL(photo), options: [.atomic, .completeFileProtection])
        return photo
    }
    func remove(_ photos: [PhotoAttachment]) {
        for photo in photos { try? FileManager.default.removeItem(at: imageURL(photo)) }
    }
    func cleanUnusedImages(conversations: [Conversation]) throws {
        let used = Set(conversations.flatMap(\.messages).flatMap(\.photos).map(\.filename))
        for url in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Images"), includingPropertiesForKeys: nil) {
            if !used.contains(url.lastPathComponent) { try FileManager.default.removeItem(at: url) }
        }
    }
}
