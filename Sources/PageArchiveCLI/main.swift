import Foundation
import AppKit
import PDFKit
import Darwin
import PageArchiveCore

do {
    let args=Array(CommandLine.arguments.dropFirst())
    guard let command=args.first else { throw ArchiveError.message("用法：shiye-check fixtures 输出目录 | inspect PDF | import 输入文件 项目目录 | render 项目目录 输出PDF") }
    switch command {
    case "fixtures":
        guard args.count==2 else { throw ArchiveError.message("请指定输出目录。") }
        let root=URL(fileURLWithPath:args[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let doc=Fixtures.document();let report=try PDFRenderer.render(document:doc,store:nil,to:root.appendingPathComponent("拾页-原生排版技术样张.pdf"))
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(report).write(to:root.appendingPathComponent("layout-report.json"),options:.atomic)
        print(String(data:try encoder.encode(report),encoding:.utf8)!)
    case "inspect":
        guard args.count==2,let pdf=PDFDocument(url:URL(fileURLWithPath:args[1])) else { throw ArchiveError.message("无法打开 PDF。") }
        var textCount=0
        for i in 0..<pdf.pageCount { textCount+=(pdf.page(at:i)?.string ?? "").count }
        print("pages=\(pdf.pageCount) text_characters=\(textCount)")
    case "import":
        guard args.count==3 else { throw ArchiveError.message("请指定输入文件与项目目录。") }
        let input=URL(fileURLWithPath:args[1]),store=try ProjectStore(root:URL(fileURLWithPath:args[2]))
        guard !FileManager.default.fileExists(atPath:store.root.appendingPathComponent("document.json").path) else {
            throw ArchiveError.message("目标项目已经存在，请使用新的项目目录；不会覆盖已有识别与校对。")
        }
        var doc=BookDocument(title:input.deletingPathExtension().lastPathComponent)
        try PageImporter.append(urls:[input],to:&doc,store:store,progress:{print($0)})
        print("Imported \(doc.pages.count) pages")
    case "render":
        guard args.count==3 else { throw ArchiveError.message("请指定项目与输出文件。") }
        let store=try ProjectStore(root:URL(fileURLWithPath:args[1])),doc=try store.load()
        let report=try PDFRenderer.render(document:doc,store:store,to:URL(fileURLWithPath:args[2]))
        print("draft=\(report.draft) issues=\(report.issueCount) extraction_mismatches=\(report.textMismatches.count)")
    default: throw ArchiveError.message("未知命令。")
    }
    var usage=rusage();if getrusage(RUSAGE_SELF,&usage)==0{print("MAX_RSS_BYTES=\(usage.ru_maxrss)")}
} catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8));exit(1) }
