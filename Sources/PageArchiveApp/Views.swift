import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PageArchiveCore

private let accent=Color(red:0.14,green:0.38,blue:0.34)

enum RecognitionMode:String,CaseIterable {
    case local="本机初稿",api="OCR Agent"
    var startLabel:String {self == .local ? "开始本机识别" : "开始 OCR Agent"}
}
private enum PageListFilter:String,CaseIterable {
    case all="全部",pending="未识别",failed="失败",review="待核对",completed="已核对"
    func includes(_ page:Page)->Bool {
        switch self {
        case .all:return true
        case .pending:return page.status == .imported
        case .failed:return page.status == .failed
        case .review:return page.status == .recognized
        case .completed:return page.status == .reviewed || page.status == .blank
        }
    }
}

struct WorkspaceView:View {
    @ObservedObject var model:AppModel
    private var recognitionMode:RecognitionMode {model.recognitionMode}
    @State private var pageFilter:PageListFilter = .all
    @State private var dropTargeted=false
    @State private var loadingDrop=false
    private var pages:[Page] { model.document?.pages ?? [] }
    private var failedCount:Int { pages.filter{$0.status == .failed}.count }
    private var hasRecognizedText:Bool { pages.contains{page in page.blocks.contains{!$0.plainText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}} }
    private var rangeProblem:String? {
        guard !pages.isEmpty else{return nil}
        guard let selected=try? PageRange.parse(model.pageRange,count:pages.count),!selected.isEmpty else {
            let example=pages.count>=5 ? "1-3,5" : pages.count>1 ? "1-\(pages.count)" : "1"
            return "有效页码为 1–\(pages.count)；例如 \(example)。"
        }
        return nil
    }
    private var visiblePages:[(offset:Int,element:Page)] { Array(pages.enumerated()).filter{pageFilter.includes($0.element)} }
    private var activePageNumbers:String { pages.enumerated().filter{model.activePageIDs.contains($0.element.id)}.map{String($0.offset+1)}.joined(separator:"、") }
    var body:some View {
        VStack(spacing:0) {
            header
            Divider()
            if model.document==nil {
                welcome
            } else {
                HStack(spacing:0) {
                    sidebar.frame(width:200)
                    Divider()
                    pageWorkspace
                    Divider()
                    InspectorView(model:model).frame(width:280)
                }
            }
            Divider()
            HStack(spacing:10) {
                if model.working {
                    ProgressView().controlSize(.small)
                    if model.document==nil {Button(model.isStopping ? "正在停止…" : "停止",action:model.cancel).buttonStyle(.borderless).disabled(model.isStopping)}
                } else { Image(systemName:"externaldrive.badge.checkmark").foregroundColor(accent) }
                Text(model.status).font(.system(size:11)).lineLimit(2).textSelection(.enabled)
                Spacer(minLength:8)
                Text("\(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "开发版") 预览版").font(.system(size:10)).foregroundColor(.secondary)
            }.padding(.horizontal,16).padding(.vertical,10)
        }
        .background(Color(nsColor:.windowBackgroundColor))
        .overlay {
            if dropTargeted && !model.working && !loadingDrop {
                ZStack {
                    RoundedRectangle(cornerRadius:10).fill(accent.opacity(0.08))
                    RoundedRectangle(cornerRadius:10).strokeBorder(accent,style:StrokeStyle(lineWidth:3,dash:[9,5]))
                    Label("松开以导入文件或打开项目",systemImage:"square.and.arrow.down").font(.system(size:17,weight:.semibold)).padding(18).background(Color(nsColor:.windowBackgroundColor)).cornerRadius(10)
                }.padding(8).allowsHitTesting(false)
            }
        }
        .onDrop(of:[UTType.fileURL.identifier],isTargeted:$dropTargeted,perform:receiveDrop)
        .sheet(isPresented:$model.settingsShown) { ProviderView(model:model) }
        .alert("拾页",isPresented:Binding(get:{model.errorMessage != nil},set:{if !$0{model.errorMessage=nil}})) { Button("知道了"){model.errorMessage=nil} } message:{Text(model.errorMessage ?? "")}
    }
    private var header:some View {
        HStack(spacing:14) {
            Image(systemName:"doc.text.viewfinder").font(.system(size:27,weight:.medium)).foregroundColor(accent)
            VStack(alignment:.leading,spacing:3) { Text("拾页").font(.system(size:21,weight:.semibold));Text("扫描书籍 · 识别与归档").font(.system(size:11)).foregroundColor(.secondary) }
            Spacer()
            Button(action:model.importFiles) {Label(model.document==nil ? "1  导入文件" : "1  添加文件",systemImage:"plus")}.keyboardShortcut("o").disabled(model.working)
                .help(model.document==nil ? "选择 PDF 或图片开始" : "将 PDF 或图片追加到当前项目；另一本书请先新建任务")
            Menu("项目") {
                Button("新建任务",action:model.newTask)
                Button("打开项目…",action:model.openProject)
                Button("保存项目副本…",action:model.saveProjectCopy).disabled(model.document==nil)
                Button("在 Finder 中显示项目") {if let root=model.store?.root{NSWorkspace.shared.activateFileViewerSelecting([root])}}.disabled(model.store==nil)
                Divider()
                Button("从原文件新建修复副本",action:model.rebuildFromSources).disabled(model.document?.sources.isEmpty ?? true)
                Button("打开排版技术样张",action:model.loadFixture)
            }.fixedSize().disabled(model.working)
            if hasRecognizedText {
                Button("3  导出可搜索 PDF",action:model.exportSearchablePDF).buttonStyle(.borderedProminent).tint(accent).disabled(model.working || rangeProblem != nil)
                    .help("按当前页范围导出：保留扫描原图，并加入已有识别文字")
            }
            Menu(hasRecognizedText ? "其他格式" : "3  导出结果") {
                if !hasRecognizedText {Button("可搜索 PDF（保留扫描）…",action:model.exportSearchablePDF)}
                Button("正文 TXT…"){model.exportEditable(format:.text)}
                Button("可编辑 Markdown…"){model.exportEditable(format:.markdown)}
                Divider()
                Button("原页重建 PDF…"){model.exportEditable()}
                Button("重建 PDF 校对稿…") {model.exportEditable(asDraft:true)}
            }.fixedSize().disabled(pages.isEmpty || model.working || rangeProblem != nil)
            Button { model.settingsShown=true } label:{Image(systemName:"gearshape")}.help("OCR Agent 设置")
        }.padding(.horizontal,22).padding(.vertical,15)
    }
    private var welcome:some View {
        VStack(spacing:23) {
            Spacer()
            Image(systemName:"book.closed").font(.system(size:62,weight:.ultraLight)).foregroundColor(accent)
            Text("把整本扫描书，变成可搜索、可复制的电子版").font(.system(size:25,weight:.medium))
            Text("把 PDF 或图片拖到这里，或点击下方按钮选择文件。").font(.system(size:14)).foregroundColor(.secondary)
            HStack(alignment:.top,spacing:32) {
                welcomeStep("1",title:"导入",detail:"选择扫描 PDF 或照片")
                welcomeStep("2",title:"识别",detail:"先试几页，再批量处理")
                welcomeStep("3",title:"导出",detail:"保存可搜索 PDF 或正文")
            }.padding(.vertical,9)
            HStack(spacing:14) { Button("选择 PDF 或图片",action:model.importFiles).buttonStyle(.borderedProminent).tint(accent);Button("打开已有项目",action:model.openProject) }
            VStack(alignment:.leading,spacing:8) {
                Label("本机初稿无需 API，疑难页可选 OCR Agent",systemImage:"text.viewfinder")
                Label("原文件、识别结果与修改记录保存在本机",systemImage:"externaldrive")
                Label("停止后可继续；识别文字仍需对照原图核对",systemImage:"checkmark.viewfinder")
            }.font(.system(size:12)).foregroundColor(.secondary).padding(.top,4)
            Button("查看排版技术样张",action:model.loadFixture).buttonStyle(.link).font(.caption)
            Spacer();Spacer()
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private func welcomeStep(_ number:String,title:String,detail:String)->some View {
        VStack(spacing:8) {
            Text(number).font(.system(size:14,weight:.semibold)).foregroundColor(accent).frame(width:30,height:30).background(accent.opacity(0.10)).clipShape(Circle())
            Text(title).font(.system(size:14,weight:.semibold))
            Text(detail).font(.system(size:12)).foregroundColor(.secondary)
        }.frame(width:180)
    }
    private var sidebar:some View {
        VStack(alignment:.leading,spacing:0) {
            VStack(alignment:.leading,spacing:12) {
                Text(model.document?.title ?? "项目").font(.system(size:13,weight:.semibold)).lineLimit(2)
                HStack {Text("整本进度").font(.caption).foregroundColor(.secondary);Spacer();Text("\(pages.count) 页").font(.caption.monospacedDigit())}
                HStack(spacing:8) {summaryTile(.pending);summaryTile(.review)}
                HStack(spacing:8) {summaryTile(.failed);summaryTile(.completed)}
                Picker("显示",selection:$pageFilter) {ForEach(PageListFilter.allCases,id:\.self){Text($0.rawValue).tag($0)}}.font(.caption)
                    .help("只筛选页面列表，不改变识别或导出范围")
            }.padding(13)
            Divider()
            if visiblePages.isEmpty {
                VStack(spacing:8) {Image(systemName:"doc.text.magnifyingglass").font(.title3);Text("没有\(pageFilter == .all ? "页面" : pageFilter.rawValue+"的页面")").font(.caption);if pageFilter != .all{Button("显示全部"){pageFilter = .all}.font(.caption)}}.foregroundColor(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing:3) {
                            ForEach(visiblePages,id:\.element.id) { item in pageRow(item.element,index:item.offset).id(item.element.id) }
                        }.padding(7)
                    }.onChange(of:model.selectedPageID){id in if let id=id{proxy.scrollTo(id,anchor:.center)}}
                }
            }
            Divider()
            HStack {
                Menu("页面排序") {Button("当前页上移"){model.movePage(-1)};Button("当前页下移"){model.movePage(1)}}.fixedSize().disabled(model.working || model.page==nil)
                Spacer(minLength:0)
                Text("显示 \(visiblePages.count) 页").font(.system(size:10)).foregroundColor(.secondary)
            }.padding(10)
        }.background(Color(nsColor:.controlBackgroundColor).opacity(0.55))
    }
    private func summaryTile(_ filter:PageListFilter)->some View {
        Button {pageFilter=filter} label:{
            VStack(alignment:.leading,spacing:3) {
                Text(String(pages.filter{filter.includes($0)}.count)).font(.system(size:19,weight:.medium,design:.rounded)).foregroundColor(filter == .failed && failedCount>0 ? .red : accent)
                Text(filter.rawValue).font(.system(size:10)).foregroundColor(.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,10).padding(.vertical,7).background(pageFilter == filter ? accent.opacity(0.10) : Color(nsColor:.windowBackgroundColor)).cornerRadius(6)
        }.buttonStyle(.plain)
    }
    private func pageRow(_ page:Page,index:Int)->some View {
        let active=model.activePageIDs.contains(page.id)
        return Button {model.selectPage(page.id)} label:{
            HStack(alignment:.top,spacing:8) {
                Text(String(index+1)).font(.system(size:12,weight:.semibold,design:.monospaced)).frame(width:26)
                VStack(alignment:.leading,spacing:4) {
                    Text("来源页 \(page.sourcePage)"+(page.printedLabel.map{" · "+$0} ?? "")).font(.system(size:11)).lineLimit(1)
                    HStack(spacing:5) {
                        if active {ProgressView().controlSize(.mini)}
                        Text(active ? "处理中" : page.status.label).font(.system(size:10)).foregroundColor(active || page.status == .reviewed || page.status == .blank ? accent : page.status == .failed ? .red : .secondary)
                    }
                };Spacer(minLength:0)
            }.padding(.vertical,10).padding(.horizontal,8).background(page.id==model.selectedPageID ? accent.opacity(0.11) : Color.clear).cornerRadius(7)
        }.buttonStyle(.plain)
    }
    private var recognitionPanel:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:10) {
                Text("2  识别文字").font(.system(size:13,weight:.semibold))
                Spacer(minLength:8)
                Text("同时处理").font(.caption).foregroundColor(.secondary)
                Picker("同时处理页数",selection:$model.concurrencyLimit) {ForEach(1...4,id:\.self){Text("\($0) 页").tag($0)}}.labelsHidden().frame(width:73).disabled(model.working)
                    .help("选择同时识别的页数；较大的扫描页或服务限流时，可减少页数")
            }
            HStack(spacing:10) {
                Picker("识别方式",selection:$model.recognitionMode) {ForEach(RecognitionMode.allCases,id:\.self){Text($0.rawValue).tag($0)}}.pickerStyle(.segmented).frame(width:205).disabled(model.working)
                if recognitionMode == .api {Button("设置接口"){model.settingsShown=true}.font(.caption).disabled(model.working)}
                Spacer(minLength:4)
                Button(recognitionMode.startLabel,action:startRecognition).buttonStyle(.borderedProminent).tint(accent).disabled(model.working || pages.isEmpty || rangeProblem != nil)
            }
            HStack(spacing:8) {
                Text("页范围").font(.caption)
                TextField("全部；例 1-5,8",text:$model.pageRange).textFieldStyle(.roundedBorder).frame(width:120).disabled(model.working)
                Menu("快捷选择") {
                    Button("整本"){model.pageRange=""}
                    Button("当前页"){if let index=model.pageIndex{model.pageRange=String(index+1)}}.disabled(model.pageIndex==nil)
                    Button("前 3 页试识别"){model.pageRange="1-\(min(3,pages.count))"}
                    Button("未生成转写的页面",action:model.choosePendingPages)
                    Button("失败页",action:model.chooseFailedPages).disabled(failedCount==0)
                }.fixedSize().disabled(model.working)
                if rangeProblem==nil {Text(model.rangeDescription).font(.system(size:11)).foregroundColor(.secondary).lineLimit(1)}
                Spacer(minLength:0)
            }
            if let problem=rangeProblem {Label(problem,systemImage:"exclamationmark.circle").font(.system(size:11)).foregroundColor(.red).fixedSize(horizontal:false,vertical:true)}
            Text(recognitionMode == .local ? "无需 API，只处理没有文字的页面，已有文字不会覆盖。识别后可直接导出可搜索 PDF。" : "\(model.ocrSkillName) · 整页识别后在本机查漏，必要时发送局部图重读。").font(.system(size:10)).foregroundColor(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(12)
    }
    private var taskProgress:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text(model.total>0 ? "已处理 \(model.completed) / \(model.total) 页" : "正在准备…").font(.system(size:12,weight:.medium)).monospacedDigit()
                Spacer()
                Button(model.isStopping ? "正在停止…" : "停止处理",action:model.cancel).controlSize(.small).disabled(model.isStopping)
            }
            if model.total>0 {ProgressView(value:Double(model.completed),total:Double(max(1,model.total))).tint(accent)}
            Text(activePageNumbers.isEmpty ? "完成的识别结果会保存在项目中" : "正在同时处理第 \(activePageNumbers) 页").font(.system(size:10)).foregroundColor(.secondary).lineLimit(2)
        }.padding(12).background(accent.opacity(0.06))
    }
    private var pageWorkspace:some View {
        VStack(spacing:0) {
            if model.needsImageReimport {
                HStack(spacing:10) {
                    Image(systemName:"exclamationmark.triangle").foregroundColor(.orange)
                    Text("旧版导入可能缩小了 PDF 内容。新建修复副本可恢复清晰度，旧项目继续保留。").font(.system(size:11)).fixedSize(horizontal:false,vertical:true)
                    Spacer()
                    Button("新建修复副本",action:model.rebuildFromSources).disabled(model.working)
                }.padding(10).background(Color.orange.opacity(0.10))
                Divider()
            }
            recognitionPanel
            Divider()
            if model.working {taskProgress;Divider()}
            else if failedCount>0 {
                HStack(spacing:8) {
                    Label("\(failedCount) 页处理失败",systemImage:"exclamationmark.circle").font(.caption).foregroundColor(.red)
                    Button("查看失败页"){pageFilter = .failed;if let page=pages.first(where:{$0.status == .failed}){model.selectPage(page.id)}}
                    Spacer()
                    Button(recognitionMode == .local ? "重试无文字失败页" : "重试失败页"){model.chooseFailedPages();startRecognition()}.help(recognitionMode == .local ? "本机识别重试无文字的失败页。已有文字的失败页可切换到 OCR Agent" : "使用当前 OCR Agent 重试失败页")
                }.font(.caption).padding(10).background(Color.red.opacity(0.04))
                Divider()
            }
            HStack(spacing:8) {
                Text(model.pageIndex.map{"第 \($0+1) 页"} ?? "页面预览").font(.system(size:12,weight:.medium))
                if let page=model.page{Text(page.status.label).font(.system(size:10)).foregroundColor(.secondary)}
                Spacer()
                Toggle("显示区域",isOn:$model.showBoxes).toggleStyle(.checkbox).font(.caption)
                Picker("缩放",selection:$model.zoom) { Text("适合宽度").tag(1.0);Text("150%").tag(1.5);Text("200%").tag(2.0) }.labelsHidden().frame(width:88)
            }.padding(.horizontal,12).padding(.vertical,8)
            Divider()
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView([.horizontal,.vertical]) {
                    let width=max(220,(Double(geo.size.width)-50)/2)*model.zoom
                    let ratio=(model.page?.height ?? 842)/(model.page?.width ?? 595)
                    HStack(alignment:.top,spacing:18) {
                        canvasColumn(title:"原扫描",subtitle:model.page?.imagePath.isEmpty == true ? "技术样张" : "原图保存在本机",image:model.originalImage,width:width,height:width*ratio,interactive:true)
                        if model.page?.blocks.isEmpty == true && model.page?.status != .blank {
                            emptyResultColumn(width:width,height:width*ratio)
                        }else if model.isLocalDraftPage {
                            VStack(alignment:.leading,spacing:8) {
                                HStack{Text("识别正文").font(.system(size:12,weight:.semibold));Spacer();Text("可选中复制").font(.system(size:10)).foregroundColor(.secondary)}
                                ScrollView {
                                    Text(model.page?.orderedBlocks.map(\.plainText).joined(separator:"\n") ?? "")
                                        .font(.system(size:14)).lineSpacing(5).textSelection(.enabled)
                                        .frame(maxWidth:.infinity,alignment:.topLeading).padding(18)
                                }.frame(width:width,height:width*ratio).background(Color.white).shadow(color:.black.opacity(0.10),radius:4,x:0,y:2)
                            }.frame(width:width)
                        }else{
                            canvasColumn(title:"原页重建",subtitle:model.page?.status == .reviewed ? "已核对" : "待核对文字与排版",image:model.rebuiltImage,width:width,height:width*ratio,interactive:false)
                        }
                    }.padding(16).frame(minWidth:geo.size.width,alignment:.topLeading).id("page-preview-top")
                    }.background(Color(nsColor:.underPageBackgroundColor))
                    .onAppear {DispatchQueue.main.async{proxy.scrollTo("page-preview-top",anchor:.topLeading)}}
                    .onChange(of:model.selectedPageID){_ in DispatchQueue.main.async{proxy.scrollTo("page-preview-top",anchor:.topLeading)}}
                }
            }
            Divider()
            HStack(spacing:8) {
                Menu("页面操作") {
                    Button(model.drawingRegion ? "取消框选" : "框选新区域"){model.drawingRegion.toggle()}
                    if let p=model.page,!p.hints.isEmpty,p.blocks.isEmpty {Button("采用已有文字候选",action:model.useExistingText)}
                    Divider();Button("确认本页为空白"){model.confirmPage(blank:true)}
                }.fixedSize().disabled(model.working || model.previewLoading || model.page==nil)
                if model.drawingRegion {Text("在原扫描上拖出一个区域").font(.system(size:10)).foregroundColor(accent)}
                Spacer(minLength:0)
                Button("下一待核对页",action:model.selectNextIssuePage).disabled(model.working)
                Button("本页核对完成"){model.confirmPage()}.disabled(model.working || model.previewLoading || model.page?.blocks.isEmpty != false)
            }.font(.system(size:11)).padding(10)
        }
    }
    private func startRecognition() {
        guard rangeProblem==nil else{return}
        if recognitionMode == .local {model.startLocalRecognition()} else {model.startRecognition()}
    }
    private func emptyResultColumn(width:Double,height:Double)->some View {
        let active=model.page.map{model.activePageIDs.contains($0.id)} ?? false
        let failed=model.page?.status == .failed
        return VStack(alignment:.leading,spacing:8) {
            Text("识别结果").font(.system(size:12,weight:.semibold))
            VStack(spacing:14) {
                if active {ProgressView().controlSize(.large)}
                else {Image(systemName:failed ? "exclamationmark.circle" : "text.viewfinder").font(.system(size:38,weight:.light)).foregroundColor(accent)}
                Text(active ? "正在识别本页" : failed ? "本页识别未完成" : "本页尚未识别").font(.system(size:16,weight:.medium))
                Text(active ? "完成后，识别结果会显示在这里。你可以继续浏览其他页面。" : failed ? "查看右侧的失败原因，再用“重试失败页”继续处理。" : "点击上方“\(recognitionMode.startLabel)”。建议先试前 3 页，识别结果会显示在这里。")
                    .font(.system(size:12)).foregroundColor(.secondary).multilineTextAlignment(.center).lineSpacing(4).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:0)
            }.padding(.horizontal,28).padding(.top,48).frame(width:width,height:height).background(Color.white).shadow(color:.black.opacity(0.10),radius:4,x:0,y:2)
        }.frame(width:width)
    }
    private func receiveDrop(_ providers:[NSItemProvider])->Bool {
        guard !model.working,!loadingDrop,!providers.isEmpty,providers.allSatisfy({$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)}) else{return false}
        loadingDrop=true
        let files=DroppedFileURLs(),group=DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil){item,error in
                defer{group.leave()}
                let url:URL?
                if let fileURL=item as? URL {url=fileURL}
                else if let data=item as? Data {url=URL(dataRepresentation:data,relativeTo:nil)}
                else if let text=item as? String {url=URL(string:text)}
                else {url=nil}
                files.append(error==nil ? url : nil)
            }
        }
        group.notify(queue:.main) {
            loadingDrop=false
            guard !model.working else{return}
            let received=files.result
            guard !received.invalid,!received.urls.isEmpty else{model.errorMessage="未能读取拖入的文件。请从 Finder 拖入 PDF、图片或拾页项目。";return}
            let urls=Array(Set(received.urls.map{$0.standardizedFileURL})).sorted{$0.path.localizedStandardCompare($1.path) == .orderedAscending}
            if urls.count==1,urls[0].pathExtension.lowercased()=="shiyebook" {model.beginOpenProject(urls[0]);return}
            if urls.contains(where:{$0.pathExtension.lowercased()=="shiyebook"}) {model.errorMessage="拾页项目请单独拖入；PDF 和图片可以一次拖入多个。";return}
            guard urls.allSatisfy({PageImporter.supportedExtensions.contains($0.pathExtension.lowercased())}) else{model.errorMessage="请拖入 PDF、JPEG、PNG、TIFF 或 HEIC 文件。文件夹和其他格式暂不支持。";return}
            model.beginImport(urls)
        }
        return true
    }
    private func canvasColumn(title:String,subtitle:String,image:NSImage?,width:Double,height:Double,interactive:Bool)->some View {
        VStack(alignment:.leading,spacing:8) {
            HStack{Text(title).font(.system(size:12,weight:.semibold));Spacer();Text(subtitle).font(.system(size:10)).foregroundColor(.secondary)}
            ZStack {
                PageCanvas(image:model.previewLoading ? nil : image,blocks:model.page?.blocks ?? [],selected:model.selectedBlockID,showBoxes:model.showBoxes && !model.previewLoading,drawing:interactive && model.drawingRegion && !model.working && !model.previewLoading,issueBox:interactive && !model.previewLoading ? model.focusedIssueBox : nil,onSelect:{if !model.previewLoading{model.selectBlock($0)}},onNew:{if interactive && !model.previewLoading{model.addRegion($0)}},onMove:{id,box in if interactive && !model.working && !model.previewLoading{model.selectBlock(id);model.modifyBlock(action:"移动区域"){$0.box=box}}})
                    .allowsHitTesting(!model.previewLoading)
                if model.previewLoading {VStack(spacing:8){ProgressView().controlSize(.small);Text("正在载入本页…").font(.caption).foregroundColor(.secondary)}.frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.white)}
            }.frame(width:width,height:height).background(Color.white).shadow(color:.black.opacity(0.10),radius:4,x:0,y:2)
        }.frame(width:width)
    }
}

private final class DroppedFileURLs {
    private let lock=NSLock()
    private var urls:[URL]=[]
    private var invalid=false
    func append(_ url:URL?) {
        lock.lock();defer{lock.unlock()}
        if let url=url,url.isFileURL {urls.append(url)} else {invalid=true}
    }
    var result:(urls:[URL],invalid:Bool) {lock.lock();defer{lock.unlock()};return(urls,invalid)}
}

struct InspectorView:View {
    @ObservedObject var model:AppModel
    @State private var rows=3
    @State private var columns=3
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:13) {
                HStack {
                    Text(model.block==nil ? "当前页" : "区域校对").font(.system(size:14,weight:.semibold))
                    Spacer()
                    if model.block != nil {Button("返回页面"){model.selectBlock(nil)}.font(.caption)}
                }
                if let b=model.block {
                    HStack {
                        Text("区域 \(b.order)").font(.caption).foregroundColor(.secondary)
                        Spacer();Button {model.moveBlock(-1)} label:{Image(systemName:"arrow.up")}.help("阅读顺序提前");Button {model.moveBlock(1)} label:{Image(systemName:"arrow.down")}.help("阅读顺序后移")
                    }
                    Picker("类型",selection:Binding(get:{b.kind},set:{kind in model.modifyBlock(action:"修改区域类型"){$0.kind=kind}})) { ForEach(BlockKind.allCases,id:\.self){Text($0.label).tag($0)} }
                    if b.kind == .table && !b.retainImage {
                        if b.cells.isEmpty {
                            Stepper("行：\(rows)",value:$rows,in:1...30);Stepper("列：\(columns)",value:$columns,in:1...20)
                            Button("建立空网格") {model.modifyBlock(action:"建立表格单元格") { block in for r in 0..<rows{for c in 0..<columns{block.cells.append(TableCell(row:r,column:c,text:""))}} }}
                        } else {
                            Picker("单元格",selection:Binding(get:{model.selectedCellID ?? ""},set:{model.flush();model.selectedCellID=$0.isEmpty ? nil : $0})) {
                                Text("选择要编辑的单元格").tag("")
                                ForEach(b.cells){c in Text("\(c.row+1)行 / \(c.column+1)列  "+String(c.text.prefix(12))).tag(c.id)}
                            }
                        }
                        Toggle("绘制表格线",isOn:Binding(get:{b.drawGrid},set:{v in model.modifyBlock(action:"修改表格线"){$0.drawGrid=v}}))
                    }
                    if !b.retainImage && b.kind != .figure && (b.kind != .table || model.cell != nil) {
                        Text(model.cell==nil ? "正文（自动保存）" : "单元格文字（自动保存）").font(.caption).foregroundColor(.secondary)
                        RichTextEditor(model:model).frame(minHeight:165,maxHeight:230).background(Color(nsColor:.textBackgroundColor)).overlay(RoundedRectangle(cornerRadius:4).stroke(Color.gray.opacity(0.3)))
                        HStack(spacing:5) {
                            Button("B"){model.applyStyle("bold")}.fontWeight(.bold)
                            Button("I"){model.applyStyle("italic")}.italic()
                            Button("上标"){model.applyStyle("super")};Button("下标"){model.applyStyle("sub")};Button("常规"){model.applyStyle("normal")}
                        }.controlSize(.small).help("先在文字框内选中文字，再应用样式")
                        DisclosureGroup("原始转写（只读）") {Text(model.cell?.rawText ?? b.rawText).font(.system(size:11)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.font(.caption)
                    }
                    DisclosureGroup("排版与高级设置") {
                        VStack(alignment:.leading,spacing:10) {
                            if !b.retainImage && b.kind != .figure && !model.isLocalDraftPage {
                                HStack {
                                    Text("字号").font(.caption)
                                    TextField("0 自动",value:Binding(get:{b.fontSize},set:{v in model.modifyBlock(action:"修改字号"){$0.fontSize=v}}),format:.number).frame(width:60).textFieldStyle(.roundedBorder)
                                    Text("0 为自动").font(.system(size:10)).foregroundColor(.secondary)
                                }
                                HStack {
                                    Text("行距").font(.caption)
                                    Slider(value:Binding(get:{b.lineSpacing},set:{v in model.modifyBlock(action:"修改行距"){$0.lineSpacing=v}}),in:1...2,step:0.05)
                                    Text(String(format:"%.2f",b.lineSpacing)).font(.caption.monospacedDigit())
                                }
                                Picker("对齐",selection:Binding(get:{b.alignment},set:{v in model.modifyBlock(action:"修改对齐"){$0.alignment=v}})) {Text("左").tag("left");Text("中").tag("center");Text("右").tag("right");Text("两端").tag("justified")}.pickerStyle(.segmented)
                            }
                            GeometryEditor(model:model,block:b).id(b.id+"|"+(model.selectedCellID ?? ""))
                            if b.kind == .table || b.kind == .figure {Toggle("整块保留原图",isOn:Binding(get:{b.retainImage},set:{v in model.modifyBlock(action:"确认图像对象保留方式"){$0.retainImage=v;$0.reviewed=false}})).font(.caption)}
                            if b.retainImage {Text("保留对象可阅读，但其中尚未恢复的文字不计为已文字化。").font(.system(size:10)).foregroundColor(.secondary)}
                        }.padding(.top,8)
                    }.font(.caption)
                    HStack {
                        Button("复识别此区域") { model.startRecognition(region:true) }
                        Spacer();Button("删除",action:model.deleteRegion).foregroundColor(.red)
                    }.controlSize(.small)
                } else {
                    currentPageOverview
                }
                Divider()
                HStack{Text("页面检查").font(.system(size:12,weight:.semibold));Spacer();Text("\(model.visibleIssues.count) 项").font(.caption).foregroundColor(.secondary)}
                if let error=model.page?.error {Text(error).font(.system(size:11)).foregroundColor(.red).textSelection(.enabled)}
                ForEach(model.visibleIssues) {issue in
                    Button { model.selectIssue(issue) } label:{Label(issue.message,systemImage:"exclamationmark.circle").font(.system(size:11)).foregroundColor(Color(red:0.62,green:0.34,blue:0.13)).multilineTextAlignment(.leading)}.buttonStyle(.plain)
                }
                Group {
                    if let area=model.focusedIssueBox,model.block==nil {
                        Button("用此框添加文字区"){model.addRegion(area)}.controlSize(.small)
                    }
                    if model.visibleIssues.isEmpty {
                        Label(model.page?.status == .imported ? "识别后可查看校对提示" : model.isLocalDraftPage ? "没有待处理的校对提示" : "未检测到结构与排版问题",systemImage:model.page?.status == .imported ? "info.circle" : "checkmark.circle").font(.caption).foregroundColor(accent)
                    }
                }
                Text("自动检查不能替代对照原图核对音标、异体字及表格关系。").font(.system(size:10)).foregroundColor(.secondary)
                Divider()
                DisclosureGroup("页面详情与字体") {
                    VStack(alignment:.leading,spacing:10) {
                        if let p=model.page {
                            Text("来源页 \(p.sourcePage) · \(Int(p.width)) × \(Int(p.height)) pt\n\(p.textLayerAssessment)").font(.system(size:10)).foregroundColor(.secondary)
                            if let r=p.recognitions.last {Text("请求：\(r.requestedModel)\n返回：\(r.returnedModel ?? "服务商未确认")\n用量：输入 \(r.promptTokens.map(String.init) ?? "未知") / 输出 \(r.completionTokens.map(String.init) ?? "未知") tokens\n实际费用：未知（由服务商计费）").font(.system(size:10)).foregroundColor(.secondary).textSelection(.enabled)}
                        }
                        Text("重建 PDF 的中文字体").font(.caption).foregroundColor(.secondary)
                        TextField("中文字体名称",text:Binding(get:{model.document?.chineseFont ?? "Songti TC"},set:{model.document?.chineseFont=$0;model.saveSoon()})).font(.caption).textFieldStyle(.roundedBorder).help("使用本机已安装字体；默认 Songti TC。修改后会重新检查缺字。")
                    }.padding(.top,8)
                }.font(.caption)
            }.padding(15).disabled(model.working || model.previewLoading)
        }.background(Color(nsColor:.controlBackgroundColor).opacity(0.45))
    }
    private var currentPageOverview:some View {
        VStack(alignment:.leading,spacing:12) {
            if let page=model.page {
                Label(page.status.label,systemImage:page.status == .reviewed || page.status == .blank ? "checkmark.circle.fill" : page.status == .failed ? "exclamationmark.circle" : "doc.text").font(.system(size:12,weight:.medium)).foregroundColor(page.status == .failed ? .red : accent)
                Text(nextStepDescription(page)).font(.system(size:12)).foregroundColor(.secondary).lineSpacing(4).fixedSize(horizontal:false,vertical:true)
                if page.textContinuation != nil {
                    Button("取消与下一页续接",action:model.removeContinuation).controlSize(.small)
                } else if model.canJoinFollowingPage {
                    Button(model.suggestsContinuation ? "核对跨页续段…" : "与下一页续接…",action:model.confirmContinuation).controlSize(.small)
                }
                if page.agentFailurePath != nil || !page.recognitions.isEmpty {
                    Button("显示识别记录",action:model.revealRecognitionRecord).controlSize(.small)
                }
                if !page.blocks.isEmpty {
                    Text("\(page.blocks.count) 个区域 · \(page.blocks.map(\.plainText).joined().count) 字符").font(.system(size:10)).foregroundColor(.secondary)
                    DisclosureGroup("选择文字区域") {
                        VStack(alignment:.leading,spacing:8) {
                            ForEach(page.orderedBlocks){block in
                                Button {model.selectBlock(block.id)} label:{HStack{Text("\(block.order) · \(block.kind.label)");Spacer();Text(String(block.plainText.prefix(12))).foregroundColor(.secondary).lineLimit(1)}}.buttonStyle(.plain).font(.system(size:11))
                            }
                        }.padding(.top,6)
                    }.font(.caption)
                }
            } else {
                Text("导入完成后，在左侧选择页面。").font(.caption).foregroundColor(.secondary)
            }
        }
    }
    private func nextStepDescription(_ page:Page)->String {
        switch page.status {
        case .imported:return "在上方选择识别方式和页范围，再开始识别。建议先试前 3 页。"
        case .failed:return "查看下方失败原因后，用“重试失败页”继续。已有完成页会保留。"
        case .recognized:return "已有识别文字，可导出可搜索 PDF 或正文。点击原图上的区域即可校对，完成后标记“本页核对完成”。"
        case .reviewed:return "本页已核对。可以继续检查下一页，或从右上角导出结果。"
        case .blank:return "本页已确认为空白，原扫描及页序仍保留。"
        }
    }
}

struct GeometryEditor:View {
    @ObservedObject var model:AppModel
    var block:Block
    @State private var x=""
    @State private var y=""
    @State private var w=""
    @State private var h=""
    var body:some View {
        DisclosureGroup(model.cell==nil ? "区域边界（页面百分比）" : "单元格边界（页面百分比）") {
            VStack(spacing:6) {
                HStack {Text("左").frame(width:18);TextField("x",text:$x);Text("上").frame(width:18);TextField("y",text:$y)}
                HStack {Text("宽").frame(width:18);TextField("w",text:$w);Text("高").frame(width:18);TextField("h",text:$h)}
                Button("应用边界") {
                    guard let a=Double(x),let b=Double(y),let c=Double(w),let d=Double(h),Box(a/100,b/100,c/100,d/100).isValid else {model.errorMessage="请输入有效页面百分比，区域不能越界。";return}
                    let box=Box(a/100,b/100,c/100,d/100)
                    model.modifyBlock(action:"修改区域或单元格边界") {block in if let id=model.selectedCellID,let i=block.cells.firstIndex(where:{$0.id==id}){block.cells[i].box=box}else{block.box=box}}
                }
            }.textFieldStyle(.roundedBorder).padding(.top,5)
        }.font(.caption).onAppear(perform:load).onChange(of:block.box){_ in load()}
    }
    private func load() {let b=model.cell.map{PDFRenderer.cellBox($0,table:block)} ?? block.box;x=String(format:"%.2f",b.x*100);y=String(format:"%.2f",b.y*100);w=String(format:"%.2f",b.width*100);h=String(format:"%.2f",b.height*100)}
}

struct ProviderView:View {
    @ObservedObject var model:AppModel
    var body:some View {
        VStack(alignment:.leading,spacing:17) {
            HStack{Image(systemName:"network").foregroundColor(accent);Text("OCR Agent 设置").font(.title2);Spacer();if model.working{Button(model.isStopping ? "正在停止…" : "取消请求",action:model.cancel).disabled(model.isStopping)};Button("关闭"){model.settingsShown=false}.disabled(model.working)}
            Text("配置自己的兼容视觉接口。密钥使用拾页独立钥匙串；原图和项目保存在本机。").font(.system(size:12)).foregroundColor(.secondary)
            VStack(alignment:.leading,spacing:7) {
                HStack {Text("API 基地址").font(.caption);Spacer();Button("填入 OpenAI 示例",action:model.useOpenAIProvider).font(.caption).disabled(model.working)}
                TextField("https://服务商地址/v1",text:$model.provider.baseURL).textFieldStyle(.roundedBorder)
                Text("填写服务商要求的地址及版本路径，例如 /v1。").font(.system(size:10)).foregroundColor(.secondary)
            }
            VStack(alignment:.leading,spacing:7) {
                HStack{Text("API 密钥").font(.caption);Spacer();Button("从本服务钥匙串读取",action:model.loadCurrentKey).font(.caption)}
                SecureField("仅用于你选择的 API",text:$model.key).textFieldStyle(.roundedBorder)
                HStack{Toggle("安全记住密钥",isOn:$model.provider.rememberKey);Spacer();Button("删除已保存密钥",action:model.forgetKey).font(.caption)}
                Text("已记住的密钥会在使用 API 时读取。").font(.system(size:10)).foregroundColor(.secondary)
            }
            HStack {
                TextField("视觉模型 ID，可直接手动填写",text:$model.provider.model).textFieldStyle(.roundedBorder)
                if !model.models.isEmpty {Menu("选择模型"){ForEach(model.models,id:\.self){name in Button(name){model.provider.model=name}}}}
                Button("获取列表"){model.providerAction(probe:false)}.disabled(model.working)
            }
            DisclosureGroup("兼容参数") {
                VStack(alignment:.leading,spacing:9) {
                    Picker("输出上限参数",selection:$model.provider.tokenParameter){Text("max_tokens").tag("max_tokens");Text("max_completion_tokens").tag("max_completion_tokens")}
                    HStack{Text("最大输出 tokens");TextField("16384",value:$model.provider.maxOutputTokens,format:.number).frame(width:110)}
                    Toggle("请求 JSON 模式（接口支持时启用）",isOn:$model.provider.useJSONMode)
                    Text("模型名称与 HTTP 成功不能证明识图能力。输出截断时会保留失败状态。").font(.system(size:10)).foregroundColor(.secondary)
                }.padding(.top,8)
            }.font(.caption)
            VStack(alignment:.leading,spacing:6) {
                Text("OCR Skill").font(.caption)
                HStack {
                    Text(model.ocrSkillName).lineLimit(1).truncationMode(.middle).font(.system(size:12))
                    Spacer()
                    Button("导入 Skill…",action:model.importOCRSkill)
                    Menu("模板") {
                        Button("保存内置模板…",action:model.saveOCRSkillTemplate)
                        Button("恢复内置 Skill",action:model.resetOCRSkill).disabled(model.customOCRSkill==nil)
                    }.fixedSize()
                }
            }.disabled(model.working)
            Divider()
            Group {
                HStack {Button("测试图片与结构"){model.providerAction(probe:true)}.disabled(model.working);Text("发送随机测试图和当前 Skill，可能产生请求费用。").font(.system(size:10)).foregroundColor(.secondary)}
                if !model.probeMessage.isEmpty {Text(model.probeMessage).font(.system(size:11)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
                HStack{Spacer();Button("保存配置",action:model.saveProvider).buttonStyle(.borderedProminent).tint(accent).disabled(model.working)}
            }
        }.padding(25).frame(width:585).background(Color(nsColor:.windowBackgroundColor)).onChange(of:model.provider.baseURL){_ in model.key="";model.models=[];model.probeMessage="地址已修改，请输入该服务的密钥，或从钥匙串读取。"}
    }
}

struct PageCanvas:NSViewRepresentable {
    var image:NSImage?,blocks:[Block],selected:String?,showBoxes:Bool,drawing:Bool
    var issueBox:Box?
    var onSelect:(String?)->Void,onNew:(Box)->Void,onMove:(String,Box)->Void
    func makeNSView(context:Context)->CanvasNSView {CanvasNSView()}
    func updateNSView(_ view:CanvasNSView,context:Context) {view.image=image;view.blocks=blocks;view.selected=selected;view.showBoxes=showBoxes;view.drawing=drawing;view.issueBox=issueBox;view.onSelect=onSelect;view.onNew=onNew;view.onMove=onMove;view.needsDisplay=true}
}
final class CanvasNSView:NSView {
    var image:NSImage?,blocks:[Block]=[],selected:String?,showBoxes=true,drawing=false
    var issueBox:Box?
    var onSelect:((String?)->Void)?,onNew:((Box)->Void)?,onMove:((String,Box)->Void)?
    var start:CGPoint?,end:CGPoint?,moving:Block?
    override var isFlipped:Bool{true}
    override var acceptsFirstResponder:Bool{true}
    override func draw(_ dirtyRect:NSRect) {
        NSColor.white.setFill();bounds.fill()
        image?.draw(in:bounds,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
        if image==nil {
            let s=NSAttributedString(string:"原图 / 预览将在这里显示",attributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.secondaryLabelColor]);s.draw(at:NSPoint(x:18,y:28))
        }
        if showBoxes {
            for b in blocks {
                let r=NSRect(x:b.box.x*bounds.width,y:b.box.y*bounds.height,width:b.box.width*bounds.width,height:b.box.height*bounds.height)
                let color=b.id==selected ? NSColor.systemTeal : b.reviewed ? NSColor.systemGreen : NSColor.systemOrange
                if b.id==selected {color.withAlphaComponent(0.08).setFill();r.fill()}
                color.withAlphaComponent(b.id==selected ? 0.9 : 0.45).setStroke();let path=NSBezierPath(rect:r);path.lineWidth=b.id==selected ? 1.8 : 0.7;path.stroke()
                let label=NSAttributedString(string:" \(b.order) ",attributes:[.font:NSFont.systemFont(ofSize:9,weight:.medium),.foregroundColor:NSColor.white,.backgroundColor:color])
                let labelPoint=r.minX>=label.size().width+2 ? NSPoint(x:r.minX-label.size().width-2,y:r.minY) : NSPoint(x:r.minX,y:max(0,r.minY-label.size().height-2))
                label.draw(at:labelPoint)
            }
        }
        if let issue=issueBox {
            let box=NSRect(x:issue.x*bounds.width,y:issue.y*bounds.height,width:issue.width*bounds.width,height:issue.height*bounds.height)
            NSColor.systemOrange.withAlphaComponent(0.16).setFill();box.fill()
            NSColor.systemOrange.setStroke()
            let outline=NSBezierPath(rect:box);outline.lineWidth=2
            outline.setLineDash([5,3],count:2,phase:0);outline.stroke()
        }
        if let a=start,let b=end,drawing {
            NSColor.systemTeal.setStroke();let p=NSBezierPath(rect:NSRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y)));p.lineWidth=1.5;p.stroke()
        }
    }
    override func mouseDown(with event:NSEvent) {
        let p=convert(event.locationInWindow,from:nil);start=p;end=p
        if !drawing {let n=CGPoint(x:p.x/bounds.width,y:p.y/bounds.height);moving=blocks.filter{$0.box.cgRect.contains(n)}.min{$0.box.area<$1.box.area};onSelect?(moving?.id)}
    }
    override func mouseDragged(with event:NSEvent) {end=convert(event.locationInWindow,from:nil);needsDisplay=true}
    override func mouseUp(with event:NSEvent) {
        defer{start=nil;end=nil;moving=nil;needsDisplay=true}
        guard let a=start else{return};let b=convert(event.locationInWindow,from:nil)
        if drawing {
            let x=max(0,min(a.x,b.x)/bounds.width),y=max(0,min(a.y,b.y)/bounds.height)
            let w=min(1-x,abs(a.x-b.x)/bounds.width),h=min(1-y,abs(a.y-b.y)/bounds.height)
            if w>0.015,h>0.01 {onNew?(Box(x,y,w,h))}
        } else if let moving=moving,abs(b.x-a.x)+abs(b.y-a.y)>5 {
            var box=moving.box;box.x=max(0,min(1-box.width,box.x+(b.x-a.x)/bounds.width));box.y=max(0,min(1-box.height,box.y+(b.y-a.y)/bounds.height));onMove?(moving.id,box)
        }
    }
}

struct RichTextEditor:NSViewRepresentable {
    @ObservedObject var model:AppModel
    func makeCoordinator()->Coordinator{Coordinator(model)}
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.borderType = .noBorder
        let view=NSTextView(frame:scroll.bounds);view.isRichText=true;view.importsGraphics=false;view.allowsUndo=true;view.isAutomaticQuoteSubstitutionEnabled=false;view.isAutomaticDashSubstitutionEnabled=false;view.isAutomaticSpellingCorrectionEnabled=false;view.isAutomaticTextReplacementEnabled=false
        view.isVerticallyResizable=true;view.isHorizontallyResizable=false;view.autoresizingMask=[.width];view.textContainer?.widthTracksTextView=true;view.textContainerInset=NSSize(width:7,height:8);view.delegate=context.coordinator;scroll.documentView=view;model.editor=view
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let view=scroll.documentView as? NSTextView else{return};model.editor=view
        let id=(model.selectedBlockID ?? "")+"|"+(model.selectedCellID ?? "")
        if context.coordinator.token != id || view.string != model.selectedText {
            if context.coordinator.token != id{view.undoManager?.removeAllActions()}
            context.coordinator.updating=true
            let a=NSMutableAttributedString(string:"")
            let runs=model.selectedRuns.map(\.text).joined()==model.selectedText ? model.selectedRuns : [TextRun(model.selectedText)]
            for r in runs {
                var f=NSFont(name:"Charis-Regular",size:14) ?? NSFont.systemFont(ofSize:14)
                if r.style.bold{f=NSFontManager.shared.convert(f,toHaveTrait:.boldFontMask)}
                if r.style.italic{f=NSFontManager.shared.convert(f,toHaveTrait:.italicFontMask)}
                a.append(NSAttributedString(string:r.text,attributes:[.font:f,.foregroundColor:NSColor.labelColor,NSAttributedString.Key("ShiyeScript"):r.style.script,.baselineOffset:r.style.script>0 ? 4 : r.style.script<0 ? -3 : 0]))
            }
            view.textStorage?.setAttributedString(a);context.coordinator.token=id;context.coordinator.updating=false
        }
    }
    static func commit(_ view:NSTextView,model:AppModel) {
        guard let a=view.textStorage else{return};var runs:[TextRun]=[]
        a.enumerateAttributes(in:NSRange(location:0,length:a.length)) {attrs,r,_ in
            let font=attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize:14),traits=NSFontManager.shared.traits(of:font)
            runs.append(TextRun(a.attributedSubstring(from:r).string,style:TextStyle(bold:traits.contains(.boldFontMask),italic:traits.contains(.italicFontMask),script:attrs[NSAttributedString.Key("ShiyeScript")] as? Int ?? 0)))
        }
        model.updateText(a.string,runs:runs)
    }
    final class Coordinator:NSObject,NSTextViewDelegate {
        let model:AppModel;var updating=false;var token=""
        init(_ model:AppModel){self.model=model}
        func textDidChange(_ notification:Notification){if !updating,let v=notification.object as? NSTextView{RichTextEditor.commit(v,model:model)}}
    }
}
