import SwiftUI
import RoomPlan
import RealityKit

struct RoomResultView: View {
    let room: CapturedRoom
    @ObservedObject var vm: ScanViewModel

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
                    Text("스캔 결과를 저장하면 최적화 여부를 결정할 수 있어요")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)

                Button("저장하기") { vm.saveAndUpload(room: room) }
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
    }
}

/// Unsaved scans resolve the public catalog without creating a room or uploading data.
private struct ServerScanPreview: View {
    let room: CapturedRoom
    @State private var models: [UUID: URL]?
    @State private var failure: String?
    @State private var retry = 0

    private struct Catalog: Decodable {
        let items: [Item]
        struct Item: Decodable {
            let model_key: String
            let usdz_url: String?
        }
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
                ProgressView("서버 가구 모델을 준비하는 중…")
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
            let endpoint = URL(string: "\(APIConfig.baseURL)/rooms/catalog/models")!
            let (data, response) = try await URLSession.shared.data(from: endpoint)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let catalog = try JSONDecoder().decode(Catalog.self, from: data)
            let provider = try CapturedRoom.ModelProvider.load()
            var resolved: [UUID: URL] = [:]
            var downloaded: [String: URL] = [:]
            for object in room.objects {
                try Task.checkCancellation()
                guard let local = try provider.modelFileURL(for: object) else {
                    failure = "인식한 가구에 대응하는 서버 카탈로그 모델을 찾지 못했어요."
                    return
                }
                let path = local.path.lowercased()
                let exact = catalog.items.filter { path.hasSuffix("/" + $0.model_key.lowercased()) }
                let matches = exact.isEmpty ? catalog.items.filter {
                    ($0.model_key as NSString).lastPathComponent.lowercased() == local.lastPathComponent.lowercased()
                } : exact
                guard matches.count == 1, let item = matches.first,
                      let value = item.usdz_url, let url = URL(string: value) else {
                    failure = "이 가구의 서버 USDZ가 아직 준비되지 않았어요. 서버 카탈로그 업데이트가 필요합니다."
                    return
                }
                if let cached = downloaded[item.model_key] {
                    resolved[object.identifier] = cached
                    continue
                }
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (file, result) = try await URLSession.shared.download(for: request)
                guard let http = result as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".usdz")
                try FileManager.default.moveItem(at: file, to: dest)
                try validateModel(dest)
                downloaded[item.model_key] = dest
                resolved[object.identifier] = dest
            }
            try Task.checkCancellation()
            models = resolved
        } catch {
            guard !Task.isCancelled else { return }
            failure = "서버 가구 모델을 불러오지 못했어요. 연결을 확인하고 다시 시도해주세요."
        }
    }
}
