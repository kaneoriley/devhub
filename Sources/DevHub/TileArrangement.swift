import Foundation

/// Maximize a common screen area, rather than total area that can favour a few
/// oversized devices. Compare shape-sorted rows and columns, preserving every
/// screen's aspect ratio and returning frames in the original device order.
enum TileArrangement {
    static func frames(aspectRatios: [CGFloat], in size: CGSize, spacing: CGFloat = 16) -> [CGRect] {
        guard !aspectRatios.isEmpty else { return [] }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return Array(repeating: .zero, count: aspectRatios.count)
        }
        let ratios = aspectRatios.map { $0.isFinite && $0 > 0 ? $0 : 0.5 }
        let gap = min(max(0, spacing), min(size.width, size.height) / CGFloat(ratios.count * 2))
        let rows = shelves(ratios, in: size, gap: gap)
        let columns = shelves(ratios.map { 1 / $0 }, in: CGSize(width: size.height, height: size.width), gap: gap)
            .map { CGRect(x: $0.minY, y: $0.minX, width: $0.height, height: $0.width) }
        func area(_ frames: [CGRect]) -> CGFloat { frames.reduce(0) { $0 + $1.width * $1.height } }
        return area(columns) > area(rows) + 0.01 ? columns : rows
    }

    private static func shelves(_ ratios: [CGFloat], in size: CGSize, gap: CGFloat) -> [CGRect] {
        let order = ratios.indices.sorted { ratios[$0] == ratios[$1] ? $0 < $1 : ratios[$0] < ratios[$1] }
        // At unit area, width = sqrt(aspect ratio), height = 1 / width.
        // A single common scale keeps all displayed screen areas equal.
        let widths = ratios.map { sqrt($0) }
        let heights = widths.map { 1 / $0 }
        var sums: [CGFloat] = [0]
        for index in order { sums.append(sums.last! + widths[index]) }
        var best: [CGRect] = []
        var bestScale: CGFloat = 0

        func evaluate(_ ranges: [Range<Int>]) {
            // Shape sorting puts the tallest device first in each row.
            let rowHeights = ranges.map { heights[order[$0.lowerBound]] }
            var scale = (size.height - CGFloat(ranges.count - 1) * gap) / rowHeights.reduce(0, +)
            for range in ranges {
                let availableWidth = size.width - CGFloat(range.count - 1) * gap
                scale = min(scale, availableWidth / (sums[range.upperBound] - sums[range.lowerBound]))
            }
            guard scale > bestScale else { return }
            bestScale = scale
            var frames = Array(repeating: CGRect.zero, count: ratios.count)
            let height = rowHeights.reduce(0, +) * scale + CGFloat(ranges.count - 1) * gap
            var y = (size.height - height) / 2
            for (row, range) in ranges.enumerated() {
                let rowHeight = rowHeights[row] * scale
                let width = (sums[range.upperBound] - sums[range.lowerBound]) * scale + CGFloat(range.count - 1) * gap
                var x = (size.width - width) / 2
                for position in range {
                    let index = order[position]
                    let width = widths[index] * scale, height = heights[index] * scale
                    frames[index] = CGRect(x: x, y: y + (rowHeight - height) / 2, width: width, height: height)
                    x += width + gap
                }
                y += rowHeight + gap
            }
            best = frames
        }

        if ratios.count <= 12 {
            // At most 2^11 partitions per axis, regardless of the device list order.
            func visit(_ start: Int, _ ranges: [Range<Int>]) {
                if start == ratios.count { evaluate(ranges); return }
                for end in (start + 1)...ratios.count { visit(end, ranges + [start..<end]) }
            }
            visit(0, [])
        } else {
            // Bound work for unusually large fleets, while retaining equal areas.
            for rows in 1...ratios.count {
                evaluate((0..<rows).map { row in
                    (row * ratios.count / rows)..<((row + 1) * ratios.count / rows)
                })
            }
        }
        return best
    }
}
