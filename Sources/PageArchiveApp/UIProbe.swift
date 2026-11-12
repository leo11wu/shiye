// Developer integration check. Operates this app's model/views only; no input synthesis or desktop capture.
import AppKit
import PDFKit
import Darwin
import PageArchiveCore

/// A synchronous recognizer substitute whose workers wait off the main thread.
/// Fixtures test application state and persistence, never OCR accuracy.
private final class BatchProbeRecognizer: @unchecked Sendable {
    private let condition=NSCondition()
    private var released=Set<Int>(),allReleased=false,started:[Int]=[]
    private var active=0,peak=0
    private let failingPages:Set<Int>
    init(failingPages:Set<Int> = [],released:Bool = false) {
        self.failingPages=failingPages;allReleased=released
    }
    var startedPages:[Int] {condition.lock();defer{condition.unlock()};return started}
    var peakConcurrent:Int {condition.lock();defer{condition.unlock()};return peak}
    func release(_ page:Int? = nil) {
        condition.lock()
        if let page=page {released.insert(page)} else {allReleased=true}
        condition.broadcast();condition.unlock()
    }
    private func waitForPermission(_ page:Int) throws {
        condition.lock();started.append(page);active+=1;peak=max(peak,active)
        defer{active-=1;condition.unlock()}
        let deadline=Date().addingTimeInterval(15)
        while !allReleased && !released.contains(page) {
            guard condition.wait(until:deadline) else{throw ArchiveError.message("批量界面检查等待识别放行超时。")}
        }
    }
    func recognize(_ page:Page) throws -> Page {
        try waitForPermission(page.sourcePage)
        if failingPages.contains(page.sourcePage) {throw ArchiveError.message("界面检查预设：此页识别失败，可单独重试。")}
        var result=page
        result.blocks=[Block(id:page.id+"-text",order:1,box:Box(0.09,0.15,0.82,0.55),
            text:"第 \(page.sourcePage) 页 · 批量处理演示\n\n本页是自动检查使用的预设文字，不是扫描识别质量样本。\n\n完成一页就保存一页；已有转写与人工校对结果会保留。\n处理其他页面时，仍可浏览当前文档。",fontSize:12)]
        result.status = .recognized;result.error=nil
        result.issues=[ReviewIssue("local-draft","本机初稿演示，预设文字，尚未人工核对。")]
        result.textLayerAssessment="界面检查预设文字，非 OCR 结果"
        return result
    }
}

final class UIProbe {
    let model:AppModel,window:NSWindow,root:URL
    var checks:[String:Bool]=[:]
    private var finished=false
    private var batchDetails:[String:Any]=[:]
    private var batchRecognizers:[BatchProbeRecognizer]=[]
    init(model:AppModel,window:NSWindow,root:URL){self.model=model;self.window=window;self.root=root}
    func start() {
        do{try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)}catch{finish(error);return}
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
            do{
                self.checks["window_visible"]=self.window.isVisible
                if CommandLine.arguments.contains("--agent-check"),CommandLine.arguments.contains("--qa") {
                    self.startAgentChecks();return
                }
                if CommandLine.arguments.contains("--batch-check") {
                    self.startBatchChecks();return
                }
                if CommandLine.arguments.contains("--book-preview") {
                    self.waitForPreview(tries:60) {
                        do {
                            try self.snapshot("book-workspace.png")
                            self.checks["local_draft_text_view"]=self.model.isLocalDraftPage
                            self.checks["original_image_loaded"]=self.model.originalImage != nil
                            self.checks["has_page_text"] = !(self.model.page?.blocks.isEmpty ?? true)
                            self.finish(nil)
                        }catch{self.finish(error)}
                    }
                    return
                }
                self.model.newTask();try self.snapshot("01-welcome.png")
                self.model.loadFixture();self.waitForPreview(tries:60){self.editAndSave()}
            }catch{self.finish(error)}
        }
    }
    func waitForPreview(tries:Int,then:@escaping()->Void) {
        if let message=model.errorMessage {finish(ArchiveError.message(message));return}
        if model.rebuiltImage != nil || (model.isLocalDraftPage && model.originalImage != nil) {DispatchQueue.main.asyncAfter(deadline:.now()+0.3,execute:then);return}
        guard tries>0 else{finish(ArchiveError.message("界面预览未完成。"));return}
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2){self.waitForPreview(tries:tries-1,then:then)}
    }
    func editAndSave() {
        do {
            try snapshot("02-workspace.png")
            checks["fixture_layout_clean"]=model.diagnostics?.issues.isEmpty==true
            model.selectBlock("title")
            let original=model.block!.rawText,new=original+"校验"
            model.updateText(new,runs:[TextRun(new,style:TextStyle(bold:true))]);model.flush()
            checks["raw_text_preserved"]=model.block!.rawText==original
            let saved=try model.store!.load()
            checks["edit_persisted"]=saved.pages[0].blocks[0].reviewedText==new
            model.refreshPreview()
            DispatchQueue.main.asyncAfter(deadline:.now()+1.0) {
                do {
                    try self.snapshot("03-editor.png")
                    self.model.confirmPage()
                    self.checks["review_status"]=self.model.page?.status == .reviewed
                    let output=self.root.appendingPathComponent("ui-integration.pdf")
                    let report=try PDFRenderer.render(document:self.model.document!,store:self.model.store,to:output)
                    self.checks["export_reopen_copy"] = !report.draft && report.textMismatches.isEmpty && (PDFDocument(url:output)?.string?.contains(new) ?? false)
                    self.model.loadProject(self.model.store!.root)
                    self.checks["project_reopened"]=self.model.document?.pages[0].blocks[0].reviewedText==new
                    self.model.settingsShown=true
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.6){
                        do{try self.snapshot("04-api-settings.png");self.checks["settings_sheet"]=self.window.attachedSheet != nil;self.finish(nil)}catch{self.finish(error)}
                    }
                } catch {self.finish(error)}
            }
        } catch {finish(error)}
    }
    func snapshot(_ name:String) throws {
        guard model.errorMessage==nil else {throw ArchiveError.message("检查时出现意外弹窗："+model.errorMessage!)}
        let target=name.contains("settings") ? (window.attachedSheet?.contentView ?? window.contentView!) : window.contentView!
        target.layoutSubtreeIfNeeded();target.displayIfNeeded()
        guard let rep=target.bitmapImageRepForCachingDisplay(in:target.bounds) else{throw ArchiveError.message("无法生成原生视图检查图。")}
        target.cacheDisplay(in:target.bounds,to:rep)
        guard let data=rep.representation(using:.png,properties:[:]) else{throw ArchiveError.message("无法保存原生视图检查图。")}
        try data.write(to:root.appendingPathComponent(name),options:.atomic)
    }
    private func encodedPages(_ pages:[Page]) throws -> Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(pages)
    }
    private func createBatchProject(_ name:String) throws -> ProjectStore {
        let store=try ProjectStore(root:root.appendingPathComponent(name+".shiyebook"))
        let fixture=Fixtures.document(),imagePath="pages/known-source.png",pdfURL=try store.url("pages/known-source.pdf")
        _=try PDFRenderer.render(document:fixture,store:nil,to:pdfURL)
        guard let pdf=PDFDocument(url:pdfURL),let source=pdf.page(at:0) else{throw ArchiveError.message("无法准备批量检查样张。")}
        let thumbnail=source.thumbnail(of:CGSize(width:900,height:1250),for:.mediaBox)
        guard let image=thumbnail.cgImage(forProposedRect:nil,context:nil,hints:nil) else{throw ArchiveError.message("无法准备批量检查图像。")}
        let imageURL=try store.url(imagePath)
        try PageImporter.writePNG(image,to:imageURL)
        var document=BookDocument(title:"批量处理演示 · 已知测试文字，非 OCR 结果")
        for number in 1...6 {
            var page=fixture.pages[0]
            page.id=name+"-page-\(number)";page.sourcePage=number
            page.imagePath=imagePath;page.imageSHA256=try Digest.file(imageURL)
            if number != 1 {page.blocks=[];page.status = .imported;page.issues=[]}
            document.pages.append(page)
        }
        try store.save(document)
        return store
    }
    private func waitForBatchIdle(tries:Int=150,then:@escaping()->Void) {
        guard !finished else{return}
        if let message=model.errorMessage {finish(ArchiveError.message(message));return}
        if !model.working {DispatchQueue.main.asyncAfter(deadline:.now()+0.2,execute:then);return}
        guard tries>0 else{finish(ArchiveError.message("批量界面检查等待任务完成超时。"));return}
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1){self.waitForBatchIdle(tries:tries-1,then:then)}
    }
    private func startBatchChecks() {
        do {
            model.newTask()
            DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
                do {
                    try self.snapshot("01-batch-welcome.png")
                    let store=try self.createBatchProject("batch-complete")
                    self.model.loadProject(store.root);self.model.concurrencyLimit=2
                    self.waitForPreview(tries:60){self.runCompleteBatch(store:store)}
                }catch{self.finish(error)}
            }
        }
    }
    private func runCompleteBatch(store:ProjectStore) {
        do {
            guard let initial=model.document else{throw ArchiveError.message("批量检查项目未打开。")}
            let reviewed=try encodedPages([initial.pages[0]]),browseID=initial.pages[5].id
            let recognizer=BatchProbeRecognizer(failingPages:[4]);batchRecognizers.append(recognizer)
            model.localRecognitionOverride={page,_ in try recognizer.recognize(page)}
            var captured=false
            model.batchProgressObserver={progress in
                guard !self.finished else{return}
                if !captured && progress.activeIndices.count==2 {
                    captured=true
                    self.checks["batch_two_active_pages"]=self.model.activePageIDs.count==2 && self.model.total==5
                    self.model.selectPage(browseID)
                    self.checks["batch_can_browse_while_working"]=self.model.working && self.model.selectedPageID==browseID
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
                        do{try self.snapshot("02-batch-running.png");recognizer.release()}
                        catch{self.finish(error)}
                    }
                }
            }
            model.startLocalRecognition()
            checks["batch_started"]=model.working
            waitForBatchIdle {
                do {
                    self.model.batchProgressObserver=nil
                    guard let current=self.model.document else{throw ArchiveError.message("批量结果缺失。")}
                    let saved=try store.load()
                    let savedReviewed=try self.encodedPages([saved.pages[0]])
                    self.checks["batch_parallel_workers"]=recognizer.peakConcurrent==2
                    self.checks["batch_skips_reviewed_page"]=recognizer.startedPages.sorted()==[2,3,4,5,6] && savedReviewed==reviewed
                    self.checks["batch_failure_isolated"]=saved.pages[3].status == .failed && saved.pages.filter{$0.status == .recognized}.count==4
                    self.checks["batch_completion_counts"]=self.model.completed==5 && self.model.total==5 && self.model.activePageIDs.isEmpty
                    self.checks["batch_selection_not_stolen"]=self.model.selectedPageID==browseID
                    self.checks["batch_saved_matches_memory"]=(try self.encodedPages(saved.pages))==(try self.encodedPages(current.pages))
                    self.batchDetails["complete_started_source_pages"]=recognizer.startedPages
                    self.batchDetails["complete_status"]=self.model.status
                    try self.snapshot("03-batch-complete.png")
                    self.startCancellationBatch()
                }catch{self.finish(error)}
            }
        }catch{finish(error)}
    }
    private func startCancellationBatch() {
        do {
            let store=try createBatchProject("batch-resume")
            model.localRecognitionOverride=nil;model.loadProject(store.root)
            guard let initial=model.document else{throw ArchiveError.message("续做检查项目未打开。")}
            let browseID=initial.pages[5].id
            let recognizer=BatchProbeRecognizer();batchRecognizers.append(recognizer)
            model.localRecognitionOverride={page,_ in try recognizer.recognize(page)}
            var began=false,requestedCancel=false
            model.batchProgressObserver={progress in
                guard !self.finished else{return}
                if !began && progress.activeIndices.count==2 {
                    began=true;self.model.selectPage(browseID)
                    recognizer.release(2)
                }
                if !requestedCancel && progress.succeeded==1 {
                    requestedCancel=true
                    do {
                        let saved=try store.load()
                        self.checks["batch_each_completion_saved"]=saved.pages[1].status == .recognized && !saved.pages[1].blocks.isEmpty
                        self.model.cancel()
                        self.checks["batch_stopping_state"]=self.model.working && self.model.isStopping
                        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
                            do{try self.snapshot("04-batch-stopping.png");recognizer.release()}
                            catch{self.finish(error)}
                        }
                    }catch{self.finish(error)}
                }
            }
            model.startLocalRecognition()
            waitForBatchIdle {
                do {
                    self.model.batchProgressObserver=nil
                    let saved=try store.load()
                    self.checks["batch_cancel_preserves_completed"]=saved.pages[1].status == .recognized && self.model.completed==1
                    self.checks["batch_cancel_leaves_remaining_pending"]=saved.pages.dropFirst(2).allSatisfy{$0.status == .imported && $0.blocks.isEmpty}
                    self.checks["batch_cancel_not_page_failure"] = !saved.pages.contains{$0.status == .failed} && self.model.errorMessage==nil
                    self.checks["batch_cancel_stops_admission"]=recognizer.startedPages.allSatisfy{(2...4).contains($0)}
                    self.checks["batch_cancel_selection_preserved"]=self.model.selectedPageID==browseID
                    self.batchDetails["cancel_started_source_pages"]=recognizer.startedPages
                    self.batchDetails["cancel_status"]=self.model.status
                    self.resumeCancelledBatch(store:store,preserved:try self.encodedPages(Array(saved.pages.prefix(2))))
                }catch{self.finish(error)}
            }
        }catch{finish(error)}
    }
    private func resumeCancelledBatch(store:ProjectStore,preserved:Data) {
        do {
            model.localRecognitionOverride=nil;model.loadProject(store.root)
            guard let reopened=model.document else{throw ArchiveError.message("无法重开已停止的项目。")}
            checks["batch_reopen_preserves_saved_pages"]=(try encodedPages(Array(reopened.pages.prefix(2))))==preserved
            let browseID=reopened.pages[5].id
            model.selectPage(browseID)
            let recognizer=BatchProbeRecognizer(released:true);batchRecognizers.append(recognizer)
            model.localRecognitionOverride={page,_ in try recognizer.recognize(page)}
            model.startLocalRecognition()
            waitForBatchIdle {
                do {
                    guard let current=self.model.document else{throw ArchiveError.message("续做结果缺失。")}
                    let saved=try store.load()
                    self.checks["batch_resume_only_pending_pages"]=recognizer.startedPages.sorted()==[3,4,5,6]
                    self.checks["batch_resume_keeps_previous_results"]=(try self.encodedPages(Array(saved.pages.prefix(2))))==preserved
                    self.checks["batch_resume_complete"]=self.model.completed==4 && self.model.total==4 && saved.pages.filter{$0.status == .recognized}.count==5
                    self.checks["batch_resume_selection_preserved"]=self.model.selectedPageID==browseID
                    self.checks["batch_resume_saved_matches_memory"]=(try self.encodedPages(saved.pages))==(try self.encodedPages(current.pages))
                    self.batchDetails["resume_started_source_pages"]=recognizer.startedPages
                    self.batchDetails["resume_status"]=self.model.status
                    try self.snapshot("05-batch-resumed.png")
                    self.finish(nil)
                }catch{self.finish(error)}
            }
        }catch{finish(error)}
    }
    private func startAgentChecks() {
        func argument(_ name:String)->String? {
            let args=CommandLine.arguments
            guard let index=args.firstIndex(of:name),args.indices.contains(index+1) else{return nil}
            return args[index+1]
        }
        do {
            guard let image=argument("--agent-fixture"),let base=argument("--agent-url"),
                  let skillPath=argument("--agent-skill"),
                  let url=URL(string:base),url.scheme=="http",url.host=="127.0.0.1" else {
                throw ArchiveError.message("OCR Agent 界面检查需要本机模拟接口、样张和 Skill。")
            }
            checks["agent_bundled_skill"]=try OCRSkill.bundled().text.contains("表格")
            let skill=try OCRSkill(file:URL(fileURLWithPath:skillPath))
            try model.setOCRSkill(skill)
            model.provider.baseURL=base;model.provider.model="fixture-vision";model.provider.rememberKey=false
            model.recognitionMode = .api
            model.visionConfirmationOverride={ [weak self] alert in
                self?.checks["agent_displays_service_and_skill"]=alert.informativeText.contains("127.0.0.1") && alert.informativeText.contains(skill.name)
                return true
            }
            model.beginImport([URL(fileURLWithPath:image)],suggestedTitle:"OCR Agent 验收样张")
            waitForBatchIdle {
                self.model.startRecognition()
                self.waitForBatchIdle {
                    self.waitForPreview(tries:70) {self.checkAgentOutput(skill:skill)}
                }
            }
        }catch{finish(error)}
    }
    private func checkAgentOutput(skill:OCRSkill) {
        do {
            guard let store=model.store,let page=try store.load().pages.first,
                  let record=page.recognitions.last else {throw ArchiveError.message("OCR Agent 未保存识别结果。")}
            let audit=try JSONDecoder().decode(OCRAgentAudit.self,from:Data(contentsOf:store.url(record.responsePath)))
            checks["agent_saved_pending_review"]=page.status == .recognized && page.ocrStructure?.layout == .leftToRight
            checks["agent_true_vision_witness"]=audit.evidence.count>=15 && audit.witnessError==nil
            checks["agent_selected_targeted_reread"]=audit.selectedAttempt==2 && audit.attempts.count==2 &&
                audit.attempts[0].issues.contains{$0.code=="agent-uncovered"} && audit.attempts[1].cropBoxes.contains{$0.y>0.8}
            checks["agent_audit_provenance"]=audit.skillHash==skill.digest && record.returnedModel=="fixture-vision" &&
                audit.attempts.map(\.requestIDs)==[["fixture-1"],["fixture-2"]]
            checks["agent_structured_result"]=page.blocks.count==10 && page.printedLabel=="27" &&
                page.blocks.contains{$0.kind == .footnote && $0.noteID=="1"} &&
                page.blocks.contains{$0.noteReferences==["1"]} &&
                page.blocks.contains{$0.cells.contains{$0.columnSpan==3}}
            let output=root.appendingPathComponent("agent-sample.md")
            try EditableBookExporter.exportMarkdown(document:store.load(),pages:[0],to:output)
            let markdown=try String(contentsOf:output,encoding:.utf8)
            let left=markdown.range(of:"抄錄者把例字分作兩組。"),right=markdown.range(of:"右欄記的是同一次採錄。")
            checks["agent_editable_export"]=left != nil && right != nil && left!.lowerBound<right!.lowerBound &&
                markdown.contains("標音依原稿保留") && markdown.contains("colspan=\"3\"")
            if let issue=page.issues.first(where:{$0.box != nil}) {
                model.selectIssue(issue);checks["agent_issue_location"]=model.focusedIssueBox==issue.box
            }else{
                let location=page.blocks[0].box
                model.selectIssue(ReviewIssue("test","定位",box:location))
                checks["agent_issue_location"]=model.focusedIssueBox==location
            }
            try snapshot("ocr-agent-workspace.png")
            guard !checks.values.contains(false) else {finish(ArchiveError.message("OCR Agent 单页验收未通过。"));return}
            guard let paragraph=page.blocks.first(where:{$0.kind == .paragraph}) else {throw ArchiveError.message("验收样张缺少正文。")}
            model.selectBlock(paragraph.id)
            let edited=paragraph.rawText+" 核對"
            model.updateText(edited,runs:[]);_ = model.flush()
            model.startRecognition()
            waitForBatchIdle {
                do {
                    let saved=try store.load().pages[0]
                    self.checks["agent_cache_keeps_manual_edits"]=saved.recognitions.count==1 &&
                        saved.blocks.first(where:{$0.id==paragraph.id})?.reviewedText==edited
                    self.finish(nil)
                }catch{self.finish(error)}
            }
        }catch{finish(error)}
    }
    func finish(_ error:Error?) {
        guard !finished else{return};finished=true
        for recognizer in batchRecognizers {recognizer.release()}
        model.localRecognitionOverride=nil;model.batchProgressObserver=nil;model.visionConfirmationOverride=nil
        do {
            checks["no_unexpected_alert"]=model.errorMessage==nil
            var result:[String:Any]=["checks":checks,"passed":error==nil && !checks.values.contains(false),"method":"native-view-render-and-model-integration; no mouse automation","status":model.status]
            if let message=model.errorMessage {result["model_error"]=message}
            var usage=rusage();if getrusage(RUSAGE_SELF,&usage)==0{result["peak_resident_bytes"]=usage.ru_maxrss}
            if let error=error{result["error"]=error.localizedDescription}
            if CommandLine.arguments.contains("--batch-check") {
                result["batch_details"]=batchDetails
                result["scope"]="Six-page known fixtures and a controlled local recognizer substitute; tests batch UI state, cancellation, resume and persistence, not OCR accuracy or mouse automation."
            }
            if CommandLine.arguments.contains("--agent-check") {
                result["scope"]="Real local Vision and application HTTP, with controlled replies on loopback. No cloud OCR accuracy claim."
            }
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("ui-results.json"),options:.atomic)
        } catch {fputs("UI check failed: \(error)\n",stderr)}
        model.settingsShown=false;model.errorMessage=nil
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2){NSApp.terminate(nil)}
    }
}
