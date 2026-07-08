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
- [x] 中英文本地化(en/zh-Hans 双目录,L10n 包装,菜单/状态栏/查找/大纲/错误全覆盖)
- [ ] 深浅色打磨 + 主题(映射 MarkMac 三主题)
- [x] 图片粘贴/拖入 → 沙盒安全落盘:Crepe onUpload → base64 桥 → assets/ 唯一名写入(文件夹 bookmark 一次授权,NSOpenPanel 锁定目录);molten-asset:// scheme handler 供沙盒内显示(防目录穿越);模型保留相对路径不泄漏 scheme
- [x] 查找(⌘F 原生查找栏 + window.find)、字数统计状态栏(CJK+拉丁混排)、大纲侧栏(⌥⌘1,桥回传 headings,点击/方向键跳转)——查找的「替换」延后
- [x] 外部改动检测(NSFilePresenter,干净文档自动重载,尺寸门槛+mtime 判重)

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
