import SwiftUI
import RoomPlan
import RealityKit

struct RoomResultView: View {
    let room: CapturedRoom
    @ObservedObject var vm: ScanViewModel
    @State private var showNamePrompt = false
    @State private var roomName = ""

    private var trimmedRoomName: String {
        roomName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Banner
            ZStack {
                Text("내 방이 잘 스캔되었는지 확인해보세요")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                HStack {
                    Image("logo_white")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 42)
                    Spacer()
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 20)
            .voGlassBanner()

            // Wait for server catalog USDZs; do not flash locally tinted placeholders.
            ServerScanPreview(room: room)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom controls
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                    Text("저장한 뒤 내 방에서 최적화할 수 있어요")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)

                Button("저장하기") {
                    roomName = ""
                    showNamePrompt = true
                }
                .buttonStyle(VOFilledButtonStyle())

                Button("다시 찍기") { vm.retake() }
                    .buttonStyle(VOOutlineButtonStyle())
            }
            .padding(.horizontal, 50)
            .padding(.vertical, 20)
        }
        .alert("저장 실패", isPresented: .constant(vm.uploadError != nil), actions: {
            Button("확인") { vm.uploadError = nil }
        }, message: {
            Text(vm.uploadError ?? "")
        })
        .alert("방 이름을 정해주세요", isPresented: $showNamePrompt) {
            TextField("예: 나의 자취방", text: $roomName)
            Button("취소", role: .cancel) {}
            Button("저장") {
                vm.saveAndUpload(room: room, name: trimmedRoomName)
            }
            .disabled(trimmedRoomName.isEmpty)
        } message: {
            Text("내 공간 목록과 방 조회 화면에 이 이름으로 표시돼요.")
        }
    }
}

/// Unsaved scans resolve models via the same on-demand S3-existence check the server
/// already uses after save (POST /rooms/catalog/resolve), instead of the curated
/// /rooms/catalog/models list — which can lag behind what's actually in S3 (e.g. RoomPlan's
/// "Unidentified_*" shape variants). This keeps pre-save and post-save results consistent.
private struct ServerScanPreview: View {
    let room: CapturedRoom
    @State private var models: [UUID: URL]?
    @State private var failure: String?
    @State private var retry = 0

    private struct ResolveRequestItem: Encodable {
        let identifier: String
        let category: String
        let model_file_name: String
    }
    private struct ResolveRequest: Encodable {
        let objects: [ResolveRequestItem]
    }
    private struct ResolveResultItem: Decodable {
        let identifier: String
        let usdz_url: String?
    }
    private struct ResolveResponse: Decodable {
        let results: [ResolveResultItem]
    }

    var body: some View {
        Group {
            if let models {
                RoomViewerView(capturedRoom: room, serverModels: models,
                               isTransparent: true, colorCustomizable: true)
            } else if let failure {
                VStack(spacing: 16) {
                    Text(failure).multilineTextAlignment(.center)
                    Button("다시 불러오기") { retry += 1 }
                }.padding(24)
            } else {
                // 문구 없이 스피너만 — 로딩 중 임시 색상 모델을 먼저 보여주진 않되, 문구는 생략.
                ProgressView()
            }
        }
        .task(id: retry) { await load() }
    }

    @MainActor private func validateModel(_ url: URL) throws {
        _ = try ModelEntity.load(contentsOf: url)
    }

    @MainActor private func load() async {
        failure = nil
        do {
            if room.objects.isEmpty { models = [:]; return }
            let provider = try CapturedRoom.ModelProvider.load()

            // category + 로컬 파일명(실제 저장 업로드 때와 동일하게 lastPathComponent만)으로
            // "S3에 이 모델 실제로 있어?"를 서버에 한 번에 물어본다.
            var items: [ResolveRequestItem] = []
            var identifierByKey: [String: UUID] = [:]
            for object in room.objects {
                guard let local = try? provider.modelFileURL(for: object) else { continue }
                let key = object.identifier.uuidString
                identifierByKey[key] = object.identifier
                items.append(ResolveRequestItem(
                    identifier: key,
                    category: "\(object.category)",
                    model_file_name: local.lastPathComponent
                ))
            }

            var resolved: [UUID: URL] = [:]
            if !items.isEmpty {
                let endpoint = URL(string: "\(APIConfig.baseURL)/rooms/catalog/resolve")!
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(ResolveRequest(objects: items))

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                let decoded = try JSONDecoder().decode(ResolveResponse.self, from: data)

                var downloaded: [String: URL] = [:]
                for result in decoded.results {
                    try Task.checkCancellation()
                    // usdz_url이 없으면 "대응 모델 없음" — 실패 처리하지 않고 건너뛴다.
                    // resolved에 안 들어간 가구는 RoomViewerView가 카테고리 색상 OBB로 대체한다.
                    guard let identifier = identifierByKey[result.identifier],
                          let value = result.usdz_url, let url = URL(string: value) else { continue }
                    if let cached = downloaded[value] {
                        resolved[identifier] = cached
                        continue
                    }
                    var dlRequest = URLRequest(url: url)
                    dlRequest.cachePolicy = .reloadIgnoringLocalCacheData
                    let (file, dlResponse) = try await URLSession.shared.download(for: dlRequest)
                    guard let dlHttp = dlResponse as? HTTPURLResponse, (200..<300).contains(dlHttp.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".usdz")
                    try FileManager.default.moveItem(at: file, to: dest)
                    try validateModel(dest)
                    downloaded[value] = dest
                    resolved[identifier] = dest
                }
            }
            try Task.checkCancellation()
            models = resolved
        } catch {
            // 네트워크/서버 오류(카탈로그 조회 실패, 다운로드 실패 등)만 여기로 전파되어
            // "연결을 확인하고 다시 시도해주세요" 오류로 구분된다 — 개별 가구의 "대응 모델
            // 없음"은 위에서 이미 건너뛰고 OBB로 대체되므로 여기까지 오지 않는다.
            guard !Task.isCancelled else { return }
            failure = "서버 가구 모델을 불러오지 못했어요. 연결을 확인하고 다시 시도해주세요."
        }
    }
}
