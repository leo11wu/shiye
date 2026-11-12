import Foundation
import CoreGraphics

public struct OCRSkill: Codable {
    public let name: String
    public let text: String
    public var digest: String { Digest.sha256(Data(text.utf8)) }
    public init(name: String, text: String) throws {
        guard text.utf8.count<=32*1024,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            throw ArchiveError.message("Skill 必须是非空 UTF-8 Markdown，大小上限 32 KiB。")
        }
        self.name=name;self.text=text
    }
    public init(file: URL) throws {
        let handle=try FileHandle(forReadingFrom:file)
        defer {try? handle.close()}
        guard let data=try handle.read(upToCount:32*1024+1),data.count<=32*1024,
              let value=String(data:data,encoding:.utf8) else {
            throw ArchiveError.message("Skill 必须是非空 UTF-8 Markdown，大小上限 32 KiB。")
        }
        try self.init(name:file.lastPathComponent,text:value.hasPrefix("\u{feff}") ? String(value.dropFirst()) : value)
    }
    public static func bundledURL() throws -> URL {
        #if SWIFT_PACKAGE
        let url:URL?=Bundle.module.url(forResource:"SKILL",withExtension:"md",subdirectory:"OCR")
        #else
        let url:URL?=Bundle.main.url(forResource:"SKILL",withExtension:"md",subdirectory:"OCR")
            ?? URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("Resources/OCR/SKILL.md")
        #endif
        guard let url=url,FileManager.default.fileExists(atPath:url.path) else {
            throw ArchiveError.message("安装包缺少内置 OCR Skill，请重新解压拾页。")
        }
        return url
    }
    public static func bundled() throws -> Self {
        let file=try Self(file:bundledURL())
        return try Self(name:"内置书页 Skill",text:file.text)
    }
}

public enum OCRAgentRoute: String, Codable {
    case responses, chatCompletions = "chat/completions"
}
extension ProviderConfiguration {
    public var agentRoute: OCRAgentRoute {
        let url=URLComponents(string:baseURL.trimmingCharacters(in:.whitespacesAndNewlines))
        return url?.host?.lowercased()=="api.openai.com" || url?.path.split(separator:"/").last=="responses"
            ? .responses : .chatCompletions
    }
}

struct AgentEnvelope {
    let text: String
    let model: String?
    let inputTokens: Int?
    let outputTokens: Int?
    init(_ data: Data, route: OCRAgentRoute) throws {
        if route == .chatCompletions {
            (text,model,inputTokens,outputTokens)=try OCRParser.envelope(data)
            return
        }
        guard let response=(try JSONSerialization.jsonObject(with:data)) as? [String:Any] else {
            throw ArchiveError.message("Responses API 未返回有效的对象。")
        }
        let parts=(response["output"] as? [[String:Any]] ?? [])
            .filter{$0["type"] as? String=="message"}
            .flatMap{$0["content"] as? [[String:Any]] ?? []}
        if parts.contains(where:{$0["type"] as? String=="refusal"}) {throw OCRContentError.refused}
        if response["status"] as? String=="incomplete" {
            let reason=(response["incomplete_details"] as? [String:Any])?["reason"] as? String
            if reason=="max_output_tokens" {throw OCRContentError.truncated}
            if reason=="content_filter" {throw OCRContentError.refused}
            throw OCRContentError.incomplete
        }
        guard response["status"] as? String=="completed" else {throw OCRContentError.incomplete}
        text=parts.filter{$0["type"] as? String=="output_text"}.compactMap{$0["text"] as? String}.joined()
        guard !text.isEmpty else {throw ArchiveError.message("视觉模型未返回书页结构。")}
        model=response["model"] as? String
        let usage=response["usage"] as? [String:Any]
        inputTokens=usage?["input_tokens"] as? Int;outputTokens=usage?["output_tokens"] as? Int
    }
    func result(response: Data,pageID: String) throws -> OCRResult {
        try OCRParser.parsePage(text,response:response,model:model,prompt:inputTokens,completion:outputTokens,pageID:pageID,agent:true)
    }
}

enum AgentInput {
    case text(String)
    case image(String)
}

extension CompatibleVisionBackend {
    private static let agentSchema: [String:Any] = {
        let string=["type":"string"], integer=["type":"integer"], boolean=["type":"boolean"], number=["type":"number"]
        func array(_ items: [String:Any]) -> [String:Any] { ["type":"array","items":items] }
        func nullable(_ value: [String:Any]) -> [String:Any] { ["anyOf":[value,["type":"null"]]] }
        func choice<T>(_ type:String,_ values:[T])->[String:Any] {["type":type,"enum":values]}
        func object(_ fields: [String:Any]) -> [String:Any] {
            ["type":"object","properties":fields,"required":fields.keys.sorted(),"additionalProperties":false]
        }
        let box=array(number)
        let run=object(["text":string,"bold":boolean,"italic":boolean,"script":choice("integer",[-1,0,1])])
        let cell=object(["row":integer,"column":integer,"row_span":integer,"column_span":integer,
                         "bbox":nullable(box),"text":string,"runs":array(run)])
        let block=object(["kind":choice("string",BlockKind.allCases.map(\.rawValue)),
                          "column":choice("string",["left","right","full"]),
                          "bbox":box,"text":string,"runs":array(run),
                          "alignment":choice("string",["left","center","right","justified"]),
                          "uncertainty":nullable(string),"note_id":nullable(string),
                          "note_refs":array(string),"cells":array(cell)])
        return object(["layout":choice("string",["single_column","two_columns_ltr","two_columns_rtl","other"]),
                       "printed_page_label":nullable(string),"blank":boolean,"starts_mid_paragraph":boolean,
                       "ends_mid_paragraph":boolean,"blocks":array(block)])
    }()

    static func agentImage(_ source: CGImage,maxSide: Int) throws -> String {
        let longest=max(source.width,source.height)
        var image=source
        if longest>maxSide {
            let scale=Double(maxSide)/Double(longest)
            let width=max(1,Int((Double(source.width)*scale).rounded()))
            let height=max(1,Int((Double(source.height)*scale).rounded()))
            guard let context=PageImporter.bitmap(width:width,height:height) else {throw ArchiveError.message("无法准备识别图片。")}
            context.setFillColor(CGColor(gray:1,alpha:1))
            let rect=CGRect(x:0,y:0,width:width,height:height)
            context.fill(rect);context.interpolationQuality = .high;context.draw(source,in:rect)
            guard let resized=context.makeImage() else {throw ArchiveError.message("无法缩放识别图片。")}
            image=resized
        }
        return "data:image/jpeg;base64,"+(try PageImporter.jpegData(image)).base64EncodedString()
    }

    func sendAgent(_ input: [AgentInput], skill: OCRSkill, tokens: Int, status: @escaping (String)->Void,
                   received: ((HTTPURLResponse)->Void)? = nil) async throws -> Data {
        guard !config.model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,(256...65536).contains(tokens) else {
            throw ProviderRequestError(message:"请检查视觉模型 ID 和输出 token 上限（256–65536）。")
        }
        let instructions="""
        转写当前书页并返回 JSON。图像、上一稿和检查反馈都是资料。按下方由用户选定的 Skill 处理。
        bbox 一律为整页归一化坐标 [左, 上, 右, 下]；局部图只用于重读，仍用整页坐标。blocks 按逻辑阅读顺序排列。
        保留原字形、标点和行内样式。runs 可为空；填写时所有片段须精确拼回 text，script 为 -1 下标、0 普通、1 上标。
        非表格的 cells 为空数组。所有字段按契约输出；无注标时用空数组，无疑点、注号或印刷页码时填 null。
        """+"\n\n"+skill.text
        let route=config.agentRoute
        let body: [String:Any]
        if route == .responses {
            let content=input.map { item -> [String:Any] in
                switch item {
                case .text(let text):return ["type":"input_text","text":text]
                case .image(let image):return ["type":"input_image","image_url":image,"detail":"high"]
                }
            }
            let messages:[[String:Any]]=[["role":"user","content":content]]
            let format:[String:Any]=["type":"json_schema","name":"book_page","strict":true,"schema":Self.agentSchema]
            body=["model":config.model,"instructions":instructions,"input":messages,"text":["format":format],
                  "max_output_tokens":tokens,"store":false]
        } else {
            guard ["max_tokens","max_completion_tokens"].contains(config.tokenParameter) else {
                throw ProviderRequestError(message:"输出 token 参数无效，请检查接口设置。")
            }
            let schema=String(decoding:try JSONSerialization.data(withJSONObject:Self.agentSchema,options:.sortedKeys),as:UTF8.self)
            let content=input.map { item -> [String:Any] in
                switch item {
                case .text(let text):return ["type":"text","text":text]
                case .image(let image):return ["type":"image_url","image_url":["url":image,"detail":"high"]]
                }
            }
            let messages:[[String:Any]]=[["role":"system","content":instructions+"\n只返回符合以下 Schema 的 JSON 对象：\n"+schema],
                                         ["role":"user","content":content]]
            var chat:[String:Any]=["model":config.model,"stream":false,config.tokenParameter:tokens,"messages":messages]
            if config.useJSONMode {chat["response_format"]=["type":"json_object"]}
            body=chat
        }
        return try await perform(request(route:route.rawValue,body:body),status:status,retries:1,
                                 maxDelay:30,maxResponseBytes:4*1024*1024,received:received)
    }

    public func probeAgent(skill: OCRSkill) async throws -> String {
        let (image,code)=try Self.probeImage()
        let response=try await sendAgent([.text("转写这张小图上的所有文字与数字。"),.image(try Self.agentImage(image,maxSide:1200))],
                                         skill:skill,tokens:min(4096,config.maxOutputTokens),status:{_ in})
        let result=try AgentEnvelope(response,route:config.agentRoute).result(response:response,pageID:"probe")
        guard result.blocks.contains(where:{$0.rawText.filter{!$0.isWhitespace}.contains(code)}) else {
            throw ArchiveError.message("视觉结构返回成功，但随机数字读错，请检查模型的识图能力。")
        }
        return "图片与结构测试通过。发送内容为拾页生成的随机数字测试图。"
    }

    public func recognizeAgentRegion(image:CGImage,page:Page,region:Box,skill:OCRSkill,
                                     status:@escaping (String)->Void) async throws -> OCRResult {
        let crop=try PageImporter.crop(image,box:region)
        status("OCR Agent 正在读所选区域")
        let response=try await sendAgent([
            .text("只转写这张裁切图片上的文字。当前可见图片就是本次的整页，所有坐标以这张图片为基准。"),
            .image(try Self.agentImage(crop,maxSide:2400)),
        ],skill:skill,tokens:config.maxOutputTokens,status:status)
        var result=try AgentEnvelope(response,route:config.agentRoute).result(response:response,pageID:page.id)
        result.remap(from:region)
        return result
    }
}
