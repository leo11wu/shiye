import AppKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import PageArchiveCore

final class CancellationFlag {
    private let lock=NSLock();private var value=false
    var cancelled:Bool { lock.lock();defer{lock.unlock()};return value }
    func cancel() { lock.lock();value=true;lock.unlock() }
}
final class AppModel:ObservableObject {
    @Published var document:BookDocument?
    @Published var selectedPageID:String?
    @Published var selectedBlockID:String?
    @Published var selectedCellID:String?
    @Published var pageRange=""
    @Published var provider=ProviderConfiguration()
    @Published var key=""
    @Published var models:[String]=[]
    @Published var working=false
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
    weak var editor:NSTextView?
    var store:ProjectStore?
    var workTask:Task<Void,Never>?
    private var cancellation=CancellationFlag()
    private let defaults:UserDefaults = {
        // The application domain is already managed by standard. Passing our own
        // bundle identifier to suiteName returns nil on macOS.
        guard CommandLine.arguments.contains("--qa") else { return .standard }
        return UserDefaults(suiteName:"local.leowu.Shiye.QA."+UUID().uuidString) ?? .standard
    }()
    private let previewQueue=DispatchQueue(label:"local.leowu.Shiye.preview",qos:.userInitiated)
    private var previewGeneration=0
    private var pendingSave:DispatchWorkItem?
    private var pendingBefore:String?
    private var pendingBlock:String?
    private var pendingPage:String?
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
        if let data=defaults.data(forKey:"provider"),let config=try? JSONDecoder().decode(ProviderConfiguration.self,from:data) { provider=config }
        if !provider.baseURL.isEmpty,provider.rememberKey { key=(try? KeychainStore.read(account:provider.account)) ?? "" }
        if let index=CommandLine.arguments.firstIndex(of:"--project"),CommandLine.arguments.count>index+1 {
            loadProject(URL(fileURLWithPath:CommandLine.arguments[index+1]))
        } else if let last=defaults.string(forKey:"last-project"),FileManager.default.fileExists(atPath:last+"/document.json") { loadProject(URL(fileURLWithPath:last)) }
    }
    func fail(_ error:Error) { errorMessage=error.localizedDescription }
    func newTask() {guard !working,flush() else{return};document=nil;store=nil;selectedPageID=nil;selectedBlockID=nil;selectedCellID=nil;errorMessage=nil;defaults.removeObject(forKey:"last-project");refreshPreview();status="新任务 · 导入 PDF 或图片开始。"}
    @discardableResult
    func flush() -> Bool {
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
        guard flush() else{return};selectedPageID=id;selectedBlockID=nil;selectedCellID=nil;refreshPreview()
    }
    func selectBlock(_ id:String?) { guard flush() else{return};selectedBlockID=id;selectedCellID=nil }
    func loadProject(_ root:URL) {
        guard !working,flush() else{return}
        do {
            guard FileManager.default.fileExists(atPath:root.appendingPathComponent("document.json").path) else { throw ArchiveError.message("请选择包含 document.json 的拾页项目。") }
            let next=try ProjectStore(root:root),doc=try next.load()
            store=next;document=doc;selectedPageID=doc.pages.first?.id;selectedBlockID=nil;selectedCellID=nil
            pageRange="";defaults.set(root.path,forKey:"last-project")
            status="已恢复 \(doc.pages.count) 页 · 原始转写与修改记录均保留";refreshPreview()
        } catch { fail(error) }
    }
    func openProject() {
        let p=NSOpenPanel();p.canChooseDirectories=true;p.canChooseFiles=true;p.allowsMultipleSelection=false;p.treatsFilePackagesAsDirectories=false;p.message="打开拾页项目（.shiyebook）"
        if p.runModal() == .OK,let url=p.url { loadProject(url) }
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
            working=true;cancellation=CancellationFlag();let flag=cancellation
            status="正在导入与检查页面…";total=0;completed=0
            workTask=Task { @MainActor in
                do {
                    let imported=try await Task.detached(priority:.userInitiated) { () throws -> BookDocument in
                        var d=current
                        try PageImporter.append(urls:urls,to:&d,store:store,progress:{ message in DispatchQueue.main.async{self.status=message} },cancelled:{flag.cancelled})
                        return d
                    }.value
                    document=imported;selectedPageID=imported.pages.first?.id;selectedBlockID=nil
                    pageRange="";defaults.set(store.root.path,forKey:"last-project")
                    status="已导入 \(imported.pages.count) 页 · 当前范围：整本；可选择试识别或直接批量处理"
                } catch {
                    if let partial=try? store.load() { document=partial;selectedPageID=partial.pages.first?.id }
                    if error is CancellationError { status="已取消导入；已完成页面已保存。" } else { fail(error);status="导入未完成；已完成页面可恢复。" }
                }
                working=false;refreshPreview()
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
        guard let page=page,let doc=document,let store=store else { originalImage=nil;rebuiltImage=nil;diagnostics=nil;return }
        let font=doc.chineseFont
        previewQueue.async {
            autoreleasepool {
                do {
                    if page.issues.contains(where:{$0.code=="local-draft"}) {
                        let original=page.imagePath.isEmpty ? nil : (try? store.url(page.imagePath)).flatMap{NSImage(contentsOf:$0)}
                        DispatchQueue.main.async {
                            guard self.previewGeneration==generation else{return}
                            self.originalImage=original;self.rebuiltImage=nil;self.diagnostics=nil
                        }
                        return
                    }
                    let dir=try store.url("preview");try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                    let url=dir.appendingPathComponent("page-\(generation).pdf")
                    var single=BookDocument(title:doc.title);single.pages=[page];single.chineseFont=font
                    let report=try PDFRenderer.render(document:single,store:store,to:url,forceDraft:true)
                    guard let previewPDF=PDFDocument(url:url),let previewPage=previewPDF.page(at:0) else {
                        throw ArchiveError.message("重建页预览无法重新打开，请重试排版。")
                    }
                    let rebuilt=previewPage.thumbnail(of:CGSize(width:1500,height:1900),for:.mediaBox)
                    let original=page.imagePath.isEmpty ? nil : (try? store.url(page.imagePath)).flatMap { NSImage(contentsOf:$0) }
                    DispatchQueue.main.async {
                        guard self.previewGeneration==generation else{return}
                        self.rebuiltImage=rebuilt;self.originalImage=original;self.diagnostics=report.pages.first
                    }
                    try? FileManager.default.removeItem(at:url)
                } catch { DispatchQueue.main.async { if self.previewGeneration==generation { self.fail(error) } } }
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
    func loadCurrentKey() { do { key=try KeychainStore.read(account:provider.account) ?? "" } catch { fail(error) } }
    func forgetKey() { do { try KeychainStore.delete(account:provider.account);key="";probeMessage="本服务的拾页钥匙串记录已删除。" } catch { fail(error) } }
    func providerAction(probe:Bool) {
        guard !working else{return};working=true;probeMessage=probe ? "正在发送随机测试图…" : "正在获取模型列表…"
        let backend=CompatibleVisionBackend(config:provider,key:key)
        workTask=Task { @MainActor in
            do {
                if probe { probeMessage=try await backend.probe() }
                else { models=try await backend.models();probeMessage="已获取 \(models.count) 个模型；列表不代表已验证图片能力。" }
            } catch { probeMessage=error is CancellationError ? "已取消请求。" : error.localizedDescription;if error is CancellationError{status="API 请求已取消。"} }
            working=false
        }
    }
    func startRecognition(region:Bool = false) {
        guard !working else{return}
        guard !needsImageReimport else{errorMessage="请先点击“新建修复副本”，避免继续向 API 发送旧版缩小的 PDF 图像。";return}
        guard flush() else{return}
        guard let doc=document,let store=store else{return}
        do {
            _=try provider.endpoint("chat/completions")
            guard !provider.model.isEmpty else { settingsShown=true;return }
            let indices=region ? (pageIndex.map{[$0]} ?? []) : try PageRange.parse(pageRange,count:doc.pages.count)
            guard !indices.isEmpty else{return}
            let box=region ? block?.box : nil, target=region ? selectedBlockID : nil
            if region && box==nil { throw ArchiveError.message("请先选中一个完整区域。") }
            let alert=NSAlert();alert.messageText=region ? "识别选中区域" : "识别所选 \(indices.count) 页"
            alert.informativeText="将向 \((try provider.endpoint("chat/completions")).host ?? provider.baseURL) 发送所选页面的图像\(region ? "裁剪" : "")。\n模型：\(provider.model)\n服务商可能计费；成功缓存会复用。未配置价格时费用显示为未知。"
            alert.addButton(withTitle:"开始识别");alert.addButton(withTitle:"取消")
            guard alert.runModal() == .alertFirstButtonReturn else{return}
            let backend=CompatibleVisionBackend(config:provider,key:key),config=provider
            working=true;total=indices.count;completed=0;cancellation=CancellationFlag();let flag=cancellation
            workTask=Task { @MainActor in
                var failures=0
                for index in indices {
                    do {
                        try Task.checkCancellation();if flag.cancelled { throw CancellationError() }
                        guard var current=document?.pages[index] else{break}
                        status="检查第 \(index+1) 页…"
                        let cacheKey=try backend.cacheKey(page:current,region:box),relative="responses/\(cacheKey).json"
                        let responseURL=try store.url(relative)
                        let imagePage=current
                        let image=try await Task.detached { try PageImporter.image(page:imagePage,store:store) }.value
                        if current.hints.isEmpty {
                            do { current.hints=try await Task.detached { try PageImporter.detectHints(image) }.value }
                            catch { current.issues.append(ReviewIssue("local-detection","本机区域检查不可用，本页需目视核对完整性。")) }
                        }
                        let result:OCRResult
                        if box==nil,FileManager.default.fileExists(atPath:responseURL.path) {
                            status="第 \(index+1) 页 · 复用缓存"
                            if current.recognitions.contains(where:{$0.cacheKey==cacheKey}),!current.blocks.isEmpty,current.status != .failed { completed+=1;continue }
                            result=try OCRParser.parse(Data(contentsOf:responseURL),pageID:current.id)
                        } else {
                            status="正在识别第 \(index+1) 页…"
                            result=try await backend.recognize(image:image,page:current,region:box,status:{ message in DispatchQueue.main.async { self.status="第 \(index+1) 页 · "+message } })
                            try result.response.write(to:responseURL,options:.atomic)
                        }
                        try Task.checkCancellation()
                        let before=String(data:try JSONEncoder().encode(current.blocks),encoding:.utf8)
                        if let target=target,let bi=current.blocks.firstIndex(where:{$0.id==target}) {
                            let old=current.blocks[bi]
                            var replacement=result.blocks
                            var blockIDMap:[String:String]=[:]
                            for j in replacement.indices {
                                let previousID=replacement[j].id
                                replacement[j].id=j==0 ? old.id : old.id+"-"+UUID().uuidString;replacement[j].order=old.order+j
                                blockIDMap[previousID]=replacement[j].id
                                for ci in replacement[j].cells.indices{replacement[j].cells[ci].id=replacement[j].id+"-c\(ci+1)"}
                            }
                            let ordered=current.orderedBlocks;let at=ordered.firstIndex(where:{$0.id==target})!
                            var all=ordered;all.replaceSubrange(at...at,with:replacement)
                            for j in all.indices { all[j].order=j+1 };current.blocks=all
                            current.issues.removeAll{$0.blockID==target};current.issues.append(contentsOf:result.issues.map { var issue=$0;if let id=issue.blockID{issue.blockID=blockIDMap[id]};return issue })
                        } else {
                            current.blocks=result.blocks;current.issues=current.issues.filter{$0.code=="local-detection"}+result.issues;current.printedLabel=result.printedLabel
                        }
                        current.status = .recognized;current.error=nil
                        current.recognitions.append(RecognitionRecord(requestedModel:config.model,returnedModel:result.returnedModel,endpoint:try config.endpoint("chat/completions").absoluteString,cacheKey:cacheKey,responsePath:relative,promptTokens:result.promptTokens,completionTokens:result.completionTokens,promptVersion:CompatibleVisionBackend.promptVersion))
                        document?.pages[index]=current;document?.edits.append(EditRecord(pageID:current.id,blockID:target,action:"应用视觉转写，旧内容保留于记录",before:before))
                        if let d=document { try store.save(d) }
                        selectedPageID=current.id;refreshPreview();completed+=1
                    } catch {
                        if error is CancellationError || Task.isCancelled { status="已取消；完成页与校对记录已保存。";break }
                        failures+=1;completed+=1
                        document?.pages[index].status = .failed;document?.pages[index].error=error.localizedDescription
                        if let d=document { try? store.save(d) }
                        status="第 \(index+1) 页失败：\(error.localizedDescription)"
                        // Authentication/parameter failures should not be repeated on every page.
                        if ["HTTP 401","HTTP 402","HTTP 403","HTTP 400","HTTP 404","HTTP 422"].contains(where:{error.localizedDescription.contains($0)}) { break }
                    }
                }
                working=false
                if !flag.cancelled && !Task.isCancelled { status="本轮结束 · 完成 \(completed)/\(total) 页，失败 \(failures) 页 · 识别完成不等于人工核对完成" }
                refreshPreview()
            }
        } catch { fail(error) }
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
    func startLocalRecognition() {
        guard !working else{return}
        guard !needsImageReimport else{errorMessage="此项目使用旧版 PDF 图像。请先点击“新建修复副本”，再识别清晰页面；旧项目仍保留。";return}
        guard flush() else{return}
        guard let doc=document,let store=store else{return}
        do {
            let selected=try PageRange.parse(pageRange,count:doc.pages.count)
            let indices=selected.filter{doc.pages[$0].blocks.isEmpty && doc.pages[$0].status != .blank}
            guard !indices.isEmpty else{status="范围内已有转写或编辑区域，本机初稿会跳过这些页面。";return}
            working=true;total=indices.count;completed=0;cancellation=CancellationFlag();let flag=cancellation
            status="正在生成本机 OCR 初稿 · \(indices.count) 页"
            let started=Date()
            workTask=Task { @MainActor in
                var failures=0
                var persistenceFailure:String?
                for index in indices {
                    do {
                        try Task.checkCancellation();if flag.cancelled{throw CancellationError()}
                        guard let original=document?.pages[index] else{break}
                        status="本机初稿 · 第 \(index+1) 页 · \(completed)/\(total)"
                        let recognized=try await Task.detached(priority:.userInitiated) {
                            try LocalBookOCR.recognize(page:original,store:store)
                        }.value
                        try Task.checkCancellation();if flag.cancelled{throw CancellationError()}
                        guard var next=document else{break}
                        next.pages[index]=recognized
                        next.edits.append(EditRecord(pageID:recognized.id,action:"生成本机 OCR 初稿，尚未人工核对"))
                        do{try store.save(next)}
                        catch{persistenceFailure=error.localizedDescription;fail(error);break}
                        document=next;completed+=1
                    } catch {
                        if error is CancellationError || Task.isCancelled || flag.cancelled{break}
                        guard var next=document else{break}
                        next.pages[index].status = .failed;next.pages[index].error=error.localizedDescription
                        do{try store.save(next)}
                        catch{persistenceFailure=error.localizedDescription;fail(error);break}
                        document=next;failures+=1;completed+=1
                    }
                }
                working=false
                if let failure=persistenceFailure{
                    status="保存失败，批处理已停止；未保存页可重试。"+failure
                }else if flag.cancelled || Task.isCancelled{
                    status="已暂停本机识别 · 完成页已保存，再次识别会跳过已有结果。"
                } else {
                    let seconds=Int(Date().timeIntervalSince(started))
                    status="本机初稿 \(completed-failures) 页 · 失败 \(failures) 页 · \(seconds) 秒；小字、音标和表格仍需核对。"
                }
                refreshPreview()
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
            working=true;total=indices.count;completed=0;cancellation=CancellationFlag();let flag=cancellation
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
                working=false
            }
        }catch{fail(error)}
    }
    func cancel() { cancellation.cancel();workTask?.cancel();status="正在取消，保留已完成页面…" }
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
    func saveProjectCopy() {
        guard !working,let doc=document,let store=store else{return};flush()
        let p=NSSavePanel();p.nameFieldStringValue=String(doc.title.prefix(60))+".shiyebook";p.canCreateDirectories=true;p.message="保存包含原文件、识别结果和修改记录的独立项目副本"
        if p.runModal() == .OK,let url=p.url { do { try store.portableCopy(to:url,document:doc);status="项目副本已保存。" } catch{fail(error)} }
    }
    func exportPDF(text:Bool = false,asDraft:Bool = false) {
        guard !working,let doc=document,let store=store else{return};flush()
        do {
            let indices=try PageRange.parse(pageRange,count:doc.pages.count)
            let draft=asDraft || indices.contains { doc.pages[$0].status != .reviewed && doc.pages[$0].status != .blank || !PDFRenderer.diagnostics(page:doc.pages[$0],chineseFont:doc.chineseFont).issues.isEmpty }
            let p=NSSavePanel();p.allowedContentTypes=[text ? .plainText : .pdf];p.canCreateDirectories=true
            p.nameFieldStringValue=String(doc.title.prefix(60))+(draft ? "-校对稿" : "-原文重建")+(text ? ".txt" : ".pdf")
            p.message="导出页范围：\(pageRange.isEmpty ? "全部" : pageRange)；原项目会继续保存。"
            guard p.runModal() == .OK,let url=p.url else{return}
            working=true;status=text ? "正在导出文字…" : "正在排版与校验 PDF…"
            workTask=Task { @MainActor in
                do {
                    let message=try await Task.detached(priority:.userInitiated) { () throws -> String in
                        let temp=url.deletingLastPathComponent().appendingPathComponent(".shiye-\(UUID().uuidString)."+(text ? "txt" : "pdf"))
                        defer{try? FileManager.default.removeItem(at:temp)}
                        var note=""
                        if text { try PDFRenderer.exportText(document:doc,pages:indices,to:temp) }
                        else {
                            let report=try PDFRenderer.render(document:doc,store:store,to:temp,pages:indices,forceDraft:draft)
                            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
                            try encoder.encode(report).write(to:url.deletingPathExtension().appendingPathExtension("validation.json"),options:.atomic)
                            note=report.draft ? "（校对稿）" : ""
                            if !report.textMismatches.isEmpty { note+="；部分页复制顺序需核对，详见校验记录" }
                        }
                        if FileManager.default.fileExists(atPath:url.path) { _=try FileManager.default.replaceItemAt(url,withItemAt:temp) }
                        else { try FileManager.default.moveItem(at:temp,to:url) }
                        return "已导出 \(indices.count) 页\(note)"
                    }.value
                    document?.outputPageMap=indices.map{doc.pages[$0].id};flush();status=message;NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch { fail(error);status="导出未完成，项目内容已保留。" }
                working=false
            }
        } catch { fail(error) }
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
