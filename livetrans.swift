// livetrans — 全本地音视频 → 双语字幕 (SRT): video.mp4 → video.zh.srt
// SpeechAnalyzer/SpeechTranscriber(设备端语音识别+词级时间轴) + Translation(系统翻译)
// 编译: swiftc -O -parse-as-library livetrans.swift -o livetrans

import Foundation
import AVFoundation
import Speech
import NaturalLanguage
import Translation

// MARK: - 基础工具

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("livetrans: " + msg + "\n").data(using: .utf8)!)
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

func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
}

@discardableResult
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return (-1, "") }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - 音频准备 (ffmpeg 全格式 → 16k 单声道 wav; 无 ffmpeg 时退回 AVAudioFile 直读)

func prepareAudio(_ input: String, tmp: String) -> (url: URL, viaFfmpeg: Bool) {
    let wav = (tmp as NSString).appendingPathComponent("aud.wav")
    let fm = FileManager.default
    // 试试 ffmpeg (支持 mkv/flv/ts 等 AVFoundation 读不了的容器)
    let (code, _) = run("/opt/homebrew/bin/ffmpeg",
                        ["-hide_banner", "-loglevel", "error", "-y", "-i", input, "-vn", "-ac", "1", "-ar", "16000", "-f", "wav", wav])
    if code == 0, fm.fileExists(atPath: wav) {
        return (URL(fileURLWithPath: wav), true)
    }
    // 退路: mp4/m4a/mp3/wav/aiff/caf 等直接喂给 SpeechAnalyzer
    if (try? AVAudioFile(forReading: URL(fileURLWithPath: input))) != nil {
        return (URL(fileURLWithPath: input), false)
    }
    fail("无法读取音频 (容器不支持且本机没有 ffmpeg): \(input)")
}

/// 容器里的音轨语言标签 (eng/jpn/chi...) → 语言代码
func probeLanguage(_ input: String) -> String? {
    guard FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ffprobe") else { return nil }
    let (code, out) = run("/opt/homebrew/bin/ffprobe",
        ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream_tags=language", "-of", "csv=p=0", input])
    guard code == 0 else { return nil }
    let tag = out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let m = ["eng": "en", "jpn": "ja", "chi": "zh", "zho": "zh", "kor": "ko",
             "fra": "fr", "fre": "fr", "deu": "de", "ger": "de", "spa": "es",
             "ita": "it", "rus": "ru", "por": "pt", "und": "", "": ""]
    return m[tag].flatMap { $0.isEmpty ? nil : $0 }
}

// 长文本按句子切分 (供字幕分块)
func splitSentences(_ text: String) -> [String] {
    let tok = NLTokenizer(unit: .sentence)
    tok.string = text
    var out: [String] = []
    tok.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
        let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { out.append(s) }
        return true
    }
    return out.isEmpty ? [text] : out
}

// MARK: - 字幕轴

struct Cue {
    var text: String
    var start: Double
    var end: Double
}

func isCJK(_ c: Character) -> Bool {
    guard let s = c.unicodeScalars.first else { return false }
    return (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value)
        || (0x3040...0x30FF).contains(s.value) || (0xAC00...0xD7AF).contains(s.value)
        || (0x3000...0x303F).contains(s.value)   // CJK 标点
}

func joinText(_ a: String, _ b: String) -> String {
    guard let la = a.last, let fb = b.first else { return a + b }
    if ".,!?;:。，！？；：…)】”\"'".contains(fb) { return a + b }          // 标点紧跟
    if isCJK(la) || isCJK(fb) { return a + b }                              // CJK 不加空格
    return a + " " + b
}

func hasSentenceEnd(_ s: String) -> Bool {
    ".!?。！？…".contains(s.last.map(String.init) ?? "")
}

/// 词级 (文本, 时间区间) → 字幕块: 静音断句 / 句末断句 / 长度与时长上限
func buildCues(_ words: [(String, Double, Double)]) -> [Cue] {
    var cues: [Cue] = []
    var cur: Cue? = nil
    for (w, s, e) in words {
        let w = w.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { continue }
        let e = max(e, s + 0.2)
        if let c = cur {
            let joined = joinText(c.text, w)
            let gap = max(0, s - c.end)
            if gap > 0.8 || joined.count > 60 || (e - c.start) > 7.0
                || (hasSentenceEnd(c.text) && joined.count > 28) {
                cues.append(c)
                cur = Cue(text: w, start: s, end: e)
            } else {
                cur = Cue(text: joined, start: c.start, end: max(c.end, e))
            }
        } else {
            cur = Cue(text: w, start: s, end: e)
        }
    }
    if let c = cur { cues.append(c) }
    return cues
}

func srtTime(_ t: Double) -> String {
    let total = max(0, Int((t * 1000).rounded()))
    return String(format: "%02d:%02d:%02d,%03d", total / 3_600_000, total / 60_000 % 60, total / 1000 % 60, total % 1000)
}

// MARK: - 翻译 (同 cbztrans: 单会话 + 去重 + 分批)

final class Translator {
    private let session: TranslationSession
    init(source: String, target: String) async throws {
        session = TranslationSession(
            installedSource: Locale.Language(identifier: normLang(source)),
            target: Locale.Language(identifier: normLang(target)))
        let ready = await session.isReady
        if !ready { try await session.prepareTranslation() }
    }

    func translate(_ texts: [String]) async throws -> [String: String] {
        let uniq = Array(Set(texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).filter { !$0.isEmpty }
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

// MARK: - 单文件处理

func process(_ inputPath: String, fromOverride: String?, target: String) async {
    let clock = ContinuousClock()
    let fm = FileManager.default
    let inURL = URL(fileURLWithPath: inputPath)
    let outPath = (inURL.deletingPathExtension().path) + ".\(shortCode(target)).srt"

    guard fm.fileExists(atPath: inputPath) else { fail("文件不存在: \(inputPath)") }

    // 1. 源语言: --from > 容器语言标签 > en
    let from = fromOverride ?? probeLanguage(inputPath) ?? "en"
    let locale = Locale(identifier: normLang(from))
    print("  源语言  \(from) (\(locale.identifier))" + (fromOverride == nil && probeLanguage(inputPath) != nil ? " ← 容器标签" : fromOverride == nil ? " ← 默认 (--from 可指定)" : ""))

    // 2. 音频: 全格式 → 16k 单声道 wav
    let tmp = fm.temporaryDirectory.appendingPathComponent("livetrans-\(UUID().uuidString)").path
    defer { try? fm.removeItem(atPath: tmp) }
    try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    let audio = prepareAudio(inputPath, tmp: tmp)
    guard let avFile = try? AVAudioFile(forReading: audio.url) else { fail("音频解码失败: \(inputPath)") }
    let dur = Double(avFile.length) / avFile.processingFormat.sampleRate
    print("  音频  \(String(format: "%.1f", dur))s  \(audio.viaFfmpeg ? "(ffmpeg 提取)" : "(直读)")")

    // 3. 语音识别 (设备端, 词级时间轴)
    let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: [.audioTimeRange])

    let status = await AssetInventory.status(forModules: [transcriber])
    if status == .unsupported { fail("语音识别不支持语言 \(locale.identifier)") }
    if status != .installed {
        print("  识别语言包未安装, 下载中...")
        if let req = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try? await req.downloadAndInstall()
        }
    }

    var words: [(String, Double, Double)] = []
    do {
        let t0 = clock.now
        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: avFile,
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse),
            finishAfterFile: true)
        for try await result in transcriber.results {
            let txt = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !txt.isEmpty else { continue }
            let r = result.range
            var s = 0.0, e = 0.0
            if r.start.isNumeric, r.duration.isNumeric {
                s = r.start.seconds; e = s + r.duration.seconds
            }
            // 结果块过长 → 按句切分, 时间按字数比例摊
            if txt.count > 60, e > s {
                let total = Double(txt.count)
                var t = s
                for sent in splitSentences(txt) {
                    let d = (e - s) * Double(sent.count) / total
                    words.append((sent, t, t + d))
                    t += d
                }
            } else {
                words.append((txt, s, e))
            }
        }
        _ = analyzer
        let recMS = ms(clock.now - t0)
        var cues = buildCues(words)
        // 时间戳缺失的兜底: 均匀铺在音频时长上
        if cues.contains(where: { $0.end == 0 }) || cues.allSatisfy({ $0.end == 0 }) {
            let total = max(dur, 1)
            for i in cues.indices where cues[i].end == 0 {
                cues[i].start = total * Double(i) / Double(max(cues.count, 1))
                cues[i].end = cues[i].start + 3
            }
        }
        cues = cues.filter { !$0.text.isEmpty }
        print("  转写  \(String(format: "%.1f", recMS / 1000))s (\(String(format: "%.0f", dur / max(recMS / 1000, 0.01)))x 实时)  \(cues.count) 条字幕")
        guard !cues.isEmpty else { fail("没识别到语音内容") }

        // 4. 翻译 (整批去重)
        let t1 = clock.now
        let translator: Translator
        do {
            translator = try await Translator(source: from, target: target)
        } catch {
            fail("翻译语言包不可用 [\(normLang(from)) → \(normLang(target))]: \(error.localizedDescription)")
        }
        let dict = try await translator.translate(cues.map(\.text))
        print("  翻译  \(String(format: "%.1f", ms(clock.now - t1) / 1000))s  去重 \(dict.count)/\(cues.count) 条")

        // 5. 写双语 SRT
        var srt = ""
        for (i, c) in cues.enumerated() {
            let zh = dict[c.text.trimmingCharacters(in: .whitespacesAndNewlines)] ?? ""
            srt += "\(i + 1)\n\(srtTime(c.start)) --> \(srtTime(c.end))\n\(c.text)\n"
            srt += zh.isEmpty ? "" : zh + "\n"
            srt += "\n"
        }
        try srt.data(using: .utf8)!.write(to: URL(fileURLWithPath: outPath))
        print("  ✓ \(outPath)  (\(cues.count) 条, \(String(format: "%.1f", ms(clock.now - t0) / 1000))s)")
    } catch {
        fail("识别失败: \((error as NSError).localizedDescription)")
    }
}

// MARK: - 入口

@main
struct LiveTrans {
    static func main() async {
        var files: [String] = []
        var from: String? = nil
        var target = "zh-Hans"
        var args = Array(CommandLine.arguments.dropFirst())
        while let a = args.first {
            args.removeFirst()
            func value() -> String {
                guard let v = args.first else { fail("选项 \(a) 缺少参数") }
                args.removeFirst(); return v
            }
            switch a {
            case "-h", "--help":
                print("""
                livetrans — 全本地音视频 → 双语字幕 (设备端语音识别 + 系统翻译)

                用法: livetrans [选项] <video.mp4 | audio.m4a | anime.mkv ...>

                输出: <原名>.zh.srt 双语字幕 (原文 + 中文各一行)

                选项:
                  --from <lang>  源语言 (缺省: 读容器语言标签, 再缺省 en)
                  --to <lang>    目标语言, 缺省 zh-Hans
                  --langs        列出已安装的识别语言
                """)
                exit(0)
            case "--from":
                let v = value(); if v.lowercased() != "auto" { from = v }
            case "--to": target = value()
            case "--langs":
                let installed = await SpeechTranscriber.installedLocales
                let all = await SpeechTranscriber.supportedLocales
                print("已安装: \(installed.map(\.identifier).joined(separator: " "))")
                print("可安装: \(all.map(\.identifier).joined(separator: " "))")
                exit(0)
            default:
                if a.hasPrefix("-") { fail("未知选项: \(a)") }
                files.append(a)
            }
        }
        guard !files.isEmpty else { fail("请指定输入文件 (--help 查看用法)") }
        for f in files {
            print("◇ \(f)")
            await process(f, fromOverride: from, target: target)
        }
    }
}
