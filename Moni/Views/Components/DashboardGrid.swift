import AppKit
import SwiftUI

enum DashboardCardID: String, CaseIterable, Codable, Hashable, Identifiable {
    case host, cpu, memory, gpu, network, storage, processes, power, docker, aiUsage

    var id: String { rawValue }

    var limits: DashboardCardLimits {
        switch self {
        case .cpu, .memory, .network, .processes, .aiUsage:
            DashboardCardLimits(maxColumns: 2, maxRows: 2)
        case .host, .gpu, .storage, .power, .docker:
            DashboardCardLimits(maxColumns: 2, maxRows: 1)
        }
    }
}

struct DashboardCardSize: Codable, Equatable, Hashable {
    var columns: Int
    var rows: Int

    static let compact = DashboardCardSize(columns: 1, rows: 1)

    func clamped(to limits: DashboardCardLimits) -> DashboardCardSize {
        DashboardCardSize(
            columns: min(max(1, columns), limits.maxColumns),
            rows: min(max(1, rows), limits.maxRows)
        )
    }
}

struct DashboardCardLimits: Equatable {
    let maxColumns: Int
    let maxRows: Int
}

struct DashboardCardLayout: Codable {
    private var sizes: [String: DashboardCardSize] = [:]
    private var order: [String] = []

    private enum CodingKeys: String, CodingKey {
        case sizes, order
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sizes = try container.decodeIfPresent([String: DashboardCardSize].self, forKey: .sizes) ?? [:]
        order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
    }

    func size(for card: DashboardCardID) -> DashboardCardSize {
        (sizes[card.rawValue] ?? .compact).clamped(to: card.limits)
    }

    mutating func setSize(_ size: DashboardCardSize, for card: DashboardCardID) {
        sizes[card.rawValue] = size.clamped(to: card.limits)
    }

    func orderedCards(visible: Set<DashboardCardID>) -> [DashboardCardID] {
        normalizedOrder.filter { visible.contains($0) }
    }

    mutating func move(
        _ source: DashboardCardID,
        relativeTo target: DashboardCardID,
        placeAfter: Bool
    ) {
        guard source != target else { return }
        var cards = normalizedOrder
        cards.removeAll { $0 == source }
        guard let targetIndex = cards.firstIndex(of: target) else { return }
        cards.insert(source, at: targetIndex + (placeAfter ? 1 : 0))
        order = cards.map(\.rawValue)
    }

    static func decode(_ data: Data) -> DashboardCardLayout {
        guard !data.isEmpty, let layout = try? JSONDecoder().decode(Self.self, from: data) else {
            return DashboardCardLayout()
        }
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
}

nonisolated private struct DashboardCardSpanKey: LayoutValueKey {
    static let defaultValue = DashboardCardSpan(columns: 1, rows: 1)
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
        let height = result.rowCount > 0
            ? CGFloat(result.rowCount) * rowHeight + CGFloat(result.rowCount - 1) * spacing
            : 0
        return CGSize(width: width, height: height)
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
            let width = CGFloat(placement.size.columns) * columnWidth
                + CGFloat(placement.size.columns - 1) * spacing
            let height = CGFloat(placement.size.rows) * rowHeight
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
                    items.append(Placement(column: column, row: row, size: size))
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
    let card: DashboardCardID
    let size: DashboardCardSize
    let limits: DashboardCardLimits
    let onResize: (DashboardCardSize) -> Void
    let onMove: (DashboardCardID, DashboardCardID, Bool) -> Void
    @ViewBuilder let content: Content

    @State private var dragOrigin: DashboardCardSize?
    @State private var dragCellSize = CGSize.zero
    @State private var isRightHandleHovered = false
    @State private var isCornerHandleHovered = false
    @State private var isDropTargeted = false

    init(
        card: DashboardCardID,
        size: DashboardCardSize,
        limits: DashboardCardLimits,
        onResize: @escaping (DashboardCardSize) -> Void,
        onMove: @escaping (DashboardCardID, DashboardCardID, Bool) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.card = card
        self.size = size
        self.limits = limits
        self.onResize = onResize
        self.onMove = onMove
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if limits.maxColumns > 1 {
                    Capsule()
                        .fill(Color.secondary.opacity(isRightHandleHovered ? 0.72 : 0.24))
                        .frame(width: 3, height: 36)
                        .frame(width: 14)
                        .frame(maxHeight: .infinity, alignment: .trailing)
                        .contentShape(Rectangle())
                        .highPriorityGesture(resizeGesture(in: geometry.size, includesRows: false))
                        .onHover { isHovered in
                            isRightHandleHovered = isHovered
                            (isHovered ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                        }
                        .help("Drag to change card width")
                }

                if limits.maxRows > 1 {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                        .opacity(isCornerHandleHovered ? 1 : 0.62)
                        .padding(6)
                        .contentShape(Rectangle())
                        .highPriorityGesture(resizeGesture(in: geometry.size, includesRows: true))
                        .onHover { isHovered in
                            isCornerHandleHovered = isHovered
                            (isHovered ? NSCursor.crosshair : NSCursor.arrow).set()
                        }
                        .help("Drag to change card width and height")
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: isDropTargeted ? 2 : 0)
                    .padding(1)
                    .allowsHitTesting(false)
            }
            .scaleEffect(isDropTargeted ? 0.99 : 1)
            .moniAnimation(value: isDropTargeted)
            .draggable(card.rawValue)
            .dropDestination(for: String.self) { items, location in
                guard
                    let rawValue = items.first,
                    let source = DashboardCardID(rawValue: rawValue),
                    source != card
                else { return false }
                onMove(source, card, location.x >= geometry.size.width / 2)
                return true
            } isTargeted: { isTargeted in
                isDropTargeted = isTargeted
            }
            .onDisappear { NSCursor.arrow.set() }
        }
        .layoutValue(
            key: DashboardCardSpanKey.self,
            value: DashboardCardSpan(columns: size.columns, rows: size.rows)
        )
    }

    private func resizeGesture(in renderedSize: CGSize, includesRows: Bool) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let origin = dragOrigin ?? size
                let cellSize = dragOrigin == nil ? baseCellSize(in: renderedSize) : dragCellSize
                if dragOrigin == nil {
                    dragOrigin = origin
                    dragCellSize = cellSize
                }

                let columnDelta = Int((value.translation.width / max(1, cellSize.width)).rounded())
                let rowDelta = includesRows
                    ? Int((value.translation.height / max(1, cellSize.height)).rounded())
                    : 0
                let resized = DashboardCardSize(
                    columns: origin.columns + columnDelta,
                    rows: origin.rows + rowDelta
                ).clamped(to: limits)
                if resized != size {
                    onResize(resized)
                }
            }
            .onEnded { _ in
                dragOrigin = nil
                dragCellSize = .zero
            }
    }

    private func baseCellSize(in renderedSize: CGSize) -> CGSize {
        CGSize(
            width: (renderedSize.width - CGFloat(size.columns - 1) * 12) / CGFloat(size.columns),
            height: (renderedSize.height - CGFloat(size.rows - 1) * 12) / CGFloat(size.rows)
        )
    }
}
