import Foundation
import CryptoKit
import Security

public enum Digest {
    public static func sha256(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    public static func file(_ url: URL) throws -> String {
        let handle=try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        var hash=SHA256()
        while let chunk=try handle.read(upToCount:1024*1024), !chunk.isEmpty { hash.update(data:chunk) }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
}
public final class ProjectStore {
    public let root: URL
    public init(root: URL) throws {
        for dir in ["sources","pages","responses"] { try FileManager.default.createDirectory(at:root.appendingPathComponent(dir),withIntermediateDirectories:true) }
        // Resolve the existing root once. Foundation normalizes /private/tmp to
        // /tmp for existing URLs, but can leave a not-yet-created child unchanged.
        self.root=root.standardizedFileURL.resolvingSymlinksInPath()
    }
    public func url(_ relative: String) throws -> URL {
        let parts=relative.components(separatedBy:"/")
        guard !parts.contains(".."),!parts.contains("."),!relative.hasPrefix("/") else {throw ArchiveError.message("项目路径超出数据目录。")}
        var prefix=root
        for part in parts where !part.isEmpty {
            prefix.appendPathComponent(part)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath:prefix.path)) != nil {throw ArchiveError.message("项目数据目录不允许符号链接。")}
        }
        let candidate=root.appendingPathComponent(relative).standardizedFileURL
        let base=root.standardizedFileURL.path + "/"
        guard !relative.hasPrefix("/"), candidate.path.hasPrefix(base) else { throw ArchiveError.message("项目路径超出数据目录。") }
        let resolved=candidate.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(root.resolvingSymlinksInPath().path+"/") else { throw ArchiveError.message("项目包含越界链接。") }
        return candidate
    }
    public func save(_ value: BookDocument) throws {
        var doc=value;doc.modifiedAt=Date()
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];encoder.dateEncodingStrategy = .iso8601
        let data=try encoder.encode(doc), destination=root.appendingPathComponent("document.json")
        if let previous=try? Data(contentsOf:destination) { try previous.write(to:root.appendingPathComponent("document.previous.json"),options:.atomic) }
        try data.write(to:destination,options:.atomic)
    }
    public func load() throws -> BookDocument {
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let doc=try decoder.decode(BookDocument.self,from:Data(contentsOf:root.appendingPathComponent("document.json")))
        guard doc.schemaVersion=="bookocr-ir-1", doc.pages.allSatisfy({ $0.width.isFinite && $0.height.isFinite && $0.width>0 && $0.height>0 && $0.width<20000 && $0.height<20000 }) else { throw ArchiveError.message("不支持的项目版本或页面尺寸。") }
        for page in doc.pages where !page.imagePath.isEmpty { _=try url(page.imagePath) }
        for source in doc.sources { _=try url(source.relativePath) }
        return doc
    }
    public func portableCopy(to destination: URL, document: BookDocument) throws {
        guard !destination.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path+"/") else { throw ArchiveError.message("请将副本保存到项目外部。") }
        try save(document)
        guard !FileManager.default.fileExists(atPath:destination.path) else { throw ArchiveError.message("该位置已有文件，请选择新名称。") }
        try FileManager.default.copyItem(at:root,to:destination)
    }
}
public struct ProviderConfiguration: Codable, Equatable {
    public var baseURL = ""
    public var model = ""
    public var tokenParameter = "max_tokens"
    public var maxOutputTokens = 16384
    public var timeout: Double = 180
    public var useJSONMode = false
    public var rememberKey = true
    public var account: String { Digest.sha256(Data(baseURL.trimmingCharacters(in:.whitespacesAndNewlines).utf8)) }
    public init() {}
    public func endpoint(_ route: String) throws -> URL {
        guard var c=URLComponents(string:baseURL.trimmingCharacters(in:.whitespacesAndNewlines)), let host=c.host, c.user==nil, c.password==nil, c.query==nil, c.fragment==nil,
              c.scheme=="https" || (c.scheme=="http" && ["localhost","127.0.0.1","::1"].contains(host)) else { throw ArchiveError.message("请输入 HTTPS API 基地址，例如 https://服务商地址/v1；本机服务可以使用 HTTP。") }
        var path=c.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        for suffix in ["/chat/completions","/models","/responses"] where path.hasSuffix(suffix) { path=String(path.dropLast(suffix.count)) }
        if ["chat/completions","models","responses"].contains(path) { path="" }
        c.path="/" + ([path,route].filter { !$0.isEmpty }.joined(separator:"/"))
        guard let url=c.url else { throw ArchiveError.message("API 地址无法解析。") };return url
    }
}
public enum KeychainStore {
    public static let service="local.leowu.Shiye.ocr.credentials"
    private static func query(_ account:String) -> [String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account] }
    public static func read(account:String) throws -> String? {
        var q=query(account);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound { return nil }
        guard status==errSecSuccess, let data=result as? Data else { throw ArchiveError.message("无法读取拾页钥匙串（\(status)）。") }
        return String(data:data,encoding:.utf8)
    }
    public static func write(_ key:String,account:String) throws {
        let q=query(account), data=Data(key.utf8)
        let status=SecItemUpdate(q as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status==errSecSuccess { return }
        guard status==errSecItemNotFound else { throw ArchiveError.message("钥匙串更新失败（\(status)）。") }
        var item=q;item[kSecValueData as String]=data;item[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let add=SecItemAdd(item as CFDictionary,nil)
        guard add==errSecSuccess else { throw ArchiveError.message("钥匙串保存失败（\(add)）。") }
    }
    public static func delete(account:String) throws {
        let status=SecItemDelete(query(account) as CFDictionary)
        guard status==errSecSuccess || status==errSecItemNotFound else { throw ArchiveError.message("钥匙串删除失败（\(status)）。") }
    }
}
