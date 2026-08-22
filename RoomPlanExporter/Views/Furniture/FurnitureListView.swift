import SwiftUI
import RealityKit

struct FurnitureListView: View {
    @ObservedObject var vm: ScanViewModel

    @State private var selectedId: UUID? = nil
    @State private var editingId: UUID? = nil
    @State private var editName: String = ""
    @FocusState private var isEditFocused: Bool

    private var selectedItem: FurnitureItem? {
        let id = selectedId ?? vm.savedFurniture.first?.id
        return vm.savedFurniture.first { $0.id == id } ?? vm.savedFurniture.first
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .alert("서버 동기화 실패", isPresented: .constant(vm.furnitureSyncError != nil), actions: {
            Button("확인") { vm.furnitureSyncError = nil }
        }, message: {
            Text(vm.furnitureSyncError ?? "")
        })
    }

    // MARK: Content (가구 목록/빈 상태 + 우측 상단 플로팅 + 버튼)

    private var content: some View {
        Group {
            if vm.savedFurniture.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        selectedPreview
                            .padding(.top, 24)
                        Divider().padding(.horizontal, 24)
                        furnitureGrid
                            .padding(.bottom, 24)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { commitEdit() }
            }
        }
        .overlay(alignment: .topTrailing) {
            addButton
                .padding(.top, 16)
                .padding(.trailing, 24)
        }
    }

    private var addButton: some View {
        Button { vm.showFurnitureAddMethodPicker() } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.voBlue)
                .frame(width: 32, height: 32)
                .background(Circle().stroke(Color.voBlue, lineWidth: 1.5))
        }
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            Text("가구 목록")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            HStack {
                Button {
                    vm.phase = .main
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.semiBold20)
                        .foregroundStyle(.white)
                }
                Spacer()
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 24)
        .voGlassBanner()
    }

    // MARK: Selected preview

    @ViewBuilder
    private var selectedPreview: some View {
        if let item = selectedItem {
            VStack(spacing: 14) {
                Group {
                    if let modelURL = vm.modelURL(for: item) {
                        FurnitureModelPreviewCard(url: modelURL)
                            .id(modelURL)   // 선택 항목 바뀔 때마다 새로 로드
                    } else if let img = vm.thumbnailImage(for: item) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "cabinet.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.voBlue.opacity(0.4))
                            .padding(40)
                    }
                }
                .frame(height: 180)
                .frame(maxWidth: .infinity)

                // Name row
                if editingId == item.id {
                    HStack {
                        TextField("이름 입력", text: $editName)
                            .focused($isEditFocused)
                            .font(.title3.bold())
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.voBlue, lineWidth: 1.5)
                            )
                            .frame(maxWidth: 220)
                            .onSubmit { commitEdit() }
                        Button { commitEdit() } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Color.voBlue)
                        }
                    }
                } else {
                    Button {
                        editingId = item.id
                        editName = item.name
                        isEditFocused = true
                    } label: {
                        HStack(spacing: 8) {
                            Text(item.name)
                                .font(.title3.bold())
                                .foregroundStyle(.primary)
                            Image(systemName: "pencil")
                                .font(.subheadline)
                                .foregroundStyle(Color.voBlue)
                        }
                    }
                }

                if let dimensionText = item.dimensionText {
                    Text(dimensionText)
                        .font(.regular12)
                        .foregroundStyle(.secondary)
                }

                modelFileInfo(for: item)
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: 저장된 3D 모델 파일 정보 (포맷/크기 확인 + 공유)

    @ViewBuilder
    private func modelFileInfo(for item: FurnitureItem) -> some View {
        if let url = vm.modelURL(for: item) {
            let ext = url.pathExtension.uppercased()
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
            HStack(spacing: 6) {
                Text("\(ext)\(size.map { " · " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption2)
                        .foregroundStyle(Color.voBlue)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
        } else {
            Text("3D 모델 파일 없음")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Grid

    private var furnitureGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(vm.savedFurniture) { item in
                let isSelected = selectedItem?.id == item.id
                FurnitureCell(
                    item: item,
                    thumbnail: vm.thumbnailImage(for: item),
                    isSelected: isSelected,
                    onTap: {
                        commitEdit()
                        selectedId = item.id
                    },
                    onDelete: {
                        if selectedItem?.id == item.id {
                            // 다음 아이템 선택
                            let next = vm.savedFurniture.first { $0.id != item.id }
                            selectedId = next?.id
                        }
                        vm.deleteFurniture(item)
                    }
                )
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "cabinet.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.voBlue.opacity(0.35))
            VStack(spacing: 6) {
                Text("등록된 가구가 없어요")
                    .font(.headline)
                Text("우측 상단 + 버튼을 눌러 추가하세요")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: Helper

    private func commitEdit() {
        guard let id = editingId else { return }
        let trimmed = editName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { vm.updateFurnitureName(trimmed, id: id) }
        editingId = nil
        isEditFocused = false
    }
}

// MARK: - Grid Cell

private struct FurnitureCell: View {
    let item: FurnitureItem
    let thumbnail: UIImage?
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack(alignment: .center) {
                    cellBackground
                        .aspectRatio(1, contentMode: .fit)

                    if let img = thumbnail {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .aspectRatio(1, contentMode: .fit)
                            .opacity(isSelected ? 0.6 : 1)
                    } else {
                        Image(systemName: "cabinet.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }

                    if isSelected {
                        Image(systemName: "trash")
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(Color.black.opacity(0.45), in: Circle())
                            .onTapGesture(perform: onDelete)
                    }
                }

                Text(item.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cellBackground: some View {
        if #available(iOS 26.0, *) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.clear)
                .glassEffect(isSelected ? .regular.tint(Color(.systemGray)) : .regular,
                             in: RoundedRectangle(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color(.systemGray5) : Color(.secondarySystemBackground))
        }
    }
}

#Preview { FurnitureListView(vm: ScanViewModel()) }
