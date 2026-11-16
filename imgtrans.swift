// imgtrans — macOS 全本地图片翻译 CLI
// Vision(OCR) + NaturalLanguage(语言检测) + Translation(翻译) + CoreText(新图渲染)
// 编译: swiftc -O imgtrans.swift -o imgtrans

import Foundation
import Vision
import NaturalLanguage
import AppKit
import CoreText
import ImageIO
import Translation

// MARK: - 参数解析

struct Options {
    var files: [String] = []
    var source: String? = nil
    var target: String = "zh-Hans"
    var render = false
    var outDir: String? = nil
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("imgtrans: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

let usageText = """
imgtrans \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "1.0") — macOS 全本地图片翻译 (Vision OCR + 系统翻译)

用法: imgtrans [选项] <图片或目录...>

选项:
  --from <lang>   源语言, 缺省自动检测 (en / ja / ko / zh-Hans ...)
  --to <lang>     目标语言, 缺省 zh-Hans
  -r, --render    生成翻译后的新图 <原名>.translated.png
  --out <dir>     新图输出目录, 缺省与原图同目录
  -h, --help      本帮助
"""

// 常见简写归一化 (NLLanguage 与 Translation 框架期望的形式)
func normLang(_ s: String) -> String {
    let m = ["zh": "zh-Hans", "zh-cn": "zh-Hans", "zh-hans": "zh-Hans", "zh-tw": "zh-Hant", "chinese": "zh-Hans",
             "en": "en-US", "english": "en-US",
             "ja": "ja-JP", "jp": "ja-JP", "japanese": "ja-JP",
             "ko": "ko-KR", "korean": "ko-KR",
             "fr": "fr-FR", "de": "de-DE", "es": "es-ES", "it": "it-IT",
             "ru": "ru-RU", "pt": "pt-BR", "uk": "uk-UA"]
    return m[s.lowercased()] ?? s
}

// MARK: - 文件收集

let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif", "bmp", "tiff", "tif", "avif"]

func collectFiles(_ paths: [String]) -> [String] {
    var out: [String] = []
    let fm = FileManager.default
    for p in paths {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: p, isDirectory: &isDir) else { fail("文件不存在: \(p)") }
        if isDir.boolValue {
            let items = (try? fm.contentsOfDirectory(atPath: p)) ?? []
            for item in items.sorted() where imageExts.contains((item as NSString).pathExtension.lowercased()) {
                out.append(p.hasSuffix("/") ? p + item : p + "/" + item)
            }
        } else {
            out.append(p)
        }
    }
    return out
}

// MARK: - 图片解码 (带 EXIF 方向矫正)

func loadCGImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    // 缩略图接口 + transform: 一次完成解码与方向矫正, 上限 6000px 防止超大图爆内存
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 6000,
    ]
    if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return cg }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// MARK: - OCR

struct Line {
    let text: String
    let box: CGRect      // Vision 归一化坐标, 原点左下
    let confidence: Float
}

func ocr(_ cg: CGImage, langs: [String]) throws -> [Line] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    if !langs.isEmpty { req.recognitionLanguages = langs }
    try VNImageRequestHandler(cgImage: cg).perform([req])
    let lines = (req.results ?? []).compactMap { obs -> Line? in
        guard let c = obs.topCandidates(1).first else { return nil }
        return Line(text: c.string, box: obs.boundingBox, confidence: c.confidence)
    }
    // 阅读顺序排序: 先按行分组(上→下), 组内左→右
    return lines.sorted {
        let tol = max($0.box.height, $1.box.height) * 0.6
        return abs($0.box.midY - $1.box.midY) > tol
            ? $0.box.midY > $1.box.midY
            : $0.box.minX < $1.box.minX
    }
}

// MARK: - 行合并 (同一气泡/段落内竖排堆叠的行拼成块, 保留翻译上下文)

struct Block {
    let text: String
    let box: CGRect
}

func isCJK(_ c: Character) -> Bool {
    guard let s = c.unicodeScalars.first else { return false }
    return (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value)
        || (0x3040...0x30FF).contains(s.value) || (0xAC00...0xD7AF).contains(s.value)
}

func mergeLines(_ lines: [Line]) -> [Block] {
    var blocks: [Block] = []
    for l in lines {
        if let last = blocks.last {
            let gap = last.box.minY - l.box.maxY   // 坐标原点在左下: 上一块的底边 - 当前行顶边
            let overlap = min(last.box.maxX, l.box.maxX) - max(last.box.minX, l.box.minX)
            let h = max(last.box.height, l.box.height)
            let sameColumn = overlap > 0.25 * min(last.box.width, l.box.width)
            if gap < h * 0.9 && gap > -h * 0.6 && sameColumn {
                let joiner = (last.text.last.map(isCJK) ?? false) && (l.text.first.map(isCJK) ?? false) ? "" : " "
                blocks[blocks.count - 1] = Block(text: last.text + joiner + l.text, box: last.box.union(l.box))
                continue
            }
        }
        blocks.append(Block(text: l.text, box: l.box))
    }
    return blocks
}

// MARK: - 翻译 (系统 Translation 框架, 批量 + 去重)

final class Translator {
    private let session: TranslationSession

    init(source: String, target: String) async throws {
        // macOS 26+ 无头初始化: 源语言须已安装; 未就绪则触发语言包下载
        session = TranslationSession(
            installedSource: Locale.Language(identifier: normLang(source)),
            target: Locale.Language(identifier: normLang(target)))
        let ready = await session.isReady
        if !ready { try await session.prepareTranslation() }
    }

    func translate(_ texts: [String]) async throws -> [String] {
        var uniq: [String] = []
        var idx: [Int] = []          // 每条输入对应 uniq 的下标; -1 = 空串跳过
        var map: [String: Int] = [:]
        for t in texts {
            let key = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { idx.append(-1); continue }
            if let i = map[key] { idx.append(i) }
            else { map[key] = uniq.count; uniq.append(key); idx.append(uniq.count - 1) }
        }
        guard !uniq.isEmpty else { return texts.map { _ in "" } }
        let reqs = uniq.enumerated().map {
            TranslationSession.Request(sourceText: $1, clientIdentifier: String($0))
        }
        let resps = try await session.translations(from: reqs)
        var out = uniq
        for r in resps {
            if let idStr = r.clientIdentifier, let i = Int(idStr), uniq.indices.contains(i) {
                out[i] = r.targetText
            }
        }
        return idx.map { $0 < 0 ? "" : out[$0] }
    }
}

// MARK: - 新图渲染 (采样背景色抹掉原文, CoreText 原位画译文)

final class Canvas {
    let ctx: CGContext
    let w: Int, h: Int
    private let px: [UInt8]

    init?(image: CGImage) {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        guard let d = ctx.data else { return nil }
        self.ctx = ctx; self.w = w; self.h = h
        self.px = [UInt8](UnsafeBufferPointer(start: d.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
    }

    // y 从图片底部数 (与 Vision 坐标系一致)
    private func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let cx = min(max(x, 0), w - 1), cy = min(max(y, 0), h - 1)
        let i = ((h - 1 - cy) * w + cx) * 4
        return (Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
    }

    // 方框外圈一圈像素的逐通道中位数 → 背景色
    func bgColor(around r: CGRect) -> (Double, Double, Double) {
        let pad = max(2.0, r.height * 0.18)
        let rect = r.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        var rs: [Double] = [], gs: [Double] = [], bs: [Double] = []
        let n = 24
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            let x = Int((rect.minX + rect.width * t).rounded()), y = Int((rect.minY + rect.height * t).rounded())
            for p in [(x, Int(rect.minY.rounded())), (x, Int(rect.maxY.rounded())),
                      (Int(rect.minX.rounded()), y), (Int(rect.maxX.rounded()), y)] {
                let c = rgb(p.0, p.1)
                rs.append(c.0); gs.append(c.1); bs.append(c.2)
            }
        }
        func med(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }
        return (med(rs), med(gs), med(bs))
    }

    // 方框内与背景差异最大的像素 → 原文字色 (保持译文与原文观感一致)
    func fgColor(in r: CGRect, bg: (Double, Double, Double)) -> (Double, Double, Double) {
        var picks: [(Double, Double, Double)] = []
        let step = max(1, Int(r.height / 12))
        var y = Int(r.minY.rounded())
        while y <= Int(r.maxY.rounded()) {
            var x = Int(r.minX.rounded())
            while x <= Int(r.maxX.rounded()) {
                let c = rgb(x, y)
                if abs(c.0 - bg.0) + abs(c.1 - bg.1) + abs(c.2 - bg.2) > 160 { picks.append(c) }
                x += step
            }
            y += step
        }
        guard !picks.isEmpty else {
            return bg.0 + bg.1 + bg.2 > 382 ? (32, 32, 32) : (244, 244, 244)
        }
        let n = Double(picks.count)
        return (picks.map(\.0).reduce(0, +) / n, picks.map(\.1).reduce(0, +) / n, picks.map(\.2).reduce(0, +) / n)
    }

    func erase(_ rect: CGRect, color: (Double, Double, Double)) {
        ctx.setFillColor(CGColor(srgbRed: color.0 / 255, green: color.1 / 255, blue: color.2 / 255, alpha: 1))
        let rad = min(rect.height * 0.2, 8)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.fillPath()
    }

    func drawText(_ text: String, in box: CGRect, color: (Double, Double, Double)) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        var size = min(box.height * 0.95, 220)
        while size > 5 {
            let attr = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .medium),
                .foregroundColor: NSColor(srgbRed: color.0 / 255, green: color.1 / 255, blue: color.2 / 255, alpha: 1),
                .paragraphStyle: style,
            ])
            let setter = CTFramesetterCreateWithAttributedString(attr)
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(
                setter, CFRange(location: 0, length: 0), nil,
                CGSize(width: box.width, height: .greatestFiniteMagnitude), nil)
            if fit.height <= box.height {
                let top = box.midY + fit.height / 2
                let rect = CGRect(x: box.minX, y: top - fit.height, width: box.width, height: fit.height)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                                     CGPath(rect: rect, transform: nil), nil)
                CTFrameDraw(frame, ctx)
                return
            }
            size *= 0.88
        }
    }

    func writePNG(to path: String) throws {
        guard let img = ctx.makeImage() else { fail("无法生成输出图像") }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
            fail("创建输出文件失败: \(path)")
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { fail("写入失败: \(path)") }
    }
}

// MARK: - 主流程

@main
struct ImgTrans {
    static func main() async {
        var opts = Options()
        var args = Array(CommandLine.arguments.dropFirst())
        while let a = args.first {
            args.removeFirst()
            func value() -> String {
                guard let v = args.first else { fail("选项 \(a) 缺少参数") }
                args.removeFirst()
                return v
            }
            switch a {
            case "-h", "--help":
                print(usageText); exit(0)
            case "--from":
                let v = value(); if v.lowercased() != "auto" { opts.source = v }
            case "--to": opts.target = value()
            case "-r", "--render": opts.render = true
            case "--out": opts.outDir = value()
            default:
                if a.hasPrefix("-") { fail("未知选项: \(a) (用 --help 查看)") }
                opts.files.append(a)
            }
        }
        if opts.files.isEmpty { print(usageText); exit(0) }
        let files = collectFiles(opts.files)
        if files.isEmpty { fail("目录中没有图片文件") }

        let clock = ContinuousClock()
        var hadError = false

        for path in files {
            let t0 = clock.now
            let name = (path as NSString).lastPathComponent
            guard let cg = loadCGImage(path) else { fail("无法解码: \(path)") }

            // 1. OCR (指定源语言则锁定, 否则用中英日韩混合识别)
            let ocrLangs = opts.source.map { [normLang($0)] } ?? ["zh-Hans", "en-US", "ja-JP", "ko-KR"]
            var lines: [Line]
            do { lines = try ocr(cg, langs: ocrLangs) }
            catch {
                lines = (try? ocr(cg, langs: [])) ?? []  // 语言组合不支持时退回默认
            }
            let blocks = mergeLines(lines)
            if blocks.isEmpty {
                print("◇ \(name) — 未识别到文字, 跳过"); continue
            }

            // 2. 源语言检测 (未指定时)
            let allText = blocks.map(\.text).joined(separator: "\n")
            var srcLang = opts.source
                ?? NLLanguageRecognizer.dominantLanguage(for: allText)?.rawValue
                ?? "en"
            srcLang = normLang(srcLang)
            let target = normLang(opts.target)

            do {
                // 3. 翻译 (批量)
                let translator = try await Translator(source: srcLang, target: target)
                let translated = try await translator.translate(blocks.map(\.text))

                let dt = clock.now - t0
                let ms = Double(dt.components.seconds) * 1_000 + Double(dt.components.attoseconds) / 1e15
                print("◇ \(name)  [\(srcLang) → \(target)]  \(blocks.count) 块  \(String(format: "%.0f", ms))ms")

                for (b, t) in zip(blocks, translated) where !t.isEmpty {
                    print("  \(b.text)")
                    print("    → \(t)")
                }

                // 4. 可选: 渲染新图
                if opts.render, !blocks.isEmpty {
                    guard let canvas = Canvas(image: cg) else { fail("画布创建失败") }
                    let W = CGFloat(canvas.w), H = CGFloat(canvas.h)
                    // 先全部采样+抹底, 再画字, 避免相邻块的底色盖住已画文字
                    var plan: [(text: String, box: CGRect, fg: (Double, Double, Double))] = []
                    for (b, t) in zip(blocks, translated) where !t.isEmpty {
                        let n = b.box
                        let rect = CGRect(x: n.minX * W, y: n.minY * H, width: n.width * W, height: n.height * H)
                        let fill = rect.insetBy(dx: -max(2, rect.height * 0.22), dy: -max(2, rect.height * 0.26))
                        let bg = canvas.bgColor(around: rect)
                        let fg = canvas.fgColor(in: rect, bg: bg)
                        canvas.erase(fill, color: bg)
                        let textBox = fill.insetBy(dx: max(2, fill.width * 0.03), dy: max(1, fill.height * 0.10))
                        plan.append((t, textBox, fg))
                    }
                    for p in plan { canvas.drawText(p.text, in: p.box, color: p.fg) }

                    let outName = (name as NSString).deletingPathExtension + ".translated.png"
                    let outPath = opts.outDir.map { (($0 as NSString).appendingPathComponent(outName)) }
                        ?? ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(outName)
                    try canvas.writePNG(to: outPath)
                    print("  ✓ 新图: \(outPath)")
                }
            } catch {
                let ns = error as NSError
                FileHandle.standardError.write(("imgtrans: 翻译失败 [\(name)] \(ns.domain) \(ns.code): \(ns.localizedDescription)\n").data(using: .utf8)!)
                if ns.domain == NSURLErrorDomain || ns.code == 1001 {
                    FileHandle.standardError.write("  提示: 语言包可能未下载。打开一次 系统设置 → 通用 → 语言与地区 → 翻译语言, 下载对应语言包后重试。\n".data(using: .utf8)!)
                }
                hadError = true
            }
        }
        exit(hadError ? 1 : 0)
    }
}
