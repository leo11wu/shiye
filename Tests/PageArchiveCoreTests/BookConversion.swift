import Foundation
import AppKit
import PDFKit
import PageArchiveCore

func runBookConversionScenarios(root:URL) throws -> [(String,Bool,String)] {
    var results:[(String,Bool,String)]=[]
    func check(_ name:String,_ body:() throws -> Void) {
        do{try body();results.append((name,true,""));print("PASS \(name)")}
        catch{results.append((name,false,String(describing:error)));print("FAIL \(name): \(error)")}
    }
    let input=root.appendingPathComponent("book-scan.png")
    let bitmap=PageImporter.bitmap(width:400,height:600)!
    bitmap.setFillColor(CGColor(gray:1,alpha:1));bitmap.fill(CGRect(x:0,y:0,width:400,height:600))
    bitmap.setFillColor(CGColor(red:0.2,green:0.4,blue:0.8,alpha:1));bitmap.fill(CGRect(x:40,y:40,width:80,height:90))
    try PageImporter.writePNG(bitmap.makeImage()!,to:input)
    let store=try ProjectStore(root:root.appendingPathComponent("book-conversion.shiyebook"))
    var doc=BookDocument(title:"Searchable archive check")
    try PageImporter.append(urls:[input],to:&doc,store:store)
    var block=Block(order:1,box:Box(0.1,0.1,0.8,0.08),text:"Original wrong text")
    block.reviewedText="Reviewed 中文 ɑ̃"
    doc.pages[0].blocks=[block];doc.pages[0].status = .recognized
    var failed=doc.pages[0];failed.id=UUID().uuidString;failed.blocks=[];failed.status = .failed;failed.error="fixture failure"
    var blank=failed;blank.id=UUID().uuidString;blank.status = .blank;blank.error=nil
    doc.pages.append(contentsOf:[failed,blank])
    try store.save(doc)

    check("扫描导出保留失败页和确认空白页且优先校对文字") {
        let url=root.appendingPathComponent("searchable-archive.pdf")
        let report=try SearchablePDFExporter.render(document:doc,store:store,to:url)
        let pdf=PDFDocument(url:url)!
        try require(pdf.pageCount==3 && report.pageCount==3)
        try require(report.pagesWithoutText==[2,3] && report.failedPages==[2])
        let text=PDFRenderer.normalizedText(pdf.page(at:0)?.string ?? "")
        try require(text.contains(PDFRenderer.normalizedText(block.reviewedText!)))
        try require(!text.contains("Originalwrongtext"))
        try require(report.extractedTextChecked)
    }
    check("本机初稿拒绝覆盖已有转写") {
        do{_ = try LocalBookOCR.recognize(page:doc.pages[0],store:store);throw CheckFailure(description:"Unexpected overwrite")}
        catch let error as ArchiveError{try require(error.localizedDescription.contains("不会覆盖"))}
    }
    check("扫描导出取消后不继续处理后续页面") {
        var cancelled=false,last=0
        try mustThrow {
            _=try SearchablePDFExporter.render(document:doc,store:store,to:root.appendingPathComponent("cancelled-archive.pdf"),
                cancelled:{cancelled},progress:{done,_ in last=done;if done==1{cancelled=true}})
        }
        try require(last==1)
    }
    check("旧项目缺少图像版本标记仍可恢复") {
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(doc)) as! [String:Any]
        var pages=object["pages"] as! [[String:Any]]
        for index in pages.indices{pages[index].removeValue(forKey:"imageRenderVersion")}
        object["pages"]=pages
        let legacy=try JSONDecoder().decode(BookDocument.self,from:JSONSerialization.data(withJSONObject:object))
        try require(legacy.pages.count==3 && legacy.pages.allSatisfy{$0.imageRenderVersion==nil})
    }
    return results
}
