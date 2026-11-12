# 拾页 0.4.0

Apple 芯片 Mac，macOS 14 或更高版本。解压后打开拾页.app。OCR Agent 在应用中原生运行，内置书页 Skill 和 Apple Vision 检查。

内置 Skill 的首节是逐字转写规则，要求按原图保留大小写、词间空格、IPA、组合附标和上下标。模糊字符用 `⟦?⟧` 标记，并在疑点中注明所在行或词。

## 工作流

1. 导入扫描 PDF、JPEG 或 PNG。在齿轮中填写视觉接口，或使用 OpenAI 示例和自己的密钥。用“测试图片与结构”检查随机测试图。
2. 选择内置 Skill 或导入自定义 Markdown。在“识别文字”选择 OCR Agent，先选一页并开始。页图和 Skill 会发给配置的服务，独立 OCR 行在本机生成。
3. 在右栏查看疑点并定位到原图。需要时可添加区域或复识别选中区域。模型结果以待核对稿保存，项目内保留原转写、人工编辑及识别记录。
4. 在“其他格式”导出可编辑 Markdown。表格保留空格和合并格，脚注按页收录。确认过的相邻页段落在导出时续接。

OpenAI 官方地址及显式的 `/responses` 地址使用 Responses API，其他兼容接口使用 Chat Completions。默认一次整页识别，发现疑点再发送至多四个裁切。请求中断或结果变差时保留可用稿。缓存绑定页面、图像、模型、Skill 与策略版本。

## 验证

测试使用自制双栏页。它包含页眉页码、脚注、IPA、合并格和空白格。模型的首轮模拟回包故意漏掉脚注，第二轮恢复。桌面端通过实际 HTTP 连接本机模拟服务，Apple Vision 实际识别页面。脚本对照独立金标准检查原始转写、阅读顺序、脚注关系和表格。真实书页的准确率需要用所选云端模型另行测量。

原生回归测试通过 74 项。Responses 和 Chat Completions 两条路径均通过单页验收。重复运行复用了保存结果，并保留手工校对。常规界面与多页处理、停止、续做的回归检查也已通过。ZIP 解包后通过签名校验和两次正常启动。 [验收数据](validation-0.4.0)

```bash
bash scripts/build.sh release/0.4.0
bash scripts/test.sh
python3 scripts/check_ocr_agent.py release/0.4.0/拾页.app --root /private/tmp/shiye-agent-responses
python3 scripts/check_ocr_agent.py release/0.4.0/拾页.app --root /private/tmp/shiye-agent-chat --route chat
python3 scripts/package.py --release-dir release/0.4.0
```

本机打包使用临时签名。分发到其他 Mac 时，签名与 Apple 公证需要单独配置。
