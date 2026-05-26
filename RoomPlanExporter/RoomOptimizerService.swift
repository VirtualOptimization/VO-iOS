//
//  Roomoptimizerservice.swift
//  RoomPlanExporter
//
//  Created by Jung Hyun Han on 4/8/26.
//  Copyright © 2026 Apple. All rights reserved.
//

import Foundation
import RoomPlan
import simd
import zlib

// MARK: - OptimizedObject (서버 응답 모델)

struct OptimizedObject: Codable, Identifiable {
    var id: UUID { identifier }
    let identifier: UUID
    let category: String
    let center: SIMD3<Float>
    let rotation: simd_quatf

    enum CodingKeys: String, CodingKey {
        case identifier, category, center, rotation
    }

    init(identifier: UUID, category: String, center: SIMD3<Float>, rotation: simd_quatf) {
        self.identifier = identifier
        self.category = category
        self.center = center
        self.rotation = rotation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(UUID.self, forKey: .identifier)
        category   = try container.decode(String.self, forKey: .category)

        let centerArr = try container.decode([Float].self, forKey: .center)
        center = SIMD3(centerArr[0], centerArr[1], centerArr[2])

        let rotArr = try container.decode([Float].self, forKey: .rotation)
        rotation = simd_quatf(ix: rotArr[0], iy: rotArr[1], iz: rotArr[2], r: rotArr[3])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(category,   forKey: .category)
        try container.encode([center.x, center.y, center.z], forKey: .center)
        try container.encode([rotation.imag.x, rotation.imag.y, rotation.imag.z, rotation.real], forKey: .rotation)
    }
}

// MARK: - 서버 응답 모델

/// POST /api/v1/scans 업로드 응답
struct UploadResponse: Codable {
    let confirmCode: String
    let objectCount: Int?
    let uploadedFiles: [String]?

    enum CodingKeys: String, CodingKey {
        case confirmCode   = "confirm_code"
        case objectCount   = "object_count"
        case uploadedFiles = "uploaded_files"
    }
}

/// POST /api/v1/scans/{confirm_code}/optimize 최적화 응답
private struct OptimizeResponse: Codable {
    let objects: [OptimizeObject]

    struct OptimizeObject: Codable {
        let identifier: String
        let category: String
        let center: [Float]
        let transform: [[Float]]

        func toOptimizedObject() -> OptimizedObject? {
            guard let uuid = UUID(uuidString: identifier), center.count >= 3 else { return nil }
            let pos = SIMD3<Float>(center[0], center[1], center[2])

            let rotation: simd_quatf
            if transform.count >= 4,
               transform[0].count >= 4, transform[1].count >= 4,
               transform[2].count >= 4, transform[3].count >= 4 {
                let mat = simd_float4x4(columns: (
                    SIMD4(transform[0][0], transform[0][1], transform[0][2], transform[0][3]),
                    SIMD4(transform[1][0], transform[1][1], transform[1][2], transform[1][3]),
                    SIMD4(transform[2][0], transform[2][1], transform[2][2], transform[2][3]),
                    SIMD4(transform[3][0], transform[3][1], transform[3][2], transform[3][3])
                ))
                rotation = simd_quatf(mat)
            } else {
                rotation = simd_quatf(angle: 0, axis: [0, 1, 0])
            }
            return OptimizedObject(identifier: uuid, category: category, center: pos, rotation: rotation)
        }
    }
}

// MARK: - RoomOptimizerService

actor RoomOptimizerService {

    private let baseURL = "http://172.30.1.62:8000/api/v1/scans"

    // MARK: - Scan Upload (zip 전송)

    func uploadScanZip(folderURL: URL) async throws -> UploadResponse {
        let zipURL = folderURL.deletingLastPathComponent()
                              .appending(path: "\(folderURL.lastPathComponent).zip")
        try createZip(from: folderURL, to: zipURL)

        let boundary = UUID().uuidString
        var body = Data()
        let zipData = try Data(contentsOf: zipURL)

        body += "--\(boundary)\r\n".data(using: .utf8)!
        body += "Content-Disposition: form-data; name=\"scan_export\"; filename=\"\(zipURL.lastPathComponent)\"\r\n".data(using: .utf8)!
        body += "Content-Type: application/zip\r\n\r\n".data(using: .utf8)!
        body += zipData
        body += "\r\n--\(boundary)--\r\n".data(using: .utf8)!

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("❌ 서버 응답: \(String(data: data, encoding: .utf8) ?? "")")
            throw OptimizerError.serverError
        }
        return try JSONDecoder().decode(UploadResponse.self, from: data)
    }

    // MARK: - 배치 최적화 요청

    func requestOptimize(confirmCode: String) async throws -> [OptimizedObject] {
        let url = URL(string: "\(baseURL)/\(confirmCode)/optimize")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("❌ 최적화 응답: \(String(data: data, encoding: .utf8) ?? "")")
            throw OptimizerError.serverError
        }
        return try JSONDecoder().decode(OptimizeResponse.self, from: data).objects.compactMap { $0.toOptimizedObject() }
    }

    // MARK: - Zip 생성 (Store, no compression)

    private func createZip(from folderURL: URL, to zipURL: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw OptimizerError.invalidResponse
        }

        struct Entry { let name: Data; let data: Data; let crc: UInt32; let offset: UInt32 }
        var zipData = Data()
        var entries: [Entry] = []

        for case let fileURL as URL in enumerator {
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir { continue }
            let fileData = try Data(contentsOf: fileURL)
            let relative = String(fileURL.path.dropFirst(folderURL.path.count + 1))
            guard let nameData = relative.data(using: .utf8) else { continue }
            let crc = crc32Value(fileData)
            let offset = UInt32(zipData.count)

            zipData += sig(0x04034b50)
            zipData += u16(20); zipData += u16(0); zipData += u16(0)
            zipData += u16(0);  zipData += u16(0)
            zipData += u32(crc); zipData += u32(UInt32(fileData.count)); zipData += u32(UInt32(fileData.count))
            zipData += u16(UInt16(nameData.count)); zipData += u16(0)
            zipData += nameData; zipData += fileData

            entries.append(Entry(name: nameData, data: fileData, crc: crc, offset: offset))
        }

        let cdStart = UInt32(zipData.count)
        for e in entries {
            zipData += sig(0x02014b50)
            zipData += u16(20); zipData += u16(20); zipData += u16(0); zipData += u16(0)
            zipData += u16(0);  zipData += u16(0)
            zipData += u32(e.crc); zipData += u32(UInt32(e.data.count)); zipData += u32(UInt32(e.data.count))
            zipData += u16(UInt16(e.name.count)); zipData += u16(0); zipData += u16(0)
            zipData += u16(0); zipData += u16(0); zipData += u32(0); zipData += u32(e.offset)
            zipData += e.name
        }

        let cdSize = UInt32(zipData.count) - cdStart
        zipData += sig(0x06054b50)
        zipData += u16(0); zipData += u16(0)
        zipData += u16(UInt16(entries.count)); zipData += u16(UInt16(entries.count))
        zipData += u32(cdSize); zipData += u32(cdStart); zipData += u16(0)

        try zipData.write(to: zipURL)
    }

    private func crc32Value(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { ptr in
            UInt32(zlib.crc32(0, ptr.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)))
        }
    }

    private func sig(_ v: UInt32) -> Data { u32(v) }
    private func u16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private func u32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v>>8) & 0xFF), UInt8((v>>16) & 0xFF), UInt8(v>>24)]) }
}

// MARK: - Error

enum OptimizerError: LocalizedError {
    case serverError
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .serverError:     return "서버 오류가 발생했습니다"
        case .invalidResponse: return "응답 형식이 올바르지 않습니다"
        }
    }
}
