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

// MARK: - 서버 응답 모델

/// POST /rooms/start 응답
struct StartScanResponse: Codable {
    let roomId:          Int
    let rawPrefix:       String
    let generatedPrefix: String
    let expiresInSeconds: Int
    let uploads:         [UploadSlot]

    enum CodingKeys: String, CodingKey {
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

/// POST /rooms/{room_id}/complete 응답 (업로드 완료 확인 + 파이프라인 시작)
struct CompleteUploadResponse: Codable {
    let roomId:          Int
    let pipelineStarted: Bool
    let message:         String?
    let executionArn:    String?
    let uploadedKeys:    [String]?

    enum CodingKeys: String, CodingKey {
        case roomId          = "room_id"
        case pipelineStarted = "pipeline_started"
        case message
        case executionArn    = "execution_arn"
        case uploadedKeys    = "uploaded_keys"
    }
}

/// GET /api/rooms 응답의 개별 항목 – 로그인 사용자의 공간 + 버전 상태 요약
struct MyRoomSummary: Codable, Identifiable {
    var id: Int { roomId }
    let roomId:         Int
    let name:           String?
    let createdAt:      String?
    let hasOriginal:    Bool
    let hasOptimized:   Bool
    let userEditedCount: Int

    enum CodingKeys: String, CodingKey {
        case roomId          = "room_id"
        case name
        case createdAt       = "created_at"
        case hasOriginal     = "has_original"
        case hasOptimized    = "has_optimized"
        case userEditedCount = "user_edited_count"
    }
}

private struct MyRoomsResponse: Decodable {
    let rooms: [MyRoomSummary]
}

/// GET /api/rooms/{room_id} 응답 (status 폴링)
struct RoomStatusResponse: Codable {
    let roomId: Int
    let status: String   // "PENDING" | "PROCESSING" | "COMPLETED" | "ERROR"

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case status
    }
}

/// GET /api/rooms/{room_id}/versions 응답 – 버전 목록
struct ScanVersion: Codable, Identifiable {
    let versionType: String
    let createdAt:   String?
    let versionId:   Int?
    let versionNo:   Int?

    var id: String { versionId.map { String($0) } ?? versionType }

    enum CodingKeys: String, CodingKey {
        case versionType = "version_type"
        case createdAt   = "created_at"
        case versionId   = "version_id"
        case versionNo   = "version_no"
    }

    /// 플레이스홀더 생성용
    init(placeholderType: String) {
        self.versionType = placeholderType
        self.createdAt   = nil
        self.versionId   = nil
        self.versionNo   = nil
    }

    var displayName: String {
        switch versionType.uppercased() {
        case "ORIGINAL", "ORIGIN": return "원본"
        case "OPTIMIZED":          return "최적화"
        case "USER_EDITED":        return "사용자 편집"
        case "VR_MODIFIED":        return "VR 수정본"
        default:                   return versionType
        }
    }

    var systemIcon: String {
        switch versionType.uppercased() {
        case "ORIGINAL", "ORIGIN": return "house"
        case "OPTIMIZED":          return "sparkles"
        case "USER_EDITED":        return "pencil"
        case "VR_MODIFIED":        return "visionpro"
        default:                   return "doc"
        }
    }

    var canBeDeleted: Bool {
        let t = versionType.uppercased()
        return t == "USER_EDITED" || t == "VR_MODIFIED"
    }

    var supportsDownload: Bool { true }
}

struct ScanDetail: Codable {
    let roomId:      Int
    var versions:    [ScanVersion]

    enum CodingKeys: String, CodingKey {
        case roomId      = "room_id"
        case versions
    }
}

/// 버전 상세 응답 (신: layout_json_url / 구: data_url 둘 다 지원)
struct RoomVersionDetail: Decodable {
    let usdzUrl:         String?
    let usdzEmptyUrl:    String?
    let glbUrl:          String?
    let layoutJsonUrl:   String?           // 신규: iOS/RoomPlan 좌표계 JSON
    let unityJsonUrl:    String?           // 신규: Unity 좌표계 JSON
    let dataUrl:         String?           // 구버전 호환 (optimized 폴링용)
    let unityDataUrl:    String?           // 구버전 호환
    let modelUrls:       [String: String]?
    // model_key(전체 경로) → 재질/색상 반영된 usdz presigned URL. layout_json_url 파일 자체에는
    // 오브젝트별 usdz_url이 안 들어있는 경우가 많아, 이 딕셔너리를 model_key로 조회하는 게
    // 실질적인 기본 경로다 (glb는 RealityKit이 못 읽음 — noImporter).
    let modelUsdzUrls:   [String: String]?
    // layout_json_url 파일은 static이라(원본은 애초에 model_key가 없고, 예전에 최적화된 방은
    // 옛날 매핑 로직으로 박제된 값을 그대로 들고 있음) 신뢰할 수 없다. ios_objects는 요청마다
    // 서버가 현재 코드로 새로 계산해서 usdz_url까지 채워주므로 이게 실질적인 진짜 소스다.
    let iosObjects:      [RoomDataPayload.RoomObject]?

    enum CodingKeys: String, CodingKey {
        case usdzUrl       = "usdz_url"
        case usdzEmptyUrl  = "usdz_empty_url"
        case glbUrl        = "glb_url"
        case layoutJsonUrl = "layout_json_url"
        case unityJsonUrl  = "unity_layout_json_url"
        case dataUrl       = "data_url"
        case unityDataUrl  = "unity_data_url"
        case modelUrls     = "model_urls"
        case modelUsdzUrls = "model_usdz_urls"
        case iosObjects    = "ios_objects"
    }

    /// 렌더링에 사용할 iOS JSON URL (신규 우선, 구버전 폴백)
    var effectiveDataUrl: String? { layoutJsonUrl ?? dataUrl }

    /// Match full catalog keys first. A basename fallback is safe only when unique.
    func catalogUSDZURL(modelKey: String?, filename: String?) -> String? {
        let urls = modelUsdzUrls ?? [:]
        if let modelKey, let exact = urls[modelKey], !exact.isEmpty { return exact }
        guard let name = (modelKey ?? filename)?.split(separator: "/").last else { return nil }
        let matches = urls.filter { $0.key.split(separator: "/").last == name && !$0.value.isEmpty }
        return matches.count == 1 ? matches.first?.value : nil
    }

    /// Recreate the scene when refreshed asset URLs change, even for the same layout.
    var renderingID: String {
        var parts: [String] = [effectiveDataUrl ?? "", usdzUrl ?? ""]
        for (key, value) in (modelUsdzUrls ?? [:]).sorted(by: { $0.key < $1.key }) {
            parts.append(key)
            parts.append(value)
        }
        for object in iosObjects ?? [] {
            parts.append(object.identifier)
            parts.append(object.usdzUrl ?? "")
            parts.append(object.usdcUrl ?? "")
        }
        return parts.joined(separator: "|")
    }
}

/// room_data.json / room_data.roomplan_optimized.json 파싱 모델
struct RoomDataPayload: Decodable {
    let objects: [RoomObject]
    let walls:   [RoomSurface]?
    let floors:  [RoomSurface]?
    let doors:   [RoomSurface]?
    let windows: [RoomSurface]?

    struct RoomObject: Decodable {
        let identifier:    String    // 구: "identifier" / 신: "id"
        let category:      String?   // 구 포맷에만 존재
        let modelFileName: String?   // 짧은 파일명 — 로컬 RoomPlanCatalog.bundle 검색용 (파일명만 매칭)
        let modelKey:      String?   // "Category/Variant/파일명" 전체 경로 — RoomVersionDetail.modelUsdzUrls 조회 키
        let usdcUrl:       String?   // 신: "usdc_url" (S3 presigned, USER_EDITED 버전)
        let usdzUrl:       String?   // 오브젝트별 presigned USDZ (있으면 최우선) — 실제로는 layout_json_url
                                      // 파일에 이 필드가 없는 경우가 많아, modelKey로 RoomVersionDetail.modelUsdzUrls를
                                      // 조회하는 경로가 사실상의 기본 경로다.
                                      // glb_url은 RealityKit이 못 읽어서(noImporter) 반드시 usdz를 써야 함.
        let center:        [Float]?  // 구 포맷에만 존재
        let dimensions:    [Float]?
        let transform:     [[Float]]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let v = try? c.decode(String.self, forKey: .identifier) {
                identifier = v
            } else {
                identifier = try c.decode(String.self, forKey: .id)
            }
            category      = try? c.decode(String.self, forKey: .category)
            modelKey      = try? c.decode(String.self, forKey: .modelKey)
            modelFileName = (try? c.decode(String.self, forKey: .modelFileName)) ?? modelKey
            usdcUrl       = try? c.decode(String.self, forKey: .usdcUrl)
            usdzUrl       = try? c.decode(String.self, forKey: .usdzUrl)
            center        = try? c.decode([Float].self, forKey: .center)
            dimensions    = try? c.decode([Float].self, forKey: .dimensions)

            // 구: [[Float]] 4x4 행렬 / 신: {rotation:[x,y,z](deg), translation:[x,y,z]}
            if let matrix = try? c.decode([[Float]].self, forKey: .transform) {
                transform = matrix
            } else {
                struct TDict: Decodable {
                    let rotation:    [Float]
                    let translation: [Float]
                }
                let d = try c.decode(TDict.self, forKey: .transform)
                transform = Self.eulerToMatrix(rotation: d.rotation, translation: d.translation)
            }
        }

        private static func eulerToMatrix(rotation: [Float], translation: [Float]) -> [[Float]] {
            let rx = (rotation.count > 0 ? rotation[0] : 0) * .pi / 180
            let ry = (rotation.count > 1 ? rotation[1] : 0) * .pi / 180
            let rz = (rotation.count > 2 ? rotation[2] : 0) * .pi / 180
            let cy = cos(ry), sy = sin(ry)
            let cx = cos(rx), sx = sin(rx)
            let cz = cos(rz), sz = sin(rz)
            // Unity ZXY 회전 순서: R = Ry * Rx * Rz (column-major)
            let tx = translation.count > 0 ? translation[0] : 0
            let ty = translation.count > 1 ? translation[1] : 0
            let tz = translation.count > 2 ? translation[2] : 0
            return [
                [cy*cz + sy*sx*sz,  cx*sz, -sy*cz + cy*sx*sz, 0],
                [-cy*sz + sy*sx*cz, cx*cz,  sy*sz + cy*sx*cz, 0],
                [sy*cx,            -sx,     cy*cx,             0],
                [tx, ty, tz, 1]
            ]
        }

        private enum CodingKeys: String, CodingKey {
            case identifier, id, category
            case modelFileName
            case modelKey = "model_key"
            case usdcUrl = "usdc_url"
            case usdzUrl = "usdz_url"
            case center, dimensions, transform
        }

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

    private var roomsBase: String { "\(APIConfig.baseURL)/rooms" }

    // MARK: 📤 업로드 세션 시작

    func startScanUpload(includeRoomUsdz: Bool = true,
                         includeRoomEmptyUsdz: Bool = false,
                         accessToken: String) async throws -> StartScanResponse {
        let url = URL(string: "\(roomsBase)/start")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
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

    private struct CompleteUploadRequest: Encodable {
        let uploadedKeys: [String]
        let runPipeline: Bool
        enum CodingKeys: String, CodingKey {
            case uploadedKeys = "uploaded_keys"
            case runPipeline  = "run_pipeline"
        }
    }

    /// runPipeline이 false면 원본 버전만 확정하고 바로 반환한다 (그냥 "저장하기" 용도 — 색상이
    /// 반영된 서버 카탈로그 모델을 조회할 수 있는 원본 버전이 이때 비로소 생긴다).
    func completeScanUpload(roomId: Int, uploadedKeys: [String], accessToken: String, runPipeline: Bool = true) async throws -> CompleteUploadResponse {
        // POST /api/rooms/{room_id}/complete  (stale-connection 대비 최대 3회 재시도)
        // 서버가 실제로 업로드된 S3 키 목록을 확인하므로 uploaded_keys를 반드시 함께 보내야 함
        let url = URL(string: "\(roomsBase)/\(roomId)/complete")!
        let body = try JSONEncoder().encode(CompleteUploadRequest(uploadedKeys: uploadedKeys, runPipeline: runPipeline))

        var lastError: Error = OptimizerError.serverError
        for attempt in 1...3 {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            req.httpBody = body
            // S3 키 존재 확인 + 파이프라인 트리거를 서버가 동기로 처리해서 서버가 붐빌 때
            // 한참 걸릴 수 있어 3분으로 늘림. 타임아웃도 연결 끊김과 마찬가지로 재시도 대상에 포함.
            req.timeoutInterval = 180

            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    print("❌ complete 응답: \(String(data: data, encoding: .utf8) ?? "")")
                    throw OptimizerError.serverError
                }
                return try JSONDecoder().decode(CompleteUploadResponse.self, from: data)
            } catch let err as NSError where (err.code == NSURLErrorNetworkConnectionLost || err.code == NSURLErrorTimedOut) && attempt < 3 {
                print("⚠️ complete 실패 (\(err.code == NSURLErrorTimedOut ? "타임아웃" : "연결 끊김")) (\(attempt)/3) – 재시도")
                lastError = err
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw lastError
    }

    // MARK: 🔍 룸 상태 조회 (최적화 완료 폴링)

    func fetchRoomStatus(roomId: Int, accessToken: String) async throws -> String {
        var req = URLRequest(url: URL(string: "\(roomsBase)/\(roomId)")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OptimizerError.serverError
        }
        return try JSONDecoder().decode(RoomStatusResponse.self, from: data).status
    }

    // MARK: ✏️ 방 이름 수정 (PATCH /api/rooms/{room_id})

    private struct RoomNameUpdateRequest: Encodable { let name: String? }

    func updateRoomName(roomId: Int, name: String, accessToken: String) async throws {
        var req = URLRequest(url: URL(string: "\(roomsBase)/\(roomId)")!)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(RoomNameUpdateRequest(name: name))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("❌ 방 이름 수정 응답: \(String(data: data, encoding: .utf8) ?? "")")
            throw OptimizerError.serverError
        }
    }

    // MARK: 🗂️ 버전 목록 조회 (rooms API)

    func fetchRoomVersions(roomId: Int, accessToken: String) async throws -> ScanDetail {
        var req = URLRequest(url: URL(string: "\(roomsBase)/\(roomId)/versions")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("❌ 버전 목록 응답: \(String(data: data, encoding: .utf8) ?? "")")
            throw OptimizerError.serverError
        }
        print("📋 버전 목록 원본: \(String(data: data, encoding: .utf8) ?? "")")
        return try JSONDecoder().decode(ScanDetail.self, from: data)
    }

    // MARK: 🗂️ 내 공간 목록 (로그인 사용자 기준, 버전 상태 요약 포함)

    /// GET /api/rooms
    func fetchMyRooms(accessToken: String) async throws -> [MyRoomSummary] {
        var req = URLRequest(url: URL(string: roomsBase)!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("❌ 내 공간 목록 응답: \(String(data: data, encoding: .utf8) ?? "")")
            throw OptimizerError.serverError
        }
        return try JSONDecoder().decode(MyRoomsResponse.self, from: data).rooms
    }

    // MARK: 📦 버전 상세 조회

    /// GET /rooms/{room_id}/optimized 또는 /rooms/{room_id}/origin (versionType으로 분기)
    func fetchVersionDetail(roomId: Int, versionType: String, accessToken: String) async throws -> RoomVersionDetail {
        var req = URLRequest(url: URL(string: "\(roomsBase)/\(roomId)/\(versionType)")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("❌ 버전 상세 응답: \(String(data: data, encoding: .utf8) ?? "")")
            throw OptimizerError.serverError
        }
        return try JSONDecoder().decode(RoomVersionDetail.self, from: data)
    }

    /// GET /api/rooms/{room_id}/versions/{version_id}
    func fetchVersionDetailById(roomId: Int, versionId: Int, accessToken: String) async throws -> RoomVersionDetail {
        var req = URLRequest(url: URL(string: "\(roomsBase)/\(roomId)/versions/\(versionId)")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("❌ 버전 상세 응답: \(String(data: data, encoding: .utf8) ?? "")")
            throw OptimizerError.serverError
        }
        print("📦 버전 상세: \(String(data: data, encoding: .utf8) ?? "")")
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
    // DELETE /api/rooms/{room_id}/versions/{version_id}
    func deleteVersion(roomId: Int, versionId: Int, accessToken: String) async throws {
        let url = URL(string: "\(roomsBase)/\(roomId)/versions/\(versionId)")!
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
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
