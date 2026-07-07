# Molten 路线图

## 定位
Typora 式单栏所见即所得 markdown 编辑器。存盘为规范化 markdown(Typora 同款取舍);macOS 先行,Shared/ 分层为 iOS 预留。

## M0 — 骨架(本次)
- [x] Crepe 编辑面离线打包(esbuild → Resources/dist,含 KaTeX 字体)
- [x] NSDocument 外壳:UTF-8 严格读写、20MB 门槛、autosave、存前拉取
- [x] 双向桥:ready/change 消息、setMarkdown/getMarkdown、web 进程崩溃自愈
- [x] 程序化主菜单、沙盒 entitlements、xcodegen 工程
- [x] 测试:文档契约、JS 字面量、真 bundle 桥往返

## M1 — 可日用
- [ ] 中英文本地化(复用 MarkMac L10n 模式)
- [ ] 深浅色打磨 + 主题(映射 MarkMac 三主题)
- [ ] 图片粘贴/拖入 → 沙盒安全落盘(assets/ 模式,复用 MarkMac 方案)
- [ ] 查找替换、字数统计、大纲侧栏(Crepe outline 或桥回传 headings)
- [ ] 外部改动检测(NSFilePresenter,复用 MarkMac 实现)

## M2 — 特色
- [ ] 图片卡片长图导出(直接移植 MarkMac card.html 流水线)
- [ ] 导出 HTML/PDF、打印
- [ ] 项目管理启动器(移植 MarkProjects)
- [ ] slash 命令菜单定制、front matter 编辑

## M3 — iOS
- [ ] iOS target(WKWebView 编辑面天然复用)

## 已知取舍
- 存盘会规范化 markdown(符号统一/空行重排)——ProseMirror 文档模型的固有行为,与 Typora 一致。「尽量保留原文」模式排期到 M2 后再评估。
- 编辑面为 JS(Crepe);这是新 app 的架构决定,不受 MarkMac AGENTS.md「禁止 JS 解析」约束。
