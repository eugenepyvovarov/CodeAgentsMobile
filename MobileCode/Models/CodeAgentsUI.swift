//
//  CodeAgentsUI.swift
//  CodeAgentsMobile
//
//  Purpose: Models + validation for codeagents_ui render-only widgets.
//

import Foundation

struct CodeAgentsUICaps {
    let maxBlocksPerMessage: Int
    let maxElementsPerBlock: Int
    let maxGalleryImages: Int
    let maxTableCells: Int
    let maxChartPoints: Int
    let maxChartSeries: Int
    let maxHeatmapDays: Int

    static let `default` = CodeAgentsUICaps(
        maxBlocksPerMessage: 3,
        maxElementsPerBlock: 40,
        maxGalleryImages: 12,
        maxTableCells: 400,
        maxChartPoints: 200,
        maxChartSeries: 6,
        maxHeatmapDays: 400
    )
}

struct CodeAgentsUIBlock: Identifiable {
    let id = UUID()
    let title: String?
    let elements: [CodeAgentsUIElement]
}

enum CodeAgentsUIElement: Identifiable {
    case card(CodeAgentsUICard)
    case markdown(CodeAgentsUIMarkdown)
    case image(CodeAgentsUIImage)
    case gallery(CodeAgentsUIGallery)
    case video(CodeAgentsUIVideo)
    case table(CodeAgentsUITable)
    case chart(CodeAgentsUIChart)

    var id: String {
        switch self {
        case .card(let value):
            return value.id
        case .markdown(let value):
            return value.id
        case .image(let value):
            return value.id
        case .gallery(let value):
            return value.id
        case .video(let value):
            return value.id
        case .table(let value):
            return value.id
        case .chart(let value):
            return value.id
        }
    }
}

struct CodeAgentsUICard {
    let id: String
    let title: String?
    let subtitle: String?
    let content: [CodeAgentsUIElement]
}

struct CodeAgentsUIMarkdown {
    let id: String
    let text: String
}

struct CodeAgentsUIImage {
    let id: String
    let source: CodeAgentsUIMediaSource
    let alt: String?
    let caption: String?
    let aspectRatio: Double?
}

struct CodeAgentsUIGallery {
    let id: String
    let images: [CodeAgentsUIImage]
    let caption: String?
}

struct CodeAgentsUIVideo {
    let id: String
    let source: CodeAgentsUIMediaSource
    let poster: CodeAgentsUIMediaSource?
    let caption: String?
}

struct CodeAgentsUITable {
    let id: String
    let columns: [String]
    let rows: [[String]]
    let caption: String?
}

struct CodeAgentsUIChart {
    let id: String
    let title: String?
    let subtitle: String?
    let kind: CodeAgentsUIChartKind
}

enum CodeAgentsUIChartKind {
    case barLine(CodeAgentsUIBarLineChart)
    case pie(CodeAgentsUIPieChart)
    case heatmap(CodeAgentsUIHeatmapChart)
}

enum CodeAgentsUIChartType: String {
    case bar
    case line
}

struct CodeAgentsUIBarLineChart {
    let chartType: CodeAgentsUIChartType
    let x: [String]
    let series: [CodeAgentsUIChartSeries]
}

struct CodeAgentsUIChartSeries {
    let name: String?
    let values: [Double?]
    let color: String?
}

struct CodeAgentsUIPieChart {
    let slices: [CodeAgentsUIPieSlice]
    let valueDisplay: CodeAgentsUIPieValueDisplay
}

struct CodeAgentsUIPieSlice {
    let label: String
    let value: Double
    let color: String?
}

enum CodeAgentsUIPieValueDisplay: String {
    case none
    case value
    case percent
    case both
}

struct CodeAgentsUIHeatmapChart {
    let days: [CodeAgentsUIHeatmapDay]
    let maxValue: Double?
    let levels: Int
    let palette: [String]
    let weekStart: CodeAgentsUIHeatmapWeekStart
}

struct CodeAgentsUIHeatmapDay {
    let date: Date
    let value: Double?
    let level: Int?
}

enum CodeAgentsUIHeatmapWeekStart: String {
    case sun
    case mon
}

enum CodeAgentsUIMediaSource {
    case url(URL)
    case projectFile(path: String)
    case base64(mediaType: String, data: Data)
}

enum CodeAgentsUIParser {
    static func parseBlock(
        from json: String,
        caps: CodeAgentsUICaps = .default,
        pathSanitizer: (String) -> String? = ProjectRelativePathSanitizer.sanitize
    ) -> CodeAgentsUIBlock? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any] else {
            return nil
        }

        guard let type = dict["type"] as? String, type == "codeagents_ui" else {
            return nil
        }
        guard let version = dict["version"] as? Int, version == 1 else {
            return nil
        }

        let title = dict["title"] as? String
        guard let elementValues = dict["elements"] as? [Any] else {
            return nil
        }

        let elements = parseElements(
            elementValues,
            caps: caps,
            pathSanitizer: pathSanitizer,
            limit: caps.maxElementsPerBlock
        )
        guard !elements.isEmpty else {
            return nil
        }

        return CodeAgentsUIBlock(title: title, elements: elements)
    }

    // MARK: - Private

    private static func parseElements(
        _ values: [Any],
        caps: CodeAgentsUICaps,
        pathSanitizer: (String) -> String?,
        limit: Int
    ) -> [CodeAgentsUIElement] {
        var elements: [CodeAgentsUIElement] = []
        elements.reserveCapacity(min(values.count, limit))

        var seenIds = Set<String>()

        for value in values {
            guard elements.count < limit,
                  let dict = value as? [String: Any],
                  let elementType = dict["type"] as? String,
                  let elementId = dict["id"] as? String,
                  !elementId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            guard seenIds.insert(elementId).inserted else { continue }

            switch elementType {
            case "card":
                if let card = parseCard(dict, caps: caps, pathSanitizer: pathSanitizer) {
                    elements.append(.card(card))
                }
            case "markdown":
                if let markdown = parseMarkdown(dict) {
                    elements.append(.markdown(markdown))
                }
            case "image":
                if let image = parseImage(dict, pathSanitizer: pathSanitizer) {
                    elements.append(.image(image))
                }
            case "gallery":
                if let gallery = parseGallery(dict, caps: caps, pathSanitizer: pathSanitizer) {
                    elements.append(.gallery(gallery))
                }
            case "video":
                if let video = parseVideo(dict, pathSanitizer: pathSanitizer) {
                    elements.append(.video(video))
                }
            case "table":
                if let table = parseTable(dict, caps: caps) {
                    elements.append(.table(table))
                }
            case "chart":
                if let chart = parseChart(dict, caps: caps) {
                    elements.append(.chart(chart))
                }
            default:
                continue
            }
        }

        return elements
    }

    private static func parseCard(
        _ dict: [String: Any],
        caps: CodeAgentsUICaps,
        pathSanitizer: (String) -> String?
    ) -> CodeAgentsUICard? {
        guard let id = dict["id"] as? String else { return nil }
        let title = dict["title"] as? String
        let subtitle = dict["subtitle"] as? String
        let contentValues = dict["content"] as? [Any] ?? []
        let content = parseElements(contentValues, caps: caps, pathSanitizer: pathSanitizer, limit: caps.maxElementsPerBlock)
        return CodeAgentsUICard(id: id, title: title, subtitle: subtitle, content: content)
    }

    private static func parseMarkdown(_ dict: [String: Any]) -> CodeAgentsUIMarkdown? {
        guard let id = dict["id"] as? String,
              let text = dict["text"] as? String else { return nil }
        return CodeAgentsUIMarkdown(id: id, text: text)
    }

    private static func parseImage(
        _ dict: [String: Any],
        pathSanitizer: (String) -> String?
    ) -> CodeAgentsUIImage? {
        guard let id = dict["id"] as? String,
              let source = parseImageSource(dict, pathSanitizer: pathSanitizer) else {
            return nil
        }
        let alt = dict["alt"] as? String
        let caption = dict["caption"] as? String
        let aspectRatio = dict["aspectRatio"] as? Double
        return CodeAgentsUIImage(id: id, source: source, alt: alt, caption: caption, aspectRatio: aspectRatio)
    }

    private static func parseGallery(
        _ dict: [String: Any],
        caps: CodeAgentsUICaps,
        pathSanitizer: (String) -> String?
    ) -> CodeAgentsUIGallery? {
        guard let id = dict["id"] as? String else { return nil }
        let caption = dict["caption"] as? String
        let captions = dict["captions"] as? [String]
        let imageValues = dict["images"] as? [Any] ?? []

        var images: [CodeAgentsUIImage] = []
        images.reserveCapacity(min(imageValues.count, caps.maxGalleryImages))

        for value in imageValues {
            guard images.count < caps.maxGalleryImages,
                  let image = parseGalleryImage(
                    value,
                    fallbackIdPrefix: id,
                    index: images.count,
                    pathSanitizer: pathSanitizer
                  ) else { continue }
            if let captions, images.count < captions.count {
                let captionValue = captions[images.count]
                if !captionValue.isEmpty, image.caption == nil {
                    images.append(
                        CodeAgentsUIImage(
                            id: image.id,
                            source: image.source,
                            alt: image.alt,
                            caption: captionValue,
                            aspectRatio: image.aspectRatio
                        )
                    )
                    continue
                }
            }
            images.append(image)
        }

        guard !images.isEmpty else { return nil }
        return CodeAgentsUIGallery(id: id, images: images, caption: caption)
    }

    private static func parseImageSource(
        _ dict: [String: Any],
        pathSanitizer: (String) -> String?
    ) -> CodeAgentsUIMediaSource? {
        if let sourceDict = dict["source"] as? [String: Any],
           let source = parseMediaSource(sourceDict, allowBase64: true, pathSanitizer: pathSanitizer) {
            return source
        }

        if let images = dict["images"] as? [Any],
           let first = images.first as? [String: Any] {
            if let sourceDict = first["source"] as? [String: Any],
               let source = parseMediaSource(sourceDict, allowBase64: true, pathSanitizer: pathSanitizer) {
                return source
            }
            if first["kind"] is String,
               let source = parseMediaSource(first, allowBase64: true, pathSanitizer: pathSanitizer) {
                return source
            }
        }

        if let urlString = dict["url"] as? String {
            if let source = parseMediaSource(["kind": "url", "url": urlString], allowBase64: true, pathSanitizer: pathSanitizer) {
                return source
            }
        }

        if let path = dict["path"] as? String {
            if let source = parseMediaSource(["kind": "project_file", "path": path], allowBase64: true, pathSanitizer: pathSanitizer) {
                return source
            }
        }

        if let mediaType = dict["mediaType"] as? String,
           let data = dict["data"] as? String {
            if let source = parseMediaSource(["kind": "base64", "mediaType": mediaType, "data": data], allowBase64: true, pathSanitizer: pathSanitizer) {
                return source
            }
        }

        return nil
    }

    private static func parseGalleryImage(
        _ value: Any,
        fallbackIdPrefix: String,
        index: Int,
        pathSanitizer: (String) -> String?
    ) -> CodeAgentsUIImage? {
        guard let dict = value as? [String: Any] else { return nil }

        if let imageType = dict["type"] as? String, imageType == "image" {
            if let image = parseImage(dict, pathSanitizer: pathSanitizer) {
                return image
            }

            if let sourceDict = dict["source"] as? [String: Any],
               let source = parseMediaSource(sourceDict, allowBase64: true, pathSanitizer: pathSanitizer) {
                let id = (dict["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalId = (id?.isEmpty == false) ? id! : "\(fallbackIdPrefix)-image-\(index)"
                let alt = dict["alt"] as? String
                let caption = dict["caption"] as? String
                let aspectRatio = dict["aspectRatio"] as? Double
                return CodeAgentsUIImage(id: finalId, source: source, alt: alt, caption: caption, aspectRatio: aspectRatio)
            }
        }

        if let sourceDict = dict["source"] as? [String: Any],
           let source = parseMediaSource(sourceDict, allowBase64: true, pathSanitizer: pathSanitizer) {
            let id = (dict["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalId = (id?.isEmpty == false) ? id! : "\(fallbackIdPrefix)-image-\(index)"
            let alt = dict["alt"] as? String
            let caption = dict["caption"] as? String
            let aspectRatio = dict["aspectRatio"] as? Double
            return CodeAgentsUIImage(id: finalId, source: source, alt: alt, caption: caption, aspectRatio: aspectRatio)
        }

        if dict["kind"] is String,
           let source = parseMediaSource(dict, allowBase64: true, pathSanitizer: pathSanitizer) {
            let finalId = "\(fallbackIdPrefix)-image-\(index)"
            return CodeAgentsUIImage(id: finalId, source: source, alt: nil, caption: nil, aspectRatio: nil)
        }

        return nil
    }

    private static func parseVideo(
        _ dict: [String: Any],
        pathSanitizer: (String) -> String?
    ) -> CodeAgentsUIVideo? {
        guard let id = dict["id"] as? String,
              let sourceDict = dict["source"] as? [String: Any],
              let source = parseMediaSource(sourceDict, allowBase64: false, pathSanitizer: pathSanitizer) else {
            return nil
        }
        let posterSource: CodeAgentsUIMediaSource?
        if let posterDict = dict["poster"] as? [String: Any] {
            posterSource = parseMediaSource(posterDict, allowBase64: true, pathSanitizer: pathSanitizer)
        } else {
            posterSource = nil
        }
        let caption = dict["caption"] as? String
        return CodeAgentsUIVideo(id: id, source: source, poster: posterSource, caption: caption)
    }

    private static func parseTable(
        _ dict: [String: Any],
        caps: CodeAgentsUICaps
    ) -> CodeAgentsUITable? {
        guard let id = dict["id"] as? String,
              let columns = dict["columns"] as? [String],
              !columns.isEmpty else { return nil }
        let caption = dict["caption"] as? String
        let rawRows = dict["rows"] as? [Any] ?? []
        let maxRows = max(0, caps.maxTableCells / max(1, columns.count))
        var rows: [[String]] = []
        rows.reserveCapacity(min(rawRows.count, maxRows))

        for value in rawRows {
            guard rows.count < maxRows,
                  let rowArray = value as? [Any] else { continue }
            var row: [String] = []
            row.reserveCapacity(columns.count)
            for cellIndex in 0..<columns.count {
                if cellIndex < rowArray.count, let cell = rowArray[cellIndex] as? String {
                    row.append(cell)
                } else {
                    row.append("")
                }
            }
            rows.append(row)
        }

        guard !rows.isEmpty else { return nil }
        return CodeAgentsUITable(id: id, columns: columns, rows: rows, caption: caption)
    }

    private static func parseChart(
        _ dict: [String: Any],
        caps: CodeAgentsUICaps
    ) -> CodeAgentsUIChart? {
        guard let id = dict["id"] as? String,
              let chartTypeRaw = dict["chartType"] as? String else { return nil }
        let title = dict["title"] as? String
        let subtitle = dict["subtitle"] as? String

        if chartTypeRaw == "pie" {
            guard let slicesValue = dict["slices"] as? [Any] else { return nil }
            let slices = parsePieSlices(slicesValue, caps: caps)
            guard !slices.isEmpty else { return nil }
            let valueDisplayRaw = dict["valueDisplay"] as? String ?? CodeAgentsUIPieValueDisplay.percent.rawValue
            let valueDisplay = CodeAgentsUIPieValueDisplay(rawValue: valueDisplayRaw) ?? .percent
            return CodeAgentsUIChart(
                id: id,
                title: title,
                subtitle: subtitle,
                kind: .pie(CodeAgentsUIPieChart(slices: slices, valueDisplay: valueDisplay))
            )
        }

        if chartTypeRaw == "heatmap" {
            guard let daysValue = dict["days"] as? [Any] else { return nil }
            let days = parseHeatmapDays(daysValue, maxCount: caps.maxHeatmapDays)
            guard !days.isEmpty else { return nil }
            let maxValue = numberValue(dict["maxValue"])
            var levels = normalizedHeatmapLevels(dict["levels"])
            let palette = heatmapPalette(from: dict["palette"], levels: &levels)
            let weekStartRaw = dict["weekStart"] as? String
            let weekStart = CodeAgentsUIHeatmapWeekStart(rawValue: weekStartRaw ?? "") ?? .mon
            return CodeAgentsUIChart(
                id: id,
                title: title,
                subtitle: subtitle,
                kind: .heatmap(
                    CodeAgentsUIHeatmapChart(
                        days: days,
                        maxValue: maxValue,
                        levels: levels,
                        palette: palette,
                        weekStart: weekStart
                    )
                )
            )
        }

        guard let chartType = CodeAgentsUIChartType(rawValue: chartTypeRaw),
              let xValues = dict["x"] as? [String] else { return nil }

        let x = Array(xValues.prefix(caps.maxChartPoints))
        guard !x.isEmpty else { return nil }

        let rawSeries = dict["series"] as? [Any] ?? []
        var series: [CodeAgentsUIChartSeries] = []
        series.reserveCapacity(min(rawSeries.count, caps.maxChartSeries))

        for value in rawSeries {
            guard series.count < caps.maxChartSeries,
                  let seriesDict = value as? [String: Any],
                  let valuesArray = seriesDict["values"] as? [Any] else { continue }
            let name = seriesDict["name"] as? String
            let color = seriesDict["color"] as? String
            let values = parseChartValues(valuesArray, maxCount: min(x.count, caps.maxChartPoints))
            guard !values.isEmpty else { continue }
            series.append(CodeAgentsUIChartSeries(name: name, values: values, color: color))
        }

        guard !series.isEmpty else { return nil }

        return CodeAgentsUIChart(
            id: id,
            title: title,
            subtitle: subtitle,
            kind: .barLine(CodeAgentsUIBarLineChart(chartType: chartType, x: x, series: series))
        )
    }

    private static func parsePieSlices(
        _ values: [Any],
        caps: CodeAgentsUICaps
    ) -> [CodeAgentsUIPieSlice] {
        var slices: [CodeAgentsUIPieSlice] = []
        slices.reserveCapacity(min(values.count, caps.maxChartPoints))

        for value in values {
            guard slices.count < caps.maxChartPoints,
                  let dict = value as? [String: Any],
                  let label = dict["label"] as? String,
                  let number = numberValue(dict["value"]) else { continue }
            let color = dict["color"] as? String
            slices.append(CodeAgentsUIPieSlice(label: label, value: number, color: color))
        }

        return slices
    }

    private static func parseChartValues(_ values: [Any], maxCount: Int) -> [Double?] {
        var parsed: [Double?] = []
        parsed.reserveCapacity(min(values.count, maxCount))

        for value in values.prefix(maxCount) {
            if value is NSNull {
                parsed.append(nil)
                continue
            }
            if let number = numberValue(value) {
                parsed.append(number)
            }
        }

        return parsed
    }

    private static func parseHeatmapDays(_ values: [Any], maxCount: Int) -> [CodeAgentsUIHeatmapDay] {
        var days: [CodeAgentsUIHeatmapDay] = []
        days.reserveCapacity(min(values.count, maxCount))

        for value in values {
            guard days.count < maxCount,
                  let dict = value as? [String: Any],
                  let dateString = dict["date"] as? String,
                  let date = heatmapDateFormatter.date(from: dateString) else {
                continue
            }
            let valueNumber = numberValue(dict["value"])
            let levelNumber = numberValue(dict["level"]).map { Int($0) }
            days.append(CodeAgentsUIHeatmapDay(date: date, value: valueNumber, level: levelNumber))
        }

        return days
    }

    private static func normalizedHeatmapLevels(_ value: Any?) -> Int {
        let raw = Int(numberValue(value) ?? 5)
        return min(max(raw, 2), 9)
    }

    private static func heatmapPalette(from value: Any?, levels: inout Int) -> [String] {
        let custom = value as? [String] ?? []
        if custom.count >= levels {
            return Array(custom.prefix(levels))
        }
        let fallback = defaultHeatmapPalette
        if levels > fallback.count {
            levels = fallback.count
        }
        return Array(fallback.prefix(levels))
    }

    private static let defaultHeatmapPalette: [String] = [
        "#ebedf0", "#9be9a8", "#40c463", "#30a14e", "#216e39"
    ]

    private static let heatmapDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func parseMediaSource(
        _ dict: [String: Any],
        allowBase64: Bool,
        pathSanitizer: (String) -> String?
    ) -> CodeAgentsUIMediaSource? {
        guard let kind = dict["kind"] as? String else { return nil }
        switch kind {
        case "url":
            guard let urlString = dict["url"] as? String,
                  let url = URL(string: urlString),
                  url.scheme?.lowercased() == "https" else {
                return nil
            }
            return .url(url)
        case "project_file":
            guard let path = dict["path"] as? String,
                  let sanitized = pathSanitizer(path) else {
                return nil
            }
            return .projectFile(path: sanitized)
        case "base64":
            guard allowBase64,
                  let mediaType = dict["mediaType"] as? String,
                  mediaType.lowercased().hasPrefix("image/"),
                  let dataString = dict["data"] as? String,
                  let data = Data(base64Encoded: dataString) else {
                return nil
            }
            return .base64(mediaType: mediaType, data: data)
        default:
            return nil
        }
    }

    private static func numberValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String, let number = Double(string) {
            return number
        }
        return nil
    }
}
