import Foundation
import PDFKit
import PageArchiveCore

func runCancelExportScenarios(root:URL) throws -> [(String,Bool,String)] {
    var results:[(String,Bool,String)]=[]
    func check(_ name:String,_ body:() throws -> Void) {
        do { try body();results.append((name,true,""));print("PASS \(name)") }
        catch { results.append((name,false,String(describing:error)));print("FAIL \(name): \(error)") }
    }
    func expectCancelled(_ body:() throws -> Void) throws {
        do { try body() }
        catch is CancellationError { return }
        throw CheckFailure(description:"导出应抛出取消错误")
    }
    var document=BookDocument(title:"Cancellable export")
    document.pages=(1...3).map { number in
        var page=Page(sourcePage:number,width:300,height:400)
        var block=Block(order:1,box:Box(0.1,0.1,0.8,0.2),text:"Export page \(number)",fontSize:12)
        block.reviewed=true;page.blocks=[block];page.status = .reviewed
        return page
    }

    check("重建PDF开始前取消不改动已有文件") {
        let url=root.appendingPathComponent("cancel-before-render.pdf"),original=Data("existing export".utf8)
        try original.write(to:url)
        try expectCancelled {
            _=try PDFRenderer.render(document:document,store:nil,to:url,cancelled:{true})
        }
        try require(try Data(contentsOf:url)==original)
    }
    check("重建PDF逐页取消且不留下部分文件") {
        let url=root.appendingPathComponent("cancel-during-render.pdf")
        var cancelled=false,completed:[Int]=[]
        try expectCancelled {
            _=try PDFRenderer.render(document:document,store:nil,to:url,cancelled:{cancelled},progress:{done,_ in
                completed.append(done);if done==1 { cancelled=true }
            })
        }
        try require(completed==[0,1] && !FileManager.default.fileExists(atPath:url.path))
    }
    check("重建PDF最后一页取消仍不交付文件") {
        let url=root.appendingPathComponent("cancel-after-render.pdf")
        var cancelled=false
        try expectCancelled {
            _=try PDFRenderer.render(document:document,store:nil,to:url,cancelled:{cancelled},progress:{done,total in
                if done==total { cancelled=true }
            })
        }
        try require(!FileManager.default.fileExists(atPath:url.path))
    }
    check("正文TXT逐页取消保留已有文件") {
        let url=root.appendingPathComponent("cancel-during-text.txt"),original=Data("existing text".utf8)
        try original.write(to:url)
        var cancelled=false,completed:[Int]=[]
        try expectCancelled {
            try PDFRenderer.exportText(document:document,pages:[0,1,2],to:url,cancelled:{cancelled},progress:{done,_ in
                completed.append(done);if done==1 { cancelled=true }
            })
        }
        let saved=try Data(contentsOf:url)
        try require(completed==[0,1] && saved==original)
    }
    check("正文TXT完成整理后取消仍不覆盖已有文件") {
        let url=root.appendingPathComponent("cancel-after-text.txt"),original=Data("existing text".utf8)
        try original.write(to:url)
        var cancelled=false
        try expectCancelled {
            try PDFRenderer.exportText(document:document,pages:[0,1,2],to:url,cancelled:{cancelled},progress:{done,total in
                if done==total { cancelled=true }
            })
        }
        try require(try Data(contentsOf:url)==original)
    }
    check("重建PDF按所选页顺序导出并报告逐页进度") {
        let url=root.appendingPathComponent("progress-render.pdf")
        var completed:[Int]=[],totals:[Int]=[]
        let report=try PDFRenderer.render(document:document,store:nil,to:url,pages:[2,0],progress:{done,total in
            completed.append(done);totals.append(total)
        })
        let pdf=PDFDocument(url:url)
        try require(completed==[0,1,2] && totals==[2,2,2])
        try require(report.extractedTextChecked && report.textMismatches.isEmpty && pdf?.pageCount==2)
        try require(pdf?.page(at:0)?.string?.contains("Export page 3")==true)
        try require(pdf?.page(at:1)?.string?.contains("Export page 1")==true)
    }
    check("正文TXT按所选页顺序导出并报告逐页进度") {
        let url=root.appendingPathComponent("progress-text.txt")
        var completed:[Int]=[],totals:[Int]=[]
        try PDFRenderer.exportText(document:document,pages:[2,0],to:url,progress:{done,total in
            completed.append(done);totals.append(total)
        })
        let text=try String(contentsOf:url,encoding:.utf8)
        try require(completed==[0,1,2] && totals==[2,2,2])
        guard let third=text.range(of:"Export page 3"),let first=text.range(of:"Export page 1") else {
            throw CheckFailure(description:"所选页面文字缺失")
        }
        try require(third.lowerBound<first.lowerBound && !text.contains("Export page 2"))
    }
    return results
}
