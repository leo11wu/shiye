import AppKit
import Foundation

let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels=size*scale, rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
        let transform=NSAffineTransform();transform.scale(by:CGFloat(pixels)/1024);transform.concat()
        NSColor(calibratedRed:0.13,green:0.35,blue:0.31,alpha:1).setFill();NSBezierPath(roundedRect:NSRect(x:40,y:40,width:944,height:944),xRadius:205,yRadius:205).fill()
        NSColor(calibratedRed:0.66,green:0.79,blue:0.72,alpha:1).setFill();NSBezierPath(roundedRect:NSRect(x:200,y:195,width:540,height:650),xRadius:35,yRadius:35).fill()
        NSColor(calibratedRed:0.98,green:0.97,blue:0.92,alpha:1).setFill();NSBezierPath(roundedRect:NSRect(x:280,y:145,width:540,height:650),xRadius:35,yRadius:35).fill()
        NSColor(calibratedRed:0.16,green:0.39,blue:0.34,alpha:1).setFill()
        for (y,w) in [(665,340),(555,340),(445,250)]{NSBezierPath(roundedRect:NSRect(x:360,y:CGFloat(y),width:CGFloat(w),height:24),xRadius:12,yRadius:12).fill()}
        NSColor(calibratedRed:0.67,green:0.43,blue:0.24,alpha:1).setStroke();let ring=NSBezierPath(ovalIn:NSRect(x:575,y:215,width:150,height:150));ring.lineWidth=24;ring.stroke()
        let handle=NSBezierPath();handle.move(to:NSPoint(x:700,y:230));handle.line(to:NSPoint(x:775,y:155));handle.lineWidth=28;handle.lineCapStyle = .round;handle.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name="icon_\(size)x\(size)"+(scale==2 ? "@2x" : "")+".png"
        try rep.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(name))
    }
}
// ICNS container with PNG representations; no iconutil or external tooling required.
var payload=Data()
func uint32(_ value:UInt32)->Data {var big=value.bigEndian;return Data(bytes:&big,count:4)}
for (kind,name) in [("icp4","icon_16x16.png"),("icp5","icon_32x32.png"),("icp6","icon_32x32@2x.png"),("ic07","icon_128x128.png"),("ic08","icon_256x256.png"),("ic09","icon_512x512.png"),("ic10","icon_512x512@2x.png")] {
    let png=try Data(contentsOf:root.appendingPathComponent(name));payload.append(Data(kind.utf8));payload.append(uint32(UInt32(png.count+8)));payload.append(png)
}
var file=Data("icns".utf8);file.append(uint32(UInt32(payload.count+8)));file.append(payload)
try file.write(to:root.deletingLastPathComponent().appendingPathComponent("AppIcon.icns"),options:.atomic)
