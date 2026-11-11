下载：[Apple 芯片 Mac 安装包](https://github.com/leo11wu/shiye/releases/download/v0.1.1/Shiye-0.1.1-macOS-arm64.zip) · [中文使用说明](https://github.com/leo11wu/shiye/releases/download/v0.1.1/Shiye-0.1.1-Quick-Start-zh-CN.txt)

拾页是独立的轻量扫描文献 PDF 重建工具，适用于 macOS 14+、Apple Silicon。解压后打开「拾页.app」，无需安装 Python、Node 或本机模型。视觉 API 由每位用户自行配置。

0.1.1 修复正常启动时错误使用 UserDefaults 设置分组导致的立即退出，并修复临时目录别名造成的项目预览误报越界。设置和项目保持独立。

支持 PDF 与图片导入、按页识别、原扫描与重建页对照、区域与表格编辑、字号和边界微调、项目恢复、PDF/TXT 导出。正文导出为真实 PDF 文字；未识别或存在排版问题的页面显示为校对稿。

验证：47 项原生功能检查、9 项程序内界面集成检查通过；正常启动、重新打开及最终 ZIP 独立解压检查另有记录。界面集成为程序操作自身模型与视图，不等于完整鼠标操作验收。安装 ZIP 约 2.43 MB，App 约 6.02 MB，没有额外模型或字体下载。

当前为预览版。没有配置真实付费 API，没有完成真实书页 OCR 准确率、5,000 字人工金标或另一台全新 Mac 的验收。样张来自已知文字。App 使用本地临时签名，尚未 Apple 公证。

其他附件：[技术样张](https://github.com/leo11wu/shiye/releases/download/v0.1.1/Shiye-0.1.1-typesetting-sample.pdf)、[验证记录](https://github.com/leo11wu/shiye/releases/download/v0.1.1/Shiye-0.1.1-Validation-zh-CN.md)、[源码 ZIP](https://github.com/leo11wu/shiye/releases/download/v0.1.1/Shiye-0.1.1-source.zip)、[SHA256 校验值](https://github.com/leo11wu/shiye/releases/download/v0.1.1/SHA256SUMS.txt)。
