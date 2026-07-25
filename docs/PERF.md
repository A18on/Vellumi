# 性能基准

用 `VellumiTests/MoltenPerformanceMeasurementTests` 在真实编辑器内核(Crepe +
ProseMirror,offscreen WKWebView)上实测。文档为中文长文样本:标题 + 正文段落
+ 列表 + Swift 代码块,接近实际写作场景。

重跑:

```bash
xcodebuild -project Vellumi.xcodeproj -scheme Vellumi -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/mac test \
  -only-testing:VellumiTests/MoltenPerformanceMeasurementTests
```

数值打印在测试日志的 `PERF |` 行。断言只拦截数量级级别的回归,不校验绝对值。

## 基线(M1 Max,2026-07-25,v0.4.2)

| 行数 | 大小 | 打开 | 序列化 | 大纲提取 | 字数统计 |
| ---- | ---- | ---- | ------ | -------- | -------- |
| 472 | 28.5 KB | 170 ms | 8.0 ms | 0.0 ms | 0.8 ms |
| 2360 | 143.0 KB | 315 ms | 36.2 ms | 0.2 ms | 2.3 ms |
| 7080 | 431.2 KB | 802 ms | 102.6 ms | 1.0 ms | 6.9 ms |

## 读数

- **成本集中在序列化**(`crepe.getMarkdown()`)。它随文档大小近似线性增长,且运行在
  JS 主线程上——每次防抖刷新都会阻塞输入这么久。大纲提取(遍历 ProseMirror 树)与
  Swift 侧字数统计(离主线程)都可忽略不计。
- **自适应节流按设计工作**:`Editor/src/main.js` 的 `flushChange` 实测序列化耗时后
  把防抖拉长到 `cost × 10`(上限 2s)。7000 行文档对应约 1s 刷新一次、每次约 100ms
  卡顿——可感知但可接受。
- **上限外推有风险**:`MoltenDocument.maximumFileSize` 允许 20 MB,按线性外推约合
  4.8 秒一次序列化,远超 2 秒的防抖上限,该区间会持续卡死。上限应下调,或对超过
  某阈值的文档给出提示 / 降级为源码模式。
- 打开 431 KB 文档约 0.8 秒(含编辑器构建与首次排版),体感可接受。

## 未测量

- 多窗口内存占用(每个文档一个 WKWebView + mermaid + 完整 CodeMirror 语言表)。
- 长时间编辑会话的内存增长。
- 项目全文搜索在大型文件夹上的耗时。
