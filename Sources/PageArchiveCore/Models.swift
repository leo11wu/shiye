import Foundation
import CoreGraphics

public enum ArchiveError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

public struct Box: Codable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x,y,width,height].allSatisfy { $0.isFinite } && x >= 0 && y >= 0 && width > 0 && height > 0 && x+width <= 1.00001 && y+height <= 1.00001
    }
    public var area: Double { max(0,width) * max(0,height) }
    public var cgRect: CGRect { CGRect(x:x,y:y,width:width,height:height) }
    public func rect(in size: CGSize) -> CGRect {
        CGRect(x: x*size.width, y:(1-y-height)*size.height, width:width*size.width,height:height*size.height)
    }
    public func intersection(_ other: Box) -> Double { let r = cgRect.intersection(other.cgRect); return r.isNull ? 0 : r.width*r.height }
    public func contains(_ other: Box) -> Bool { intersection(other) >= other.area * 0.97 }
}

public enum BlockKind: String, Codable, CaseIterable {
    case paragraph, heading, list, footnote, header, footer, table, figure
    var isBody: Bool { self != .header && self != .footer && self != .footnote }
    public var label: String {
        switch self {
        case .paragraph: return "正文"; case .heading: return "标题"; case .list: return "条目"
        case .footnote: return "脚注"; case .header: return "页眉"; case .footer: return "页码 / 页脚"
        case .table: return "表格"; case .figure: return "图像"
        }
    }
}
public enum OCRColumn: String, Codable { case left, right, full }
public enum OCRPageLayout: String, Codable {
    case single = "single_column", leftToRight = "two_columns_ltr", rightToLeft = "two_columns_rtl", other
}
public struct OCRPageStructure: Codable {
    public var layout: OCRPageLayout
    public var startsMidParagraph: Bool
    public var endsMidParagraph: Bool
    public init(layout: OCRPageLayout, startsMidParagraph: Bool, endsMidParagraph: Bool) {
        self.layout=layout;self.startsMidParagraph=startsMidParagraph;self.endsMidParagraph=endsMidParagraph
    }
}
public enum ContinuationSeparator: String, Codable {
    case none, space
    public var text: String { self == .space ? " " : "" }
}
public struct TextContinuation: Codable, Equatable {
    public var nextPageID: String
    public var tailBlockID: String
    public var headBlockID: String
    public var separator: ContinuationSeparator
    public init(nextPageID: String, tailBlockID: String, headBlockID: String, separator: ContinuationSeparator) {
        self.nextPageID=nextPageID;self.tailBlockID=tailBlockID;self.headBlockID=headBlockID;self.separator=separator
    }
}
public struct TextStyle: Codable, Equatable {
    public var bold = false, italic = false
    public var script: Int = 0 // -1 subscript, 0 normal, 1 superscript
    public init(bold: Bool = false, italic: Bool = false, script: Int = 0) { self.bold=bold;self.italic=italic;self.script=script }
}
public struct TextRun: Codable, Equatable {
    public var text: String
    public var style: TextStyle
    public init(_ text: String, style: TextStyle = TextStyle()) { self.text=text;self.style=style }
}
public struct TableCell: Codable, Identifiable {
    public var id: String
    public var row: Int, column: Int, rowSpan: Int, columnSpan: Int
    public var box: Box? // page-normalized, not table-relative
    public var rawText: String, reviewedText: String?
    public var runs: [TextRun]
    public var text: String { reviewedText ?? rawText }
    public init(id: String = UUID().uuidString, row: Int, column: Int, text: String, box: Box? = nil, rowSpan: Int = 1, columnSpan: Int = 1, runs: [TextRun] = []) {
        self.id=id;self.row=row;self.column=column;self.rowSpan=rowSpan;self.columnSpan=columnSpan;self.rawText=text;self.box=box;self.runs=runs
    }
}
public struct Block: Codable, Identifiable {
    public var id: String
    public var kind: BlockKind
    public var order: Int
    public var box: Box
    public var rawText: String, reviewedText: String?
    public var runs: [TextRun]
    public var cells: [TableCell]
    public var fontSize: Double // 0 = infer from original area
    public var lineSpacing: Double
    public var alignment: String
    public var uncertainty: String?
    public var reviewed: Bool
    public var retainImage: Bool
    public var drawGrid: Bool
    public var ocrColumn: OCRColumn?
    public var noteID: String?
    public var noteReferences: [String]?
    public var text: String { reviewedText ?? rawText }
    public init(id: String = UUID().uuidString, kind: BlockKind = .paragraph, order: Int = 1, box: Box = Box(0.08,0.08,0.84,0.20), text: String = "", runs: [TextRun] = [], cells: [TableCell] = [], fontSize: Double = 0) {
        self.id=id;self.kind=kind;self.order=order;self.box=box;self.rawText=text;self.runs=runs;self.cells=cells;self.fontSize=fontSize
        self.lineSpacing=1.15;self.alignment="left";self.reviewed=false;self.retainImage=false;self.drawGrid=false
    }
    public var plainText: String {
        if kind == .table && !retainImage { return cells.sorted { ($0.row,$0.column) < ($1.row,$1.column) }.map(\.text).joined(separator:"\t") }
        return retainImage || kind == .figure ? "" : text
    }
}
public struct TextHint: Codable {
    public var box: Box
    public var text: String
    public var confidence: Double?
    public init(box: Box, text: String, confidence: Double? = nil) {
        self.box=box;self.text=text;self.confidence=confidence
    }
}
public struct ReviewIssue: Codable, Identifiable {
    public var id: String
    public var code: String, message: String, blockID: String?
    public var resolved: Bool
    public var box: Box?
    public init(_ code: String, _ message: String, blockID: String? = nil, resolved: Bool = false, box: Box? = nil) {
        self.id=UUID().uuidString;self.code=code;self.message=message;self.blockID=blockID;self.resolved=resolved;self.box=box
    }
}
public struct RecognitionRecord: Codable {
    public var requestedModel: String, returnedModel: String?, endpoint: String
    public var timestamp: Date, cacheKey: String, responsePath: String
    public var promptTokens: Int?, completionTokens: Int?
    public var promptVersion: String
    public init(requestedModel:String,returnedModel:String?,endpoint:String,cacheKey:String,responsePath:String,promptTokens:Int?,completionTokens:Int?,promptVersion:String) {
        self.requestedModel=requestedModel;self.returnedModel=returnedModel;self.endpoint=endpoint;self.cacheKey=cacheKey;self.responsePath=responsePath;self.promptTokens=promptTokens;self.completionTokens=completionTokens;self.promptVersion=promptVersion;timestamp=Date()
    }
}
public enum PageStatus: String, Codable {
    case imported, recognized, reviewed, blank, failed
    public var label: String {
        switch self { case .imported:return "待识别";case .recognized:return "待核对";case .reviewed:return "已核对";case .blank:return "确认空白";case .failed:return "失败" }
    }
}
public struct Page: Codable, Identifiable {
    public var id: String
    public var sourceID: String, sourcePage: Int, printedLabel: String?
    public var sourceSHA256:String?
    public var sourceImageOrientation:Int?
    public var sourcePixelWidth:Double?, sourcePixelHeight:Double?
    public var width: Double, height: Double
    public var sourceRotation: Int, sourceCropBox: [Double]
    public var imagePath: String, imageSHA256: String
    public var imageRenderVersion: String?
    public var textLayerAssessment: String
    public var status: PageStatus
    public var blocks: [Block], hints: [TextHint], issues: [ReviewIssue]
    public var recognitions: [RecognitionRecord]
    public var error: String?
    public var ocrStructure: OCRPageStructure?
    public var textContinuation: TextContinuation?
    public var agentFailurePath: String?
    public var size: CGSize { CGSize(width:width,height:height) }
    public init(id: String = UUID().uuidString, sourceID: String = "fixture", sourcePage: Int, width: Double, height: Double, imagePath: String = "", imageSHA256: String = "") {
        self.id=id;self.sourceID=sourceID;self.sourcePage=sourcePage;self.width=width;self.height=height;self.imagePath=imagePath;self.imageSHA256=imageSHA256
        self.imageRenderVersion=nil
        self.sourceRotation=0;self.sourceCropBox=[0,0,width,height];self.textLayerAssessment="无文字层";self.status = .imported
        self.blocks=[];self.hints=[];self.issues=[];self.recognitions=[]
    }
    public var orderedBlocks: [Block] { blocks.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order } }
    public var orderedBodyBlocks: [Block] { orderedBlocks.filter{$0.kind.isBody} }
}
public struct SourceFile: Codable, Identifiable {
    public var id: String, filename: String, relativePath: String, sha256: String
}
public struct EditRecord: Codable {
    public var timestamp: Date, pageID: String, blockID: String?, action: String
    public var before: String?, after: String?
    public init(pageID: String, blockID: String? = nil, action: String, before: String? = nil, after: String? = nil) {
        timestamp=Date();self.pageID=pageID;self.blockID=blockID;self.action=action;self.before=before;self.after=after
    }
}
public struct BookDocument: Codable {
    public var schemaVersion = "bookocr-ir-1"
    public var id = UUID().uuidString
    public var title: String
    public var createdAt = Date(), modifiedAt = Date()
    public var sources: [SourceFile] = []
    public var pages: [Page] = []
    public var edits: [EditRecord] = []
    public var chineseFont = "Songti TC"
    public var outputPageMap: [String] = []
    public init(title: String) { self.title=title }
}
public enum PageRange {
    public static func parse(_ input: String, count: Int) throws -> [Int] {
        if input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return Array(0..<count) }
        var result = Set<Int>()
        for segment in input.replacingOccurrences(of:"，",with:",").components(separatedBy:",") {
            let parts=segment.trimmingCharacters(in:.whitespaces).components(separatedBy:"-")
            guard (1...2).contains(parts.count), let first=Int(parts[0]), first>=1, first<=count else { throw ArchiveError.message("页码格式错误。示例：1-5,8,12；有效范围 1–\(count)。") }
            let last: Int
            if parts.count==2 { guard let end=Int(parts[1]), end>=first, end<=count else { throw ArchiveError.message("页范围无效：\(segment)") };last=end } else { last=first }
            result.formUnion((first...last).map { $0-1 })
        }
        return result.sorted()
    }
}
