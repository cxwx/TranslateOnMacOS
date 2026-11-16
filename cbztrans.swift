// cbztrans — 全本地漫画翻译: aa.cbz → aa.zh.cbz (支持 cbz/zip/cbr/rar/cb7/7z)
// Vision(OCR) + NaturalLanguage(语言检测) + Translation(系统翻译) + CoreText(渲染)
// 极速架构: 并行OCR → 全书去重单会话批量翻译 → 并行渲染 → 无文字页原样保留 → zip -0 打包
// 编译: swiftc -O -parse-as-library cbztrans.swift -o cbztrans

import Foundation
import Vision
import NaturalLanguage
import AppKit
import CoreText
import ImageIO
import Translation

// MARK: - 工具函数

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("cbztrans: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func normLang(_ s: String) -> String {
    let m = ["zh": "zh-Hans", "zh-cn": "zh-Hans", "zh-hans": "zh-Hans", "zh-tw": "zh-Hant", "chinese": "zh-Hans",
             "en": "en-US", "english": "en-US",
             "ja": "ja-JP", "jp": "ja-JP", "japanese": "ja-JP",
             "ko": "ko-KR", "korean": "ko-KR",
             "fr": "fr-FR", "de": "de-DE", "es": "es-ES", "it": "it-IT",
             "ru": "ru-RU", "pt": "pt-BR", "uk": "uk-UA"]
    return m[s.lowercased()] ?? s
}

func shortCode(_ lang: String) -> String {
    let n = normLang(lang)
    return n.split(separator: "-").first.map(String.init) ?? n
}

func isCJK(_ c: Character) -> Bool {
    guard let s = c.unicodeScalars.first else { return false }
    return (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value)
        || (0x3040...0x30FF).contains(s.value) || (0xAC00...0xD7AF).contains(s.value)
}

let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif", "bmp", "tiff", "tif", "avif"]

@discardableResult
func run(_ exe: String, _ args: [String], cwd: String? = nil, stdinData: Data? = nil) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    if let stdinData {
        let pipe = Pipe()
        p.standardInput = pipe
        try p.run()
        try pipe.fileHandleForWriting.write(contentsOf: stdinData)
        try pipe.fileHandleForWriting.close()
    } else {
        try p.run()
    }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { fail("\(exe) 退出码 \(p.terminationStatus)") }
}

// 并行 for (同步重活用线程池跑满)
func parallelFor(_ n: Int, _ body: @escaping (Int) -> Void) async {
    guard n > 0 else { return }
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: n) { i in body(i) }
            cont.resume()
        }
    }
}

// MARK: - OCR (同 imgtrans)

struct Line {
    let text: String
    let box: CGRect
}

struct Block {
    let text: String
    let box: CGRect
}

func loadCGImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 6000,
    ]
    if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return cg }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func ocr(_ cg: CGImage, langs: [String], fast: Bool) throws -> [Line] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = fast ? .fast : .accurate
    req.usesLanguageCorrection = true
    if !langs.isEmpty { req.recognitionLanguages = langs }
    try VNImageRequestHandler(cgImage: cg).perform([req])
    let lines = (req.results ?? []).compactMap { obs -> Line? in
        guard let c = obs.topCandidates(1).first else { return nil }
        return Line(text: c.string, box: obs.boundingBox)
    }
    return lines.sorted {
        let tol = max($0.box.height, $1.box.height) * 0.6
        return abs($0.box.midY - $1.box.midY) > tol
            ? $0.box.midY > $1.box.midY
            : $0.box.minX < $1.box.minX
    }
}

func mergeLines(_ lines: [Line]) -> [Block] {
    var blocks: [Block] = []
    for l in lines {
        if let last = blocks.last {
            let gap = last.box.minY - l.box.maxY
            let overlap = min(last.box.maxX, l.box.maxX) - max(last.box.minX, l.box.minX)
            let h = max(last.box.height, l.box.height)
            if gap < h * 0.9 && gap > -h * 0.6 && overlap > 0.25 * min(last.box.width, l.box.width) {
                let joiner = (last.text.last.map(isCJK) ?? false) && (l.text.first.map(isCJK) ?? false) ? "" : " "
                blocks[blocks.count - 1] = Block(text: last.text + joiner + l.text, box: last.box.union(l.box))
                continue
            }
        }
        blocks.append(Block(text: l.text, box: l.box))
    }
    return blocks
}

// MARK: - 语言检测 (按块加权投票, 约束在 OCR 候选集内)
// 漫画全书大写碎片会被 NLLanguageRecognizer 误判成 nl 等语言, 必须约束候选

func detectLang(_ texts: [String], candidates: [String]) -> String? {
    let rec = NLLanguageRecognizer()
    rec.languageConstraints = candidates.map { NLLanguage(rawValue: $0) }
    var votes: [String: Int] = [:]
    for t in texts where t.count >= 2 {
        rec.reset()
        rec.processString(t)
        if let l = rec.dominantLanguage { votes[l.rawValue, default: 0] += t.count + 1 }
    }
    return votes.max { $0.value < $1.value }?.key
}

// MARK: - 翻译 (整本书共用一个会话, 全局去重, 分批)

final class Translator {
    private let session: TranslationSession

    init(source: String, target: String, hq: Bool) async throws {
        // 注: preferredStrategy(.lowLatency/.highFidelity) 在对应模型语言包未就绪时
        // 会直接 "Unable to Translate", 故用默认策略; --hq 保留给后续验证
        _ = hq
        session = TranslationSession(
            installedSource: Locale.Language(identifier: normLang(source)),
            target: Locale.Language(identifier: normLang(target)))
        let ready = await session.isReady
        if !ready {
            FileHandle.standardError.write("  (语言包未就绪, 触发下载...)".data(using: .utf8)!)
            try await session.prepareTranslation()
        }
    }

    /// 全局去重后分批翻译, 返回 [原文: 译文]
    func translate(_ texts: [String]) async throws -> [String: String] {
        let uniq = Array(Set(texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }
        guard !uniq.isEmpty else { return [:] }
        var out: [String: String] = [:]
        var start = 0
        while start < uniq.count {
            let chunk = uniq[start..<min(start + 64, uniq.count)]
            let reqs = chunk.map { TranslationSession.Request(sourceText: $0) }
            for r in try await session.translations(from: reqs) {
                out[r.sourceText] = r.targetText
            }
            start += 64
        }
        return out
    }
}

// MARK: - 渲染画布

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

    private func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let cx = min(max(x, 0), w - 1), cy = min(max(y, 0), h - 1)
        let i = ((h - 1 - cy) * w + cx) * 4
        return (Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
    }

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

    func write(to path: String, jpeg: Bool) {
        guard let img = ctx.makeImage() else { fail("无法生成输出图像") }
        let uti = (jpeg ? "public.jpeg" : "public.png") as CFString
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, uti, 1, nil) else {
            fail("创建输出文件失败: \(path)")
        }
        if jpeg { CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary) }
        else { CGImageDestinationAddImage(dest, img, nil) }
        guard CGImageDestinationFinalize(dest) else { fail("写入失败: \(path)") }
    }
}

// MARK: - 单本书处理

struct PageJob {
    let path: String          // 解压后绝对路径
    let relPath: String       // 归档内相对路径
}

var ocrMS = 0.0, transMS = 0.0, renderMS = 0.0, packMS = 0.0

func processBook(_ inputPath: String, srcOverride: String?, target: String, fast: Bool, hq: Bool, force: Bool) async {
    let clock = ContinuousClock()
    let fm = FileManager.default
    let inputURL = URL(fileURLWithPath: inputPath)
    let ext = inputURL.pathExtension.lowercased()
    let base = inputURL.deletingPathExtension().lastPathComponent
    let outPath = (inputURL.deletingLastPathComponent().path as NSString)
        .appendingPathComponent("\(base).\(shortCode(target)).cbz")

    guard fm.fileExists(atPath: inputPath) else { fail("文件不存在: \(inputPath)") }
    if !force && fm.fileExists(atPath: outPath) { fail("输出已存在: \(outPath) (--force 覆盖)") }

    // 1. 解压
    let tmp = fm.temporaryDirectory.appendingPathComponent("cbztrans-\(UUID().uuidString)").path
    defer { try? fm.removeItem(atPath: tmp) }
    do {
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let t0 = clock.now
        switch ext {
        case "cbz", "zip":
            try run("/usr/bin/unzip", ["-qq", "-o", inputPath, "-d", tmp])
        case "cbr", "rar":
            try run("/opt/homebrew/bin/unar", ["-quiet", "-force-overwrite", "-output-directory", tmp, inputPath])
        case "cb7", "7z":
            try run("/opt/homebrew/bin/7zz", ["x", "-y", "-bd", "-o\(tmp)", inputPath])
        default:
            fail("不支持的格式 .\(ext) (支持 cbz/zip/cbr/rar/cb7/7z)")
        }
        print("  解压  \(String(format: "%.1f", ms(clock.now - t0) / 1000))s")
        guard fm.subpaths(atPath: tmp)?.isEmpty != true else { fail("压缩包是空的") }
    } catch { fail("解压失败: \(error.localizedDescription)") }

    // 2. 收集页面 (自然排序, 跳过系统垃圾文件)
    var pages: [PageJob] = []
    if let en = fm.enumerator(atPath: tmp) {
        var all: [(String, String)] = []
        while let f = en.nextObject() as? String {
            if f.hasPrefix("__MACOSX") || f.hasSuffix(".DS_Store") || f.hasSuffix("/") { continue }
            let abs = (tmp as NSString).appendingPathComponent(f)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: abs, isDirectory: &isDir), !isDir.boolValue else { continue }
            all.append((f, abs))
        }
        all.sort { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        for (rel, abs) in all {
            let e = (rel as NSString).pathExtension.lowercased()
            if imageExts.contains(e) {
                pages.append(PageJob(path: abs, relPath: rel))
            }
        }
        // 无文字的普通文件 (如 ComicInfo.xml) 留在原地, 打包时原样带回
    }
    guard !pages.isEmpty else { fail("压缩包里没有图片") }
    print("  页面  \(pages.count) 张")

    // 3. 并行 OCR
    var boxes: [[Block]] = .init(repeating: [], count: pages.count)
    let ocrLangs = srcOverride.map { [normLang($0)] } ?? ["zh-Hans", "en-US", "ja-JP", "ko-KR"]
    let lock = NSLock()
    var done = 0
    let t0 = clock.now
    await parallelFor(pages.count) { i in
        guard let cg = loadCGImage(pages[i].path) else { return }
        if let lines = try? ocr(cg, langs: ocrLangs, fast: fast), !lines.isEmpty {
            boxes[i] = mergeLines(lines)
        }
        lock.lock(); done += 1
        if done % 10 == 0 || done == pages.count {
            FileHandle.standardError.write("\r  OCR   \(done)/\(pages.count)".data(using: .utf8)!)
        }
        lock.unlock()
    }
    ocrMS = ms(clock.now - t0)
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    print("  OCR   \(String(format: "%.1f", ocrMS / 1000))s  \(boxes.reduce(0) { $0 + $1.count }) 块")
    let allTexts = boxes.flatMap { $0.map(\.text) }
    guard !allTexts.isEmpty else {
        print("  全书未识别到文字, 不生成输出")
        return
    }

    // 4. 语言检测 + 整书单会话翻译 (全局去重)
    let candidates = ["en", "zh-Hans", "ja", "ko"]
    var srcLang = normLang(srcOverride ?? detectLang(allTexts, candidates: candidates) ?? "en")
    do {
        let t0 = clock.now
        var translator: Translator? = nil
        do {
            translator = try await Translator(source: srcLang, target: target, hq: hq)
        } catch {
            guard srcLang != "en-US" else { throw error }
            // 检测出的语言包不可用 → 回退英语 (cbz→zh 场景英文书占绝对多数)
            FileHandle.standardError.write("  (源语言 \(srcLang) 不可用, 回退 en-US)".data(using: .utf8)!)
            srcLang = "en-US"
            translator = try await Translator(source: srcLang, target: target, hq: hq)
        }
        let dict = try await translator!.translate(allTexts)
        transMS = ms(clock.now - t0)
        print("  翻译  \(String(format: "%.1f", transMS / 1000))s  [\(srcLang) → \(normLang(target))] 去重 \(dict.count)/\(allTexts.count) 条")

        // 5. 并行渲染 (无文字/译文为空的页原样保留)
        let t1 = clock.now
        var rendered = 0
        await parallelFor(pages.count) { i in
            guard !boxes[i].isEmpty,
                  let cg = loadCGImage(pages[i].path),
                  let canvas = Canvas(image: cg) else { return }
            let W = CGFloat(canvas.w), H = CGFloat(canvas.h)
            var plan: [(String, CGRect, (Double, Double, Double))] = []
            for b in boxes[i] {
                guard let t = dict[b.text.trimmingCharacters(in: .whitespacesAndNewlines)], !t.isEmpty else { continue }
                let n = b.box
                let rect = CGRect(x: n.minX * W, y: n.minY * H, width: n.width * W, height: n.height * H)
                let fill = rect.insetBy(dx: -max(2, rect.height * 0.22), dy: -max(2, rect.height * 0.26))
                let bg = canvas.bgColor(around: rect)
                let fg = canvas.fgColor(in: rect, bg: bg)
                canvas.erase(fill, color: bg)
                let textBox = fill.insetBy(dx: max(2, fill.width * 0.03), dy: max(1, fill.height * 0.10))
                plan.append((t, textBox, fg))
            }
            guard !plan.isEmpty else { return }   // 没有可画内容 → 原样保留
            for p in plan { canvas.drawText(p.0, in: p.1, color: p.2) }
            // webp 等无法回写的格式 → 输出 jpg 并替换; png 回写 png; jpg 回写 jpg
            let e = (pages[i].relPath as NSString).pathExtension.lowercased()
            let out: String
            if e == "png" || e == "jpg" || e == "jpeg" { out = pages[i].path }
            else {
                out = (pages[i].path as NSString).deletingPathExtension + ".jpg"
                try? FileManager.default.removeItem(atPath: pages[i].path)
            }
            canvas.write(to: out, jpeg: e != "png")
            lock.lock(); rendered += 1; lock.unlock()
        }
        renderMS = ms(clock.now - t1)
        print("  渲染  \(String(format: "%.1f", renderMS / 1000))s  \(rendered) 张重绘, \(pages.count - rendered) 张原样")

        // 6. 打包 (store 模式, 图片已压缩, 零损耗零耗时)
        let t2 = clock.now
        var names: [String] = []
        if let en = fm.enumerator(atPath: tmp) {
            while let f = en.nextObject() as? String {
                if f.hasPrefix("__MACOSX") || f.hasSuffix(".DS_Store") { continue }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: (tmp as NSString).appendingPathComponent(f), isDirectory: &isDir), !isDir.boolValue {
                    names.append(f)
                }
            }
        }
        names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        try? fm.removeItem(atPath: outPath)
        try run("/usr/bin/zip", ["-0", "-qq", "-X", outPath, "-@"], cwd: tmp,
                stdinData: (names.joined(separator: "\n") + "\n").data(using: .utf8))
        packMS = ms(clock.now - t2)
        let size = (try? fm.attributesOfItem(atPath: outPath)[.size] as? Int).flatMap { $0 } ?? 0
        print("  打包  \(String(format: "%.1f", packMS / 1000))s  → \(URL(fileURLWithPath: outPath).lastPathComponent) (\(String(format: "%.1f", Double(size) / 1_048_576)) MB)")
        print("  ✓ 完成")
    } catch {
        let ns = error as NSError
        fail("翻译失败 \(ns.domain) \(ns.code): \(ns.localizedDescription)\n  若提示语言包问题, 可去 系统设置 → 通用 → 语言与地区 → 翻译语言 手动下载后重试")
    }
}

func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
}

var ocrTotal = 0.0, transTotal = 0.0, renderTotal = 0.0, packTotal = 0.0

// MARK: - 入口

@main
struct CbzTrans {
    static func main() async {
        var files: [String] = []
        var src: String? = nil
        var target = "zh-Hans"
        var fast = false, hq = false, force = false
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
                print("""
                cbztrans — 全本地漫画批量翻译 (Vision OCR + 系统翻译 + CoreText 渲染)

                用法: cbztrans [选项] <aa.cbz|aa.zip|aa.cbr|aa.rar|aa.7z ...>

                输出: aa.zh.cbz (与输入同目录; 输出统一为 cbz)

                选项:
                  --from <lang>  源语言, 缺省自动检测
                  --to <lang>    目标语言, 缺省 zh-Hans
                  --fast         OCR 快速模式 (更快, 手写体/艺术字准确率略降)
                  --hq           高保真翻译模型 (默认 lowLatency 低延迟模型)
                  --force        覆盖已存在的输出
                """)
                exit(0)
            case "--from":
                let v = value(); if v.lowercased() != "auto" { src = v }
            case "--to": target = value()
            case "--fast": fast = true
            case "--hq": hq = true
            case "--force", "-f": force = true
            default:
                if a.hasPrefix("-") { fail("未知选项: \(a)") }
                files.append(a)
            }
        }
        guard !files.isEmpty else { fail("请指定输入文件 (--help 查看用法)") }

        for f in files {
            let t0 = ContinuousClock.now
            print("◇ \(f)")
            await processBook(f, srcOverride: src, target: target, fast: fast, hq: hq, force: force)
            let total = ms(ContinuousClock.now - t0) / 1000
            print("  合计  \(String(format: "%.1f", total))s")
        }
    }
}
