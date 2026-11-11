import AppKit
import CoreText
import PDFKit

public struct PageDiagnostics: Codable {
    public var pageID:String, issues:[ReviewIssue]
    public var fittedFontSizes:[String:Double]
}
public struct RenderReport: Codable {
    public var draft:Bool, pages:[PageDiagnostics]
    public var extractedTextChecked:Bool = false
    public var textMismatches:[String] = []
    public var issueCount:Int { pages.reduce(0) { $0+$1.issues.filter { !$0.resolved }.count } }
}
public enum ArchiveFonts {
    public static let directory:URL = {
        #if SWIFT_PACKAGE
        Bundle.module.url(forResource:"Fonts",withExtension:nil)!
        #else
        let app=Bundle.main.resourceURL?.appendingPathComponent("Fonts")
        if let app=app,FileManager.default.fileExists(atPath:app.path) { return app }
        return URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("Resources/Fonts")
        #endif
    }()
    private static let registered:Void = {
        for name in ["Regular","Italic","Bold","BoldItalic"] {
            CTFontManagerRegisterFontsForURL(directory.appendingPathComponent("Charis-\(name).ttf") as CFURL,.process,nil)
        }
    }()
    public static func font(size:CGFloat,style:TextStyle,chinese:String) -> CTFont {
        _=registered
        let suffix=style.bold ? (style.italic ? "BoldItalic" : "Bold") : (style.italic ? "Italic" : "Regular")
        let attributes:[CFString:Any]=[kCTFontNameAttribute:"Charis-\(suffix)",kCTFontCascadeListAttribute:[CTFontDescriptorCreateWithNameAndSize(chinese as CFString,size)]]
        let descriptor=CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor,size,nil)
    }
}
public enum PDFRenderer {
    private struct Layout {
        var frame:CTFrame, size:Double, clipped:Bool, missingGlyph:Bool, inkOutside:Bool
    }
    private static func attributed(text:String,runs:[TextRun],size:Double,spacing:Double,alignment:String,chinese:String) -> NSAttributedString {
        let result=NSMutableAttributedString(string:"")
        let actual=runs.isEmpty ? [TextRun(text)] : runs
        for run in actual {
            let script=run.style.script,point=size*(script==0 ? 1 : 0.72)
            let font=ArchiveFonts.font(size:point,style:run.style,chinese:chinese)
            var attrs:[NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):NSColor.black.cgColor]
            if script != 0 { attrs[NSAttributedString.Key(kCTBaselineOffsetAttributeName as String)]=size*(script>0 ? 0.32 : -0.20) }
            result.append(NSAttributedString(string:run.text,attributes:attrs))
        }
        let paragraph=NSMutableParagraphStyle()
        paragraph.alignment=alignment=="center" ? .center : alignment=="right" ? .right : alignment=="justified" ? .justified : .left
        paragraph.lineHeightMultiple=max(1,min(2.5,spacing));paragraph.lineBreakMode = .byWordWrapping
        result.addAttribute(.paragraphStyle,value:paragraph,range:NSRange(location:0,length:result.length))
        return result
    }
    private static func layout(text:String,runs:[TextRun],rect:CGRect,requested:Double,spacing:Double,alignment:String,chinese:String) -> Layout {
        let count=max(1,text.components(separatedBy:"\n").count)
        let inferred=min(18,max(8,Double(rect.height)/Double(count)*0.67))
        let start=requested>0 ? requested : min(12,inferred)
        let floor=requested>0 ? max(4,start*0.90) : max(8,start*0.90)
        var point=start,result:Layout!
        repeat {
            let attributed=attributed(text:text,runs:runs,size:point,spacing:spacing,alignment:alignment,chinese:chinese)
            let framesetter=CTFramesetterCreateWithAttributedString(attributed)
            let frame=CTFramesetterCreateFrame(framesetter,CFRange(location:0,length:0),CGPath(rect:rect,transform:nil),nil)
            let visible=CTFrameGetVisibleStringRange(frame)
            let lines=CTFrameGetLines(frame) as! [CTLine]
            var origins=[CGPoint](repeating:.zero,count:lines.count)
            if !origins.isEmpty { CTFrameGetLineOrigins(frame,CFRange(location:0,length:0),&origins) }
            var missing=text.unicodeScalars.contains{$0.properties.generalCategory == .unassigned},outside=false
            for (i,line) in lines.enumerated() {
                let ink=CTLineGetBoundsWithOptions(line,.useGlyphPathBounds).offsetBy(dx:rect.minX+origins[i].x,dy:rect.minY+origins[i].y)
                if !ink.isEmpty && !rect.insetBy(dx:-1.2,dy:-1.2).contains(ink) { outside=true }
                for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                    let attributes=CTRunGetAttributes(run) as NSDictionary
                    if let font=attributes[kCTFontAttributeName] {let name=CTFontCopyPostScriptName(font as! CTFont) as String;if name.localizedCaseInsensitiveContains("LastResort"){missing=true}}
                    let n=CTRunGetGlyphCount(run)
                    var glyphs=[CGGlyph](repeating:0,count:n)
                    if n>0 { CTRunGetGlyphs(run,CFRange(location:0,length:0),&glyphs) }
                    if glyphs.contains(0) { missing=true }
                }
            }
            result=Layout(frame:frame,size:point,clipped:visible.length<attributed.length,missingGlyph:missing,inkOutside:outside)
            if !result.clipped && !result.inkOutside { break }
            if point<=floor+0.001 { break };point=max(floor,point-0.25)
        } while true
        return result
    }
    public static func cellBox(_ cell:TableCell,table:Block) -> Box {
        if let b=cell.box { return b }
        let rows=max(1,table.cells.map { $0.row+$0.rowSpan }.max() ?? 1),cols=max(1,table.cells.map { $0.column+$0.columnSpan }.max() ?? 1)
        return Box(table.box.x+Double(cell.column)*table.box.width/Double(cols),table.box.y+Double(cell.row)*table.box.height/Double(rows),table.box.width*Double(cell.columnSpan)/Double(cols),table.box.height*Double(cell.rowSpan)/Double(rows))
    }
    public static func diagnostics(page:Page,chineseFont:String) -> PageDiagnostics { draw(page:page,store:nil,chineseFont:chineseFont,context:nil) }
    @discardableResult
    private static func draw(page:Page,store:ProjectStore?,chineseFont:String,context:CGContext?) -> PageDiagnostics {
        var issues=page.issues.filter { !$0.resolved },sizes:[String:Double]=[:]
        if NSFont(name:chineseFont,size:12)==nil && !NSFontManager.shared.availableFontFamilies.contains(chineseFont) {issues.append(ReviewIssue("font-unavailable","指定中文字体未安装，请填写本机可用字体名称。"))}
        if page.status == .failed { issues.append(ReviewIssue("failed",page.error ?? "页面识别失败。")) }
        if page.status != .blank && page.blocks.isEmpty { issues.append(ReviewIssue("unrecognized","本页尚未重建；校对稿中保留原扫描。")) }
        let blocks=page.orderedBlocks
        for (i,a) in blocks.enumerated() {
            for b in blocks.dropFirst(i+1) where a.box.intersection(b.box)>min(a.box.area,b.box.area)*0.15 {
                issues.append(ReviewIssue("overlap","区域与 \(b.order) 存在显著重叠，请核对。",blockID:a.id))
            }
        }
        var sourceImage:CGImage?
        if let store=store { sourceImage=try? PageImporter.image(page:page,store:store) }
        if blocks.isEmpty,page.status != .blank,let image=sourceImage,let ctx=context { ctx.draw(image,in:CGRect(origin:.zero,size:page.size)) }
        for b in blocks {
            guard b.box.isValid, b.fontSize.isFinite, (0...100).contains(b.fontSize), b.lineSpacing.isFinite else { issues.append(ReviewIssue("bounds","区域边界或字号无效。",blockID:b.id));continue }
            let rect=b.box.rect(in:page.size)
            if b.retainImage && b.kind != .table && b.kind != .figure {issues.append(ReviewIssue("invalid-retention","正文须保留为文字，请取消原图保留。",blockID:b.id))}
            if b.retainImage || b.kind == .figure {
                if !b.retainImage { issues.append(ReviewIssue("retention-unconfirmed","请确认以整块原图保留此对象。",blockID:b.id)) }
                if let image=sourceImage,let crop=try? PageImporter.crop(image,box:b.box) { context?.draw(crop,in:rect) }
                else if context != nil { issues.append(ReviewIssue("asset-missing","原图对象缺失。",blockID:b.id)) }
                continue
            }
            func paint(_ text:String,_ runs:[TextRun],_ target:CGRect,_ id:String,_ alignment:String) {
                guard !text.isEmpty else { return }
                let l=layout(text:text,runs:runs,rect:target,requested:b.fontSize,spacing:b.lineSpacing,alignment:alignment,chinese:chineseFont)
                sizes[id]=l.size
                if l.clipped || l.inkOutside { issues.append(ReviewIssue("overflow","文字无法在允许的局部微调范围内装入，或附标超出区域。",blockID:b.id)) }
                if l.missingGlyph { issues.append(ReviewIssue("missing-glyph","字体无法绘制部分字符，请选择覆盖字体或核对字形。",blockID:b.id)) }
                if text.unicodeScalars.contains(where:{$0.value==0 || $0.value==0xfffd}) { issues.append(ReviewIssue("invalid-unicode","正文含 NUL 或替换字符。",blockID:b.id)) }
                if text.contains("⟦") { issues.append(ReviewIssue("unresolved-mark","正文中仍有疑难字标记。",blockID:b.id)) }
                if let ctx=context { ctx.saveGState();ctx.textMatrix = .identity;CTFrameDraw(l.frame,ctx);ctx.restoreGState() }
            }
            if b.kind == .table {
                if b.cells.isEmpty { issues.append(ReviewIssue("empty-table","表格尚未恢复单元格。",blockID:b.id)) }
                var occupied=Set<String>()
                for c in b.cells.sorted(by:{($0.row,$0.column)<($1.row,$1.column)}) {
                    guard c.row>=0,c.column>=0,c.rowSpan>0,c.columnSpan>0,c.row+c.rowSpan<=500,c.column+c.columnSpan<=100 else {issues.append(ReviewIssue("cell-bounds","单元格行列或合并关系无效。",blockID:b.id));continue}
                    for r in c.row..<c.row+c.rowSpan {for col in c.column..<c.column+c.columnSpan {if !occupied.insert("\(r):\(col)").inserted{issues.append(ReviewIssue("cell-bounds","表格单元格合并关系重叠。",blockID:b.id))}}}
                    let box=cellBox(c,table:b)
                    guard box.isValid,b.box.contains(box) else { issues.append(ReviewIssue("cell-bounds","单元格超出表格边界。",blockID:b.id));continue }
                    let cellRect=box.rect(in:page.size)
                    if b.drawGrid,let ctx=context { ctx.saveGState();ctx.setStrokeColor(CGColor(gray:0.65,alpha:1));ctx.setLineWidth(0.35);ctx.stroke(cellRect);ctx.restoreGState() }
                    paint(c.text,c.runs.map(\.text).joined()==c.text ? c.runs : [],cellRect.insetBy(dx:2,dy:1.5),c.id,"left")
                }
            } else {
                if b.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{issues.append(ReviewIssue("empty-text","区域尚未填写原文。",blockID:b.id))}
                paint(b.text,b.runs.map(\.text).joined()==b.text ? b.runs : [],rect,b.id,b.alignment)
            }
        }
        // Compare area coverage of independent local detections, not model confidence.
        for hint in page.hints where hint.box.area>0 {
            let covered=blocks.reduce(0.0) { $0+$1.box.intersection(hint.box) }
            if covered<hint.box.area*0.65, page.status != .blank {
                issues.append(ReviewIssue("uncovered","本机检测到未覆盖的文字区域（约 x=\(Int(hint.box.x*100))%，y=\(Int(hint.box.y*100))%），请核对漏块。"));break
            }
        }
        return PageDiagnostics(pageID:page.id,issues:issues,fittedFontSizes:sizes)
    }
    public static func render(document:BookDocument,store:ProjectStore?,to url:URL,pages:[Int]? = nil,forceDraft:Bool = false) throws -> RenderReport {
        let selected=pages ?? Array(document.pages.indices)
        guard !selected.isEmpty,selected.allSatisfy({document.pages.indices.contains($0)}) else { throw ArchiveError.message("没有可导出的页面。") }
        let preliminary=selected.map { diagnostics(page:document.pages[$0],chineseFont:document.chineseFont) }
        let draft=forceDraft || preliminary.contains { !$0.issues.isEmpty } || selected.contains { ![PageStatus.reviewed,.blank].contains(document.pages[$0].status) }
        guard let consumer=CGDataConsumer(url:url as CFURL),let ctx=CGContext(consumer:consumer,mediaBox:nil,[kCGPDFContextTitle:document.title+(draft ? "（校对稿）" : ""),kCGPDFContextCreator:"拾页",kCGPDFContextSubject:"原文重建；逐页来源与修改记录保存在拾页项目中"] as CFDictionary) else { throw ArchiveError.message("无法创建 PDF，请检查保存位置。") }
        var reports:[PageDiagnostics]=[]
        for index in selected {
            autoreleasepool {
                let page=document.pages[index]
                var media=CGRect(origin:.zero,size:page.size)
                let data=Data(bytes:&media,count:MemoryLayout<CGRect>.size)
                ctx.beginPDFPage([kCGPDFContextMediaBox:data] as CFDictionary)
                ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(media)
                let report=draw(page:page,store:store,chineseFont:document.chineseFont,context:ctx);reports.append(report)
                if draft {
                    let label="校对稿 · 来源页 \(page.sourcePage)"+(page.blocks.isEmpty && page.status != .blank ? " · 原扫描待重建" : "")
                    let a=NSAttributedString(string:label,attributes:[.font:NSFont.systemFont(ofSize:6),.foregroundColor:NSColor(calibratedRed:0.55,green:0.25,blue:0.15,alpha:1)])
                    ctx.saveGState();ctx.textPosition=CGPoint(x:5,y:3);CTLineDraw(CTLineCreateWithAttributedString(a),ctx);ctx.restoreGState()
                }
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        var report=RenderReport(draft:draft,pages:reports)
        if !draft && reports.contains(where:{!$0.issues.isEmpty}) {try? FileManager.default.removeItem(at:url);throw ArchiveError.message("导出过程中发现资源或排版问题，请保存校对稿并处理。")}
        guard let pdf=PDFDocument(url:url),pdf.pageCount==selected.count else { throw ArchiveError.message("导出 PDF 无法重新打开，或页数不匹配。") }
        for (output,index) in selected.enumerated() {
            let page=document.pages[index],expected=normalizedText(page.orderedBlocks.map(\.plainText).joined(separator:"\n"))
            let actual=normalizedText(pdf.page(at:output)?.string ?? "")
            if !expected.isEmpty && !actual.contains(expected) { report.textMismatches.append(page.id) }
        }
        report.extractedTextChecked=true
        // PDFKit may infer different ordering in spatial tables. Never silently call that validated.
        if !report.textMismatches.isEmpty && !draft {
            try? FileManager.default.removeItem(at:url)
            throw ArchiveError.message("导出后文字提取与原文不一致（\(report.textMismatches.count) 页）。请导出校对稿检查复制顺序。")
        }
        return report
    }
    public static func normalizedText(_ text:String) -> String { String(text.precomposedStringWithCanonicalMapping.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }) }
    public static func exportText(document:BookDocument,pages:[Int],to url:URL) throws {
        let text=pages.map { index in
            let p=document.pages[index]
            let separator=p.issues.contains(where:{$0.code=="local-draft"}) ? "\n" : "\n\n"
            return "[项目页 \(index+1) / 来源页 \(p.sourcePage) / \(p.status.label)]\n"+p.orderedBlocks.map { b in b.retainImage || b.kind == .figure ? "[原图对象：\(b.id)]" : b.plainText }.joined(separator:separator)
        }.joined(separator:"\n\n\u{000C}\n\n")
        try text.write(to:url,atomically:true,encoding:.utf8)
    }
}
