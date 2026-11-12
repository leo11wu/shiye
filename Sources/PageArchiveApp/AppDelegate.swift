import AppKit
import SwiftUI
import PageArchiveCore

final class AppDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow!
    let model=AppModel()
    func applicationDidFinishLaunching(_ notification:Notification) {
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:820),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="拾页 · 整本扫描书转换";window.minSize=NSSize(width:1180,height:740)
        window.contentView=NSHostingView(rootView:WorkspaceView(model:model))
        window.center();window.makeKeyAndOrderFront(nil);buildMenu()
        NSApp.activate(ignoringOtherApps:true)
        if ProcessInfo.processInfo.environment["SHIYE_STARTUP_CHECK"] == "1",window.isVisible {
            fputs("SHIYE_MAIN_WINDOW_READY\n",stderr)
        }
        model.restoreStartupProject()
        if let i=CommandLine.arguments.firstIndex(of:"--ui-check"),CommandLine.arguments.count>i+1 {
            let probe=UIProbe(model:model,window:window,root:URL(fileURLWithPath:CommandLine.arguments[i+1]));probe.start()
        }
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard model.working else{return model.flush() ? .terminateNow : .terminateCancel}
        model.cancel()
        let pending=model.workTask
        Task { @MainActor in
            await pending?.value
            sender.reply(toApplicationShouldTerminate:model.flush())
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification:Notification){if !model.working{model.flush()}}
    func application(_ sender:NSApplication,openFiles filenames:[String]) {
        if CommandLine.arguments.contains("--qa") || CommandLine.arguments.contains("--ui-check") {
            sender.reply(toOpenOrPrint:.success);return
        }
        let urls=filenames.map{URL(fileURLWithPath:$0)}
        if urls.count==1,urls[0].pathExtension=="shiyebook" {model.beginOpenProject(urls[0])}else{model.beginImport(urls)}
        sender.reply(toOpenOrPrint:.success)
    }
    func buildMenu() {
        let main=NSMenu(),appItem=NSMenuItem(),appMenu=NSMenu()
        main.addItem(appItem);appItem.submenu=appMenu
        appMenu.addItem(withTitle:"关于拾页",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
        appMenu.addItem(.separator());appMenu.addItem(withTitle:"OCR Agent 设置…",action:#selector(settings),keyEquivalent:",").target=self
        appMenu.addItem(.separator());appMenu.addItem(withTitle:"退出拾页",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let fileItem=NSMenuItem(),file=NSMenu(title:"文件");main.addItem(fileItem);fileItem.submenu=file
        file.addItem(withTitle:"导入文件…",action:#selector(importFiles),keyEquivalent:"o").target=self
        file.addItem(withTitle:"打开项目…",action:#selector(openProject),keyEquivalent:"").target=self
        file.addItem(withTitle:"保存",action:#selector(save),keyEquivalent:"s").target=self
        file.addItem(withTitle:"导出可搜索 PDF…",action:#selector(export),keyEquivalent:"e").target=self
        file.addItem(withTitle:"导出原页重建 PDF…",action:#selector(exportRebuilt),keyEquivalent:"").target=self
        let editItem=NSMenuItem(),edit=NSMenu(title:"编辑");main.addItem(editItem);editItem.submenu=edit
        for (title,action,key) in [("撤销",Selector(("undo:")),"z"),("剪切",#selector(NSText.cut(_:)),"x"),("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] {edit.addItem(withTitle:title,action:action,keyEquivalent:key)}
        let helpItem=NSMenuItem(),help=NSMenu(title:"帮助");main.addItem(helpItem);helpItem.submenu=help
        help.addItem(withTitle:"打开排版技术样张",action:#selector(fixture),keyEquivalent:"").target=self
        NSApp.mainMenu=main
    }
    @objc func settings(){model.settingsShown=true}
    @objc func importFiles(){model.importFiles()}
    @objc func openProject(){model.openProject()}
    @objc func save(){model.flush()}
    @objc func export(){model.exportSearchablePDF()}
    @objc func exportRebuilt(){model.exportEditable()}
    @objc func fixture(){model.loadFixture()}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
}
