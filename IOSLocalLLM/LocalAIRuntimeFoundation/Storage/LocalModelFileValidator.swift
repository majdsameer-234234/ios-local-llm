import Foundation

// MARK: - LocalModelFileValidator

enum LocalModelFileValidator {
    struct ValidationResult: Equatable {
        var isSupported: Bool
        var failures: [String]

        static let supported = ValidationResult(isSupported: true, failures: [])
    }

    static func validateModelRoot(_ dir: URL) -> ValidationResult {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
              isDir.boolValue else {
            return .init(isSupported: false, failures: ["Directory does not exist."])
        }

        if hasCompleteGGUFVLMPair(in: dir) || hasValidGGUFTextModel(in: dir) {
            return .supported
        }

        guard let files = recursiveFiles(in: dir) else {
            return .init(isSupported: false, failures: ["Could not enumerate model directory."])
        }

        let names = Set(files.map(\.lastPathComponent))
        let hasConfig = names.contains("config.json") || names.contains("model_index.json")
        let hasTokenizer = names.contains("tokenizer.json")
            || names.contains("tokenizer_config.json")
            || names.contains("vocab.json")
        let weightFiles = files.filter { isRecognizedWeightFile($0.lastPathComponent) }
        guard hasConfig || hasTokenizer else {
            return .init(isSupported: false, failures: ["Missing config.json or tokenizer companion file."])
        }
        guard !weightFiles.isEmpty else {
            return .init(isSupported: false, failures: ["Missing model weights."])
        }
        let emptyWeights = weightFiles.filter { !isNonEmptyFile($0) }
        guard emptyWeights.isEmpty else {
            return .init(
                isSupported: false,
                failures: emptyWeights.map { "\($0.lastPathComponent) is empty." }
            )
        }
        if let shardFailure = validateSafetensorShards(in: dir, files: files) {
            return .init(isSupported: false, failures: [shardFailure])
        }
        return .supported
    }

    /// True when `dir` holds a model the MLX/safetensors **text** loader can
    /// actually load. Stricter than `validateModelRoot` on purpose: the
    /// swift-transformers `Hub.loadConfig` path hard-requires `tokenizer.json`
    /// and throws `configurationMissing("tokenizer.json")` without it — even
    /// when `config.json`, `tokenizer_config.json`, and weights are all present.
    /// `validateModelRoot` deliberately accepts a `tokenizer_config.json` /
    /// `vocab.json` companion as "has a tokenizer", so a snapshot missing only
    /// `tokenizer.json` passed as usable and was then loaded as a LOCAL
    /// directory (giving the loader no chance to fetch the missing file) — the
    /// "Qwen3-4B failed to load: Required configuration file missing:
    /// tokenizer.json" regression. GGUF models embed their tokenizer, so
    /// they're exempt. Callers that resolve a *pre-staged* MLX text model must
    /// use this, not the generic validator, so a tokenizer-less dir is rejected
    /// and the loader falls back to the repo-id config (HubApi then re-fetches
    /// only the missing file).
    static func isUsableMLXTextModelDirectory(_ dir: URL) -> Bool {
        guard validateModelRoot(dir).isSupported else { return false }
        guard let files = recursiveFiles(in: dir) else { return false }
        let names = Set(files.map { $0.lastPathComponent.lowercased() })
        if names.contains(where: { $0.hasSuffix(".gguf") }) { return true }  // GGUF embeds its tokenizer
        return names.contains("tokenizer.json")
    }

    static func hasCompleteGGUFVLMPair(in dir: URL) -> Bool {
        ggufLLM(in: dir) != nil && ggufProjector(in: dir) != nil
    }

    /// First valid LLM-weights GGUF (any `*.gguf` not prefixed `mmproj`)
    /// anywhere under `dir`, or nil. Single source of truth for the GGUF
    /// VLM load path: the readiness probe (`hasCompleteGGUFVLMPair`) and the
    /// loader (`LlamaCppVLMService.resolveLLMPath`) BOTH route through this, so
    /// a repo whose weights sit in a subfolder — or end in uppercase `.GGUF` —
    /// can never pass the probe yet fail to resolve at load.
    static func ggufLLM(in dir: URL) -> URL? {
        firstValidGGUF(in: dir) { !$0.hasPrefix("mmproj") }
    }

    /// First valid vision-projector GGUF (`mmproj-*.gguf`) under `dir`, or nil.
    static func ggufProjector(in dir: URL) -> URL? {
        firstValidGGUF(in: dir) { $0.hasPrefix("mmproj") }
    }

    /// Shared recursive, case-insensitive GGUF finder. `nameMatches` receives
    /// the lowercased filename.
    private static func firstValidGGUF(in dir: URL, where nameMatches: (String) -> Bool) -> URL? {
        guard let files = recursiveFiles(in: dir) else { return nil }
        return files.first { url in
            url.pathExtension.lowercased() == "gguf"
                && nameMatches(url.lastPathComponent.lowercased())
                && isValidGGUFFile(url)
        }
    }

    static func hasValidGGUFTextModel(in dir: URL) -> Bool {
        guard let files = recursiveFiles(in: dir) else { return false }
        let ggufs = files.filter { url in
            url.pathExtension.lowercased() == "gguf"
                && !url.lastPathComponent.lowercased().hasPrefix("mmproj")
        }
        return ggufs.contains(where: isValidGGUFFile)
    }

    /// A four-byte magic check calls a truncated download valid, and the load
    /// then fails minutes later with no explanation. Walk the header instead:
    /// metadata, tensor table, and the highest tensor offset must land inside
    /// the file.
    static func hasIntactGGUFStructure(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.int64Value > 1024 else { return false }
        let fileSize = size.int64Value

        func read(_ count: Int) -> Data? {
            guard count > 0, let d = try? handle.read(upToCount: count), d.count == count else {
                return nil
            }
            return d
        }
        func u32(_ d: Data) -> UInt32 { d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func u64(_ d: Data) -> UInt64 { d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } }

        guard let magic = read(4), magic == Data([0x47, 0x47, 0x55, 0x46]),
              let vRaw = read(4), u32(vRaw) == 3,
              let tcRaw = read(8),
              let kcRaw = read(8) else { return false }

        let tensorCount = Int(u64(tcRaw))
        let kvCount = Int(u64(kcRaw))
        guard tensorCount > 0, tensorCount < 100_000, kvCount < 100_000 else { return false }

        func skipString() -> Bool {
            guard let lenRaw = read(8) else { return false }
            let len = Int(u64(lenRaw))
            guard len >= 0, len < 1 << 24 else { return false }
            return len == 0 || read(len) != nil
        }
        func skipValue(_ type: UInt32) -> Bool {
            switch type {
            case 0, 1, 7:               return read(1) != nil
            case 2, 3:                  return read(2) != nil
            case 4, 5, 6:               return read(4) != nil
            case 10, 11, 12:            return read(8) != nil
            case 8:                     return skipString()
            case 9:
                guard let t = read(4), let c = read(8) else { return false }
                let elementType = u32(t), count = Int(u64(c))
                guard count >= 0, count < 10_000_000 else { return false }
                for _ in 0..<count where !skipValue(elementType) { return false }
                return true
            default:                    return false
            }
        }

        for _ in 0..<kvCount {
            guard skipString(), let t = read(4), skipValue(u32(t)) else { return false }
        }

        var highestOffset: UInt64 = 0
        for _ in 0..<tensorCount {
            guard skipString(),
                  let dimsRaw = read(4),
                  let offRaw = read(8) else { return false }
            let dims = Int(u32(dimsRaw))
            guard dims >= 0, dims <= 4 else { return false }
            for _ in 0..<dims where read(8) == nil { return false }
            guard read(4) != nil else { return false }
            highestOffset = max(highestOffset, u64(offRaw))
        }

        let position = (try? handle.offsetInFile) ?? 0
        let dataStart = Int64(position) + 32
        return Int64(highestOffset) < fileSize - dataStart
    }

    static func isValidGGUFFile(_ url: URL) -> Bool {
        guard isNonEmptyFile(url),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        return data == Data([0x47, 0x47, 0x55, 0x46]) // "GGUF"
    }

    static func isNonEmptyFile(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return false }
        return size.int64Value > 0
    }

    private static func recursiveFiles(in dir: URL) -> [URL]? {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    private static func isRecognizedWeightFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".safetensors")
            || lower.hasSuffix(".npz")
            || lower.hasSuffix(".bin")
            || lower.hasSuffix(".gguf")
    }

    private static func validateSafetensorShards(in dir: URL, files: [URL]) -> String? {
        guard let indexURL = files.first(where: { $0.lastPathComponent == "model.safetensors.index.json" }) else {
            return nil
        }
        guard let required = requiredSafetensorShards(indexURL: indexURL), !required.isEmpty else {
            return nil
        }
        let present = Set(files.map(\.lastPathComponent))
        let missing = required.subtracting(present)
        if missing.isEmpty { return nil }
        return "Missing safetensor shard(s): \(missing.sorted().joined(separator: ", "))."
    }

    private static func requiredSafetensorShards(indexURL: URL) -> Set<String>? {
        guard
            let data = try? Data(contentsOf: indexURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let weightMap = json["weight_map"] as? [String: String]
        else { return nil }
        return Set(weightMap.values)
    }
}
