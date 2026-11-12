import Foundation
import PageArchiveCore

private func agentBlock(_ text:String,kind:String="paragraph",bbox:[Double]=[0.1,0.15,0.8,0.25],
                        noteID:String?=nil,refs:[String]=[])->[String:Any] {
    ["kind":kind,"column":"full","bbox":bbox,"text":text,"alignment":"left","runs":[[String:Any]](),"cells":[[String:Any]](),
     "note_id":noteID as Any? ?? NSNull(),"note_refs":refs,"uncertainty":NSNull()]
}
private func agentReply(_ blocks:[[String:Any]],route:OCRAgentRoute = .responses) throws -> Data {
    let page:[String:Any]=["layout":"single_column","printed_page_label":NSNull(),"blank":false,
                           "starts_mid_paragraph":false,"ends_mid_paragraph":false,"blocks":blocks]
    let text=String(decoding:try JSONSerialization.data(withJSONObject:page),as:UTF8.self)
    let usage = route == .responses ? ["input_tokens":20,"output_tokens":10] : ["prompt_tokens":20,"completion_tokens":10]
    let data:[String:Any]
    if route == .responses {
        let part:[String:Any]=["type":"output_text","text":text]
        let message:[String:Any]=["type":"message","content":[part]]
        data=["status":"completed","model":"fixture-vision","output":[message],"usage":usage]
    } else {
        data=["choices":[["finish_reason":"stop","message":["content":text]] as [String:Any]],"model":"fixture-vision","usage":usage]
    }
    return try JSONSerialization.data(withJSONObject:data)
}

func runOCRAgentScenarios(root:URL)throws->[(String,Bool,String)] {
    var checks:[(String,Bool,String)]=[]
    func check(_ name:String,_ run:()throws->Void) {
        do{try run();checks.append((name,true,""));print("PASS \(name)")}
        catch{checks.append((name,false,String(describing:error)));print("FAIL \(name): \(error)")}
    }
    let page=Page(id:"agent-page",sourcePage:1,width:300,height:420,imageSHA256:"image")
    let image=PageImporter.bitmap(width:300,height:420)!.makeImage()!
    let paragraph=agentBlock("採錄標音¹",refs:["1"])
    let footnote=agentBlock("1. 原稿附記",kind:"footnote",bbox:[0.1,0.84,0.7,0.88],noteID:"1")
    let evidence=[TextHint(box:Box(0.11,0.16,0.50,0.04),text:"採錄標音¹",confidence:1),
                  TextHint(box:Box(0.11,0.845,0.40,0.02),text:"1. 原稿附記",confidence:0.5)]
    var config=ProviderConfiguration();config.baseURL="https://api.openai.com/v1";config.model="vision"
    config.maxOutputTokens=4096
    let skill=try OCRSkill(name:"测试",text:"本轮策略：逐字保存聲調。")
    func agent(_ stub:StubTransport,_ configuration:ProviderConfiguration?=nil)->OCRAgent {
        OCRAgent(backend:CompatibleVisionBackend(config:configuration ?? config,key:"fixture-token",transport:stub,sleep:{_ in}),
                 skill:skill,detectLines:{_ in evidence})
    }
    check("OCR Agent 安装包模板和版本化缓存") {
        try require(try OCRSkill.bundled().text.contains("腳注") || OCRSkill.bundled().text.contains("脚注"))
        try mustThrow{_ = try OCRSkill(name:"空白",text:" ")}
        let first=agent(StubTransport([]))
        let changed=OCRAgent(backend:first.backend,skill:try OCRSkill(name:skill.name,text:skill.text+" 加入新策略"))
        try require(try first.cacheKey(for:page) != changed.cacheKey(for:page))
    }
    check("OCR Agent 查漏、裁切重读、用量和复原") {
        let stub=StubTransport([(200,try agentReply([paragraph]),["x-request-id":"first"]),
                                (200,try agentReply([paragraph,footnote]),["x-request-id":"second"])])
        let backend=agent(stub)
        let result=try awaitResult{try await backend.recognize(image:image,page:page,status:{_ in})}
        try require(result.audit.selectedAttempt==2 && result.audit.cacheable)
        try require(result.audit.attempts[0].issues.contains{$0.code=="agent-uncovered" && $0.box != nil})
        try require(result.audit.attempts[1].cropBoxes.contains{$0.y>0.8})
        try require(result.result.blocks.map(\.kind)==[.paragraph,.footnote])
        try require(result.result.blocks[0].noteReferences==["1"] && result.result.blocks[1].noteID=="1")
        try require(result.promptTokens==40 && result.completionTokens==20)
        let restored=try backend.restore(result.audit.encoded(),page:page)
        try require(restored.result.blocks.map(\.rawText)==result.result.blocks.map(\.rawText))
        let request=stub.requests[0]
        let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        try require(request.url?.path=="/v1/responses")
        try require((body["instructions"] as? String)?.contains(skill.text)==true && body["store"] as? Bool==false)
        try require(request.value(forHTTPHeaderField:"Authorization")=="Bearer fixture-token")
        try require(!String(decoding:request.httpBody!,as:UTF8.self).contains("fixture-token"))
        let format=(body["text"] as? [String:Any])?["format"] as? [String:Any]
        try require(format?["strict"] as? Bool==true && format?["type"] as? String=="json_schema")
    }
    check("OCR Agent 重读服务失败保留首稿") {
        let stub=StubTransport([(200,try agentReply([paragraph]),[:]),(401,Data(),[:])])
        let backend=agent(stub)
        let result=try awaitResult{try await backend.recognize(image:image,page:page,status:{_ in})}
        try require(result.audit.selectedAttempt==1 && !result.audit.cacheable && stub.requests.count==2)
        try require(result.result.issues.contains{$0.code=="agent-reread-failed"})
    }
    check("OCR Agent 首轮鉴权失败记录诊断并停止") {
        let stub=StubTransport([(401,Data(),[:])]),backend=agent(stub)
        do {
            _ = try awaitResult{try await backend.recognize(image:image,page:page,status:{_ in})}
            throw CheckFailure(description:"鉴权失败被当成成功")
        } catch let error as OCRAgentFailure {
            let failure=PageWorkFailure.classify(error)
            try require(failure.kind == .provider && stub.requests.count==1)
            let audit=try JSONDecoder().decode(OCRAgentAudit.self,from:failure.auditData!)
            try require(audit.selectedAttempt==nil && audit.attempts[0].httpStatuses==[401])
        }
    }
    check("OCR Agent 截断后加预算重读") {
        let cut=Data(#"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}"#.utf8)
        let stub=StubTransport([(200,cut,[:]),(200,try agentReply([paragraph,footnote]),[:])]),backend=agent(stub)
        let result=try awaitResult{try await backend.recognize(image:image,page:page,status:{_ in})}
        try require(result.audit.selectedAttempt==2 && result.audit.attempts.map(\.outputTokenLimit)==[4096,8192])
    }
    check("OCR Agent 保留兼容接口和局部坐标映射") {
        var compatible=config;compatible.baseURL="https://example.invalid/vision/v1";compatible.useJSONMode=true
        let region=Box(0.2,0.3,0.4,0.2)
        let reply=try agentReply([agentBlock("区块",bbox:[0,0,1,1])],route:.chatCompletions)
        let stub=StubTransport([(200,reply,[:])])
        let backend=agent(stub,compatible).backend
        let result=try awaitResult{try await backend.recognizeAgentRegion(image:image,page:page,region:region,skill:skill,status:{_ in})}
        try require(result.blocks[0].box==region && stub.requests[0].url?.path=="/vision/v1/chat/completions")
        let body=try JSONSerialization.jsonObject(with:stub.requests[0].httpBody!) as! [String:Any]
        try require((body["response_format"] as? [String:String])?["type"]=="json_object")
    }
    check("Markdown 仅续接确认过且相邻的段落") {
        var left=page,right=Page(id:"next",sourcePage:2,width:300,height:420)
        left.blocks=[Block(id:"tail",text:"未完的段落，"),Block(id:"foot",kind:.footnote,order:2,text:"1. 小注")]
        right.blocks=[Block(id:"head",text:"接着读。")]
        left.textContinuation=TextContinuation(nextPageID:right.id,tailBlockID:"tail",headBlockID:"head",separator:.none)
        var book=BookDocument(title:"段落");book.pages=[left,right]
        let path=root.appendingPathComponent("agent-continuation.md")
        try EditableBookExporter.exportMarkdown(document:book,pages:[0,1],to:path)
        let joined=try String(contentsOf:path,encoding:.utf8)
        try require(joined.contains("未完的段落，接着读。") && joined.contains("小注"))
        book.pages[1].blocks[0].id="replacement"
        try EditableBookExporter.exportMarkdown(document:book,pages:[0,1],to:path)
        let separate=try String(contentsOf:path,encoding:.utf8)
        try require(separate.contains("未完的段落，\n\n接着读。"))
    }
    check("旧项目可解码新增的可选 OCR 字段") {
        let before=Fixtures.document()
        let data=try JSONEncoder().encode(before)
        let after=try JSONDecoder().decode(BookDocument.self,from:data)
        try require(after.pages[0].ocrStructure==nil && after.pages[0].textContinuation==nil)
        try require(after.pages[0].blocks[0].ocrColumn==nil)
    }
    return checks
}
