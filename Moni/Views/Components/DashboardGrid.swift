import SwiftUI

enum DashboardCardID: String, CaseIterable, Codable, Hashable, Identifiable {
    case host, cpu, memory, gpu, network, storage, processes, docker, power, aiUsage

    var id: String { rawValue }

    var defaultSize: DashboardCardSize {
        self == .aiUsage ? DashboardCardSize(columns: 3, rows: 1) : .compact
    }

    var limits: DashboardCardLimits {
        DashboardCardLimits(maxColumns: 3)
    }
}

struct DashboardCardSize: Codable, Equatable, Hashable {
    var columns: Int
    var rows: Int

    static let compact = DashboardCardSize(columns: 1, rows: 1)

    func clamped(to limits: DashboardCardLimits) -> DashboardCardSize {
        DashboardCardSize(
            columns: min(max(1, columns), limits.maxColumns),
            rows: max(1, rows)
        )
    }
}

struct DashboardCardLimits: Equatable {
    let maxColumns: Int
}

struct DashboardCardLayout: Codable {
    private static let currentVersion = 1

    private var version = currentVersion
    private var sizes: [String: DashboardCardSize] = [:]
    private var order: [String] = []

    private enum CodingKeys: String, CodingKey {
        case version, sizes, order
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        sizes = try container.decodeIfPresent([String: DashboardCardSize].self, forKey: .sizes) ?? [:]
        order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
        if storedVersion < Self.currentVersion {
            sizes.removeValue(forKey: DashboardCardID.aiUsage.rawValue)
        }
        version = Self.currentVersion
    }

    func size(for card: DashboardCardID) -> DashboardCardSize {
        (sizes[card.rawValue] ?? card.defaultSize).clamped(to: card.limits)
    }

    mutating func setSize(_ size: DashboardCardSize, for card: DashboardCardID) {
        sizes[card.rawValue] = size.clamped(to: card.limits)
    }

    func orderedCards(visible: Set<DashboardCardID>) -> [DashboardCardID] {
        normalizedOrder.filter { visible.contains($0) }
    }

    @discardableResult
    mutating func move(
        _ source: DashboardCardID,
        relativeTo target: DashboardCardID,
        placeAfter: Bool
    ) -> Bool {
        guard source != target else { return false }
        var cards = normalizedOrder
        let original = cards
        cards.removeAll { $0 == source }
        guard let targetIndex = cards.firstIndex(of: target) else { return false }
        cards.insert(source, at: targetIndex + (placeAfter ? 1 : 0))
        guard cards != original else { return false }
        order = cards.map(\.rawValue)
        return true
    }

    /// `orderedCards` and `cardSize` are read once per card per body pass, and the
    /// dashboard re-renders on every sample, so decoding each time was pure waste.
    private static var decoded: (data: Data, layout: DashboardCardLayout)?

    static func decode(_ data: Data) -> DashboardCardLayout {
        if let decoded, decoded.data == data { return decoded.layout }
        let layout = data.isEmpty
            ? DashboardCardLayout()
            : (try? JSONDecoder().decode(Self.self, from: data)) ?? DashboardCardLayout()
        decoded = (data, layout)
        return layout
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    private var normalizedOrder: [DashboardCardID] {
        var seen: Set<DashboardCardID> = []
        let stored = order.compactMap(DashboardCardID.init(rawValue:)).filter { seen.insert($0).inserted }
        return stored + DashboardCardID.allCases.filter { !seen.contains($0) }
    }
}

nonisolated private struct DashboardCardSpan: Equatable {
    let columns: Int
    let rows: Int
    let renderedSize: CGSize?
}

nonisolated private struct DashboardCardSpanKey: LayoutValueKey {
    static let defaultValue = DashboardCardSpan(columns: 1, rows: 1, renderedSize: nil)
}

nonisolated enum DashboardGridCoordinateSpace {
    static let name = "dashboard-grid"
}

nonisolated struct DashboardCardFrameKey: SwiftUI.PreferenceKey {
    static let defaultValue: [DashboardCardID: CGRect] = [:]

    static func reduce(
        value: inout [DashboardCardID: CGRect],
        nextValue: () -> [DashboardCardID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

@MainActor
final class DashboardCardDragContext {
    var frames: [DashboardCardID: CGRect] = [:]
}

nonisolated struct DashboardCardDragPreview: Equatable {
    let card: DashboardCardID
    let size: CGSize
    let pointerOffset: CGSize
    var location: CGPoint
}

struct DashboardGridLayout: Layout {
    private struct Cell: Hashable {
        let column: Int
        let row: Int
    }

    private struct Placement {
        let column: Int
        let row: Int
        let size: DashboardCardSize
        let renderedSize: CGSize?
    }

    let columns: Int
    let rowHeight: CGFloat
    let spacing: CGFloat

    init(columns: Int = 3, rowHeight: CGFloat = 205, spacing: CGFloat = 12) {
        self.columns = columns
        self.rowHeight = rowHeight
        self.spacing = spacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 0
        let result = placements(for: subviews)
        let gridHeight = result.rowCount > 0
            ? CGFloat(result.rowCount) * rowHeight + CGFloat(result.rowCount - 1) * spacing
            : 0
        let renderedHeight = result.items.map { placement in
            let itemHeight = placement.renderedSize?.height
                ?? CGFloat(placement.size.rows) * rowHeight
                    + CGFloat(placement.size.rows - 1) * spacing
            return CGFloat(placement.row) * (rowHeight + spacing) + itemHeight
        }.max() ?? 0
        return CGSize(width: width, height: max(gridHeight, renderedHeight))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = placements(for: subviews)
        let columnWidth = max(0, (bounds.width - CGFloat(columns - 1) * spacing) / CGFloat(columns))

        for (index, placement) in result.items.enumerated() {
            let width = placement.renderedSize?.width
                ?? CGFloat(placement.size.columns) * columnWidth
                    + CGFloat(placement.size.columns - 1) * spacing
            let height = placement.renderedSize?.height
                ?? CGFloat(placement.size.rows) * rowHeight
                    + CGFloat(placement.size.rows - 1) * spacing
            let point = CGPoint(
                x: bounds.minX + CGFloat(placement.column) * (columnWidth + spacing),
                y: bounds.minY + CGFloat(placement.row) * (rowHeight + spacing)
            )
            subviews[index].place(
                at: point,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: height)
            )
        }
    }

    private func placements(for subviews: Subviews) -> (items: [Placement], rowCount: Int) {
        var occupied: Set<Cell> = []
        var items: [Placement] = []
        var rowCount = 0

        for subview in subviews {
            let requested = subview[DashboardCardSpanKey.self]
            let size = DashboardCardSize(
                columns: min(max(1, requested.columns), columns),
                rows: max(1, requested.rows)
            )
            var row = 0

            while true {
                var didPlace = false
                for column in 0...(columns - size.columns) {
                    let cells = (row..<(row + size.rows)).flatMap { candidateRow in
                        (column..<(column + size.columns)).map { candidateColumn in
                            Cell(column: candidateColumn, row: candidateRow)
                        }
                    }
                    guard cells.allSatisfy({ !occupied.contains($0) }) else { continue }

                    occupied.formUnion(cells)
                    items.append(
                        Placement(
                            column: column,
                            row: row,
                            size: size,
                            renderedSize: requested.renderedSize
                        )
                    )
                    rowCount = max(rowCount, row + size.rows)
                    didPlace = true
                    break
                }
                if didPlace { break }
                row += 1
            }
        }

        return (items, rowCount)
    }
}

struct ResizableDashboardCard<Content: View>: View {
    private enum ResizeAxis {
        case width
        case height
    }

    let card: DashboardCardID
    let size: DashboardCardSize
    let limits: DashboardCardLimits
    let onResizeChanged: (DashboardCardSize) -> Void
    let onResizeEnded: (DashboardCardSize) -> Void
    let onMoveStarted: (DashboardCardID, CGRect, CGPoint) -> Void
    let onMoveChanged: (DashboardCardID, CGPoint) -> Void
    let onMoveEnded: (DashboardCardID) -> Void
    @Binding var draggingCard: DashboardCardID?
    @ViewBuilder let content: Content

    @State private var dragOrigin: DashboardCardSize?
    @State private var dragCellSize = CGSize.zero
    @State private var dragRenderedSize = CGSize.zero
    @State private var liveRenderedSize: CGSize?
    @State private var pendingSize: DashboardCardSize?
    @State private var pendingSnappedSize: DashboardCardSize?
    @State private var isRightHandleHovered = false
    @State private var isBottomHandleHovered = false
    @State private var isResizingRows = false
    @State private var isReordering = false

    init(
        card: DashboardCardID,
        size: DashboardCardSize,
        limits: DashboardCardLimits,
        onResizeChanged: @escaping (DashboardCardSize) -> Void,
        onResizeEnded: @escaping (DashboardCardSize) -> Void,
        onMoveStarted: @escaping (DashboardCardID, CGRect, CGPoint) -> Void,
        onMoveChanged: @escaping (DashboardCardID, CGPoint) -> Void,
        onMoveEnded: @escaping (DashboardCardID) -> Void,
        draggingCard: Binding<DashboardCardID?>,
        @ViewBuilder content: () -> Content
    ) {
        self.card = card
        self.size = size
        self.limits = limits
        self.onResizeChanged = onResizeChanged
        self.onResizeEnded = onResizeEnded
        self.onMoveStarted = onMoveStarted
        self.onMoveChanged = onMoveChanged
        self.onMoveEnded = onMoveEnded
        self._draggingCard = draggingCard
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if limits.maxColumns > 1 {
                    Capsule()
                        .fill(isRightHandleHovered ? MoniPalette.foregroundSecondary : MoniPalette.foregroundQuaternary)
                        .frame(width: 3, height: 36)
                        .opacity(isRightHandleHovered || (dragOrigin != nil && !isResizingRows) ? 1 : 0)
                        .frame(width: 14)
                        .frame(maxHeight: .infinity, alignment: .trailing)
                        .contentShape(Rectangle())
                        .highPriorityGesture(resizeGesture(in: geometry.size, axis: .width))
                        .pointerStyle(.columnResize)
                        .onHover { isRightHandleHovered = $0 }
                        .help("Drag to change card width")
                        .moniAnimation(MoniMotion.press, value: isRightHandleHovered)
                }

                Capsule()
                    .fill(isBottomHandleHovered ? MoniPalette.foregroundSecondary : MoniPalette.foregroundQuaternary)
                    .frame(width: 36, height: 3)
                    .opacity(isBottomHandleHovered || isResizingRows ? 1 : 0)
                    .frame(height: 14)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .highPriorityGesture(resizeGesture(in: geometry.size, axis: .height))
                    .pointerStyle(.rowResize)
                    .onHover { isBottomHandleHovered = $0 }
                    .help("Drag to change card height")
                    .moniAnimation(MoniMotion.press, value: isBottomHandleHovered)
            }
            .preference(
                key: DashboardCardFrameKey.self,
                value: [
                    card: geometry.frame(
                        in: .named(DashboardGridCoordinateSpace.name)
                    )
                ]
            )
            .opacity(draggingCard == card ? 0 : 1)
            .highPriorityGesture(reorderGesture(in: geometry))
        }
        .layoutValue(
            key: DashboardCardSpanKey.self,
            value: DashboardCardSpan(
                columns: size.columns,
                rows: size.rows,
                renderedSize: liveRenderedSize
            )
        )
        .zIndex(dragOrigin == nil ? 0 : 1)
    }

    private func reorderGesture(in geometry: GeometryProxy) -> some Gesture {
        DragGesture(
            minimumDistance: 8,
            coordinateSpace: .named(DashboardGridCoordinateSpace.name)
        )
        .onChanged { value in
            guard !isRightHandleHovered, !isBottomHandleHovered else { return }
            let frame = geometry.frame(in: .named(DashboardGridCoordinateSpace.name))
            if !isReordering {
                isReordering = true
                draggingCard = card
                onMoveStarted(card, frame, value.startLocation)
            }
            guard draggingCard == card else { return }
            onMoveChanged(card, value.location)
        }
        .onEnded { _ in
            guard isReordering else { return }
            isReordering = false
            onMoveEnded(card)
        }
    }

    private func resizeGesture(in renderedSize: CGSize, axis: ResizeAxis) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let origin = dragOrigin ?? size
                let cellSize = dragOrigin == nil ? baseCellSize(in: renderedSize) : dragCellSize
                if dragOrigin == nil {
                    dragOrigin = origin
                    dragCellSize = cellSize
                    dragRenderedSize = renderedSize
                    isResizingRows = axis == .height
                }

                let width = axis == .width
                    ? min(
                        max(cellSize.width, dragRenderedSize.width + value.translation.width),
                        CGFloat(limits.maxColumns) * cellSize.width
                            + CGFloat(limits.maxColumns - 1) * 12
                    )
                    : dragRenderedSize.width
                let height = axis == .height
                    ? max(cellSize.height, dragRenderedSize.height + value.translation.height)
                    : dragRenderedSize.height
                liveRenderedSize = CGSize(width: width, height: height)

                let columnProgress = (width + 12) / max(1, cellSize.width + 12)
                let rowProgress = (height + 12) / max(1, cellSize.height + 12)
                let occupiedColumns = axis == .width
                    ? Int(ceil(columnProgress - 0.0001))
                    : origin.columns
                let occupiedRows = axis == .height
                    ? Int(ceil(rowProgress - 0.0001))
                    : origin.rows
                let occupiedSize = DashboardCardSize(
                    columns: occupiedColumns,
                    rows: occupiedRows
                ).clamped(to: limits)
                pendingSnappedSize = DashboardCardSize(
                    columns: axis == .width ? Int(columnProgress.rounded()) : origin.columns,
                    rows: axis == .height ? Int(rowProgress.rounded()) : origin.rows
                ).clamped(to: limits)
                if pendingSize != occupiedSize {
                    pendingSize = occupiedSize
                    onResizeChanged(occupiedSize)
                }
            }
            .onEnded { _ in
                let finalSize = pendingSnappedSize ?? size
                dragOrigin = nil
                dragCellSize = .zero
                dragRenderedSize = .zero
                pendingSize = nil
                pendingSnappedSize = nil
                isResizingRows = false
                onResizeEnded(finalSize)
                withAnimation(MoniMotion.dashboardSnap) {
                    liveRenderedSize = nil
                }
            }
    }

    private func baseCellSize(in renderedSize: CGSize) -> CGSize {
        CGSize(
            width: (renderedSize.width - CGFloat(size.columns - 1) * 12) / CGFloat(size.columns),
            height: (renderedSize.height - CGFloat(size.rows - 1) * 12) / CGFloat(size.rows)
        )
    }
}
