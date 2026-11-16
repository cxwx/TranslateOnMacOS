# imgtrans / cbztrans / livetrans — macOS 全本地 图片·漫画·字幕 翻译 CLI

只用 macOS 自带能力，零依赖、零 API key、零网络（除非语言包首次下载）：
**Vision** OCR / **SpeechAnalyzer** 语音识别 → **NaturalLanguage** 语言检测 → **Translation** 系统翻译 → **CoreText** 渲染新图。

## 编译（需要 Xcode 命令行工具）

```sh
swiftc -O -parse-as-library imgtrans.swift -o imgtrans
swiftc -O -parse-as-library cbztrans.swift -o cbztrans
swiftc -O -parse-as-library livetrans.swift -o livetrans
```

## 音视频 → 双语字幕 livetrans

```sh
./livetrans video.mp4           # → video.zh.srt 双语字幕（原文+中文各一行）
./livetrans --from ja anime.mkv # 指定源语言（缺省读容器语言标签，再缺省 en）
./livetrans --langs             # 查看已安装/可安装的识别语言
```

- 语音识别用 macOS 26+ 的 `SpeechAnalyzer`/`SpeechTranscriber`（设备端，实测 30~40 倍实时速）
- 源语言自动读容器音轨语言标签（eng/jpn/chi…，走 ffprobe）
- mkv/flv 等非 Apple 容器自动用 ffmpeg 提音频（无 ffmpeg 时退回 AVFoundation 直读 mp4/m4a/mp3/wav 等）
- 断轴规则：静音 >0.8s / 句末 / 60 字 / 7 秒上限；超长块按句切分、时间按字数比例摊

## 整本漫画翻译 cbztrans

```sh
./cbztrans aa.cbz              # → aa.zh.cbz (支持 cbz/zip/cbr/rar/cb7/7z, 输出统一为 cbz)
./cbztrans --from en --hq a.cbz b.cbr   # 指定源语言, 多文件
```

- 输入格式：cbz/zip 用系统 unzip；cbr/rar 用 unar；cb7/7z 用 7zz（后两个需 brew 装）
- 极速架构：**并行 OCR** → **全书去重、单会话批量翻译** → **并行渲染** → zip store 打包
- 无文字的页**原样保留**（字节级拷贝，零损耗零耗时）
- webp/gif 等无法回写的页面译后转 jpg；png/jpg 保持原格式
- 实测：52 页英文漫画 → 21.5s（M 系芯片，OCR 热身后）
- `--fast` OCR 快速模式；`--hq` 高保真翻译；`--force` 覆盖输出；`--to` 换目标语言

## 单张图片 imgtrans

```sh
./imgtrans 图片.webp                    # OCR + 自动检测语言 + 翻成中文，输出到终端
./imgtrans -r 图片.jpg                  # 同上，并生成 图片.translated.png（原位替换文字）
./imgtrans --from en --to ja -r *.png   # 指定语言
./imgtrans -r --out out/ 某目录/        # 整个目录批量处理
```

- 源语言缺省自动检测；目标语言缺省 `zh-Hans`
- `-r/--render`：采样原图背景色抹掉原文，按原位置、原配色绘制译文
- 支持 png / jpg / heic / webp / gif / bmp / tiff / avif

## 想全局可用

```sh
mkdir -p ~/bin && cp imgtrans ~/bin/    # 并把 ~/bin 加进 PATH
```

## 语言包

系统翻译的语言包按需下载（`prepareTranslation()` 会自动触发）。
如果首次翻译某语言失败，去 系统设置 → 通用 → 语言与地区 → 翻译语言 手动下载一次即可。
