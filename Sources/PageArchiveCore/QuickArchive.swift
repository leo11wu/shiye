import Foundation
import CoreGraphics
import CoreText
import PDFKit
import ImageIO
import Vision

/// A fast, entirely on-device draft. Recognition is never evidence of human review.
public enum LocalBookOCR {
    public static func recognize(page: Page, store: ProjectStore) throws -> Page {
        guard page.blocks.isEmpty, page.status != .blank else {
            throw ArchiveError.message("此页已有转写或已确认空白；本机初稿不会覆盖已有内容。")
        }
        return try autoreleasepool {
            let image = try PageImporter.image(page: page, store: store)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.revision = VNRecognizeTextRequestRevision3
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.003
            let supported = try request.supportedRecognitionLanguages()
            request.recognitionLanguages = ["en-US", "zh-Hant", "zh-Hans"].filter { supported.contains($0) }
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

            // Preserve the engine's order. Sorting near-aligned lines by maxY can
            // scramble their order; complex layouts still need human review.
            let observations = (request.results ?? []).enumerated()
            var blocks: [Block] = []
            for entry in observations {
                guard let candidate = entry.element.topCandidates(1).first,
                      !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let r = entry.element.boundingBox
                let box = Box(Double(max(0, r.minX)), Double(max(0, 1 - r.maxY)),
                              Double(min(1, r.maxX) - max(0, r.minX)),
                              Double(min(1, r.maxY) - max(0, r.minY)))
                guard box.isValid else { continue }
                var block = Block(order: blocks.count + 1, box: box, text: candidate.string)
                block.uncertainty = "本机 OCR 初稿，未校对；引擎置信度 \(Int(candidate.confidence * 100))%，不能代表文字准确率。"
                block.reviewed = false
                blocks.append(block)
            }
            guard !blocks.isEmpty else {
                throw ArchiveError.message("本机 OCR 未找到可用文字。页面没有被标记为空白；请检查图像清晰度、方向，或使用云端识别。")
            }
            var result = page
            result.blocks = blocks
            result.status = .recognized
            result.error = nil
            result.textLayerAssessment = "本机 OCR 初稿，未校对"
            result.issues.removeAll { $0.code == "local-draft" }
            result.issues.append(ReviewIssue("local-draft",
                "本机初稿仅供搜索和初步转写。小字、英文、表格及多栏阅读顺序需要核对；此页尚未人工确认。"))
            return result
        }
    }
}

/// Page numbers are one-based output PDF positions, except sourcePageIndices,
/// which records the corresponding one-based project page indices.
public struct SearchablePDFReport: Codable {
    public var pageCount: Int = 0
    public var sourcePageIndices: [Int] = []
    public var pagesWithoutText: [Int] = []
    public var unreviewedPages: [Int] = []
    public var failedPages: [Int] = []
    public var tablePages: [Int] = []
    public var missingGlyphPages: [Int] = []
    public var textMismatches: [Int] = []
    /// NFC-normalized, non-whitespace character frequencies differ.
    public var characterMismatches: [Int] = []
    /// Character frequencies match, but their sequence differs. This does not prove OCR accuracy.
    public var readingOrderDifferences: [Int] = []
    public var extractedTextChecked: Bool = false
    public var warnings: [String] = []
    public init() {}
}

/// Retains the saved scan as the visible page, with editable block text as a hidden index.
/// This export does not rebuild typography, infer table structure, or improve OCR accuracy.
public enum SearchablePDFExporter {
    private struct Fragment {
        var text: String
        var box: Box
        var label: String
    }

    private struct SourcePDF {
        var graphics: CGPDFDocument
        var text: PDFDocument
    }

    public static func render(
        document: BookDocument,
        store: ProjectStore,
        to outputURL: URL,
        pages: [Int]? = nil,
        cancelled: () -> Bool = { false },
        progress: (Int, Int) -> Void = { _, _ in }
    ) throws -> SearchablePDFReport {
        let selected = pages ?? Array(document.pages.indices)
        guard !selected.isEmpty else { throw ArchiveError.message("没有可导出的页面。") }
        guard selected.allSatisfy({ document.pages.indices.contains($0) }) else {
            throw ArchiveError.message("导出页范围超出项目页数。")
        }
        guard !cancelled() else { throw ArchiveError.message("已取消可搜索 PDF 导出。") }

        var report = SearchablePDFReport()
        report.pageCount = selected.count
        report.sourcePageIndices = selected.map { $0 + 1 }
        report.warnings = [
            "页码均为输出 PDF 中的位置，从 1 开始；sourcePageIndices 对应项目页码。",
            "可见页面优先复用无文字层的原 PDF；其他页面使用高质量 JPEG 压缩的项目扫描图，项目原图不变。文字层采用当前转写及校对内容；提取校验不验证 OCR 是否忠于原书。",
            "文字层位置以区块或单元格边界近似；多栏、跨行及表格的复制顺序可能需要人工整理。"
        ]
        guard let consumer = CGDataConsumer(url: outputURL as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, [
                kCGPDFContextTitle as String: document.title,
                kCGPDFContextCreator as String: "拾页 — 保留扫描的可搜索 PDF"
              ] as CFDictionary) else {
            throw ArchiveError.message("无法创建可搜索 PDF，请检查输出目录。")
        }
        var closed = false
        defer { if !closed { context.closePDF() } }
        var expectedTexts: [String] = []
        var sourcePDFs: [String: SourcePDF] = [:]
        var unavailableSources = Set<String>()
        var reusedSourcePages = 0
        var compressedImagePages = 0
        progress(0, selected.count)

        for (position, index) in selected.enumerated() {
            guard !cancelled() else { throw ArchiveError.message("已取消可搜索 PDF 导出。") }
            let outputPage = position + 1
            let page = document.pages[index]
            guard page.width.isFinite, page.height.isFinite, page.width > 0, page.height > 0,
                  page.width < 20000, page.height < 20000 else {
                throw ArchiveError.message("项目第 \(index + 1) 页尺寸无效，已停止导出以避免遗漏页面。")
            }
            let expected: String = try autoreleasepool {
                // Reuse compressed source PDF imagery when it cannot contribute an
                // existing text layer. Otherwise embed JPEG without decoding it again.
                let sourcePage = try reusableSourcePage(page: page, document: document, store: store,
                                                        cache: &sourcePDFs, unavailable: &unavailableSources)
                let image: CGImage?
                if sourcePage == nil {
                    image = try compressedScan(page: page, store: store)
                } else {
                    image = nil
                }
                var mediaBox = CGRect(origin: .zero, size: page.size)
                let mediaData = withUnsafeBytes(of: &mediaBox) { Data($0) }
                context.beginPDFPage([kCGPDFContextMediaBox as String: mediaData] as CFDictionary)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(mediaBox)
                if let sourcePage {
                    context.saveGState()
                    // The destination is already measured in PDF points. Unlike bitmap
                    // import, no DPI scale is needed; normalize crop/rotation at natural size.
                    context.concatenate(sourcePage.getDrawingTransform(.cropBox, rect: mediaBox,
                                                                        rotate: 0, preserveAspectRatio: true))
                    context.drawPDFPage(sourcePage)
                    context.restoreGState()
                    reusedSourcePages += 1
                } else if let image {
                    context.draw(image, in: mediaBox)
                    compressedImagePages += 1
                }

                if page.status == .failed { report.failedPages.append(outputPage) }
                if page.status != .blank &&
                    (page.status != .reviewed || page.blocks.contains(where: { !$0.reviewed })) {
                    report.unreviewedPages.append(outputPage)
                }
                var warnings: [String] = []
                let fragments = textFragments(page: page, warnings: &warnings)
                if page.blocks.contains(where: { $0.kind == .table && !$0.retainImage }) {
                    report.tablePages.append(outputPage)
                }
                var written: [String] = []
                var missingGlyph = false
                for fragment in fragments {
                    guard fragment.box.isValid else {
                        warnings.append("\(fragment.label) 坐标无效，未生成该区块的文字层；扫描图完整保留。")
                        continue
                    }
                    let text = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    missingGlyph = drawInvisibleText(text, in: fragment.box.rect(in: page.size),
                                                     chineseFont: document.chineseFont,
                                                     context: context) || missingGlyph
                    written.append(text)
                }
                if written.isEmpty { report.pagesWithoutText.append(outputPage) }
                if missingGlyph { report.missingGlyphPages.append(outputPage) }
                report.warnings.append(contentsOf: warnings.map { "输出第 \(outputPage) 页：" + $0 })
                context.endPDFPage()
                return written.joined(separator: "\n")
            }
            expectedTexts.append(expected)
            progress(outputPage, selected.count)
        }
        context.closePDF()
        closed = true
        guard !cancelled() else { throw ArchiveError.message("已取消可搜索 PDF 导出。") }
        guard let pdf = PDFDocument(url: outputURL), pdf.pageCount == selected.count else {
            throw ArchiveError.message("输出 PDF 重新打开或页数核验失败；请勿将该文件作为完整归档。")
        }
        for position in selected.indices {
            guard !cancelled() else { throw ArchiveError.message("已取消可搜索 PDF 校验。") }
            autoreleasepool {
                let actual = pdf.page(at: position)?.string ?? ""
                let expected = normalized(expectedTexts[position])
                let extracted = normalized(actual)
                if expected != extracted {
                    report.textMismatches.append(position + 1)
                    if characterFrequencies(expected) == characterFrequencies(extracted) {
                        report.readingOrderDifferences.append(position + 1)
                    } else {
                        report.characterMismatches.append(position + 1)
                    }
                }
            }
        }
        report.extractedTextChecked = true
        report.warnings.append("可见页面中，\(reusedSourcePages) 页复用原 PDF 扫描内容；\(compressedImagePages) 页采用 JPEG 质量 90% 压缩。")
        if !report.pagesWithoutText.isEmpty {
            report.warnings.append("部分页面没有可用文字层，已保留完整扫描图；请按 pagesWithoutText 补做识别。已确认空白的页也可能在此列表。")
        }
        if !report.unreviewedPages.isEmpty {
            report.warnings.append("部分文字尚未人工核对。可搜索不等于转写准确，也不等于整本书已校对完成。")
        }
        if !report.failedPages.isEmpty {
            report.warnings.append("项目中标为识别失败的页面也已保留；其文字层可能为空或来自已有内容。")
        }
        if !report.tablePages.isEmpty {
            report.warnings.append("表格外观由扫描图保留，文字层按已有单元格顺序写入；不会生成可编辑的表格网格。")
        }
        if !report.missingGlyphPages.isEmpty {
            report.warnings.append("检测到字体回退或缺失字形风险，请核对 missingGlyphPages 的复制和搜索结果。")
        }
        if !report.characterMismatches.isEmpty {
            report.warnings.append("characterMismatches 中的页面，PDF 提取文字与写入内容在 NFC 归一化、去除空白后，字符频数仍不同；请检查缺字、重复或字体编码。扫描内容仍保留。")
        }
        if !report.readingOrderDifferences.isEmpty {
            report.warnings.append("readingOrderDifferences 中的页面，字符频数相同但提取顺序不同，需核对阅读顺序；字符频数相同不代表内容或 OCR 正确。textMismatches 包含两类差异。")
        }
        return report
    }

    /// Reuse only pages imported with the corrected geometry, from the unchanged
    /// source PDF, whose existing text layer will not be duplicated.
    private static func reusableSourcePage(page: Page, document: BookDocument, store: ProjectStore,
                                            cache: inout [String: SourcePDF],
                                            unavailable: inout Set<String>) throws -> CGPDFPage? {
        guard page.imageRenderVersion == PageImporter.renderVersion,
              let source = document.sources.first(where: { $0.id == page.sourceID }),
              URL(fileURLWithPath: source.relativePath).pathExtension.lowercased() == "pdf",
              !unavailable.contains(source.id) else { return nil }
        if cache[source.id] == nil {
            let url = try store.url(source.relativePath)
            guard (try? Digest.file(url)) == source.sha256,
                  let graphics = CGPDFDocument(url as CFURL),
                  let text = PDFDocument(url: url), !text.isLocked else {
                unavailable.insert(source.id)
                return nil
            }
            cache[source.id] = SourcePDF(graphics: graphics, text: text)
        }
        guard let pdf = cache[source.id],
              let graphicsPage = pdf.graphics.page(at: page.sourcePage),
              let textPage = pdf.text.page(at: page.sourcePage - 1),
              textPage.numberOfCharacters == 0, (textPage.string ?? "").isEmpty else { return nil }
        var size = graphicsPage.getBoxRect(.cropBox).size
        if abs(Int(graphicsPage.rotationAngle)) % 180 == 90 {
            size = CGSize(width: size.height, height: size.width)
        }
        guard abs(size.width - page.size.width) < 0.01,
              abs(size.height - page.size.height) < 0.01 else { return nil }
        return graphicsPage
    }

    /// Supplying the JPEG data provider directly lets Quartz embed its compressed
    /// stream. Drawing a decoded PNG instead can make a book-sized PDF enormous.
    private static func compressedScan(page: Page, store: ProjectStore) throws -> CGImage {
        let image = try PageImporter.image(page: page, store: store)
        guard let bitmap = PageImporter.bitmap(width: image.width, height: image.height) else {
            throw ArchiveError.message("页面压缩内存分配失败；导出已停止，未跳过页面。")
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(rect)
        bitmap.draw(image, in: rect)
        guard let opaqueImage = bitmap.makeImage() else {
            throw ArchiveError.message("无法准备页面压缩图像。")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw ArchiveError.message("无法创建 JPEG 页面压缩。")
        }
        CGImageDestinationAddImage(destination, opaqueImage,
                                  [kCGImageDestinationLossyCompressionQuality: 0.90] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let provider = CGDataProvider(data: data as CFData),
              let compressed = CGImage(jpegDataProviderSource: provider, decode: nil,
                                       shouldInterpolate: true, intent: .defaultIntent) else {
            throw ArchiveError.message("页面 JPEG 压缩失败；导出已停止，未跳过页面。")
        }
        return compressed
    }

    private static func textFragments(page: Page, warnings: inout [String]) -> [Fragment] {
        var result: [Fragment] = []
        for block in page.orderedBlocks {
            guard block.kind != .figure, !block.retainImage else { continue }
            if block.kind == .table {
                guard !block.cells.isEmpty else {
                    if !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        result.append(Fragment(text: block.text, box: block.box, label: "表格 \(block.order)"))
                        warnings.append("表格 \(block.order) 没有单元格数据，使用该区块文字作为搜索索引。")
                    }
                    continue
                }
                let cells = block.cells.sorted {
                    if $0.row != $1.row { return $0.row < $1.row }
                    if $0.column != $1.column { return $0.column < $1.column }
                    return $0.id < $1.id
                }
                let minimumRow = cells.map(\.row).min() ?? 0
                let minimumColumn = cells.map(\.column).min() ?? 0
                let rowCount = max(1, (cells.map { $0.row + max(1, $0.rowSpan) }.max() ?? 1) - minimumRow)
                let columnCount = max(1, (cells.map { $0.column + max(1, $0.columnSpan) }.max() ?? 1) - minimumColumn)
                var inferredBox = false
                for cell in cells {
                    let box: Box
                    if let cellBox = cell.box, cellBox.isValid {
                        box = cellBox
                    } else {
                        inferredBox = true
                        box = Box(
                            block.box.x + block.box.width * Double(cell.column - minimumColumn) / Double(columnCount),
                            block.box.y + block.box.height * Double(cell.row - minimumRow) / Double(rowCount),
                            block.box.width * Double(max(1, cell.columnSpan)) / Double(columnCount),
                            block.box.height * Double(max(1, cell.rowSpan)) / Double(rowCount))
                    }
                    result.append(Fragment(text: cell.text, box: box, label: "表格 \(block.order) 单元格"))
                }
                if inferredBox {
                    warnings.append("表格 \(block.order) 部分单元格没有有效坐标，文字层按均分网格近似定位。")
                }
            } else {
                result.append(Fragment(text: block.text, box: block.box, label: "区块 \(block.order)"))
            }
        }
        return result
    }

    /// Core Text writes real PDF text in invisible rendering mode, leaving scan pixels untouched.
    private static func drawInvisibleText(_ text: String, in rect: CGRect,
                                          chineseFont: String, context: CGContext) -> Bool {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        let lineHeight = rect.height / CGFloat(max(1, lines.count))
        let fontSize = max(0.1, lineHeight * 0.72)
        let font = ArchiveFonts.font(size: fontSize, style: TextStyle(), chinese: chineseFont)
        var missingGlyph = false
        for (index, content) in lines.enumerated() where !content.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: content, attributes: attributes))
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let horizontalScale = width > rect.width && width > 0 ? rect.width / width : 1
            let baseline = rect.maxY - CGFloat(index + 1) * lineHeight + lineHeight * 0.20
            context.saveGState()
            context.translateBy(x: rect.minX, y: baseline)
            context.scaleBy(x: horizontalScale, y: 1)
            context.textMatrix = .identity
            context.textPosition = .zero
            context.setTextDrawingMode(.invisible)
            CTLineDraw(line, context)
            context.restoreGState()

            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                if count > 0 {
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                    if glyphs.contains(0) { missingGlyph = true }
                }
                let runAttributes = CTRunGetAttributes(run) as NSDictionary
                if let runFont = runAttributes[kCTFontAttributeName] {
                    let name = CTFontCopyPostScriptName(runFont as! CTFont) as String
                    if name.localizedCaseInsensitiveContains("LastResort") { missingGlyph = true }
                }
            }
        }
        return missingGlyph
    }

    private static func characterFrequencies(_ text: String) -> [UInt32: Int] {
        text.unicodeScalars.reduce(into: [:]) { result, scalar in
            result[scalar.value, default: 0] += 1
        }
    }

    private static func normalized(_ text: String) -> String {
        let normalized = text.precomposedStringWithCanonicalMapping
        return String(String.UnicodeScalarView(normalized.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }))
    }
}
