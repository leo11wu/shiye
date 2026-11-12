import Foundation
import CoreGraphics

public struct OCRAgentAttempt: Codable {
    public let number: Int
    public let cropBoxes: [Box]
    public let outputTokenLimit: Int
    public var httpStatuses: [Int] = []
    public var requestIDs: [String] = []
    public var response: Data?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var coveredLineNumbers: [Int] = []
    public var issues: [ReviewIssue] = []
    public var error: String?
    public var seconds: Double = 0
}

public struct OCRAgentAudit: Codable {
    public let version: String
    public let pageID: String
    public let imageHash: String
    public let skillName: String
    public let skillHash: String
    public let route: OCRAgentRoute
    public let requestedModel: String
    public var witnessError: String?
    public var evidence: [TextHint] = []
    public var attempts: [OCRAgentAttempt] = []
    public var selectedAttempt: Int?
    public var issues: [ReviewIssue] = []
    public var cacheable = false
    public var seconds: Double = 0

    public func encoded() throws -> Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        return try encoder.encode(self)
    }
}

public struct OCRAgentOutcome {
    public let result: OCRResult
    public let audit: OCRAgentAudit
    public var promptTokens: Int? { total(audit.attempts.compactMap(\.inputTokens)) }
    public var completionTokens: Int? { total(audit.attempts.compactMap(\.outputTokens)) }
    private func total(_ values: [Int]) -> Int? { values.isEmpty ? nil : values.reduce(0,+) }
}

public struct OCRAgentFailure: LocalizedError {
    public let message: String
    public let providerFailure: Bool
    public let auditData: Data?
    public var errorDescription: String? { message }
}

public struct OCRAgent {
    public static let version="book-page-agent-1"
    public let backend: CompatibleVisionBackend
    public let skill: OCRSkill
    private let detectLines: (CGImage) throws -> [TextHint]

    public init(backend: CompatibleVisionBackend, skill: OCRSkill,
                detectLines: @escaping (CGImage) throws -> [TextHint] = {
                    try PageImporter.detectHints($0,languages:["zh-Hant","zh-Hans","en-US"])
                }) {
        self.backend=backend;self.skill=skill;self.detectLines=detectLines
    }
    public func cacheKey(for page: Page) throws -> String {
        let endpoint=try backend.config.endpoint(backend.config.agentRoute.rawValue).absoluteString
        let parts=[Self.version,page.id,try backend.cacheKey(page:page),endpoint,skill.digest]
        return Digest.sha256(try JSONEncoder().encode(parts))
    }
    public func restore(_ data: Data, page: Page) throws -> OCRAgentOutcome {
        let audit=try JSONDecoder().decode(OCRAgentAudit.self,from:data)
        guard audit.version==Self.version,audit.pageID==page.id,audit.imageHash==page.imageSHA256,
              audit.skillHash==skill.digest,audit.route==backend.config.agentRoute,audit.requestedModel==backend.config.model,
              audit.cacheable,let selected=audit.selectedAttempt,
              let response=audit.attempts.first(where:{$0.number==selected})?.response else {
            throw ArchiveError.message("OCR Agent 缓存与本页或当前 Skill 不匹配。")
        }
        var result=try AgentEnvelope(response,route:audit.route).result(response:response,pageID:page.id)
        result.issues=audit.issues
        return OCRAgentOutcome(result:result,audit:audit)
    }

    public func recognize(image: CGImage,page: Page,status: @escaping (String)->Void) async throws -> OCRAgentOutcome {
        let started=Date()
        let route=backend.config.agentRoute
        var audit=OCRAgentAudit(version:Self.version,pageID:page.id,imageHash:page.imageSHA256,skillName:skill.name,
                                skillHash:skill.digest,route:route,requestedModel:backend.config.model)
        status("正在提取本机查漏行框")
        do {audit.evidence=try detectLines(image)}
        catch {audit.witnessError="本机行识别不可用，需对照原图核查。"}
        try Task.checkCancellation()
        let overview=try CompatibleVisionBackend.agentImage(image,maxSide:2400)
        var best: (result:OCRResult, check:AgentAssessment, json:String)?
        var lastError: Error?
        var tokens=backend.config.maxOutputTokens
        for number in 1...2 {
            try Task.checkCancellation()
            let findings=best?.check.findings.filter(\.retry) ?? []
            let crops=Self.cropBoxes(findings)
            let attemptStarted=Date()
            var attempt=OCRAgentAttempt(number:number,cropBoxes:crops,outputTokenLimit:tokens)
            var stop=false
            do {
                var prompt="转写当前整页。来源顺序第 \(page.sourcePage) 页，印刷页码以图为准。"
                if let error=lastError {prompt+="\n上一轮未通过解析：\(error.localizedDescription) 请返回完整书页。"}
                if let previous=best {
                    let details=try JSONEncoder().encode(findings.prefix(40).map(\.issue))
                    prompt+="\n对照整页和局部图复核。校验疑点："+String(decoding:details,as:UTF8.self)
                    prompt+="\n上一稿（待核对）："+previous.json
                }
                var input:[AgentInput]=[.text(prompt),.image(overview)]
                for (index,box) in crops.enumerated() {
                    let coords=[box.x,box.y,box.x+box.width,box.y+box.height].map{String(format:"%.4f",$0)}.joined(separator:",")
                    let panel=try PageImporter.crop(image,box:box)
                    input.append(.text("裁切 \(index+1) 的整页坐标 [\(coords)]"))
                    input.append(.image(try CompatibleVisionBackend.agentImage(panel,maxSide:1500)))
                }
                status(number==1 ? "OCR Agent 正在读整页" : "OCR Agent 正在重读\(crops.isEmpty ? "整页" : " \(crops.count) 处疑点")")
                let response=try await backend.sendAgent(input,skill:skill,tokens:tokens,status:status,received:{ http in
                    attempt.httpStatuses.append(http.statusCode)
                    if let requestID=http.value(forHTTPHeaderField:"x-request-id") {attempt.requestIDs.append(requestID)}
                })
                attempt.response=response
                try Task.checkCancellation()
                let envelope=try AgentEnvelope(response,route:route)
                attempt.inputTokens=envelope.inputTokens;attempt.outputTokens=envelope.outputTokens
                let result=try envelope.result(response:response,pageID:page.id)
                let check=AgentPageChecks.inspect(result,hints:audit.evidence)
                attempt.issues=check.issues;attempt.coveredLineNumbers=check.covered.sorted().map{$0+1}
                if let previous=best {
                    if previous.check.covered.isSubset(of:check.covered),check.score<previous.check.score {
                        best=(result,check,envelope.text);audit.selectedAttempt=number
                    }
                } else {
                    best=(result,check,envelope.text);audit.selectedAttempt=number
                }
                lastError=nil
                stop=best?.check.findings.contains(where:\.retry)==false
            } catch {
                if error is CancellationError || Task.isCancelled {throw CancellationError()}
                attempt.error=error.localizedDescription;lastError=error
                if let contentError=error as? OCRContentError {
                    switch contentError {
                    case .truncated:stop=tokens>=65536;tokens=min(65536,tokens*2)
                    case .refused,.incomplete:stop=true
                    }
                } else if error is ProviderRequestError {stop=true}
            }
            attempt.seconds=Date().timeIntervalSince(attemptStarted)
            audit.attempts.append(attempt)
            if stop {break}
        }
        audit.seconds=Date().timeIntervalSince(started)
        guard let best=best else {
            throw OCRAgentFailure(message:lastError?.localizedDescription ?? "本页没有可用的结构化转写。",
                                  providerFailure:lastError is ProviderRequestError,auditData:try? audit.encoded())
        }
        var result=best.result
        result.issues=best.check.issues
        if let error=lastError {
            result.issues.append(ReviewIssue("agent-reread-failed","重读未完成，已保留可用稿。"+error.localizedDescription))
        }
        if let error=audit.witnessError {result.issues.append(ReviewIssue("local-detection",error))}
        audit.issues=result.issues
        audit.cacheable=lastError==nil && !best.check.findings.contains(where:{$0.retry || $0.issue.code=="agent-evidence"}) && !result.blankCandidate
        return OCRAgentOutcome(result:result,audit:audit)
    }

    private static func cropBoxes(_ findings: [AgentFinding]) -> [Box] {
        let order=["agent-uncovered":0,"agent-table":1,"uncertain":2,"agent-text":3]
        let ranked=findings.enumerated().sorted { (order[$0.element.issue.code] ?? 4,$0.offset) < (order[$1.element.issue.code] ?? 4,$1.offset) }
        var boxes:[Box]=[]
        for item in ranked {
            guard let raw=item.element.issue.box else{continue}
            let box=AgentPageChecks.expanded(raw,dx:0.04,dy:0.023)
            if boxes.contains(where:{$0.intersection(box)>=0.8*box.area}) {continue}
            boxes.append(box)
            if boxes.count==4 {break}
        }
        return boxes
    }
}

struct AgentFinding {
    let issue: ReviewIssue
    var retry = true
}
struct AgentAssessment {
    var findings:[AgentFinding]
    var covered=Set<Int>()
    var issues:[ReviewIssue] { findings.map(\.issue) }
    var score:(Int,Int,Int,Int) {
        let retryable=findings.filter(\.retry)
        return (-covered.count,retryable.filter{$0.issue.code != "agent-unsupported"}.count,retryable.count,findings.count)
    }
}

enum AgentPageChecks {
    static func expanded(_ box:Box,dx:Double,dy:Double)->Box {
        let x=max(0,box.x-dx),y=max(0,box.y-dy)
        return Box(x,y,min(1,box.x+box.width+dx)-x,min(1,box.y+box.height+dy)-y)
    }
    private static func norm(_ text:String)->String {
        text.precomposedStringWithCompatibilityMapping.lowercased().filter{!$0.isWhitespace}
    }
    private static func centerY(_ box:Box)->Double {box.y+box.height/2}

    static func inspect(_ result: OCRResult,hints: [TextHint]) -> AgentAssessment {
        let blocks=result.blocks
        var report=AgentAssessment(findings:result.issues.map { issue in
            var located=issue
            located.box=blocks.first(where:{$0.id==issue.blockID})?.box
            return AgentFinding(issue:located,retry:["uncertain","table-unresolved","table-geometry"].contains(issue.code))
        })
        func add(_ code:String,_ message:String,block:Block?=nil,box:Box?=nil,retry:Bool=true) {
            report.findings.append(AgentFinding(issue:ReviewIssue(code,message,blockID:block?.id,box:box ?? block?.box),retry:retry))
        }
        let body=blocks.filter{$0.kind.isBody}
        if let structure=result.structure {
            if structure.layout == .other {add("agent-layout","复杂版面，请人工核对阅读顺序。",retry:false)}
            else if let wrong=misordered(body,layout:structure.layout) {
                add("agent-order","区块顺序与栏内或通栏位置冲突，请核对。",block:wrong)
            }
            if structure.layout == .single, likelyColumns(hints,blocks:blocks) {
                add("agent-columns","本机行框显示可能有双栏，请核对栏与阅读顺序。")
            }
            if structure.layout == .single,let block=body.first(where:{$0.ocrColumn != .full}) {
                add("agent-columns","单栏页的区块栏标记不一致。",block:block)
            }
            if [.leftToRight,.rightToLeft].contains(structure.layout) {
                let left=body.filter{$0.ocrColumn == .left}.map(\.box.x).min()
                let right=body.filter{$0.ocrColumn == .right}.map(\.box.x).min()
                if left==nil || right==nil || (left ?? 0)>=(right ?? 0) {
                    add("agent-columns","双栏标记和正文区块的位置或数量不符。")
                }
            }
            if (structure.startsMidParagraph && body.first?.kind != .paragraph) ||
               (structure.endsMidParagraph && body.last?.kind != .paragraph) {
                add("agent-continuation","续段标记缺少对应的页首或页尾段落。")
            }
        }
        if let label=result.printedLabel,!norm(label).isEmpty,!blocks.contains(where:{
            ($0.kind == .footer || $0.kind == .header) && norm($0.rawText).contains(norm(label))
        }) {add("agent-page-label","印刷页码在页眉页脚中找不到。")}
        let noteIDs=Dictionary(grouping:blocks.filter{$0.kind == .footnote},by:{$0.noteID ?? ""})
        let references=Set(body.flatMap{$0.noteReferences ?? []})
        for block in blocks {
            if block.kind == .header && centerY(block.box)>0.22 || block.kind == .footer && centerY(block.box)<0.78 {
                add("agent-margin","该页眉或页脚的位置异常，请核对区块类型。",block:block)
            }
            if block.kind == .footnote {
                let id=block.noteID ?? ""
                if id.isEmpty || noteIDs[id]?.count != 1 || !references.contains(id) {
                    add("agent-footnote","脚注编号缺失、重复或没有对应正文注标。",block:block)
                }
            } else if (block.noteReferences ?? []).contains(where:{noteIDs[$0]?.count != 1 || $0.isEmpty}) {
                add("agent-footnote","正文注标缺少对应脚注。",block:block,box:Box(0,0.73,1,0.27))
            }
            if block.kind == .table,!block.cells.isEmpty {
                let rows=block.cells.map{$0.row+$0.rowSpan}.max() ?? 0
                let cols=block.cells.map{$0.column+$0.columnSpan}.max() ?? 0
                if block.cells.reduce(0,{$0+$1.rowSpan*$1.columnSpan}) != rows*cols || disorderedCells(block.cells) {
                    add("agent-table","表格行列存在缺口或位置冲突，请核对空白格与合并格。",block:block)
                }
                if !norm(block.rawText).isEmpty {add("agent-table","已分格表格还有独立文字，请核对是否重复。",block:block)}
                if block.cells.contains(where:{$0.rawText.contains("⟦") || $0.rawText.contains("�")}) {
                    add("uncertain","表格含疑难字。",block:block)
                }
            }
        }

        var used:[String:Int]=[:]
        var located=Set<String>()
        var eligible=0
        for (index,hint) in hints.enumerated() {
            let text=norm(hint.text),confidence=hint.confidence ?? 0
            guard confidence>=0.25,hint.box.isValid,!text.isEmpty else{continue}
            let strong=confidence>=0.5
            if strong {eligible+=1}
            let nearby=blocks.filter {
                (!$0.rawText.isEmpty || !$0.cells.isEmpty) && expanded($0.box,dx:0.018,dy:0.012).intersection(hint.box)>=0.45*hint.box.area
            }
            located.formUnion(nearby.map(\.id))
            var found=false
            for block in nearby {
                let (candidate,scope)=textInRegion(block,hint:hint.box)
                let key=block.id+"|"+scope+"|"+text
                if candidate.components(separatedBy:text).count-1>used[key,default:0] {
                    if strong {report.covered.insert(index);used[key,default:0]+=1}
                    found=true;break
                }
            }
            if !found {
                if nearby.isEmpty {add("agent-uncovered","本机识别到一行文字，当前转写缺少对应区域。",box:hint.box)}
                else {add(strong ? "agent-text" : "agent-weak-text",
                          strong ? "同一区域的本机 OCR 与视觉转写有差异。" : "低置信度本机行有分歧，请对照原图。",
                          block:nearby.first,box:hint.box,retry:strong)}
            }
        }
        if eligible==0 {add("agent-evidence","可用的独立行证据不足，请对照原图核查完整性。",retry:false)}
        else {
            for block in blocks where !located.contains(block.id) && (!norm(block.rawText).isEmpty || block.cells.contains(where:{!norm($0.rawText).isEmpty})) {
                add("agent-unsupported","此区块缺少同位置的本机行证据，请核对。",block:block)
            }
        }
        return report
    }

    private static func misordered(_ body:[Block],layout:OCRPageLayout)->Block? {
        let spans=body.filter{$0.ocrColumn == .full}.map{centerY($0.box)}
        let first:OCRColumn=layout == .rightToLeft ? .right : .left
        func key(_ block:Block)->(Int,Int,Double,Double,Int) {
            let full=block.ocrColumn == .full
            let earlier=spans.filter{$0<centerY(block.box)}.count
            let band=layout == .single ? 0 : 2*earlier+(full ? 1 : 0)
            let column=layout == .single || full || block.ocrColumn==first ? 0 : 1
            return (band,column,block.box.y,block.box.x,block.order)
        }
        return zip(body,body.sorted{key($0)<key($1)}).first(where:{$0.id != $1.id})?.0
    }
    private static func likelyColumns(_ hints:[TextHint],blocks:[Block])->Bool {
        let tables=blocks.filter{$0.kind == .table}
        let body=hints.filter { hint in
            (hint.confidence ?? 0)>=0.5 && norm(hint.text).count>=5 && (0.12...0.82).contains(centerY(hint.box)) &&
            !tables.contains{$0.box.intersection(hint.box)>=hint.box.area*0.5}
        }.map(\.box)
        let right=body.filter{$0.x>=0.48}
        var baselines:[Double]=[]
        for left in body where left.x+left.width<=0.52 {
            let y=centerY(left)
            if !baselines.contains(where:{abs($0-y)<0.02}) &&
                right.contains(where:{$0.x-left.x-left.width>=0.08 && abs(centerY($0)-y)<0.015}) {
                baselines.append(y)
            }
        }
        return baselines.count>=3
    }
    private static func disorderedCells(_ cells:[TableCell])->Bool {
        for row in Dictionary(grouping:cells,by:\.row).values {
            let xs=row.sorted{$0.column<$1.column}.compactMap{$0.box.map{$0.x+$0.width/2}}
            if zip(xs,xs.dropFirst()).contains(where:{$0 >= $1}) {return true}
        }
        for column in Dictionary(grouping:cells,by:\.column).values {
            let ys=column.sorted{$0.row<$1.row}.compactMap{$0.box.map{centerY($0)}}
            if zip(ys,ys.dropFirst()).contains(where:{$0 >= $1}) {return true}
        }
        return false
    }
    private static func textInRegion(_ block:Block,hint:Box)->(String,String) {
        guard block.kind == .table,!block.cells.isEmpty else{return(norm(block.rawText),"")}
        let cells=block.cells.sorted{($0.row,$0.column)<($1.row,$1.column)}.filter {cell in
            guard let box=cell.box else{return true}
            return expanded(box,dx:0.012,dy:0.008).intersection(hint)>=0.15*min(hint.area,box.area)
        }
        return (norm(cells.map(\.rawText).joined()),cells.map(\.id).joined(separator:","))
    }
}
