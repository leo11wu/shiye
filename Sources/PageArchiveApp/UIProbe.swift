// Developer integration check. Operates this app's model/views only; no input synthesis or desktop capture.
import AppKit
import PDFKit
import Darwin
import PageArchiveCore

final class UIProbe {
    let model:AppModel,window:NSWindow,root:URL
    var checks:[String:Bool]=[:]
    init(model:AppModel,window:NSWindow,root:URL){self.model=model;self.window=window;self.root=root}
    func start() {
        do{try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)}catch{finish(error);return}
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
            do{
                self.checks["window_visible"]=self.window.isVisible
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
    func finish(_ error:Error?) {
        do {
            checks["no_unexpected_alert"]=model.errorMessage==nil
            var result:[String:Any]=["checks":checks,"passed":error==nil && !checks.values.contains(false),"method":"native-view-render-and-model-integration; no mouse automation","status":model.status]
            if let message=model.errorMessage {result["model_error"]=message}
            var usage=rusage();if getrusage(RUSAGE_SELF,&usage)==0{result["peak_resident_bytes"]=usage.ru_maxrss}
            if let error=error{result["error"]=error.localizedDescription}
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("ui-results.json"),options:.atomic)
        } catch {fputs("UI check failed: \(error)\n",stderr)}
        model.settingsShown=false
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2){NSApp.terminate(nil)}
    }
}
