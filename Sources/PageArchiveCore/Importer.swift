import AppKit
import PDFKit
import ImageIO
import Vision
import UniformTypeIdentifiers

public enum PageImporter {
    public static let supportedExtensions = ["pdf","jpg","jpeg","png","tif","tiff","heic","heif"]
    public static let renderVersion = "explicit-scale-300dpi-max4200-v2"

    public static func append(urls: [URL], to document: inout BookDocument, store: ProjectStore,
                              progress: (String) -> Void = {_ in}, cancelled: () -> Bool = {false}) throws {
        for input in urls {
            if cancelled() { throw CancellationError() }
            let ext=input.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { throw ArchiveError.message("不支持 \(input.lastPathComponent)。请选择 PDF、JPEG、PNG、TIFF 或 HEIC。") }
            let id=UUID().uuidString, relative="sources/\(id).\(ext)", copied=try store.url(relative)
            let hash=try Digest.file(input)
            try FileManager.default.copyItem(at:input,to:copied)
            document.sources.append(SourceFile(id:id,filename:input.lastPathComponent,relativePath:relative,sha256:hash))
            if ext=="pdf" {
                guard let pdf=PDFDocument(url:copied), !pdf.isLocked, let cg=CGPDFDocument(copied as CFURL) else { throw ArchiveError.message("无法读取 PDF；加密文件请先解锁。") }
                for index in 0..<pdf.pageCount {
                    if cancelled() { throw CancellationError() }
                    progress("导入 \(input.lastPathComponent) · \(index+1)/\(pdf.pageCount)")
                    try autoreleasepool {
                        guard let page=cg.page(at:index+1), let pdfPage=pdf.page(at:index) else { throw ArchiveError.message("无法读取 PDF 第 \(index+1) 页。") }
                        let crop=page.getBoxRect(.cropBox), rotation=Int(page.rotationAngle)
                        var size=crop.size
                        if abs(rotation)%180==90 { size=CGSize(width:size.height,height:size.width) }
                        guard size.width>0, size.height>0, size.width<20000, size.height<20000 else { throw ArchiveError.message("第 \(index+1) 页尺寸异常。") }
                        let scale=min(300.0/72.0,4200/max(size.width,size.height))
                        let width=max(1,Int(ceil(size.width*scale))),height=max(1,Int(ceil(size.height*scale)))
                        guard let ctx=bitmap(width:width,height:height) else { throw ArchiveError.message("页面内存分配失败。") }
                        ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(CGRect(x:0,y:0,width:width,height:height))
                        // PDF boxes use points; the bitmap uses pixels. On macOS the
                        // drawing transform may center a small page without upscaling it.
                        // Apply the DPI scale explicitly, then normalize crop/rotation in points.
                        ctx.interpolationQuality = .high
                        ctx.scaleBy(x:CGFloat(width)/size.width,y:CGFloat(height)/size.height)
                        ctx.concatenate(page.getDrawingTransform(.cropBox,rect:CGRect(origin:.zero,size:size),rotate:0,preserveAspectRatio:true))
                        ctx.drawPDFPage(page)
                        guard let image=ctx.makeImage() else { throw ArchiveError.message("页面渲染失败。") }
                        var entry=try saveImage(image,sourceID:id,sourcePage:index+1,size:size,store:store)
                        entry.sourceSHA256=hash
                        entry.sourceRotation=rotation;entry.sourceCropBox=[crop.minX,crop.minY,crop.width,crop.height].map(Double.init)
                        let text=pdfPage.string ?? ""
                        entry.textLayerAssessment=assessTextLayer(text)
                        // Existing text is offered as a candidate and never silently accepted.
                        if !text.isEmpty {
                            entry.hints=existingHints(page:pdfPage,crop:crop,rotation:rotation)
                            entry.issues.append(ReviewIssue("existing-text","已有文字层尚未确认；可选择采用候选，或重新视觉识别。"))
                        }
                        document.pages.append(entry)
                        try store.save(document)
                    }
                }
            } else {
                guard let source=CGImageSourceCreateWithURL(copied as CFURL,nil) else { throw ArchiveError.message("无法解码图片。") }
                for index in 0..<CGImageSourceGetCount(source) {
                    if cancelled() { throw CancellationError() }
                    progress("导入 \(input.lastPathComponent) · 图像 \(index+1)")
                    try autoreleasepool {
                        let options:[CFString:Any]=[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:4200,kCGImageSourceShouldCacheImmediately:true]
                        guard let image=CGImageSourceCreateThumbnailAtIndex(source,index,options as CFDictionary) else { throw ArchiveError.message("无法解码第 \(index+1) 张图像。") }
                        let props=CGImageSourceCopyPropertiesAtIndex(source,index,nil) as? [CFString:Any] ?? [:]
                        let rawW=(props[kCGImagePropertyPixelWidth] as? Double) ?? Double(image.width)
                        let rawH=(props[kCGImagePropertyPixelHeight] as? Double) ?? Double(image.height)
                        let orientation=(props[kCGImagePropertyOrientation] as? Int) ?? 1
                        let dpiX=(props[kCGImagePropertyDPIWidth] as? Double) ?? 200
                        let dpiY=(props[kCGImagePropertyDPIHeight] as? Double) ?? 200
                        var size=CGSize(width:rawW*72/min(1200,max(72,dpiX)),height:rawH*72/min(1200,max(72,dpiY)))
                        if [5,6,7,8].contains(orientation) { size=CGSize(width:size.height,height:size.width) }
                        let factor=min(1,2000/max(size.width,size.height));size=CGSize(width:size.width*factor,height:size.height*factor)
                        var entry=try saveImage(image,sourceID:id,sourcePage:index+1,size:size,store:store)
                        entry.sourceSHA256=hash;entry.sourceImageOrientation=orientation;entry.sourcePixelWidth=rawW;entry.sourcePixelHeight=rawH
                        document.pages.append(entry);try store.save(document)
                    }
                }
            }
        }
    }
    public static func bitmap(width:Int,height:Int) -> CGContext? {
        CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)
    }
    private static func saveImage(_ image: CGImage,sourceID:String,sourcePage:Int,size:CGSize,store:ProjectStore) throws -> Page {
        let id=UUID().uuidString,relative="pages/\(id).png", url=try store.url(relative)
        try writePNG(image,to:url)
        var page=Page(id:id,sourceID:sourceID,sourcePage:sourcePage,width:size.width,height:size.height,imagePath:relative,imageSHA256:try Digest.file(url))
        page.imageRenderVersion=renderVersion
        return page
    }
    public static func writePNG(_ image:CGImage,to url:URL) throws {
        guard let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else { throw ArchiveError.message("无法写入页面图像。") }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw ArchiveError.message("页面图像保存失败。") }
    }
    public static func image(page:Page,store:ProjectStore) throws -> CGImage {
        let url=try store.url(page.imagePath)
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { throw ArchiveError.message("项目的页面图像缺失，请重新导入原文件。") }
        return image
    }
    public static func crop(_ image:CGImage,box:Box) throws -> CGImage {
        guard box.isValid else { throw ArchiveError.message("区域边界无效。") }
        let rect=CGRect(x:box.x*Double(image.width),y:box.y*Double(image.height),width:box.width*Double(image.width),height:box.height*Double(image.height)).integral.intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
        guard let cropped=image.cropping(to:rect) else { throw ArchiveError.message("无法裁取识别区域。") };return cropped
    }
    public static func jpegData(_ image:CGImage) throws -> Data {
        let data=NSMutableData()
        guard let dest=CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil) else { throw ArchiveError.message("无法编码图像。") }
        CGImageDestinationAddImage(dest,image,[kCGImageDestinationLossyCompressionQuality:0.96] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ArchiveError.message("无法编码图像。") };return data as Data
    }
    public static func assessTextLayer(_ text:String) -> String {
        let chars=Array(text.unicodeScalars)
        if chars.isEmpty { return "无文字层" }
        let bad=chars.filter { $0.value==0 || $0.value==0xfffd || ($0.value>=0xe000 && $0.value<=0xf8ff) }.count
        if chars.count<20 || Double(bad)/Double(chars.count)>0.01 { return "疑似不可靠文字层，建议重新识别" }
        return "已有文字候选，需确认内容与顺序"
    }
    private static func existingHints(page:PDFPage,crop:CGRect,rotation:Int) -> [TextHint] {
        // Rotated PDF selection coordinates vary; cloud/manual route stays available.
        guard rotation%360==0, let selection=page.selection(for:crop) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            let rect=line.bounds(for:page);guard let text=line.string, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return nil }
            let box=Box((rect.minX-crop.minX)/crop.width,1.0-Double((rect.maxY-crop.minY)/crop.height),rect.width/crop.width,rect.height/crop.height)
            return box.isValid ? TextHint(box:box,text:text) : nil
        }
    }
    public static func detectHints(_ image:CGImage,languages:[String] = ["en-US","zh-Hant","zh-Hans"]) throws -> [TextHint] {
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.usesLanguageCorrection=false
        request.revision=VNRecognizeTextRequestRevision3;request.minimumTextHeight=0.003
        let supported=try request.supportedRecognitionLanguages()
        request.recognitionLanguages=languages.filter { supported.contains($0) }
        try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
        return (request.results ?? []).compactMap { item in
            guard let candidate=item.topCandidates(1).first else { return nil }
            let b=item.boundingBox
            let left=max(0,b.minX),top=max(0,1-b.maxY),right=min(1,b.maxX),bottom=min(1,1-b.minY)
            let box=Box(left,top,right-left,bottom-top)
            guard box.isValid,!candidate.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return nil}
            return TextHint(box:box,text:candidate.string,confidence:Double(candidate.confidence))
        }
    }
    public static func groupHints(_ hints:[TextHint],pageID:String) -> [Block] {
        let sorted=hints.sorted { abs($0.box.y-$1.box.y)<0.005 ? $0.box.x<$1.box.x : $0.box.y<$1.box.y }
        var groups:[(Box,String)]=[]
        for hint in sorted {
            if let last=groups.last, hint.box.y>=last.0.y,
               hint.box.y-(last.0.y+last.0.height)<hint.box.height*0.65,
               hint.box.x<last.0.x+0.08, abs(hint.box.width-last.0.width)<0.20 {
                let union=last.0.cgRect.union(hint.box.cgRect)
                groups[groups.count-1]=(Box(union.minX,union.minY,union.width,union.height),last.1+"\n"+hint.text)
            } else { groups.append((hint.box,hint.text)) }
        }
        return groups.enumerated().map { index,item in Block(id:"\(pageID)-b\(index+1)",order:index+1,box:item.0,text:item.1) }
    }
}
