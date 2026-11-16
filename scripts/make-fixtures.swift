import AppKit
import PDFKit

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Tests/Fixtures", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let output = root.appendingPathComponent("reading-fixture.pdf")
let data = NSMutableData()
let consumer = CGDataConsumer(data: data)!
var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
for page in 1...3 {
    context.beginPDFPage(nil)
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let title = "Reader verification — page \(page)"
    title.draw(at: NSPoint(x: 54, y: 710), withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.black])
    let body = "This is selectable PDF text for testing Reader.\n\nA stored highlight belongs to page \(page) in page coordinates.\nIt should stay over this passage after zooming and rotation.\n\nThe original PDF must remain byte-for-byte unchanged.\nA passage note should survive closing and reopening Reader.\n\nSearch token: persimmon-\(page).\n\nThe blue square below helps check that colour is preserved."
    body.draw(in: NSRect(x: 54, y: 300, width: 500, height: 360), withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black])
    context.setFillColor(NSColor.systemBlue.cgColor)
    context.fill(CGRect(x: 54, y: 220, width: 90, height: 90))
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
}
context.closePDF()
let document = PDFDocument(data: data as Data)!
document.page(at: 1)?.rotation = 90
if !document.write(to: output) { fatalError("Could not write fixture") }
print(output.path)
