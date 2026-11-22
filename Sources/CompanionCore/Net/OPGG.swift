import Foundation

public protocol BaseBuildSource: Sendable {
    func baseBuild(championID: String, role: Role) async -> BaseBuild?
}

public actor OPGGClient: BaseBuildSource {
    public static let endpoint = URL(string: "https://mcp-api.op.gg/mcp")!
    static let desiredFields = [
        "data.starter_items.{ids[]}",
        "data.core_items.{ids[]}",
        "data.boots.{ids[]}",
        "data.fourth_items[].{ids[]}",
        "data.fifth_items[].{ids[]}",
    ]
    static let maxSituational = 6

    private let session: URLSession
    private let cacheDir: URL
    private let patch: String
    private let timeout: TimeInterval

    public init(session: URLSession = URLSession(configuration: .ephemeral), cacheDir: URL, patch: String, timeout: TimeInterval = 5) {
        self.session = session
        self.cacheDir = cacheDir
        self.patch = patch
        self.timeout = timeout
    }

    public func baseBuild(championID: String, role: Role) async -> BaseBuild? {
        let file = cacheFile(championID: championID, role: role)
        if let cached = Self.readCache(file) { return cached }
        guard let text = await fetchText(champion: Self.opggName(championID), role: role),
              let parsed = try? OPGGParser.parse(text),
              let b = Self.build(from: parsed.root, headers: parsed.headers)
        else { return nil }
        let result = BaseBuild(champion: championID, role: role, starter: b.starter, core: b.core,
                               boots: b.boots, situational: b.situational, source: .opgg, patch: patch)
        Self.writeCache(result, to: file)
        return result
    }

    private static func readCache(_ file: URL) -> BaseBuild? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(BaseBuild.self, from: data)
    }

    private static func writeCache(_ build: BaseBuild, to file: URL) {
        guard let data = try? JSONEncoder().encode(build) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// data dragon id to op.gg upper snake case: an underscore goes before an uppercase letter that
    /// follows a lowercase one (two-word names split, single-letter prefixes do not). monkey king maps to wukong.
    public static func opggName(_ ddragonID: String) -> String {
        if ddragonID == "MonkeyKing" { return "WUKONG" }
        var out = ""
        var prevLower = false
        for ch in ddragonID where ch.isLetter || ch.isNumber {
            if ch.isUppercase && prevLower { out.append("_") }
            out.append(ch)
            prevLower = ch.isLowercase
        }
        return out.uppercased()
    }

    /// maps the parsed tree by header field position (constructor names are unreliable).
    /// nil unless core items are present.
    static func build(from root: OPGGValue, headers: [String: [String]])
        -> (starter: [Int], core: [Int], boots: Int?, situational: [Int])? {
        guard case let .object(rootName, rootArgs) = root else { return nil }
        let dataIndex = headers[rootName]?.firstIndex(of: "data") ?? 0
        guard dataIndex < rootArgs.count,
              case let .object(dataName, dataArgs) = rootArgs[dataIndex],
              let fields = headers[dataName]
        else { return nil }

        func field(_ name: String) -> OPGGValue? {
            guard let i = fields.firstIndex(of: name), i < dataArgs.count else { return nil }
            return dataArgs[i]
        }

        let core = field("core_items").map { primaryIDs($0, headers: headers) } ?? []
        guard !core.isEmpty else { return nil }
        let starter = field("starter_items").map { primaryIDs($0, headers: headers) } ?? []
        let boots = field("boots").map { primaryIDs($0, headers: headers) }?.first

        var taken = Set(core).union(starter)
        if let boots { taken.insert(boots) }
        var situational: [Int] = []
        for name in ["fourth_items", "fifth_items"] {
            guard let value = field(name) else { continue }
            for id in options(value).flatMap({ ids(of: $0, headers: headers) }) where !taken.contains(id) {
                taken.insert(id)
                situational.append(id)
            }
        }
        return (starter, core, boots, Array(situational.prefix(maxSituational)))
    }

    /// ids of a single-option field; if it arrives as a list of options, uses the first.
    private static func primaryIDs(_ value: OPGGValue, headers: [String: [String]]) -> [Int] {
        if case let .array(items) = value, let first = items.first, case .object = first {
            return ids(of: first, headers: headers)
        }
        return ids(of: value, headers: headers)
    }

    private static func options(_ value: OPGGValue) -> [OPGGValue] {
        switch value {
        case let .array(items): items
        case .object: [value]
        default: []
        }
    }

    /// the `ids` arg of an item-set object (by header position), else its first numeric array.
    private static func ids(of value: OPGGValue, headers: [String: [String]]) -> [Int] {
        switch value {
        case let .object(name, args):
            if let i = headers[name]?.firstIndex(of: "ids"), i < args.count, let list = intArray(args[i]) {
                return list
            }
            for arg in args { if let list = intArray(arg) { return list } }
            return []
        case .array:
            return intArray(value) ?? []
        default:
            return []
        }
    }

    private static func intArray(_ value: OPGGValue) -> [Int]? {
        guard case let .array(items) = value, !items.isEmpty else { return nil }
        var out: [Int] = []
        for item in items {
            guard case let .number(d) = item, d.isFinite, d == d.rounded(), d > 0, d < 1e9 else { return nil }
            out.append(Int(d))
        }
        return out
    }

    private func cacheFile(championID: String, role: Role) -> URL {
        func safe(_ s: String) -> String {
            String(s.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" })
        }
        return cacheDir
            .appendingPathComponent(safe(patch).isEmpty ? "unknown" : safe(patch), isDirectory: true)
            .appendingPathComponent("\(safe(championID))_\(role.rawValue).json")
    }

    private func fetchText(champion: String, role: Role) async -> String? {
        guard let request = makeRequest(champion: champion, role: role) else { return nil }
        let session = self.session
        let timeout = self.timeout
        let result: (Data, URLResponse)? = try? await withThrowingTaskGroup(of: (Data, URLResponse)?.self) { group in
            group.addTask { try await session.data(for: request) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        guard let (data, response) = result,
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return Self.extractText(data)
    }

    private func makeRequest(champion: String, role: Role) -> URLRequest? {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "lol_get_champion_analysis",
                "arguments": [
                    "champion": champion,
                    "position": role.rawValue,
                    "game_mode": "ranked",
                    "desired_output_fields": Self.desiredFields,
                ] as [String: Any],
            ] as [String: Any],
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = httpBody
        return request
    }

    /// pulls `result.content[0].text` out of a json-rpc body (plain or sse-framed).
    static func extractText(_ data: Data) -> String? {
        var candidates: [Data] = [data]
        if let raw = String(data: data, encoding: .utf8), !raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            candidates = raw.split(whereSeparator: \.isNewline)
                .filter { $0.hasPrefix("data:") }
                .map { Data($0.dropFirst(5).utf8) }
        }
        for candidate in candidates {
            guard let obj = try? JSONSerialization.jsonObject(with: candidate) as? [String: Any] else { continue }
            if obj["error"] != nil { return nil }
            guard let result = obj["result"] as? [String: Any] else { continue }
            if result["isError"] as? Bool == true { return nil }
            guard let content = result["content"] as? [[String: Any]] else { return nil }
            return content.lazy.compactMap { $0["text"] as? String }.first
        }
        return nil
    }
}
