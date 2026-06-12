import Foundation
import RoomPlan
import simd

// MARK: - 서버 요청 모델 (private)

/// POST /rooms/start 요청
private struct StartScanRequest: Encodable {
    let includeRoomUsdz:     Bool
    let includeRoomEmptyUsdz: Bool

    enum CodingKeys: String, CodingKey {
        case includeRoomUsdz      = "include_room_usdz"
        case includeRoomEmptyUsdz = "include_room_empty_usdz"
    }
}

/// POST /rooms/{confirm_code}/complete 요청
private struct CompleteUploadRequest: Encodable {
    let uploadedKeys: [String]
    enum CodingKeys: String, CodingKey { case uploadedKeys = "uploaded_keys" }
}

// MARK: - 서버 응답 모델

/// POST /rooms/start 응답
struct StartScanResponse: Codable {
    let confirmCode:     String
    let roomId:          Int
    let rawPrefix:       String
    let generatedPrefix: String
    let expiresInSeconds: Int
    let uploads:         [UploadSlot]

    enum CodingKeys: String, CodingKey {
        case confirmCode      = "confirm_code"
        case roomId           = "room_id"
        case rawPrefix        = "raw_prefix"
        case generatedPrefix  = "generated_prefix"
        case expiresInSeconds = "expires_in_seconds"
        case uploads
    }

    struct UploadSlot: Codable {
        let logicalName:  String
        let s3Key:        String
        let presignedURL: String
        let contentType:  String

        enum CodingKeys: String, CodingKey {
            case logicalName  = "logical_name"
            case s3Key        = "s3_key"
            case presignedURL = "presigned_url"
            case contentType  = "content_type"
        }
    }
}

/// POST /rooms/{confirm_code}/complete 응답
struct CompleteUploadResponse: Codable {
    let confirmCode:     String
    let pipelineStarted: Bool

    enum CodingKeys: String, CodingKey {
        case confirmCode     = "confirm_code"
        case pipelineStarted = "pipeline_started"
    }
}

/// GET /api/rooms/{confirm_code} 응답 (status 폴링)
struct RoomStatusResponse: Codable {
    let roomId:      Int?
    let confirmCode: String
    let status:      String   // "PENDING" | "PROCESSING" | "COMPLETED" | "ERROR"

    enum CodingKeys: String, CodingKey {
        case roomId      = "room_id"
        case confirmCode = "confirm_code"
        case status
    }
}

/// GET /api/rooms/{confirm_code}/versions 응답 – 버전 목록
/// origin/optimized는 version_id 없음, vr_modified는 version_id 있음
struct ScanVersion: Codable, Identifiable {
    let versionType: String
    let createdAt:   String?
    let versionId:   String?   // VR 수정본 등 삭제 가능한 버전의 식별자

    /// Identifiable – version_type 을 id로 사용 (vr_modified는 versionId 우선)
    var id: String { versionId ?? versionType }

    enum CodingKeys: String, CodingKey {
        case versionType = "version_type"
        case createdAt   = "created_at"
        case versionId   = "version_id"
    }

    /// 플레이스홀더 생성용
    init(placeholderType: String) {
        self.versionType = placeholderType
        self.createdAt   = nil
        self.versionId   = nil
    }

    var displayName: String {
        switch versionType {
        case "origin":      return "원본"
        case "optimized":   return "최적화"
        case "vr_modified": return "VR 수정본"
        default:            return versionType
        }
    }

    var systemIcon: String {
        switch versionType {
        case "origin":      return "house"
        case "optimized":   return "sparkles"
        case "vr_modified": return "visionpro"
        default:            return "doc"
        }
    }

    var supportsDownload: Bool { true }  // placeholder는 DisplayVersion.isPlaceholder 로 처리
}

struct ScanDetail: Codable {
    let roomId:      Int?
    let confirmCode: String
    let createdAt:   String?
    var versions:    [ScanVersion]

    enum CodingKeys: String, CodingKey {
        case roomId      = "room_id"
        case confirmCode = "confirm_code"
        case createdAt   = "created_at"
        case versions
    }
}

/// GET /api/rooms/{confirm_code}/origin|optimized 응답
struct RoomVersionDetail: Codable {
    let usdzUrl:      String?             // Room.usdz presigned URL (가구 포함 원본)
    let usdzEmptyUrl: String?             // Room_empty.usdz presigned URL (가구 없는 방 구조만, B안용)
    let glbUrl:       String?             // output.glb presigned URL (Unity용)
    let dataUrl:      String?             // room_data.roomplan_optimized.json (RoomPlan 좌표계, iOS용)
    let unityDataUrl: String?             // room_data.roomplan_optimized.unity.json (Unity 좌표계) — nullable
    let modelUrls:    [String: String]?   // 카탈로그 모델 URL (key = modelFileName)

    enum CodingKeys: String, CodingKey {
        case usdzUrl      = "usdz_url"
        case usdzEmptyUrl = "usdz_empty_url"
        case glbUrl       = "glb_url"
        case dataUrl      = "data_url"
        case unityDataUrl = "unity_data_url"
        case modelUrls    = "model_urls"
    }
}

/// room_data.json / room_data.roomplan_optimized.json 파싱 모델
struct RoomDataPayload: Codable {
    let objects: [RoomObject]
    let walls:   [RoomSurface]?
    let floors:  [RoomSurface]?
    let doors:   [RoomSurface]?
    let windows: [RoomSurface]?

    struct RoomObject: Codable {
        let identifier:    String
        let category:      String
        let modelFileName: String?
        let center:        [Float]
        let dimensions:    [Float]?
        let transform:     [[Float]]

        var simdTransform: simd_float4x4? {
            guard transform.count == 4, transform.allSatisfy({ $0.count >= 4 }) else { return nil }
            return simd_float4x4(columns: (
                SIMD4(transform[0][0], transform[0][1], transform[0][2], transform[0][3]),
                SIMD4(transform[1][0], transform[1][1], transform[1][2], transform[1][3]),
                SIMD4(transform[2][0], transform[2][1], transform[2][2], transform[2][3]),
                SIMD4(transform[3][0], transform[3][1], transform[3][2], transform[3][3])
            ))
        }
    }

    struct RoomSurface: Codable {
        let center:     [Float]
        let dimensions: [Float]
        let transform:  [[Float]]

        var simdTransform: simd_float4x4? {
            guard transform.count == 4, transform.allSatisfy({ $0.count >= 4 }) else { return nil }
            return simd_float4x4(columns: (
                SIMD4(transform[0][0], transform[0][1], transform[0][2], transform[0][3]),
                SIMD4(transform[1][0], transform[1][1], transform[1][2], transform[1][3]),
                SIMD4(transform[2][0], transform[2][1], transform[2][2], transform[2][3]),
                SIMD4(transform[3][0], transform[3][1], transform[3][2], transform[3][3])
            ))
        }
    }
}

// MARK: - RoomOptimizerService

actor RoomOptimizerService {

    private let apiBase  = "http://43.201.10.153:8000/api"
    private var roomsBase: String { "\(apiBase)/rooms" }

    // MARK: 📤 업로드 세션 시작

    func startScanUpload(includeRoomUsdz: Bool = true,
                         includeRoomEmptyUsdz: Bool = false) async throws -> StartScanResponse {
        let url = URL(string: "\(roomsBase)/start")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            StartScanRequest(includeRoomUsdz: includeRoomUsdz,
                             includeRoomEmptyUsdz: includeRoomEmptyUsdz)
        )
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("❌ start 응답: \(String(data: data, encoding: .utf8) ?? "")")
            throw OptimizerError.serverError
        }
        return try JSONDecoder().decode(StartScanResponse.self, from: data)
    }

    // MARK: S3 직접 업로드 (Presigned PUT)

    func uploadFileToS3(presignedURL: String, data: Data, contentType: String) async throws {
        guard let url = URL(string: presignedURL) else { throw OptimizerError.invalidResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 120

        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("❌ S3 PUT 실패: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            throw OptimizerError.serverError
        }
    }

    // MARK: 업로드 완료 → 파이프라인 트리거

    func completeScanUpload(confirmCode: String,
                            uploadedKeys: [String]) async throws -> CompleteUploadResponse {
        // POST /api/rooms/{confirm_code}/complete  (stale-connection 대비 최대 3회 재시도)
        let url = URL(string: "\(roomsBase)/\(confirmCode)/complete")!
        let body = try JSONEncoder().encode(CompleteUploadRequest(uploadedKeys: uploadedKeys))

        var lastError: Error = OptimizerError.serverError
        for attempt in 1...3 {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            req.timeoutInterval = 30

            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    print("❌ complete 응답: \(String(data: data, encoding: .utf8) ?? "")")
                    throw OptimizerError.serverError
                }
                return try JSONDecoder().decode(CompleteUploadResponse.self, from: data)
            } catch let err as NSError where err.code == NSURLErrorNetworkConnectionLost && attempt < 3 {
                print("⚠️ complete 연결 끊김 (\(attempt)/3) – 재시도")
                lastError = err
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw lastError
    }

    // MARK: 🔍 룸 상태 조회 (최적화 완료 폴링)

    func fetchRoomStatus(confirmCode: String) async throws -> String {
        let url = URL(string: "\(roomsBase)/\(confirmCode)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OptimizerError.serverError
        }
        return try JSONDecoder().decode(RoomStatusResponse.self, from: data).status
    }

    // MARK: 🗂️ 버전 목록 조회 (rooms API)

    func fetchRoomVersions(confirmCode: String) async throws -> ScanDetail {
        let url = URL(string: "\(roomsBase)/\(confirmCode)/versions")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("❌ 버전 목록 응답: \(String(data: data, encoding: .utf8) ?? "")")
            throw OptimizerError.serverError
        }
        print("📋 버전 목록 원본: \(String(data: data, encoding: .utf8) ?? "")")
        return try JSONDecoder().decode(ScanDetail.self, from: data)
    }

    // saveAndUpload 완료 후 결과 조회용 (rooms API로 전환)
    func fetchScanDetail(confirmCode: String) async throws -> ScanDetail {
        try await fetchRoomVersions(confirmCode: confirmCode)
    }

    // MARK: 📦 버전 상세 조회 (가구 배치 + USDC URL)
    // GET /api/rooms/{confirm_code}/origin  또는  /api/rooms/{confirm_code}/optimized

    func fetchVersionDetail(confirmCode: String, versionType: String) async throws -> RoomVersionDetail {
        let url = URL(string: "\(roomsBase)/\(confirmCode)/\(versionType)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("❌ 버전 상세 응답: \(String(data: data, encoding: .utf8) ?? "")")
            throw OptimizerError.serverError
        }
        print("📦 버전 상세 원본: \(String(data: data, encoding: .utf8) ?? "")")
        return try JSONDecoder().decode(RoomVersionDetail.self, from: data)
    }

    /// Presigned URL에서 USDZ 다운로드 → 로컬 임시 파일 URL 반환
    func downloadUSDZ(from urlString: String) async throws -> URL {
        guard let remoteURL = URL(string: urlString) else { throw OptimizerError.invalidResponse }
        let (tempURL, _) = try await URLSession.shared.download(from: remoteURL)
        let destURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".usdz")
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        return destURL
    }

    // MARK: 🗑️ 버전 삭제 (VR 수정본 전용)
    // DELETE /api/rooms/{confirm_code}/versions/{version_id}
    func deleteVersion(confirmCode: String, versionId: String) async throws {
        let url = URL(string: "\(roomsBase)/\(confirmCode)/versions/\(versionId)")!
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("❌ 삭제 응답: \(String(data: data, encoding: .utf8) ?? "")")
            throw OptimizerError.serverError
        }
    }
}

// MARK: - Error

enum OptimizerError: LocalizedError {
    case serverError
    case invalidResponse
    case timeout

    var errorDescription: String? {
        switch self {
        case .serverError:     return "서버 오류가 발생했습니다"
        case .invalidResponse: return "응답 형식이 올바르지 않습니다"
        case .timeout:         return "최적화 시간이 초과되었습니다"
        }
    }
}
