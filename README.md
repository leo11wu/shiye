# 拾页 0.4.0

Apple 芯片 Mac 上的整本扫描书转换工具。提供多页并行的本机 OCR 初稿与可选视觉 API、逐页保存恢复、可搜索扫描 PDF、正文 TXT，以及精细原页重建。

0.4.0 将整页视觉识别接入 OCR Agent。应用内置书页 Skill，可从设置导入自定义 Markdown Skill。模型恢复双栏、脚注及表格，本机 Vision 用行框和原文检查疑点，必要时附裁切图重读一次。可编辑 Markdown 支持表格、脚注和人工确认过的跨页续段。见 [0.4.0 使用与验证](docs/RELEASE-0.4.0.md)。

0.3.0 将两种识别方式接入有限并发队列：默认同时处理 2 页，可选 1–4 页；完成页依次保存。界面以“导入 → 识别 → 导出”为主路径，提供整本状态总览、页面筛选、失败页重试和处理中页码；后台完成页不再抢走当前阅读位置。停止后保留已保存结果，退出会等待处理结束后保存。见 [0.3.0 验证与边界](docs/RELEASE-0.3.0.md)。

0.2.0 修复了 PDF 导入时画布放大但正文未同步放大的问题，改为显式 300 DPI 渲染（最长边 4200 px）。旧项目可以从保存的原始文件新建修复副本，旧成果保留。问题依据见 [审查记录](docs/BOOK-CONVERSION-AUDIT-20261106.md)，本轮验证见 [0.2.0 验证](docs/RELEASE-0.2.0.md)。

## 使用

双击 release/0.4.0/拾页.app。可以选择文件，也可以直接从 Finder 拖入 PDF、图片或单个拾页项目。旧 PDF 项目先点击“新建修复副本”，新书直接导入 PDF 或照片。在“2 识别文字”中选择本机初稿或 OCR Agent、处理范围和同时处理的页数。默认使用本机初稿、整本、同时 2 页。也可先选前 3 页试识别。

左侧状态卡片与筛选只改变显示列表，不改变识别和导出范围。失败页可单独查看、重试；本机仅重试尚无文字的页，有旧转写需要重新识别时可选择视觉 API。字号、边界和字体等设置收在高级排版中。

“导出”提供可搜索扫描 PDF、正文 TXT 和原页重建 PDF。可搜索扫描版保留全部页面并附质量记录，不要求先调整每个区域的字号。原页重建仍需文字与布局校对。完整说明：[docs/使用说明.txt](docs/使用说明.txt)。

## 构建与检查

本机只有 Command Line Tools，构建脚本直接调用 Swift 编译器，无第三方编译依赖。需要 Apple 芯片 Mac 和 Apple Swift 5.8+。

```bash
bash scripts/build.sh release/0.4.0
bash scripts/test.sh
.build/native/shiye-check fixtures output/pdf
python3 scripts/check_launch.py release/0.4.0/拾页.app --report /private/tmp/shiye-launch-check.json
python3 scripts/check_ui.py release/0.4.0/拾页.app --root /private/tmp/shiye-ui-check
python3 scripts/check_ui.py release/0.4.0/拾页.app --root /private/tmp/shiye-batch-check --batch
```

`Package.swift` 也提供完整 Xcode/SwiftPM 环境下的目标：`Shiye`、`shiye-check`、`shiye-tests`。当前环境实际验证的是上述原生脚本。

`scripts/test.sh` 使用无外部依赖的 Swift 检查程序。测试报告写入 `.build/test-results.json`。`scripts/audit_cer.py` 可从项目生成待人工填写的金标清单，再计算正文 CER。

`scripts/check_launch.py` 连续启动、关闭并重新打开实际 App，两次均不使用 `--qa` 或界面测试参数。0.1.1 修复了 0.1.0 在正常启动时错误创建设置分组导致的闪退；自动界面检查曾因使用独立测试设置而漏掉此问题。

## 数据与接口

- 项目为 `.shiyebook` 目录包。`document.json` 使用 `bookocr-ir-1`，附带原始文件、页面副本、逐页响应及修改历史；原始转写不被用户编辑覆盖。
- 默认项目位置：`~/Library/Application Support/Shiye/Projects/`。项目菜单可显示所在位置或保存独立副本。普通设置使用 `local.leowu.Shiye`，密钥单独存入 `local.leowu.Shiye.ocr.credentials` 钥匙串服务。
- OCR Agent 在 OpenAI 官方地址或显式填入的 `/responses` 地址使用 Responses API 和严格结构化输出。其他兼容地址走 `/chat/completions`，在本机解析检查。图片以 JPEG data URI 发送，模型列表为 `GET <基地址>/models`。
- 单页结构包括来源、尺寸、方向、图像哈希、块、样式片段、表格单元格、阅读顺序、疑难项和识别记录。坐标统一为左上原点、0–1 的页面归一化坐标。
- 本机和 API 默认同时处理 2 页，可选 1–4 页；结果依次保存，完成计数以保存成功为准。停止后不调度新页，未完成页可再次处理。本机识别可能需等待正在处理的页返回。
- OCR Agent 每页最多两轮识别，每轮允许一次短暂网络重试，遵守可接受的 `Retry-After`。首轮服务或鉴权失败会停止队列。单页内容错误保存诊断并继续，重读失败时保留已取得的初稿。请求按页独立发出。
- 使用系统中文字体，随包只包含 Charis 四种样式。缺字、LastResort 兜底字体、溢出、疑似漏块和区域重叠会产生校对问题。

## 当前边界

以横排印刷文献为首版适用范围。原页尺寸与页序保留，允许局部调版，不自动添加续页。模型坐标及本机区域检测都需要检查；自动检测不能保证发现所有遗漏。

真实项目已有三页历史视觉 API 转写。本轮使用本机识别验证整书流程，结果仍是未校对初稿，尚未完成整书独立金标准准确率验收。技术样张只验证预设文字排版。手机照片的曲面展平、透视纠正、跨页拆分及章节重排未实现。App 使用本地临时签名，未通过 Apple 公证。

公开依据：[Apple Core Text](https://developer.apple.com/library/archive/documentation/StringsTextFonts/Conceptual/CoreText_Programming/LayoutOperations/LayoutOperations.html)、[图片请求格式](https://developers.openai.com/api/docs/guides/images-vision)、[Charis 7.000](https://software.sil.org/charis/download/)。Charis 字体附带 SIL OFL 1.1，其他正文源代码使用 MIT 许可。
