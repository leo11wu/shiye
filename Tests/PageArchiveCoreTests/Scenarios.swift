import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import PageArchiveCore

struct CheckFailure:Error,CustomStringConvertible {var description:String}
func require(_ condition:@autoclosure () throws->Bool,_ message:String = "断言未通过") throws {if try !condition(){throw CheckFailure(description:message)}}
func mustThrow(_ work:() throws -> Void) throws {do{try work()}catch{return};throw CheckFailure(description:"预期拒绝，但操作成功")}
final class LockedResult<T> {
    let lock=NSLock();var value:Result<T,Error>?
    func set(_ v:Result<T,Error>){lock.lock();value=v;lock.unlock()}
    func get()->Result<T,Error>?{lock.lock();defer{lock.unlock()};return value}
}
func awaitResult<T>(_ work:@escaping () async throws->T) throws -> T {
    let box=LockedResult<T>(),done=DispatchSemaphore(value:0)
    Task.detached {do{box.set(.success(try await work()))}catch{box.set(.failure(error))};done.signal()}
    guard done.wait(timeout:.now()+30) == .success,let result=box.get() else{throw CheckFailure(description:"异步测试超时")}
    return try result.get()
}
final class StubTransport:HTTPTransport {
    var responses:[(Int,Data,[String:String])],requests:[URLRequest]=[]
    var networkError:URLError?
    init(_ responses:[(Int,Data,[String:String])]){self.responses=responses}
    func send(_ request:URLRequest) async throws -> (Data,HTTPURLResponse) {
        requests.append(request)
        if let e=networkError{throw e}
        guard !responses.isEmpty else{throw CheckFailure(description:"没有更多测试响应")}
        let item=responses.removeFirst()
        return(item.1,HTTPURLResponse(url:request.url!,statusCode:item.0,httpVersion:"HTTP/1.1",headerFields:item.2)!)
    }
}
func envelope(_ blocks:[[String:Any]],blank:Bool=false,finish:String="stop",model:String?="test-vision-returned") throws -> Data {
    let page:[String:Any]=["blank":blank,"printed_page_label":"viii","blocks":blocks]
    let content=String(data:try JSONSerialization.data(withJSONObject:page),encoding:.utf8)!
    var object:[String:Any]=["choices":[["finish_reason":finish,"message":["content":content]]],"usage":["prompt_tokens":12,"completion_tokens":34]]
    if let model=model{object["model"]=model}
    return try JSONSerialization.data(withJSONObject:object)
}
func textBlock(_ text:String="Original ɑ̃ 語",box:[Double]=[0.1,0.1,0.9,0.3])->[String:Any]{["kind":"paragraph","order":1,"bbox":box,"text":text,"runs":[],"cells":[]]}

func runScenarios(root:URL) throws -> [(String,Bool,String)] {
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    var results:[(String,Bool,String)]=[]
    func check(_ name:String,_ body:() throws->Void){do{try body();results.append((name,true,""));print("PASS \(name)")}catch{results.append((name,false,error.localizedDescription+" "+String(describing:error)));print("FAIL \(name): \(error)")}}
    check("页范围去重与排序"){try require(try PageRange.parse("3,1-2,2",count:5)==[0,1,2])}
    check("空范围选择全部"){try require(try PageRange.parse("",count:3)==[0,1,2])}
    check("中文逗号页范围"){try require(try PageRange.parse("1，3",count:4)==[0,2])}
    check("拒绝倒序与越界范围"){for s in ["0","1-8","3-1","x","1,,2"]{try mustThrow{_ = try PageRange.parse(s,count:5)}}}
    check("拒绝非有限或越界坐标"){try require(!Box(.nan,0,0.2,0.2).isValid);try require(!Box(0.9,0,0.2,0.2).isValid);try require(Box(0,0,1,1).isValid)}
    check("坐标由顶端归一化转换为PDF原点"){let r=Box(0.1,0.2,0.3,0.4).rect(in:CGSize(width:100,height:200));try require(abs(r.minY-80)<0.001)}
    check("API基地址保留版本与去除重复路由"){var c=ProviderConfiguration();c.baseURL="https://example.invalid/v1/chat/completions";try require(try c.endpoint("models").absoluteString=="https://example.invalid/v1/models")}
    check("拒绝明文远端与带凭据URL"){for s in ["http://example.invalid/v1","https://user:secret@example.invalid/v1","https://example.invalid/v1?key=secret"]{var c=ProviderConfiguration();c.baseURL=s;try mustThrow{_ = try c.endpoint("models")}}}
    check("允许本机HTTP接口"){var c=ProviderConfiguration();c.baseURL="http://127.0.0.1:12345/v1";try require(try c.endpoint("models").host=="127.0.0.1")}
    check("逐页保留请求与返回模型差别"){let r=try OCRParser.parse(envelope([textBlock()]),pageID:"p1");try require(r.returnedModel=="test-vision-returned" && r.promptTokens==12);try require(r.blocks[0].rawText=="Original ɑ̃ 語")}
    check("返回模型未知时保持空值"){let r=try OCRParser.parse(envelope([textBlock()],model:nil),pageID:"p1");try require(r.returnedModel==nil)}
    check("截断输出不能成功"){try mustThrow{_ = try OCRParser.parse(envelope([textBlock()],finish:"length"),pageID:"p1")}}
    check("拒绝坏坐标与未知区域类型"){try mustThrow{_ = try OCRParser.parse(envelope([textBlock(box:[0.2,0.2,1.2,0.4])]),pageID:"p1")};var b=textBlock();b["kind"]="unknown";try mustThrow{_ = try OCRParser.parse(envelope([b]),pageID:"p1")}}
    check("拒绝空成功与空文字块"){try mustThrow{_ = try OCRParser.parse(envelope([]),pageID:"p1")};try mustThrow{_ = try OCRParser.parse(envelope([textBlock("")]),pageID:"p1")}}
    check("空白判定保留人工确认问题"){let r=try OCRParser.parse(envelope([],blank:true),pageID:"p1");try require(r.blankCandidate && r.issues.contains{$0.code=="blank-candidate"})}
    check("疑难附标保留标记"){let r=try OCRParser.parse(envelope([textBlock("d⟦?⟧i")]),pageID:"p1");try require(r.blocks[0].rawText.contains("⟦?⟧") && !r.issues.isEmpty)}
    check("样式片段必须与原文完全相同"){var b=textBlock("H2O");b["runs"]=[["text":"H"],["text":"2","script":-1],["text":"O"]];let r=try OCRParser.parse(envelope([b]),pageID:"p1");try require(r.blocks[0].runs[1].style.script == -1);b["runs"]=[["text":"water"]];try mustThrow{_ = try OCRParser.parse(envelope([b]),pageID:"p1")}}
    check("表格合并关系不能重叠"){let cell:[String:Any]=["row":0,"column":0,"row_span":2,"column_span":1,"text":"A"];let b:[String:Any]=["kind":"table","order":1,"bbox":[0.1,0.1,0.9,0.9],"cells":[cell,cell]];try mustThrow{_ = try OCRParser.parse(envelope([b]),pageID:"p1")}}
    check("表格单元格不能超出表格"){let b:[String:Any]=["kind":"table","order":1,"bbox":[0.1,0.1,0.9,0.9],"cells":[["row":0,"column":0,"text":"A","bbox":[0.0,0.0,0.2,0.2]]]];try mustThrow{_ = try OCRParser.parse(envelope([b]),pageID:"p1")}}
    check("拒绝重复阅读顺序"){try mustThrow{_ = try OCRParser.parse(envelope([textBlock(),textBlock()]),pageID:"p1")}}
    check("缓存随图像和模型变化"){var c=ProviderConfiguration();c.baseURL="https://example.invalid/v1";c.model="a";var p=Page(sourcePage:1,width:100,height:100,imageSHA256:"hash-a");let a=try CompatibleVisionBackend(config:c,key:"").cacheKey(page:p);p.imageSHA256="hash-b";try require(a != (try CompatibleVisionBackend(config:c,key:"").cacheKey(page:p)));p.imageSHA256="hash-a";c.model="b";try require(a != (try CompatibleVisionBackend(config:c,key:"").cacheKey(page:p)))}
    check("项目保存恢复与原始转写不被覆盖"){let s=try ProjectStore(root:root.appendingPathComponent("resume.shiyebook"));var d=Fixtures.document();let raw=d.pages[0].blocks[2].rawText;try s.save(d);d.pages[0].blocks[2].reviewedText="User correction";try s.save(d);let loaded=try s.load();try require(loaded.pages[0].blocks[2].rawText==raw && loaded.pages[0].blocks[2].reviewedText=="User correction");try require(FileManager.default.fileExists(atPath:s.root.appendingPathComponent("document.previous.json").path))}
    check("拒绝项目目录越界和符号链接"){let s=try ProjectStore(root:root.appendingPathComponent("paths.shiyebook"));try mustThrow{_ = try s.url("../secret")};try FileManager.default.createSymbolicLink(at:s.root.appendingPathComponent("outside"),withDestinationURL:root);try mustThrow{_ = try s.url("outside/secret")}}
    check("排版样张Unicode文字完整复制"){let output=root.appendingPathComponent("known.pdf"),r=try PDFRenderer.render(document:Fixtures.document(),store:nil,to:output);try require(!r.draft && r.issueCount==0 && r.textMismatches.isEmpty);let text=PDFDocument(url:output)!.string!;try require(text.contains("ɑ̃") && text.contains("繁體") && text.contains("H2O"))}
    check("正文溢出不能靠无限缩小掩盖"){var p=Page(sourcePage:1,width:300,height:300);p.blocks=[Block(id:"overflow",box:Box(0.1,0.1,0.1,0.03),text:String(repeating:"Long original text ",count:30),fontSize:12)];let r=PDFRenderer.diagnostics(page:p,chineseFont:"Songti TC");try require(r.issues.contains{$0.code=="overflow"});try require((r.fittedFontSizes["overflow"] ?? 0)>=10.8)}
    check("缺字方框必须被检测"){var p=Page(sourcePage:1,width:300,height:300);p.blocks=[Block(box:Box(0.1,0.1,0.8,0.6),text:"Unknown \u{0378}",fontSize:12)];try require(PDFRenderer.diagnostics(page:p,chineseFont:"Songti TC").issues.contains{$0.code=="missing-glyph"})}
    check("非BMP与组合字符保留Unicode序列"){let text="𠀀 ɑ\u{0303} n\u{0329}";var b=Block(text:text);b.reviewedText="𠀀 ɑ\u{0303} n\u{0329}";let data=try JSONEncoder().encode(b),decoded=try JSONDecoder().decode(Block.self,from:data);try require(Array(decoded.rawText.unicodeScalars)==Array(text.unicodeScalars))}
    check("区域重叠被检测"){var p=Page(sourcePage:1,width:300,height:300);p.blocks=[Block(order:1,text:"A"),Block(order:2,text:"B")];try require(PDFRenderer.diagnostics(page:p,chineseFont:"Songti TC").issues.contains{$0.code=="overlap"})}
    check("未识别页面明确为校对稿"){var d=BookDocument(title:"Incomplete");d.pages=[Page(sourcePage:1,width:300,height:300)];let r=try PDFRenderer.render(document:d,store:nil,to:root.appendingPathComponent("incomplete.pdf"));try require(r.draft && r.issueCount>0)}
    check("确认空白页保留页数"){var d=BookDocument(title:"Blank");var p=Page(sourcePage:2,width:300,height:400);p.status = .blank;d.pages=[p];let u=root.appendingPathComponent("blank.pdf"),r=try PDFRenderer.render(document:d,store:nil,to:u);try require(!r.draft && PDFDocument(url:u)?.pageCount==1)}
    check("空文字区域不能完成"){var p=Page(sourcePage:1,width:300,height:300);p.blocks=[Block(text:"")];try require(PDFRenderer.diagnostics(page:p,chineseFont:"Songti TC").issues.contains{$0.code=="empty-text"})}
    check("正文不能以图片冒充文字化"){var p=Page(sourcePage:1,width:300,height:300);var b=Block(text:"body");b.retainImage=true;p.blocks=[b];try require(PDFRenderer.diagnostics(page:p,chineseFont:"Songti TC").issues.contains{$0.code=="invalid-retention"})}
    check("PDF导入文字层只是待核对候选"){let s=try ProjectStore(root:root.appendingPathComponent("text-import.shiyebook"));var d=BookDocument(title:"Text import");let source=root.appendingPathComponent("known.pdf"),before=try Digest.file(source);try PageImporter.append(urls:[source],to:&d,store:s);try require(d.pages.count==1 && d.pages[0].status == .imported && !d.pages[0].hints.isEmpty);try require(try Digest.file(source)==before)}
    check("旋转页保持正向尺寸"){let source=root.appendingPathComponent("known.pdf"),rotated=root.appendingPathComponent("rotated.pdf");let pdf=PDFDocument(url:source)!;pdf.page(at:0)!.rotation=90;try require(pdf.write(to:rotated));var d=BookDocument(title:"Rotated");let s=try ProjectStore(root:root.appendingPathComponent("rotated.shiyebook"));try PageImporter.append(urls:[rotated],to:&d,store:s);try require(d.pages[0].sourceRotation==90 && d.pages[0].width>d.pages[0].height)}
    check("多页TIFF逐帧导入"){let image=PageImporter.bitmap(width:200,height:300)!.makeImage()!,url=root.appendingPathComponent("multi.tiff");let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.tiff.identifier as CFString,2,nil)!;CGImageDestinationAddImage(dest,image,nil);CGImageDestinationAddImage(dest,image,nil);try require(CGImageDestinationFinalize(dest));var d=BookDocument(title:"TIFF");let s=try ProjectStore(root:root.appendingPathComponent("tiff.shiyebook"));try PageImporter.append(urls:[url],to:&d,store:s);try require(d.pages.count==2 && d.pages[1].sourcePage==2)}
    check("JPEG的EXIF旋转在导入时归一化"){let image=PageImporter.bitmap(width:200,height:300)!.makeImage()!,url=root.appendingPathComponent("oriented.jpg");let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.jpeg.identifier as CFString,1,nil)!;CGImageDestinationAddImage(dest,image,[kCGImagePropertyOrientation:6] as CFDictionary);try require(CGImageDestinationFinalize(dest));var d=BookDocument(title:"EXIF");let s=try ProjectStore(root:root.appendingPathComponent("exif.shiyebook"));try PageImporter.append(urls:[url],to:&d,store:s);try require(d.pages[0].width>d.pages[0].height);let read=try PageImporter.image(page:d.pages[0],store:s);try require(read.width>read.height)}
    check("HTTP429遵守RetryAfter并复用请求"){var c=ProviderConfiguration();c.baseURL="https://example.invalid/v1";let stub=StubTransport([(429,Data(),["Retry-After":"0"]),(200,Data("{\"data\":[{\"id\":\"vision\"}]}".utf8),[:])]);let backend=CompatibleVisionBackend(config:c,key:"test-secret",transport:stub,sleep:{_ in});let names=try awaitResult{try await backend.models()};try require(names==["vision"] && stub.requests.count==2)}
    check("HTTP401直接失败且不回显密钥"){var c=ProviderConfiguration();c.baseURL="https://example.invalid/v1";let stub=StubTransport([(401,Data("test-secret".utf8),[:])]);let backend=CompatibleVisionBackend(config:c,key:"test-secret",transport:stub,sleep:{_ in});do{_ = try awaitResult{try await backend.models()};throw CheckFailure(description:"鉴权不应成功")}catch{try require(!error.localizedDescription.contains("test-secret"))};try require(stub.requests.count==1)}
    check("HTTP402余额不足不重试"){var c=ProviderConfiguration();c.baseURL="https://example.invalid/v1";let stub=StubTransport([(402,Data(),[:])]);let backend=CompatibleVisionBackend(config:c,key:"",transport:stub,sleep:{_ in});try mustThrow{_ = try awaitResult{try await backend.models()}};try require(stub.requests.count==1)}
    check("502重试有明确上限"){var c=ProviderConfiguration();c.baseURL="https://example.invalid/v1";let stub=StubTransport(Array(repeating:(502,Data(),[:]),count:4));let backend=CompatibleVisionBackend(config:c,key:"",transport:stub,sleep:{_ in});try mustThrow{_ = try awaitResult{try await backend.models()}};try require(stub.requests.count==4)}
    check("超时与断网有限重试"){for code in [URLError.Code.timedOut,.notConnectedToInternet]{var c=ProviderConfiguration();c.baseURL="https://example.invalid/v1";let stub=StubTransport([]);stub.networkError=URLError(code);let backend=CompatibleVisionBackend(config:c,key:"",transport:stub,sleep:{_ in});try mustThrow{_ = try awaitResult{try await backend.models()}};try require(stub.requests.count==4)}}
    check("取消不会继续重试"){var c=ProviderConfiguration();c.baseURL="https://example.invalid/v1";let stub=StubTransport([]);stub.networkError=URLError(.cancelled);let backend=CompatibleVisionBackend(config:c,key:"",transport:stub,sleep:{_ in});try mustThrow{_ = try awaitResult{try await backend.models()}};try require(stub.requests.count==1)}
    check("RetryAfter日期与超长等待"){let date=Date(timeIntervalSince1970:0),response=HTTPURLResponse(url:URL(string:"https://example.invalid")!,statusCode:429,httpVersion:nil,headerFields:["Retry-After":"Thu, 01 Jan 1970 00:00:30 GMT"])!;try require(CompatibleVisionBackend.retryDelay(response,attempt:0,now:date)==30)}
    check("图像请求格式与密钥隔离"){var c=ProviderConfiguration();c.baseURL="https://example.invalid/v1";c.model="vision";let stub=StubTransport([(200,try envelope([textBlock()]),[:])]);let backend=CompatibleVisionBackend(config:c,key:"test-secret",transport:stub);let image=PageImporter.bitmap(width:100,height:200)!.makeImage()!;let page=Page(id:"p",sourcePage:1,width:100,height:200);_ = try awaitResult{try await backend.recognize(image:image,page:page,region:nil,status:{_ in})};let req=stub.requests[0];let body=try JSONSerialization.jsonObject(with:req.httpBody!) as! [String:Any];try require(req.value(forHTTPHeaderField:"Authorization")=="Bearer test-secret");try require(!String(data:req.httpBody!,encoding:.utf8)!.contains("test-secret"));let messages=body["messages"] as! [[String:Any]],parts=messages[0]["content"] as! [[String:Any]],url=(parts[1]["image_url"] as! [String:Any])["url"] as! String;try require(url.hasPrefix("data:image/jpeg;base64,"))}
    check("局部识别坐标返回到原页"){var c=ProviderConfiguration();c.baseURL="https://example.invalid/v1";c.model="vision";let stub=StubTransport([(200,try envelope([textBlock(box:[0,0,1,1])]),[:])]);let backend=CompatibleVisionBackend(config:c,key:"",transport:stub),image=PageImporter.bitmap(width:100,height:200)!.makeImage()!,page=Page(id:"p",sourcePage:1,width:100,height:200),region=Box(0.2,0.3,0.4,0.2);let r=try awaitResult{try await backend.recognize(image:image,page:page,region:region,status:{_ in})};try require(r.blocks[0].box==region)}
    check("系统临时目录别名下可创建预览文件"){
        for prefix in ["/private/tmp","/tmp"] {
            let temp=URL(fileURLWithPath:prefix).appendingPathComponent("shiye-path-check-"+UUID().uuidString+".shiyebook")
            defer {try? FileManager.default.removeItem(at:temp)}
            let s=try ProjectStore(root:temp),dir=try s.url("preview"),file=try s.url("preview/page.txt")
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            try Data("原文".utf8).write(to:file)
            try require(try Data(contentsOf:s.url("preview/page.txt"))==Data("原文".utf8))
            try mustThrow{_ = try s.url("../outside")}
        }
    }
    check("项目JSON不包含API密钥"){let bytes=try JSONEncoder().encode(Fixtures.document());try require(!String(data:bytes,encoding:.utf8)!.contains("api_key"));try require(KeychainStore.service != "PaperStudio")}
    return results
}
