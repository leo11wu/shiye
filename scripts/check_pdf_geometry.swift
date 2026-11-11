// Synthetic geometry checks only. Build PageArchiveCore first; this file does not call OCR.
// Run from the project root; each invocation preserves artifacts in a fresh subdirectory.
import AppKit
import PDFKit
import PageArchiveCore

struct Check: Error, CustomStringConvertible { let description: String }
func require(_ value: Bool, _ message: String) throws {
    if !value { throw Check(description: message) }
}
struct GeometryCase {
    let name: String, crop: CGRect, rotation: Int, pixels: CGSize, corners: [Int]
}
let colors: [[CGFloat]] = [[1,0,0], [0,1,0], [0,0,1], [0,0,0]]
// PDF corners are bottom-left, bottom-right, top-left, top-right.
func makePDF(_ item: GeometryCase, at url: URL) throws {
    let data = NSMutableData()
    var media = CGRect(x: 0, y: 0, width: item.crop.maxX + 80, height: item.crop.maxY + 90)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
        throw Check(description: "Cannot create fixture PDF")
    }
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
    context.fill(media) // Cropping must exclude this magenta surround.
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(item.crop)
    for index in 0..<4 {
        let x: CGFloat = index % 2 == 0 ? 0.05 : 0.75
        let y: CGFloat = index < 2 ? 0.05 : 0.75
        let color = colors[index]
        context.setFillColor(CGColor(red: color[0], green: color[1], blue: color[2], alpha: 1))
        context.fill(CGRect(x: item.crop.minX + item.crop.width * x,
                            y: item.crop.minY + item.crop.height * y,
                            width: item.crop.width * 0.20, height: item.crop.height * 0.20))
    }
    context.endPDFPage(); context.closePDF()
    guard let pdf = PDFDocument(data: data as Data), let page = pdf.page(at: 0) else {
        throw Check(description: "Cannot reopen fixture PDF")
    }
    page.setBounds(item.crop, for: .cropBox); page.rotation = item.rotation
    try require(pdf.write(to: url), "Cannot save fixture PDF")
}
func rgb(_ image: CGImage, x: CGFloat, y: CGFloat) throws -> [CGFloat] {
    // CGImage crop coordinates use the image's top-left pixel origin.
    let rect = CGRect(x: floor(CGFloat(image.width) * x), y: floor(CGFloat(image.height) * y), width: 1, height: 1)
    guard let pixel = image.cropping(to: rect),
          let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
          let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
        throw Check(description: "Cannot read marker pixel")
    }
    context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (0..<3).map { CGFloat(bytes[$0]) / 255 }
}
do {
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/book-conversion-check/render-regression-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let crop = CGRect(x: 47, y: 73, width: 240, height: 360)
    // Expected colors in raster top-left, top-right, bottom-left, bottom-right order.
    let cases = [
        GeometryCase(name: "nonzero-crop", crop: crop, rotation: 0, pixels: CGSize(width: 1000, height: 1500), corners: [2,3,0,1]),
        GeometryCase(name: "rotate-90", crop: crop, rotation: 90, pixels: CGSize(width: 1500, height: 1000), corners: [0,2,1,3]),
        GeometryCase(name: "rotate-270", crop: crop, rotation: 270, pixels: CGSize(width: 1500, height: 1000), corners: [3,1,2,0]),
        GeometryCase(name: "cap-4200", crop: CGRect(x: 17, y: 23, width: 1800, height: 1200), rotation: 0,
                     pixels: CGSize(width: 4200, height: 2800), corners: [2,3,0,1])
    ]
    for item in cases {
        let source = base.appendingPathComponent(item.name + ".pdf")
        try makePDF(item, at: source)
        let store = try ProjectStore(root: base.appendingPathComponent(item.name + ".shiyebook"))
        var document = BookDocument(title: item.name)
        try PageImporter.append(urls: [source], to: &document, store: store)
        try require(document.pages.count == 1, item.name + ": page count")
        let page = document.pages[0], image = try PageImporter.image(page: document.pages[0], store: store)
        let rotated = item.rotation % 180 != 0
        try require(abs(page.width - Double(rotated ? item.crop.height : item.crop.width)) < 0.01 &&
                    abs(page.height - Double(rotated ? item.crop.width : item.crop.height)) < 0.01, item.name + ": point size")
        try require(abs(image.width - Int(item.pixels.width)) <= 1 && abs(image.height - Int(item.pixels.height)) <= 1 &&
                    max(image.width, image.height) <= 4200, item.name + ": pixel size / cap")
        for index in 0..<4 {
            let actual = try rgb(image, x: index % 2 == 0 ? 0.15 : 0.85, y: index < 2 ? 0.15 : 0.85)
            let expected = colors[item.corners[index]]
            try require(zip(actual, expected).allSatisfy { ($0.1 > 0.5 ? $0.0 > 0.70 : $0.0 < 0.35) },
                        item.name + ": corner \(index) marker misplaced or underscaled: \(actual)")
        }
        print("PASS \(item.name): \(image.width)x\(image.height), four corner colors aligned")
    }
    print("PASS 4 geometry cases; renderVersion=\(PageImporter.renderVersion)")
    print("Artifacts: \(base.path)")
} catch {
    fputs("FAIL render-regression: \(error)\n", stderr)
    exit(1)
}
