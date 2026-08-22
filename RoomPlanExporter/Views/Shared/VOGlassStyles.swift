import SwiftUI

// MARK: - 글라스 배너/카드 공용 헬퍼
// iOS 26+: 네이티브 Liquid Glass(.glassEffect). 그 이전 버전: Material 블러로 유사하게 폴백.

extension View {
    /// 화면 상단 배너 (제목 + 로고/뒤로가기 등). voBlue 톤이 유리질로 비치게.
    @ViewBuilder
    func voGlassBanner() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(Color.voBlue), in: Rectangle())
        } else {
            self.background(Color.voBlue)
        }
    }

    /// 카드형 배경 (목록 셀, 안내 카드, 팝업 등).
    @ViewBuilder
    func voGlassCard(cornerRadius: CGFloat = 16) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// voGlassCard처럼 카드 배경을 넣되, glassEffect가 콘텐츠 고유 크기로 되돌리는 것을 막고
    /// 부모가 제안한 크기(예: maxWidth/maxHeight .infinity)를 그대로 유지해야 하는 곳에서 사용.
    /// (예: 같은 줄에서 옆 카드와 높이를 맞춰야 하는 그리드/컬럼 레이아웃)
    @ViewBuilder
    func voGlassCardFillingParent(cornerRadius: CGFloat = 16) -> some View {
        voGlassCard(cornerRadius: cornerRadius)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
