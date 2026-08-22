import Foundation

/// GET /rooms/catalog/models 결과를 프로세스 생명주기 동안 1회만 조회해 캐싱.
/// 로컬 RoomPlanCatalog.bundle에 없는 model_key를 만났을 때의 서버 폴백용.
actor CatalogModelCache {
    static let shared = CatalogModelCache()

    private var models: [String: CatalogModel]?
    private let service = RoomOptimizerService()

    private init() {}

    private func loadIfNeeded() async -> [String: CatalogModel] {
        if let models { return models }
        let fetched = (try? await service.fetchCatalogModels()) ?? []
        let dict = Dictionary(uniqueKeysWithValues: fetched.map { ($0.modelKey, $0) })
        models = dict
        return dict
    }

    /// model_key로 서버 카탈로그의 usdc_url 조회 (로컬에 없을 때 폴백)
    func usdcURL(forModelKey key: String) async -> URL? {
        let dict = await loadIfNeeded()
        guard let url = dict[key]?.usdcUrl else { return nil }
        return URL(string: url)
    }
}
