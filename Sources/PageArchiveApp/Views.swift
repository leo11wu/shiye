import SwiftUI
import AppKit
import PageArchiveCore

private let accent=Color(red:0.14,green:0.38,blue:0.34)

struct WorkspaceView:View {
    @ObservedObject var model:AppModel
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:14) {
                Image(systemName:"doc.text.viewfinder").font(.system(size:27,weight:.medium)).foregroundColor(accent)
                VStack(alignment:.leading,spacing:3) { Text("拾页").font(.system(size:21,weight:.semibold));Text("扫描书籍 · 批量识别与归档").font(.system(size:11)).foregroundColor(.secondary) }
                Spacer()
                Button("导入文件",action:model.importFiles).keyboardShortcut("o").disabled(model.working)
                Menu("项目") {
                    Button("打开项目…",action:model.openProject)
                    Button("保存项目副本…",action:model.saveProjectCopy).disabled(model.document==nil)
                    Button("从原文件新建修复副本",action:model.rebuildFromSources).disabled(model.document?.sources.isEmpty ?? true)
                    Button("导出 PDF 校对稿…") {model.exportPDF(asDraft:true)}.disabled(model.document==nil)
                    Button("新任务",action:model.newTask)
                    Button("在 Finder 中显示项目") {if let root=model.store?.root{NSWorkspace.shared.activateFileViewerSelecting([root])}}.disabled(model.store==nil)
                    Divider();Button("打开排版技术样张",action:model.loadFixture)
                }.fixedSize().disabled(model.working)
                Menu("导出") {
                    Button("可搜索 PDF（保留扫描）…",action:model.exportSearchablePDF)
                    Button("正文 TXT…"){model.exportPDF(text:true)}
                    Divider()
                    Button("原页重建 PDF…"){model.exportPDF()}
                }.fixedSize().disabled((model.document?.pages.isEmpty ?? true) || model.working)
                Button { model.settingsShown=true } label:{Image(systemName:"gearshape")}.help("视觉 API 设置")
            }.padding(.horizontal,22).padding(.vertical,15)
            Divider()
            if model.document==nil {
                welcome
            } else {
                HStack(spacing:0) {
                    sidebar.frame(width:172)
                    Divider()
                    pageWorkspace
                    Divider()
                    InspectorView(model:model).frame(width:290)
                }
            }
            Divider()
            HStack(spacing:10) {
                if model.working { ProgressView().controlSize(.small);Button("取消",action:model.cancel).buttonStyle(.borderless) }
                else { Image(systemName:"externaldrive.badge.checkmark").foregroundColor(accent) }
                Text(model.status).font(.system(size:11)).lineLimit(2).textSelection(.enabled)
                Spacer()
                if model.working && model.total>0 { Text("\(model.completed)/\(model.total)").font(.system(size:11,design:.monospaced)) }
                Text("\(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "开发版") 预览版").font(.system(size:10)).foregroundColor(.secondary)
            }.padding(.horizontal,16).padding(.vertical,10)
        }
        .background(Color(nsColor:.windowBackgroundColor))
        .sheet(isPresented:$model.settingsShown) { ProviderView(model:model) }
        .alert("拾页",isPresented:Binding(get:{model.errorMessage != nil},set:{if !$0{model.errorMessage=nil}})) { Button("知道了"){model.errorMessage=nil} } message:{Text(model.errorMessage ?? "")}
    }
    private var welcome:some View {
        VStack(spacing:22) {
            Spacer()
            Image(systemName:"book.closed").font(.system(size:68,weight:.ultraLight)).foregroundColor(accent)
            Text("把整本扫描书，变成可搜索、可复制的电子版").font(.system(size:25,weight:.medium))
            Text("批量识别 · 断点恢复 · 扫描版 PDF 与正文分别导出").font(.system(size:14)).foregroundColor(.secondary)
            HStack(spacing:14) { Button("选择 PDF 或图片",action:model.importFiles).buttonStyle(.borderedProminent).tint(accent);Button("打开已有项目",action:model.openProject) }
            Button("先看排版技术样张（不需要 API）",action:model.loadFixture).buttonStyle(.link)
            VStack(alignment:.leading,spacing:8) {
                Label("原文件和修改记录保存在本机",systemImage:"externaldrive")
                Label("本机初稿无需 API；疑难书页可再用视觉 API 识别",systemImage:"text.viewfinder")
                Label("建议先试代表页，再选择整本；已有结果自动保存",systemImage:"checkmark.viewfinder")
            }.font(.system(size:12)).foregroundColor(.secondary).padding(.top,10)
            Spacer();Spacer()
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private var sidebar:some View {
        VStack(alignment:.leading,spacing:0) {
            Text(model.document?.title ?? "项目").font(.system(size:12,weight:.semibold)).lineLimit(2).padding(14)
            Divider()
            ScrollView {
                LazyVStack(spacing:3) {
                    ForEach(Array((model.document?.pages ?? []).enumerated()),id:\.element.id) { index,page in
                        Button { model.selectPage(page.id) } label:{
                            HStack(alignment:.top,spacing:9) {
                                Text(String(index+1)).font(.system(size:12,weight:.semibold,design:.monospaced)).frame(width:25)
                                VStack(alignment:.leading,spacing:4) {
                                    Text("来源页 \(page.sourcePage)"+(page.printedLabel.map{" · "+$0} ?? "")).font(.system(size:11)).lineLimit(1)
                                    Text(page.status.label).font(.system(size:10)).foregroundColor(page.status == .reviewed || page.status == .blank ? accent : page.status == .failed ? .red : .secondary)
                                };Spacer(minLength:0)
                            }.padding(.vertical,10).padding(.horizontal,8).background(page.id==model.selectedPageID ? accent.opacity(0.11) : Color.clear).cornerRadius(7)
                        }.buttonStyle(.plain)
                    }
                }.padding(7)
            }
            HStack { Button { model.movePage(-1) } label:{Image(systemName:"arrow.up")};Button {model.movePage(1)} label:{Image(systemName:"arrow.down")};Spacer();Text("\(model.document?.pages.count ?? 0) 页").font(.caption).foregroundColor(.secondary) }.padding(10).disabled(model.working)
        }.background(Color(nsColor:.controlBackgroundColor).opacity(0.55))
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
            HStack(spacing:8) {
                Text("页范围").font(.caption)
                TextField("全部；例 1-5",text:$model.pageRange).textFieldStyle(.roundedBorder).frame(width:125).disabled(model.working)
                Menu {
                    Button("整本"){model.pageRange=""}
                    Button("前 3 页试识别"){model.pageRange="1-\(min(3,model.document?.pages.count ?? 1))"}
                    Button("仅未生成转写的页面",action:model.choosePendingPages)
                } label:{Image(systemName:"line.3.horizontal.decrease.circle")}.fixedSize().disabled(model.working)
                Text(model.rangeDescription).font(.system(size:10)).foregroundColor(.secondary).lineLimit(1)
                Button("本机初稿",action:model.startLocalRecognition).disabled(model.working).help("在本机批量识别，跳过已有结果；小字、音标和复杂版面需要校对。")
                Button("API 识别") { model.startRecognition() }.buttonStyle(.borderedProminent).tint(accent).disabled(model.working)
                Spacer(minLength:0)
                Toggle("区域",isOn:$model.showBoxes).toggleStyle(.checkbox).font(.caption)
                Picker("缩放",selection:$model.zoom) { Text("适合宽度").tag(1.0);Text("150%").tag(1.5);Text("200%").tag(2.0) }.labelsHidden().frame(width:88)
            }.padding(12)
            Divider()
            GeometryReader { geo in
                ScrollView([.horizontal,.vertical]) {
                    let width=max(220,(Double(geo.size.width)-50)/2)*model.zoom
                    let ratio=(model.page?.height ?? 842)/(model.page?.width ?? 595)
                    HStack(alignment:.top,spacing:18) {
                        canvasColumn(title:"原扫描",subtitle:model.originalImage==nil ? "技术样张，无扫描原图" : "图像保留在本机",image:model.originalImage,width:width,height:width*ratio,interactive:true)
                        if model.isLocalDraftPage {
                            VStack(alignment:.leading,spacing:8) {
                                HStack{Text("识别正文").font(.system(size:12,weight:.semibold));Spacer();Text("本机初稿 · 可直接复制").font(.system(size:10)).foregroundColor(.secondary)}
                                ScrollView {
                                    Text(model.page?.orderedBlocks.map(\.plainText).joined(separator:"\n") ?? "")
                                        .font(.system(size:14)).lineSpacing(5).textSelection(.enabled)
                                        .frame(maxWidth:.infinity,alignment:.topLeading).padding(18)
                                }.frame(width:width,height:width*ratio).background(Color.white).shadow(color:.black.opacity(0.10),radius:4,x:0,y:2)
                            }.frame(width:width)
                        }else{
                            canvasColumn(title:"原页重建",subtitle:model.page?.status == .reviewed ? "本页已由用户确认" : "校对稿 · 待检查文字与排版",image:model.rebuiltImage,width:width,height:width*ratio,interactive:false)
                        }
                    }.padding(16).frame(minWidth:geo.size.width,alignment:.topLeading)
                }.background(Color(nsColor:.underPageBackgroundColor))
            }
            Divider()
            HStack(spacing:8) {
                Button(model.drawingRegion ? "取消框选" : "框选新区域") { model.drawingRegion.toggle() }.disabled(model.working)
                if let p=model.page,!p.hints.isEmpty,p.blocks.isEmpty { Button("采用已有文字候选",action:model.useExistingText).disabled(model.working) }
                Spacer()
                Button("确认空白") {model.confirmPage(blank:true)}.disabled(model.working)
                Button("本页核对完成") {model.confirmPage()}.disabled(model.working)
            }.font(.system(size:11)).padding(10)
        }
    }
    private func canvasColumn(title:String,subtitle:String,image:NSImage?,width:Double,height:Double,interactive:Bool)->some View {
        VStack(alignment:.leading,spacing:8) {
            HStack{Text(title).font(.system(size:12,weight:.semibold));Spacer();Text(subtitle).font(.system(size:10)).foregroundColor(.secondary)}
            PageCanvas(image:image,blocks:model.page?.blocks ?? [],selected:model.selectedBlockID,showBoxes:model.showBoxes,drawing:interactive && model.drawingRegion && !model.working,onSelect:{model.selectBlock($0)},onNew:{model.addRegion($0)},onMove:{id,box in if !model.working{model.selectBlock(id);model.modifyBlock(action:"移动区域"){$0.box=box}}})
                .frame(width:width,height:height).background(Color.white).shadow(color:.black.opacity(0.10),radius:4,x:0,y:2)
        }.frame(width:width)
    }
}

struct InspectorView:View {
    @ObservedObject var model:AppModel
    @State private var rows=3
    @State private var columns=3
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:13) {
                Text("区域校对").font(.system(size:14,weight:.semibold))
                if let b=model.block {
                    HStack {
                        Text("区域 \(b.order)").font(.caption).foregroundColor(.secondary)
                        Spacer();Button {model.moveBlock(-1)} label:{Image(systemName:"arrow.up")};Button {model.moveBlock(1)} label:{Image(systemName:"arrow.down")}
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
                    HStack {
                        Button("复识别此区域") { model.startRecognition(region:true) }
                        Spacer();Button("删除",action:model.deleteRegion).foregroundColor(.red)
                    }.controlSize(.small)
                } else {
                    Text("点击页面上的区域，核对文字与位置。\n也可以在原扫描上框选一个新区域，手工输入或单独识别。").font(.system(size:12)).foregroundColor(.secondary).lineSpacing(5)
                    if let blocks=model.page?.orderedBlocks,!blocks.isEmpty {
                        ForEach(blocks){b in Button {model.selectBlock(b.id)} label:{HStack{Text("\(b.order) · \(b.kind.label)");Spacer();Text(String(b.plainText.prefix(12))).foregroundColor(.secondary)}}.buttonStyle(.plain).font(.system(size:11))}
                    }
                }
                Group {
                Divider()
                HStack{Text("页面检查").font(.system(size:12,weight:.semibold));Spacer();Text("\(model.visibleIssues.count) 项").font(.caption).foregroundColor(.secondary)}
                if let error=model.page?.error {Text(error).font(.system(size:11)).foregroundColor(.red).textSelection(.enabled)}
                ForEach(model.visibleIssues) {issue in
                    Button { if let id=issue.blockID{model.selectBlock(id)} } label:{Label(issue.message,systemImage:"exclamationmark.circle").font(.system(size:11)).foregroundColor(Color(red:0.62,green:0.34,blue:0.13)).multilineTextAlignment(.leading)}.buttonStyle(.plain)
                }
                if model.visibleIssues.isEmpty {Label(model.isLocalDraftPage ? "没有待处理的校对提示" : "未检测到结构与排版问题",systemImage:"checkmark.circle").font(.caption).foregroundColor(accent)}
                Text("自动检查不能替代对照原图核对音标、异体字及表格关系。").font(.system(size:10)).foregroundColor(.secondary)
                }
                Divider()
                TextField("中文字体名称",text:Binding(get:{model.document?.chineseFont ?? "Songti TC"},set:{model.document?.chineseFont=$0;model.saveSoon()})).font(.caption).textFieldStyle(.roundedBorder).help("使用本机已安装字体；默认 Songti TC。修改后会重新检查缺字。")
                Button("导出当前范围正文 TXT") {model.exportPDF(text:true)}.font(.caption)
                if let p=model.page {
                    Text("来源页 \(p.sourcePage) · \(Int(p.width)) × \(Int(p.height)) pt\n\(p.textLayerAssessment)").font(.system(size:10)).foregroundColor(.secondary)
                    if let r=p.recognitions.last {Text("请求：\(r.requestedModel)\n返回：\(r.returnedModel ?? "服务商未确认")\n用量：输入 \(r.promptTokens.map(String.init) ?? "未知") / 输出 \(r.completionTokens.map(String.init) ?? "未知") tokens\n实际费用：未知（由服务商计费）").font(.system(size:10)).foregroundColor(.secondary).textSelection(.enabled)}
                }
            }.padding(15).disabled(model.working)
        }.background(Color(nsColor:.controlBackgroundColor).opacity(0.45))
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
            HStack{Image(systemName:"network").foregroundColor(accent);Text("视觉 API").font(.title2);Spacer();if model.working{Button("取消请求",action:model.cancel)};Button("关闭"){model.settingsShown=false}.disabled(model.working)}
            Text("配置自己的兼容视觉接口。密钥使用拾页独立钥匙串；原图和项目保存在本机。").font(.system(size:12)).foregroundColor(.secondary)
            VStack(alignment:.leading,spacing:7) {Text("API 基地址").font(.caption);TextField("https://服务商地址/v1",text:$model.provider.baseURL).textFieldStyle(.roundedBorder);Text("保留服务商要求的 /v1 等路径；仅填写地址不会上传书页。").font(.system(size:10)).foregroundColor(.secondary)}
            VStack(alignment:.leading,spacing:7) {
                HStack{Text("API 密钥").font(.caption);Spacer();Button("从本服务钥匙串读取",action:model.loadCurrentKey).font(.caption)}
                SecureField("仅用于你选择的 API",text:$model.key).textFieldStyle(.roundedBorder)
                HStack{Toggle("安全记住密钥",isOn:$model.provider.rememberKey);Spacer();Button("删除已保存密钥",action:model.forgetKey).font(.caption)}
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
            Divider()
            HStack {Button("测试图片能力"){model.providerAction(probe:true)}.disabled(model.working);Text("发送随机测试图，可能产生少量请求费用。").font(.system(size:10)).foregroundColor(.secondary)}
            if !model.probeMessage.isEmpty {Text(model.probeMessage).font(.system(size:11)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
            HStack{Spacer();Button("保存配置",action:model.saveProvider).buttonStyle(.borderedProminent).tint(accent).disabled(model.working)}
        }.padding(25).frame(width:585).background(Color(nsColor:.windowBackgroundColor)).onChange(of:model.provider.baseURL){_ in model.key="";model.models=[];model.probeMessage="地址已修改，请输入该服务的密钥，或从钥匙串读取。"}
    }
}

struct PageCanvas:NSViewRepresentable {
    var image:NSImage?,blocks:[Block],selected:String?,showBoxes:Bool,drawing:Bool
    var onSelect:(String?)->Void,onNew:(Box)->Void,onMove:(String,Box)->Void
    func makeNSView(context:Context)->CanvasNSView {CanvasNSView()}
    func updateNSView(_ view:CanvasNSView,context:Context) {view.image=image;view.blocks=blocks;view.selected=selected;view.showBoxes=showBoxes;view.drawing=drawing;view.onSelect=onSelect;view.onNew=onNew;view.onMove=onMove;view.needsDisplay=true}
}
final class CanvasNSView:NSView {
    var image:NSImage?,blocks:[Block]=[],selected:String?,showBoxes=true,drawing=false
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
