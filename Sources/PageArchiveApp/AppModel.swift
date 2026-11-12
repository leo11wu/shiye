import AppKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import PageArchiveCore

final class CancellationFlag: @unchecked Sendable {
    private let lock=NSLock();private var value=false
    var cancelled:Bool { lock.lock();defer{lock.unlock()};return value }
    func cancel() { lock.lock();value=true;lock.unlock() }
}
private struct RecognitionUpdate {
    var page:Page
    var edit:EditRecord?
    var response:Data? = nil
    var responsePath:String? = nil
    var cachePath:String? = nil
    var replaceCache=false
    var changedRecognition=false
}
enum EditableExportFormat {
    case pdf, text, markdown
    var fileExtension:String {switch self {case .pdf:return "pdf";case .text:return "txt";case .markdown:return "md"}}
}
final class AppModel:ObservableObject {
    @Published var document:BookDocument?
    @Published var selectedPageID:String?
    @Published var selectedBlockID:String?
    @Published var selectedCellID:String?
    @Published var pageRange=""
    @Published var recognitionMode:RecognitionMode = .local
    @Published var provider=ProviderConfiguration()
    @Published private(set) var customOCRSkill:OCRSkill?
    @Published var key=""
    @Published var models:[String]=[]
    @Published var working=false
    @Published var concurrencyLimit=2 { didSet { defaults.set(concurrencyLimit,forKey:"page-concurrency") } }
    @Published var activePageIDs:Set<String>=[]
    @Published var previewLoading=false
    @Published var isStopping=false
    @Published var status="导入整本扫描书或照片，识别后导出可搜索 PDF 或正文。"
    @Published var completed=0
    @Published var total=0
    @Published var originalImage:NSImage?
    @Published var rebuiltImage:NSImage?
    @Published var diagnostics:PageDiagnostics?
    @Published var errorMessage:String?
    @Published var settingsShown=false
    @Published var drawingRegion=false
    @Published var showBoxes=true
    @Published var zoom=1.0
    @Published var probeMessage=""
    @Published var sourceTextVisible=false
    @Published var focusedIssueBox:Box?
    weak var editor:NSTextView?
    var store:ProjectStore?
    var workTask:Task<Void,Never>?
    // Internal integration-test seams; normal app runs use the real local engine.
    var localRecognitionOverride:(@Sendable (Page,ProjectStore) throws -> Page)?
    var visionConfirmationOverride:((NSAlert)->Bool)?
    var batchProgressObserver:((PageWorkProgress)->Void)?
    private var cancellation=CancellationFlag()
    private var importing=false
    private let defaults:UserDefaults = {
        // The application domain is already managed by standard. Passing our own
        // bundle identifier to suiteName returns nil on macOS.
        guard CommandLine.arguments.contains("--qa") else { return .standard }
        return UserDefaults(suiteName:"local.leowu.Shiye.QA."+UUID().uuidString) ?? .standard
    }()
    private let previewQueue=DispatchQueue(label:"local.leowu.Shiye.preview",qos:.userInitiated)
    private var previewGeneration=0
    private var previewCancellation=CancellationFlag()
    private var pendingSave:DispatchWorkItem?
    private var pendingBefore:String?
    private var pendingBlock:String?
    private var pendingPage:String?
    private var startupProject:URL?
    var pageIndex:Int? { document?.pages.firstIndex { $0.id==selectedPageID } }
    var page:Page? { guard let i=pageIndex else{return nil};return document?.pages[i] }
    var block:Block? { page?.blocks.first { $0.id==selectedBlockID } }
    var cell:TableCell? { block?.cells.first { $0.id==selectedCellID } }
    var selectedText:String { cell?.text ?? block?.text ?? "" }
    var selectedRuns:[TextRun] { cell?.runs ?? block?.runs ?? [] }
    var dataRoot:URL {
        if let index=CommandLine.arguments.firstIndex(of:"--data-root"),CommandLine.arguments.count>index+1 { return URL(fileURLWithPath:CommandLine.arguments[index+1]) }
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Shiye/Projects")
    }
    init() {
        let savedConcurrency=defaults.integer(forKey:"page-concurrency")
        concurrencyLimit=(1...4).contains(savedConcurrency) ? savedConcurrency : 2
        if let data=defaults.data(forKey:"provider"),let config=try? JSONDecoder().decode(ProviderConfiguration.self,from:data) { provider=config }
        if let data=defaults.data(forKey:"ocr-skill"),let skill=try? JSONDecoder().decode(OCRSkill.self,from:data) {customOCRSkill=skill}
        if let index=CommandLine.arguments.firstIndex(of:"--project"),CommandLine.arguments.count>index+1 {
            startupProject=URL(fileURLWithPath:CommandLine.arguments[index+1])
        } else if let last=defaults.string(forKey:"last-project"),FileManager.default.fileExists(atPath:last+"/document.json") { startupProject=URL(fileURLWithPath:last) }
    }
    func restoreStartupProject() {if let root=startupProject{startupProject=nil;beginOpenProject(root)}}
    func beginOpenProject(_ root:URL) {
        guard !working,flush() else{return}
        working=true;isStopping=false;activePageIDs=[];total=0;completed=0;cancellation=CancellationFlag();let flag=cancellation
        status="正在打开项目，读取已保存的页面…"
        workTask=Task { @MainActor in
            do {
                let loaded=try await Task.detached(priority:.userInitiated) { () throws -> (ProjectStore,BookDocument) in
                    guard FileManager.default.fileExists(atPath:root.appendingPathComponent("document.json").path) else{throw ArchiveError.message("请选择有效的拾页项目。")}
                    let next=try ProjectStore(root:root);return (next,try next.load())
                }.value
                if flag.cancelled{throw CancellationError()}
                store=loaded.0;document=loaded.1;selectedPageID=loaded.1.pages.first?.id;selectedBlockID=nil;selectedCellID=nil;focusedIssueBox=nil;pageRange=""
                defaults.set(root.path,forKey:"last-project");status="已恢复 \(loaded.1.pages.count) 页 · 可以继续识别或导出";refreshPreview()
            }catch{
                if error is CancellationError{status="已停止打开项目。"}else{fail(error);status="项目未能打开，原文件仍保留。"}
            }
            working=false;isStopping=false
        }
    }
    func fail(_ error:Error) { errorMessage=error.localizedDescription }
    func newTask() {guard !working,flush() else{return};document=nil;store=nil;selectedPageID=nil;selectedBlockID=nil;selectedCellID=nil;focusedIssueBox=nil;errorMessage=nil;defaults.removeObject(forKey:"last-project");refreshPreview();status="新任务 · 导入 PDF 或图片开始。"}
    @discardableResult
    func flush() -> Bool {
        // Import owns its incremental document until it hands the final/partial
        // snapshot back. Browsing or Cmd-S must not overwrite it with an old copy.
        guard !importing else{return true}
        pendingSave?.cancel();pendingSave=nil
        guard var doc=document,let store=store else{return true}
        if let before=pendingBefore,let pid=pendingPage {
            let after=page?.blocks.first { $0.id==pendingBlock }.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data:$0,encoding:.utf8) }
            doc.edits.append(EditRecord(pageID:pid,blockID:pendingBlock,action:"编辑文字或样式",before:before,after:after))
            document=doc;pendingBefore=nil;pendingBlock=nil;pendingPage=nil
        }
        do { try store.save(doc);return true } catch { fail(error);return false }
    }
    func saveSoon() {
        pendingSave?.cancel()
        let work=DispatchWorkItem { [weak self] in self?.flush();self?.refreshPreview() }
        pendingSave=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.65,execute:work)
    }
    func selectPage(_ id:String?) {
        guard flush() else{return};selectedPageID=id;selectedBlockID=nil;selectedCellID=nil;focusedIssueBox=nil;refreshPreview()
    }
    func selectBlock(_ id:String?) { guard flush() else{return};selectedBlockID=id;selectedCellID=nil;focusedIssueBox=nil }
    func selectIssue(_ issue:ReviewIssue) {
        guard flush() else{return}
        selectedBlockID=issue.blockID;selectedCellID=nil;focusedIssueBox=issue.box
    }
    func loadProject(_ root:URL) {
        guard !working,flush() else{return}
        do {
            guard FileManager.default.fileExists(atPath:root.appendingPathComponent("document.json").path) else { throw ArchiveError.message("请选择包含 document.json 的拾页项目。") }
            let next=try ProjectStore(root:root),doc=try next.load()
            store=next;document=doc;selectedPageID=doc.pages.first?.id;selectedBlockID=nil;selectedCellID=nil;focusedIssueBox=nil
            pageRange="";defaults.set(root.path,forKey:"last-project")
            status="已恢复 \(doc.pages.count) 页 · 原始转写与修改记录均保留";refreshPreview()
        } catch { fail(error) }
    }
    func openProject() {
        let p=NSOpenPanel();p.canChooseDirectories=true;p.canChooseFiles=true;p.allowsMultipleSelection=false;p.treatsFilePackagesAsDirectories=false;p.message="打开拾页项目（.shiyebook）"
        if p.runModal() == .OK,let url=p.url { beginOpenProject(url) }
    }
    func importFiles() {
        guard !working else{return}
        let p=NSOpenPanel();p.allowsMultipleSelection=true;p.allowedContentTypes=PageImporter.supportedExtensions.compactMap{UTType(filenameExtension:$0)};p.message="按文件名排序导入；之后可调整页面顺序"
        if p.runModal() == .OK { beginImport(p.urls.sorted{$0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending}) }
    }
    func beginImport(_ urls:[URL],suggestedTitle:String? = nil) {
        guard !working,!urls.isEmpty,flush() else{return}
        do {
            if document==nil {
                let root=dataRoot.appendingPathComponent(UUID().uuidString+".shiyebook")
                store=try ProjectStore(root:root);document=BookDocument(title:suggestedTitle ?? urls[0].deletingPathExtension().lastPathComponent)
            }
            guard let store=store,let current=document else{return}
            working=true;importing=true;isStopping=false;activePageIDs=[];cancellation=CancellationFlag();let flag=cancellation
            defaults.set(store.root.path,forKey:"last-project")
            status="正在导入与检查页面…";total=0;completed=0
            workTask=Task { @MainActor in
                do {
                    let imported=try await Task.detached(priority:.userInitiated) { () throws -> BookDocument in
                        var d=current
                        try PageImporter.append(urls:urls,to:&d,store:store,progress:{ message in DispatchQueue.main.async{self.status=message} },cancelled:{flag.cancelled})
                        return d
                    }.value
                    document=imported;selectedPageID=imported.pages.first?.id;selectedBlockID=nil;selectedCellID=nil;focusedIssueBox=nil
                    pageRange="";defaults.set(store.root.path,forKey:"last-project")
                    status="已导入 \(imported.pages.count) 页 · 当前范围：整本；可选择试识别或直接批量处理"
                } catch {
                    if let partial=try? store.load() { document=partial;selectedPageID=partial.pages.first?.id }
                    if error is CancellationError { status="已取消导入；已完成页面已保存。" } else { fail(error);status="导入未完成；已完成页面可恢复。" }
                }
                importing=false;working=false;isStopping=false;refreshPreview()
            }
        } catch { fail(error) }
    }
    func loadFixture() {
        guard !working else{return};flush()
        do {
            let root=dataRoot.appendingPathComponent(UUID().uuidString+".shiyebook"),next=try ProjectStore(root:root)
            let doc=Fixtures.document();try next.save(doc)
            store=next;document=doc;selectedPageID=doc.pages.first?.id;selectedBlockID=nil;selectedCellID=nil;pageRange=""
            status="技术样张：已知文字，用于测试排版与复制；不是 OCR 识别结果。";refreshPreview()
        } catch { fail(error) }
    }
    func refreshPreview() {
        previewGeneration+=1;let generation=previewGeneration
        previewCancellation.cancel();previewCancellation=CancellationFlag();let previewFlag=previewCancellation
        originalImage=nil;rebuiltImage=nil;diagnostics=nil;previewLoading=false
        guard let page=page,let doc=document,let store=store else{return}
        previewLoading=true
        let font=doc.chineseFont
        previewQueue.async {
            guard !previewFlag.cancelled else{return}
            autoreleasepool {
                do {
                    if page.issues.contains(where:{$0.code=="local-draft"}) {
                        let original=page.imagePath.isEmpty ? nil : (try? store.url(page.imagePath)).flatMap{NSImage(contentsOf:$0)}
                        DispatchQueue.main.async {
                            guard self.previewGeneration==generation else{return}
                            self.originalImage=original;self.rebuiltImage=nil;self.diagnostics=nil;self.previewLoading=false
                        }
                        return
                    }
                    let dir=try store.url("preview");try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                    let url=dir.appendingPathComponent("page-\(generation).pdf")
                    var single=BookDocument(title:doc.title);single.pages=[page];single.chineseFont=font
                    let report=try PDFRenderer.render(document:single,store:store,to:url,forceDraft:true,cancelled:{previewFlag.cancelled})
                    guard let previewPDF=PDFDocument(url:url),let previewPage=previewPDF.page(at:0) else {
                        throw ArchiveError.message("重建页预览无法重新打开，请重试排版。")
                    }
                    let rebuilt=previewPage.thumbnail(of:CGSize(width:1500,height:1900),for:.mediaBox)
                    let original=page.imagePath.isEmpty ? nil : (try? store.url(page.imagePath)).flatMap { NSImage(contentsOf:$0) }
                    DispatchQueue.main.async {
                        guard self.previewGeneration==generation else{return}
                        self.rebuiltImage=rebuilt;self.originalImage=original;self.diagnostics=report.pages.first;self.previewLoading=false
                    }
                    try? FileManager.default.removeItem(at:url)
                } catch { DispatchQueue.main.async { if self.previewGeneration==generation { self.previewLoading=false;self.fail(error) } } }
            }
        }
    }
    func saveProvider() {
        do {
            _=try provider.endpoint("chat/completions")
            if provider.rememberKey,!key.isEmpty { try KeychainStore.write(key,account:provider.account) }
            if !provider.rememberKey { try KeychainStore.delete(account:provider.account) }
            defaults.set(try JSONEncoder().encode(provider),forKey:"provider");settingsShown=false
            status="API 配置已保存 · 图像只在你启动识别时发送"
        } catch { fail(error) }
    }
    var ocrSkillName:String {customOCRSkill?.name ?? "内置书页 Skill"}
    private func resolvedOCRSkill() throws -> OCRSkill {
        if let custom=customOCRSkill {return try OCRSkill(name:custom.name,text:custom.text)}
        return try OCRSkill.bundled()
    }
    func setOCRSkill(_ skill:OCRSkill?) throws {
        if let skill=skill {defaults.set(try JSONEncoder().encode(skill),forKey:"ocr-skill")}
        else {defaults.removeObject(forKey:"ocr-skill")}
        customOCRSkill=skill
        probeMessage=""
    }
    func importOCRSkill() {
        let panel=NSOpenPanel()
        panel.message="选择用于书页识别的 SKILL.md"
        panel.allowedContentTypes=[UTType(filenameExtension:"md") ?? .plainText]
        if panel.runModal() == .OK,let url=panel.url {
            do{try setOCRSkill(OCRSkill(file:url))}catch{fail(error)}
        }
    }
    func saveOCRSkillTemplate() {
        let panel=NSSavePanel();panel.nameFieldStringValue="SKILL.md";panel.canCreateDirectories=true
        if panel.runModal() == .OK,let url=panel.url {
            do{try Data(contentsOf:OCRSkill.bundledURL()).write(to:url,options:.atomic)}catch{fail(error)}
        }
    }
    func resetOCRSkill() {do{try setOCRSkill(nil)}catch{fail(error)}}
    func useOpenAIProvider() {
        provider.baseURL="https://api.openai.com/v1"
        provider.model="gpt-5.4-mini"
        provider.tokenParameter="max_completion_tokens"
    }
    func loadCurrentKey() { do { key=try KeychainStore.read(account:provider.account) ?? "" } catch { fail(error) } }
    @discardableResult
    func loadRememberedKeyIfNeeded()->Bool {
        guard provider.rememberKey,key.isEmpty,!provider.baseURL.isEmpty else{return true}
        do{key=try KeychainStore.read(account:provider.account) ?? "";return true}catch{fail(error);return false}
    }
    func forgetKey() { do { try KeychainStore.delete(account:provider.account);key="";probeMessage="本服务的拾页钥匙串记录已删除。" } catch { fail(error) } }
    func providerAction(probe:Bool) {
        guard !working,loadRememberedKeyIfNeeded() else{return}
        let skill:OCRSkill?
        do{skill=probe ? try resolvedOCRSkill() : nil}catch{probeMessage=error.localizedDescription;return}
        working=true;isStopping=false;total=0;completed=0;activePageIDs=[];cancellation=CancellationFlag();probeMessage=probe ? "正在发送随机测试图…" : "正在获取模型列表…"
        let backend=CompatibleVisionBackend(config:provider,key:key)
        workTask=Task { @MainActor in
            do {
                if let skill=skill { probeMessage=try await backend.probeAgent(skill:skill) }
                else { models=try await backend.models();probeMessage="已获取 \(models.count) 个模型；列表不代表已验证图片能力。" }
            } catch { probeMessage=error is CancellationError ? "已取消请求。" : error.localizedDescription;if error is CancellationError{status="API 请求已取消。"} }
            working=false;isStopping=false
        }
    }
    func startRecognition(region:Bool = false) {
        guard !working else{return}
        guard !needsImageReimport else{errorMessage="请先新建修复副本，再识别清晰的 PDF 页面。";return}
        guard flush(),let doc=document,let store=store else{return}
        do {
            if provider.model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || provider.baseURL.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { settingsShown=true;return }
            let config=provider
            let route=config.agentRoute
            let endpoint=try config.endpoint(route.rawValue)
            let skill=try resolvedOCRSkill()
            guard loadRememberedKeyIfNeeded() else{return}
            let indices=region ? (pageIndex.map{[$0]} ?? []) : try PageRange.parse(pageRange,count:doc.pages.count)
            guard !indices.isEmpty else{return}
            let box=region ? block?.box : nil,target=region ? selectedBlockID : nil
            if region && box==nil {throw ArchiveError.message("请先选中一个完整区域。")}
            let existing=indices.filter{!doc.pages[$0].blocks.isEmpty}.count
            let limit=region ? 1 : min(4,max(1,concurrencyLimit))
            let label=region ? "区域复识别" : "OCR Agent"
            let alert=NSAlert();alert.messageText=region ? "识别选中区域" : "识别所选 \(indices.count) 页"
            let strategy="\nSkill：\(skill.name)"+(region ? "" : " · 每页按疑点最多重读一次。")
            alert.informativeText="将向 \(endpoint.host ?? config.baseURL) 发送所选图像\(region ? "裁剪" : "")。\n模型：\(config.model) · 同时最多 \(limit) 页"+strategy+"\n服务商可能计费，成功缓存会复用。"+(existing>0 ? "\n已有内容可能被新识别结果替换，旧内容仍保留在项目记录中。" : "")
            alert.addButton(withTitle:"开始识别");alert.addButton(withTitle:"取消")
            guard visionConfirmationOverride?(alert) ?? (alert.runModal() == .alertFirstButtonReturn) else{return}
            let keySnapshot=key
            beginRecognition(count:indices.count,label:label)
            let flag=cancellation,started=Date()
            workTask=Task { @MainActor in
                let summary=await PageWorkQueue.run(indices:indices,maxConcurrent:limit,cancelled:{flag.cancelled},operation:{ index in
                    try await Self.recognizeAPIPage(page:doc.pages[index],config:config,key:keySnapshot,store:store,box:box,target:target,skill:skill,status:{ message in
                        DispatchQueue.main.async {
                            guard !flag.cancelled,self.working else{return}
                            self.status="第 \(index+1) 页 · "+message
                        }
                    })
                },commit:{ index,result in
                    try await MainActor.run {if flag.cancelled{throw CancellationError()};try self.commitRecognition(result,at:index,store:store)}
                },progress:{ progress in
                    await MainActor.run {self.updateRecognitionProgress(progress,document:doc)}
                })
                finishRecognition(summary,label:label,started:started)
            }
        }catch{fail(error)}
    }
    private static func recognizeAPIPage(page:Page,config:ProviderConfiguration,key:String,store:ProjectStore,box:Box?,target:String?,skill:OCRSkill,status:@escaping(String)->Void) async throws -> RecognitionUpdate {
        let backend=CompatibleVisionBackend(config:config,key:key)
        let agent=box==nil ? OCRAgent(backend:backend,skill:skill) : nil
        var current=page
        let baseKey=try backend.cacheKey(page:current,region:box)
        let cacheKey=try agent?.cacheKey(for:current) ?? Digest.sha256(Data((baseKey+"|"+skill.digest+"|"+OCRAgent.version).utf8))
        let relative="responses/\(cacheKey).json"
        let responseURL=try store.url(relative)
        let hasCache=agent != nil && FileManager.default.fileExists(atPath:responseURL.path)
        if hasCache,current.recognitions.contains(where:{$0.cacheKey==cacheKey}),!current.blocks.isEmpty,current.status != .failed {
            return RecognitionUpdate(page:current)
        }
        let result:OCRResult
        let endpoint:URL,promptVersion:String,promptTokens:Int?,completionTokens:Int?
        let freshResponse:Data?,savedResponse:String,newCache:Bool,replaceCache:Bool
        let uniqueResponse="responses/\(cacheKey)-\(UUID().uuidString).json"
        if let agent=agent {
            let restored=hasCache ? (try? agent.restore(Data(contentsOf:responseURL),page:current)) : nil
            let outcome:OCRAgentOutcome
            if let restored=restored {
                outcome=restored;freshResponse=nil;savedResponse=relative
            } else {
                outcome=try await agent.recognize(image:PageImporter.image(page:current,store:store),page:current,status:status)
                freshResponse=try outcome.audit.encoded();savedResponse=uniqueResponse
            }
            result=outcome.result;current.hints=outcome.audit.evidence
            newCache=restored==nil && outcome.audit.cacheable;replaceCache=newCache && hasCache
            endpoint=try config.endpoint(config.agentRoute.rawValue);promptVersion=OCRAgent.version
            promptTokens=outcome.promptTokens;completionTokens=outcome.completionTokens
        } else if let box=box {
            let image=try PageImporter.image(page:current,store:store)
            if current.hints.isEmpty {
                do{current.hints=try PageImporter.detectHints(image)}
                catch{current.issues.append(ReviewIssue("local-detection","本机区域检查不可用，本页需目视核对完整性。"))}
            }
            result=try await backend.recognizeAgentRegion(image:image,page:current,region:box,skill:skill,status:status)
            guard !result.blocks.isEmpty else {throw ArchiveError.message("所选区域未返回文字区域，已保留当前稿。")}
            freshResponse=result.response;savedResponse=uniqueResponse;newCache=false;replaceCache=false
            endpoint=try config.endpoint(config.agentRoute.rawValue);promptVersion=OCRAgent.version+"-region"
            promptTokens=result.promptTokens;completionTokens=result.completionTokens
        } else {throw ArchiveError.message("未指定要复识别的区域。")}
        try Task.checkCancellation()
        let before=String(data:try JSONEncoder().encode(current.blocks),encoding:.utf8)
        if let target=target,let bi=current.blocks.firstIndex(where:{$0.id==target}) {
            let old=current.blocks[bi]
            var replacement=result.blocks,blockIDMap:[String:String]=[:]
            for j in replacement.indices {
                let previousID=replacement[j].id
                replacement[j].id=j==0 ? old.id : old.id+"-"+UUID().uuidString
                replacement[j].ocrColumn=old.ocrColumn
                if replacement.count==1 && replacement[j].kind==old.kind {
                    replacement[j].noteID=old.noteID;replacement[j].noteReferences=old.noteReferences
                }
                blockIDMap[previousID]=replacement[j].id
                for ci in replacement[j].cells.indices{replacement[j].cells[ci].id=replacement[j].id+"-c\(ci+1)"}
            }
            var all=current.orderedBlocks
            guard let at=all.firstIndex(where:{$0.id==target}) else{throw ArchiveError.message("选中区域已不存在。")}
            all.replaceSubrange(at...at,with:replacement)
            for j in all.indices{all[j].order=j+1};current.blocks=all
            current.issues.removeAll{$0.blockID==target}
            current.issues.removeAll { issue in
                guard issue.code=="agent-uncovered",let area=issue.box else{return false}
                return replacement.contains{$0.box.intersection(area)>=0.65*area.area}
            }
            current.issues.append(contentsOf:result.issues.map {var issue=$0;if let id=issue.blockID{issue.blockID=blockIDMap[id]};return issue})
        } else {
            current.blocks=result.blocks;current.issues=result.issues;current.printedLabel=result.printedLabel
            current.ocrStructure=result.structure
        }
        current.status = .recognized;current.error=nil;current.agentFailurePath=nil
        current.recognitions.append(RecognitionRecord(requestedModel:config.model,returnedModel:result.returnedModel,endpoint:endpoint.absoluteString,cacheKey:cacheKey,responsePath:savedResponse,promptTokens:promptTokens,completionTokens:completionTokens,promptVersion:promptVersion))
        return RecognitionUpdate(page:current,edit:EditRecord(pageID:current.id,blockID:target,action:agent==nil ? "应用局部视觉转写" : "应用 OCR Agent 待校对稿",before:before),
                                 response:freshResponse,responsePath:savedResponse,cachePath:newCache ? relative : nil,replaceCache:replaceCache,changedRecognition:true)
    }
    private func beginRecognition(count:Int,label:String) {
        working=true;isStopping=false;total=count;completed=0;activePageIDs=[]
        cancellation=CancellationFlag();status="\(label) · 正在准备 \(count) 页"
    }
    private func updateRecognitionProgress(_ progress:PageWorkProgress,document snapshot:BookDocument) {
        total=progress.total;completed=progress.completed
        activePageIDs=Set(progress.activeIndices.filter{snapshot.pages.indices.contains($0)}.map{snapshot.pages[$0].id})
        batchProgressObserver?(progress)
    }
    private func commitRecognition(_ result:Result<RecognitionUpdate,PageWorkFailure>,at index:Int,store:ProjectStore) throws {
        guard var next=document,next.pages.indices.contains(index) else{throw ArchiveError.message("项目状态已改变，处理已停止。")}
        switch result {
        case .success(let update):
            if let response=update.response,let relative=update.responsePath {
                // Keep each request's evidence immutable even when duplicate source
                // pages miss the same cache concurrently. Only the first fills it.
                try response.write(to:store.url(relative),options:.atomic)
                if let cache=update.cachePath {
                    let url=try store.url(cache)
                    if update.replaceCache || !FileManager.default.fileExists(atPath:url.path){try response.write(to:url,options:.atomic)}
                }
            }
            next.pages[index]=update.page
            if update.changedRecognition {
                next.pages[index].textContinuation=nil
                if index>0,next.pages[index-1].textContinuation?.nextPageID==update.page.id {next.pages[index-1].textContinuation=nil}
            }
            if let edit=update.edit{next.edits.append(edit)}
        case .failure(let failure):
            next.pages[index].status = .failed;next.pages[index].error=failure.message
            if let audit=failure.auditData {
                let relative="responses/agent-failure-\(UUID().uuidString).json"
                try audit.write(to:store.url(relative),options:.atomic)
                next.pages[index].agentFailurePath=relative
            }
        }
        try store.save(next)
        document=next
        if selectedPageID==next.pages[index].id {focusedIssueBox=nil;refreshPreview()}
    }
    private func finishRecognition(_ summary:PageWorkSummary,label:String,started:Date) {
        working=false;isStopping=false;activePageIDs=[]
        completed=summary.progress.completed;total=summary.progress.total
        if let failure=summary.stoppedBy {
            status=failure.kind == .persistence ? "保存失败，处理已停止；未保存页可以重试。" : "服务暂时不可用，处理已停止；完成页已保存。"
            errorMessage=failure.message
        }else if summary.cancelled {
            status="已停止 · 已保存 \(completed)/\(total) 页；再次开始可继续处理。"
        }else{
            status="\(label)完成 · 成功 \(summary.progress.succeeded) 页，失败 \(summary.progress.failed) 页 · \(Int(Date().timeIntervalSince(started))) 秒；识别文字仍需核对。"
        }
        refreshPreview()
    }
    var needsImageReimport:Bool {
        guard let doc=document else{return false}
        let pdfSources=Set(doc.sources.filter{$0.filename.lowercased().hasSuffix(".pdf")}.map(\.id))
        return doc.pages.contains{pdfSources.contains($0.sourceID) && $0.imageRenderVersion != PageImporter.renderVersion}
    }
    func rebuildFromSources() {
        guard !working,let old=document,let oldStore=store,!old.sources.isEmpty,flush() else{return}
        do {
            let urls=try old.sources.map{try oldStore.url($0.relativePath)}
            guard urls.allSatisfy({FileManager.default.fileExists(atPath:$0.path)}) else{
                throw ArchiveError.message("原始文件副本缺失，请重新选择原始 PDF 或照片。")
            }
            document=nil;store=nil;selectedPageID=nil;selectedBlockID=nil;selectedCellID=nil
            defaults.removeObject(forKey:"last-project")
            beginImport(urls,suggestedTitle:old.title+"-修复导入")
        }catch{fail(error)}
    }
    var isLocalDraftPage:Bool { page?.issues.contains(where:{$0.code=="local-draft"}) == true }
    var visibleIssues:[ReviewIssue] { isLocalDraftPage ? (page?.issues.filter{!$0.resolved} ?? []) : (diagnostics?.issues ?? []) }
    var rangeDescription:String {
        guard let doc=document else{return ""}
        guard let count=try? PageRange.parse(pageRange,count:doc.pages.count).count else{return "页码格式有误"}
        return count==doc.pages.count ? "整本 \(count) 页" : "所选 \(count) / \(doc.pages.count) 页"
    }
    func choosePendingPages() {
        guard !working,let doc=document else{return}
        let pending=doc.pages.indices.filter{doc.pages[$0].blocks.isEmpty && doc.pages[$0].status != .blank}
        guard !pending.isEmpty else{status="所选项目已有文字结果；可导出或继续校对。";return}
        pageRange=pending.map{String($0+1)}.joined(separator:",")
    }
    func chooseFailedPages() {
        guard !working,let doc=document else{return}
        let indices=doc.pages.indices.filter{doc.pages[$0].status == .failed}
        guard !indices.isEmpty else{status="没有识别失败的页面。";return}
        pageRange=indices.map{String($0+1)}.joined(separator:",")
    }
    func selectNextIssuePage() {
        guard let doc=document,!doc.pages.isEmpty else{return}
        let start=(pageIndex ?? -1)+1
        let ordered=Array(start..<doc.pages.count)+Array(0..<min(start,doc.pages.count))
        if let index=ordered.first(where:{doc.pages[$0].status != .reviewed && doc.pages[$0].status != .blank}) {selectPage(doc.pages[index].id)}
        else{status="所有页面都已核对或确认空白。"}
    }
    func startLocalRecognition() {
        guard !working else{return}
        guard !needsImageReimport else{errorMessage="请先新建修复副本，再识别清晰的 PDF 页面；旧项目会保留。";return}
        guard flush(),let doc=document,let store=store else{return}
        do {
            let selected=try PageRange.parse(pageRange,count:doc.pages.count)
            let indices=selected.filter{doc.pages[$0].blocks.isEmpty && doc.pages[$0].status != .blank}
            guard !indices.isEmpty else{status="所选页面已有文字。需要重新识别时，请选择 OCR Agent。";return}
            let limit=min(4,max(1,concurrencyLimit))
            let operation=localRecognitionOverride ?? { page,store in try LocalBookOCR.recognize(page:page,store:store) }
            beginRecognition(count:indices.count,label:"本机识别")
            let flag=cancellation,started=Date()
            workTask=Task { @MainActor in
                let summary=await PageWorkQueue.run(indices:indices,maxConcurrent:limit,cancelled:{flag.cancelled},operation:{ index in
                    let recognized=try operation(doc.pages[index],store)
                    return RecognitionUpdate(page:recognized,edit:EditRecord(pageID:recognized.id,action:"生成本机 OCR 初稿，尚未人工核对"))
                },commit:{ index,result in
                    try await MainActor.run {if flag.cancelled{throw CancellationError()};try self.commitRecognition(result,at:index,store:store)}
                },progress:{ progress in
                    await MainActor.run {self.updateRecognitionProgress(progress,document:doc)}
                })
                finishRecognition(summary,label:"本机识别",started:started)
            }
        }catch{fail(error)}
    }
    func exportSearchablePDF() {
        guard !working,flush() else{return}
        guard let doc=document,let store=store else{return}
        do {
            let indices=try PageRange.parse(pageRange,count:doc.pages.count)
            guard !indices.isEmpty else{return}
            let panel=NSSavePanel();panel.allowedContentTypes=[.pdf];panel.canCreateDirectories=true
            panel.nameFieldStringValue=String(doc.title.prefix(60))+"-可搜索扫描版.pdf"
            panel.message="导出\(rangeDescription)：保留扫描页面，添加已有识别文字；未识别页也会保留。"
            guard panel.runModal() == .OK,let url=panel.url else{return}
            let projectPath=store.root.resolvingSymlinksInPath().standardizedFileURL.path
            let outputPath=url.resolvingSymlinksInPath().standardizedFileURL.path
            guard outputPath != projectPath,!outputPath.hasPrefix(projectPath+"/") else{
                throw ArchiveError.message("请将导出文件保存在项目包之外，以免覆盖原始资料。")
            }
            working=true;isStopping=false;activePageIDs=[];total=indices.count;completed=0;cancellation=CancellationFlag();let flag=cancellation
            status="正在导出可搜索扫描版…"
            workTask=Task { @MainActor in
                do {
                    let note=try await Task.detached(priority:.userInitiated) { () throws -> String in
                        let temp=url.deletingLastPathComponent().appendingPathComponent(".shiye-search-\(UUID().uuidString).pdf")
                        defer{try? FileManager.default.removeItem(at:temp)}
                        let report=try SearchablePDFExporter.render(document:doc,store:store,to:temp,pages:indices,cancelled:{flag.cancelled},progress:{done,count in
                            DispatchQueue.main.async{self.completed=done;self.status="正在导出可搜索扫描版 · \(done)/\(count)"}
                        })
                        if flag.cancelled{throw CancellationError()}
                        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
                        let reportData=try encoder.encode(report)
                        if FileManager.default.fileExists(atPath:url.path){_=try FileManager.default.replaceItemAt(url,withItemAt:temp)}
                        else{try FileManager.default.moveItem(at:temp,to:url)}
                        let reportURL=url.deletingPathExtension().appendingPathExtension("ocr-report.json")
                        do{try reportData.write(to:reportURL,options:.atomic)}
                        catch{return "已导出 \(indices.count) 页；质量记录保存失败：\(error.localizedDescription)"}
                        let missing=report.pagesWithoutText.filter{position in indices.indices.contains(position-1) && doc.pages[indices[position-1]].status != .blank}.count
                        return "已导出 \(indices.count) 页可搜索扫描版"+(missing>0 ? "；其中 \(missing) 页尚无文字层" : "")+(report.textMismatches.isEmpty ? "" : "；\(report.textMismatches.count) 页复制校验需复核")+" · OCR 文字仍需核对"
                    }.value
                    status=note;NSWorkspace.shared.activateFileViewerSelecting([url])
                }catch{
                    if error is CancellationError || flag.cancelled{status="已取消导出，完成的识别结果仍保存在项目中。"}
                    else{fail(error);status="导出失败；识别结果仍保存在项目中。"}
                }
                working=false;isStopping=false
            }
        }catch{fail(error)}
    }
    func cancel() { guard working else{return};isStopping=true;cancellation.cancel();workTask?.cancel();status="正在停止，已保存页面会保留…" }
    func updateText(_ text:String,runs:[TextRun]) {
        guard !working,let pi=pageIndex,let bi=document?.pages[pi].blocks.firstIndex(where:{$0.id==selectedBlockID}) else{return}
        if pendingBefore==nil { pendingBefore=(try? JSONEncoder().encode(document!.pages[pi].blocks[bi])).flatMap{String(data:$0,encoding:.utf8)};pendingBlock=selectedBlockID;pendingPage=selectedPageID }
        if let cell=selectedCellID,let ci=document?.pages[pi].blocks[bi].cells.firstIndex(where:{$0.id==cell}) {
            document?.pages[pi].blocks[bi].cells[ci].reviewedText=text;document?.pages[pi].blocks[bi].cells[ci].runs=runs
        } else { document?.pages[pi].blocks[bi].reviewedText=text;document?.pages[pi].blocks[bi].runs=runs }
        document?.pages[pi].blocks[bi].reviewed=false;document?.pages[pi].status = .recognized;saveSoon()
    }
    func modifyBlock(action:String,_ mutate:(inout Block)->Void) {
        guard !working,let pi=pageIndex,let bi=document?.pages[pi].blocks.firstIndex(where:{$0.id==selectedBlockID}) else{return};flush()
        let before=(try? JSONEncoder().encode(document!.pages[pi].blocks[bi])).flatMap{String(data:$0,encoding:.utf8)}
        mutate(&document!.pages[pi].blocks[bi]);document?.pages[pi].status = .recognized
        document?.edits.append(EditRecord(pageID:document!.pages[pi].id,blockID:selectedBlockID,action:action,before:before))
        flush();refreshPreview()
    }
    func addRegion(_ box:Box) {
        guard !working,box.isValid,let pi=pageIndex else{return};flush()
        focusedIssueBox=nil
        var b=Block(order:(document!.pages[pi].blocks.map(\.order).max() ?? 0)+1,box:box,text:"")
        b.fontSize=11;document!.pages[pi].blocks.append(b);document!.pages[pi].status = .recognized
        selectedBlockID=b.id;selectedCellID=nil;drawingRegion=false
        document!.edits.append(EditRecord(pageID:document!.pages[pi].id,blockID:b.id,action:"手工添加区域"));flush();refreshPreview()
    }
    func deleteRegion() {
        guard !working,let pi=pageIndex,let b=block else{return};flush()
        let alert=NSAlert();alert.messageText="删除选中区域？";alert.informativeText="删除记录会保存在项目内，请确认不是遗漏原文。";alert.addButton(withTitle:"删除区域");alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        document?.edits.append(EditRecord(pageID:document!.pages[pi].id,blockID:b.id,action:"删除区域",before:(try? JSONEncoder().encode(b)).flatMap{String(data:$0,encoding:.utf8)}))
        document?.pages[pi].blocks.removeAll{$0.id==b.id};document?.pages[pi].issues.removeAll{$0.blockID==b.id};document?.pages[pi].status = .recognized;selectedBlockID=nil;flush();refreshPreview()
    }
    func confirmPage(blank:Bool = false) {
        guard !working,let pi=pageIndex else{return};flush()
        if blank {
            let a=NSAlert();a.messageText="确认本页为空白？";a.informativeText="本页仍保留页序与原扫描；导出的这一页将为空白。";a.addButton(withTitle:"确认空白");a.addButton(withTitle:"取消")
            guard a.runModal() == .alertFirstButtonReturn else{return}
            document?.edits.append(EditRecord(pageID:document!.pages[pi].id,action:"人工确认空白",before:(try? JSONEncoder().encode(document!.pages[pi].blocks)).flatMap{String(data:$0,encoding:.utf8)}))
            document?.pages[pi].blocks=[];document?.pages[pi].issues=[];document?.pages[pi].status = .blank
        } else {
            guard let p=page,!p.blocks.isEmpty else { errorMessage="请先识别或手工输入本页内容。";return }
            let problems=PDFRenderer.diagnostics(page:p,chineseFont:document!.chineseFont).issues
            let hard=["overflow","missing-glyph","font-unavailable","overlap","bounds","uncovered","cell-bounds","empty-table","empty-text","unresolved-mark","invalid-unicode","retention-unconfirmed","invalid-retention","asset-missing"]
            if problems.contains(where:{hard.contains($0.code)}) { errorMessage="本页仍有排版、缺字、漏块或图像保留问题，请先处理。";return }
            for i in document!.pages[pi].issues.indices { document!.pages[pi].issues[i].resolved=true }
            for i in document!.pages[pi].blocks.indices { document!.pages[pi].blocks[i].reviewed=true }
            document?.pages[pi].error=nil;document?.pages[pi].status = .reviewed
            document?.edits.append(EditRecord(pageID:p.id,action:"用户确认本页已对照核对"))
        }
        flush();refreshPreview()
    }
    func useExistingText() {
        guard !working,let pi=pageIndex,let p=page,!p.hints.isEmpty,p.blocks.isEmpty else{return}
        document?.pages[pi].blocks=PageImporter.groupHints(p.hints,pageID:p.id);document?.pages[pi].status = .recognized
        document?.edits.append(EditRecord(pageID:p.id,action:"采用已有文字候选，尚未人工接受"));flush();refreshPreview()
    }
    func movePage(_ delta:Int) {
        guard !working,let i=pageIndex,let d=document,d.pages.indices.contains(i+delta) else{return};flush()
        document?.pages.swapAt(i,i+delta);document?.edits.append(EditRecord(pageID:selectedPageID!,action:"调整项目页序"));flush()
    }
    func moveBlock(_ delta:Int) {
        guard !working,let pi=pageIndex,let p=page,let i=p.orderedBlocks.firstIndex(where:{$0.id==selectedBlockID}),p.blocks.indices.contains(i+delta) else{return};flush()
        var blocks=p.orderedBlocks;blocks.swapAt(i,i+delta);for j in blocks.indices{blocks[j].order=j+1}
        document?.pages[pi].blocks=blocks;document?.pages[pi].status = .recognized
        document?.edits.append(EditRecord(pageID:p.id,blockID:selectedBlockID,action:"调整区域阅读顺序"));flush();refreshPreview()
    }
    private var followingBoundary:(page:Page,next:Page,tail:Block,head:Block)? {
        guard let doc=document,let index=pageIndex,doc.pages.indices.contains(index+1) else{return nil}
        let page=doc.pages[index],next=doc.pages[index+1]
        guard page.ocrStructure != nil || next.ocrStructure != nil,
              let boundary=EditableBookExporter.paragraphBoundary(from:page,to:next) else{return nil}
        return (page,next,boundary.tail,boundary.head)
    }
    var canJoinFollowingPage:Bool {followingBoundary != nil}
    var suggestsContinuation:Bool {
        followingBoundary.map{$0.page.ocrStructure?.endsMidParagraph==true || $0.next.ocrStructure?.startsMidParagraph==true} ?? false
    }
    func confirmContinuation() {
        guard !working,flush(),let index=pageIndex,let pair=followingBoundary else{return}
        let alert=NSAlert()
        alert.messageText="在 Markdown 中续接这两个段落？"
        alert.informativeText="本页段尾\n\(pair.tail.text.suffix(240))\n\n下一页段首\n\(pair.head.text.prefix(240))"
        alert.addButton(withTitle:"直接相接")
        alert.addButton(withTitle:"加一个空格")
        alert.addButton(withTitle:"取消")
        let choice=alert.runModal()
        guard choice == .alertFirstButtonReturn || choice == .alertSecondButtonReturn,
              let doc=document,doc.pages.indices.contains(index+1),
              doc.pages[index].id==pair.page.id,doc.pages[index+1].id==pair.next.id else{return}
        let join=TextContinuation(nextPageID:pair.next.id,tailBlockID:pair.tail.id,headBlockID:pair.head.id,
                                  separator:choice == .alertSecondButtonReturn ? .space : .none)
        document?.pages[index].textContinuation=join
        document?.edits.append(EditRecord(pageID:pair.page.id,blockID:pair.tail.id,action:"确认导出时跨页续接",after:pair.next.id))
        if flush(){status="已确认跨页续接 · 导出 Markdown 时生效。"}
    }
    func removeContinuation() {
        guard !working,flush(),let index=pageIndex,let p=page,p.textContinuation != nil else{return}
        document?.pages[index].textContinuation=nil
        document?.edits.append(EditRecord(pageID:p.id,action:"取消跨页续接"))
        if flush(){status="已取消跨页续接。"}
    }
    func revealRecognitionRecord() {
        guard let page=page,let store=store,let path=page.agentFailurePath ?? page.recognitions.last?.responsePath else{return}
        do {NSWorkspace.shared.activateFileViewerSelecting([try store.url(path)])}catch{fail(error)}
    }
    func saveProjectCopy() {
        guard !working,let doc=document,let store=store else{return};flush()
        let p=NSSavePanel();p.nameFieldStringValue=String(doc.title.prefix(60))+".shiyebook";p.canCreateDirectories=true;p.message="保存包含原文件、识别结果和修改记录的独立项目副本"
        if p.runModal() == .OK,let url=p.url { do { try store.portableCopy(to:url,document:doc);status="项目副本已保存。" } catch{fail(error)} }
    }
    func exportEditable(format:EditableExportFormat = .pdf,asDraft:Bool = false) {
        guard !working,flush(),let doc=document,let store=store else{return}
        do {
            let indices=try PageRange.parse(pageRange,count:doc.pages.count)
            guard !indices.isEmpty else{return}
            let isPDF=format == .pdf
            let draft = isPDF && (asDraft || indices.contains {doc.pages[$0].status != .reviewed && doc.pages[$0].status != .blank || !PDFRenderer.diagnostics(page:doc.pages[$0],chineseFont:doc.chineseFont).issues.isEmpty})
            let panel=NSSavePanel();panel.allowedContentTypes=[isPDF ? .pdf : UTType(filenameExtension:format.fileExtension) ?? .plainText];panel.canCreateDirectories=true
            panel.nameFieldStringValue=String(doc.title.prefix(60))+(isPDF ? (draft ? "-校对稿.pdf" : "-原文重建.pdf") : "-正文."+format.fileExtension)
            panel.message="导出\(rangeDescription)；原项目会继续保存。"
            guard panel.runModal() == .OK,let url=panel.url else{return}
            let projectPath=store.root.resolvingSymlinksInPath().standardizedFileURL.path
            let outputPath=url.resolvingSymlinksInPath().standardizedFileURL.path
            guard outputPath != projectPath,!outputPath.hasPrefix(projectPath+"/") else{throw ArchiveError.message("请将导出文件保存在项目包之外，以免覆盖原始资料。")}
            working=true;isStopping=false;activePageIDs=[];total=indices.count;completed=0;cancellation=CancellationFlag();let flag=cancellation
            status=isPDF ? "正在排版与校验 PDF…" : "正在导出正文…"
            workTask=Task { @MainActor in
                do {
                    let message=try await Task.detached(priority:.userInitiated) { () throws -> String in
                        let temp=url.deletingLastPathComponent().appendingPathComponent(".shiye-\(UUID().uuidString)."+format.fileExtension)
                        defer{try? FileManager.default.removeItem(at:temp)}
                        var note="",reportData:Data?
                        let progress:(Int,Int)->Void={done,count in
                            DispatchQueue.main.async {
                                guard !flag.cancelled else{return}
                                self.completed=done;self.status=(!isPDF ? "正在导出正文" : done==count ? "正在校验 PDF" : "正在排版 PDF")+" · \(done)/\(count)"
                            }
                        }
                        switch format {
                        case .text:
                            try PDFRenderer.exportText(document:doc,pages:indices,to:temp,cancelled:{flag.cancelled},progress:progress)
                        case .markdown:
                            try EditableBookExporter.exportMarkdown(document:doc,pages:indices,to:temp,cancelled:{flag.cancelled},progress:progress)
                        case .pdf:
                            let report=try PDFRenderer.render(document:doc,store:store,to:temp,pages:indices,forceDraft:draft,cancelled:{flag.cancelled},progress:progress)
                            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
                            reportData=try encoder.encode(report)
                            note=report.draft ? "（校对稿）" : ""
                            if !report.textMismatches.isEmpty{note+="；部分页复制顺序需核对，详见校验记录"}
                        }
                        if flag.cancelled{throw CancellationError()}
                        if FileManager.default.fileExists(atPath:url.path){_=try FileManager.default.replaceItemAt(url,withItemAt:temp)}
                        else{try FileManager.default.moveItem(at:temp,to:url)}
                        if let data=reportData {
                            do{try data.write(to:url.deletingPathExtension().appendingPathExtension("validation.json"),options:.atomic)}
                            catch{note+="；校验记录未能保存：\(error.localizedDescription)"}
                        }
                        return "已导出 \(indices.count) 页\(note)"
                    }.value
                    document?.outputPageMap=indices.map{doc.pages[$0].id};flush();status=message
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }catch{
                    if error is CancellationError || flag.cancelled{status="已停止导出；原文件与项目内容已保留。"}
                    else{fail(error);status="导出未完成，项目内容已保留。"}
                }
                working=false;isStopping=false
            }
        }catch{fail(error)}
    }
    func applyStyle(_ style:String) {
        guard !working,let editor=editor,editor.selectedRange().length>0,let storage=editor.textStorage else{return}
        let range=editor.selectedRange()
        switch style {
        case "bold","italic":
            storage.enumerateAttribute(.font,in:range) { value,r,_ in
                let font=value as? NSFont ?? NSFont.systemFont(ofSize:14)
                let mask:NSFontTraitMask=style=="bold" ? .boldFontMask : .italicFontMask
                let has=NSFontManager.shared.traits(of:font).contains(mask)
                let changed=has ? NSFontManager.shared.convert(font,toNotHaveTrait:mask) : NSFontManager.shared.convert(font,toHaveTrait:mask)
                storage.addAttribute(.font,value:changed,range:r)
            }
        default:
            let v=style=="super" ? 1 : style=="sub" ? -1 : 0
            storage.addAttributes([NSAttributedString.Key("ShiyeScript"):v,.baselineOffset:v==0 ? 0 : v>0 ? 4 : -3],range:range)
        }
        RichTextEditor.commit(editor,model:self)
    }
}
