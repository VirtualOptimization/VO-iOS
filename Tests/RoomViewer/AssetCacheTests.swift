import Foundation

@main
struct AssetCacheTests {
    static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = FurnitureAssetFiles(directory: folder)
        let model = base.appendingPathComponent("same-model")
        let files = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<16 { group.addTask { try await cache.file(for: model, fileExtension: "usdz") } }
            var results: [URL] = []
            for try await result in group { results.append(result) }
            return results
        }
        precondition(Set(files).count == 1)
        let bytes = try Data(contentsOf: files[0])
        precondition(bytes.count == 4096)
        _ = try await cache.file(for: model, fileExtension: "usdz")
        let reopened = FurnitureAssetFiles(directory: folder)
        _ = try await reopened.file(for: model, fileExtension: "usdz")
        await cache.prefetch((0..<8).map { base.appendingPathComponent("prefetch-\($0)") })
        for _ in 0..<2 {
            do {
                _ = try await cache.file(for: base.appendingPathComponent("failure"), fileExtension: "usdz")
                preconditionFailure("A failed HTTP response must not become a model file")
            } catch { }
        }
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let stats = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let counts = stats["counts"] as! [String: Int]
        precondition(counts["/same-model"] == 1, "Concurrent and reopened requests must reuse one file")
        precondition(counts["/failure"] == 2, "HTTP failures must be retryable")
        let maximum = stats["maximum"] as! Int
        precondition((2...4).contains(maximum), "Prefetch should overlap work without exceeding four requests")
        for index in 0..<8 { precondition(counts["/prefetch-\(index)"] == 1) }
        let first = URL(string: "https://bucket.s3.ap-southeast-2.amazonaws.com/model.usdz?X-Amz-Signature=one")!
        let second = URL(string: "https://bucket.s3.ap-southeast-2.amazonaws.com/model.usdz?X-Amz-Signature=two")!
        precondition(FurnitureAssetFiles.cacheKey(first) == FurnitureAssetFiles.cacheKey(second))
        let versioned = URL(string: second.absoluteString + "&versionId=next")!
        precondition(FurnitureAssetFiles.cacheKey(first) != FurnitureAssetFiles.cacheKey(versioned))
        let other = URL(string: "https://example.com/model?version=2")!
        precondition(FurnitureAssetFiles.cacheKey(other).contains("version=2"))
        print("PASS: one download for 16 concurrent model loads, disk reuse, four-way prefetch, retryable failures, signed URL and version identity")
    }
}
