<!-- 第二轮审计(v0.5.0 基线):7 路专项 —— 对新代码的回归复查 ×2、图片卡渲染器、
     崩溃恢复与状态还原、更新流程与首次启动、产品缺口、测试质量 —— 每条再经对抗
     验证代理逐一尝试证伪。41 条通过、3 条被证伪。

     A1/A2/B8 已在 v0.5.1 修复并发布(见 git log);其余条目待处理。 -->

# Vellumi v0.5.0 审计收敛 —— 处置计划

## 结论先行

**v0.5.0 已发布的二进制根本无法启动。** 我直接解包 `dist/Vellumi-0.5.0.app.zip`（7424613 字节，与 `appcast.xml:11` 的 size 一致）并运行，dyld 在 `main()` 之前 abort：

```
Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
Reason: ... code signature ... not valid for use in process:
        mapping process and mapped file (non-platform) have different Team IDs
```

这是本波次引入的回归（`a0d1b13` 用 `--preserve-metadata=entitlements` 签名，无 runtime 标志；HEAD 的 `scripts/release.sh:78` 加了 `--options runtime`）。所有其它结论都排在这条后面。

回归 / 既有的划分（依据 `git diff a0d1b13..HEAD --stat`：`Resources/imagecard/card.html` 与 `Mac/Export/MoltenExporter.swift` **不在**本波次改动清单内）：

- **本波次引入的回归**：A1、A2、A8
- **其余全部为既有缺口**，波次未触及或只修了一半

---

## (A) 必须修

### A1. v0.5.0 无法启动：hardened runtime + ad-hoc 签名的 Sparkle 被 dyld 拒绝 【回归】
`scripts/release.sh:78`
- **用户影响**：任何下载 v0.5.0 DMG/zip 的人，双击后什么都不会发生；0.4.2 用户点了应用内更新会把能用的版本换成打不开的版本。
- **修法**：在拿到真实 Developer ID 之前，二选一 —— 去掉 `release.sh:78` 的 `--options runtime`（回到 0.4.2 能启动的行为），或在 `Vellumi.entitlements` 加 `com.apple.security.cs.disable-library-validation`（A/B 实测该 entitlement 可让 ad-hoc 框架在 hardened runtime 下加载）。随后同步修改 `release.sh:88-93` 的断言，否则那条断言正在强制执行这个 bug。
- **工作量**：小

### A2. 签名喂的是源 entitlements 模板，沙盒挡住 Sparkle 的全部 mach 服务 【回归】
`scripts/release.sh:79`
- **用户影响**：从 0.5.0 起这个版本永远无法自更新——下载能完成，安装驱动不起来（用户只能重新下 DMG）。
- **证据**：`codesign -d --entitlements - --xml` 打出的是字面量 `<string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>` / `-spki`；Xcode 处理过的 `.build/release/Build/Intermediates.noindex/Vellumi.build/Release/Vellumi.build/Vellumi.app.xcent` 里才是展开后的 `com.aaron.vellumi-spks`。codesign 不展开 Xcode 构建变量。附带确认：已发布的包连 `e4ceb88` 新加的 `-spkp` 都没有，签的是更早的模板。
- **修法**：改用 `--entitlements <…>/Vellumi.app.xcent`（用 `find "$DERIVED" -name 'Vellumi.app.xcent'` 定位，找不到就硬失败）。`release.sh:101-105` 现有断言只 grep 子串 `-spks`，字面量模板也能过，必须改成 grep `com.aaron.vellumi-spks`。
- **工作量**：小

### A3. source 模式 NSTextView 与文档 undo 栈共用，整体重灌文本后 ⌘Z 崩溃或静默错位
`Mac/Editor/MoltenWorkspaceViewController.swift:378`（新增的 `noteDocumentContentReplaced`）、`:503`（`enterSourceMode` 重新播种）、`:571`（`allowsUndo = true`，delegate 无 `undoManager(for:)`）
- **用户影响**：在 source 模式打过字、回到熔字模式做了一次缩短正文的编辑、再切回 source 按 ⌘Z —— 要么 `NSRangeException` 直接崩，要么把旧字节插进新正文中间，`textDidChange`(`:882`) → `adoptSourceText` 立刻把这份污染写进 `text` 并可保存。
- **修法**：`:378` 和 `:503` 赋 `.string` 之后立即 `textView.undoManager?.removeAllActions()`，赋值前 `textView.inputContext?.discardMarkedText()`。彻底做法是在 delegate 上实现 `undoManager(for:)` 返回一个专属 UndoManager，让 source 模式的撤销永不与文档栈混流。
- **工作量**：微（三行）；专属 UndoManager 版本小。
- 注：`:503` 在 `a0d1b13` 逐字节相同，本波只是多加了第三条重灌路径。

### A4. 图片卡：两个并发分页 pass 抢同一个 measureStage，长文档尾部整页被静默裁掉 【既有】
`Resources/imagecard/card.html:1240 / :1333 / :1359`，触发源 `Mac/Export/MoltenImageCardExportView.swift:354-358`
- **用户影响**：面板一打开就发生（零用户操作）：`didFinish` 连发 `setContent` 和 `setOptions` 两次 `evaluateJavaScript`，先跑完的 pass 在 `finally` 里 `measureStage.replaceChildren()` 把还活着的 pass 的 shell 摘掉；此后 `renderNodesToMeasure`(`:936`) 恒为 `0 <= 0+1`，剩余内容全堆到当前页，被 `.card-content{overflow:hidden}`(`:130-136`) 裁掉。实测 60 段文档：正常 8 页，走 `didFinish` 序列后 7 页，末页 `scrollHeight 2515` vs `clientHeight 1735`，约 780px 文字消失在导出的 PNG 之外。
- **修法**：每个 pass 自建容器（`document.createElement('div')` + `appendChild`，`finally` 里 `stage.remove()`），并把 `generation` 传进 `paginateRenderedHtml`，每次 `await yieldToBrowser()` 后比对 `state.renderGeneration` 提前退出。兜底：`renderNodesToMeasure` 在 `measure.body.clientHeight === 0` 时返回 `false`。
- **工作量**：小

### A5. 含 `<img>` 的表格/列表/代码块被判为不可分割，超长部分整段裁掉 【既有】
`Resources/imagecard/card.html:1202`
- **用户影响**：一张 60 行、其中一格放了图片的表格，导出成 **1 张卡**，45 行不存在于任何输出文件里，无任何提示。实测：无图 → 4 页，每页 `scrollHeight == clientHeight`；一格加图 → 1 页，`scrollHeight 6035` vs `clientHeight 1735`（~71% 被裁）。
- **修法**：把 `img` 判断挪到 `UL/OL`(`:1205`)、`TABLE`(`:1208`)、`PRE`(`:1211`) 的结构分派**之后**，只保留 `tagName === "IMG"` 和"整块只有一张图的 P"。另外补 `.card-content img { max-height: 100%; object-fit: contain; }`（全文件 `grep max-height` 目前零命中），否则 1080×4000 的长截图会被裁掉一半。
- **工作量**：小

### A6. Quick Open / 项目全文搜索没启动 security scope，重启后永远空 【既有】
`Mac/Projects/MoltenQuickOpenWindow.swift:64`、`:71`；`Mac/Projects/MoltenProjectsWindow.swift:310`
- **用户影响**：加项目当次能用，退出重开后 ⇧⌘P 一个文件都搜不到；⌥⌘2 文件树里明明还看得见——用户会判定"这功能坏了"。崩溃后重启（最需要 Quick Open 找回稿子的时刻）同样为空。
- **证据**：`MoltenProjectStore.resolveFolderURL(for:)`(`:76-88`) 只解析书签；`startAccessingSecurityScopedResource()` 只存在于**实例**方法 `markdownFiles(in project:)`(`:96-99`)，Quick Open 走的是无作用域的**静态** `markdownFiles(inFolder:)`。`ensureAccess` 救不了：项目书签存在 `Vellumi.projects.list`，不是 `MoltenFolderAccess` 的 `Vellumi.folderBookmark.<path>` 键。
- **修法**：Quick Open 与内容搜索改走实例 `markdownFiles(in:)`；或在启动/首次使用时把所有项目书签一次性通过 `MoltenFolderAccess` 式的"整进程 start + 去重"纳入作用域。
- **工作量**：小

### A7. `assetSchemeHandler.documentDirectory` 只在 `loadDocumentText` 里刷新，首次保存后 / 另存为后图片全裂
`Mac/Editor/MoltenEditorViewController.swift:140`（全仓唯一赋值点）
- **用户影响**：最高频路径 —— ⌘N → ⌘S 存到某处 → 粘贴截图：PNG 正确落盘、markdown 链接正确，但预览是裂图占位符，必须关闭再打开才恢复。另存为跨目录后同理（旧目录的图还显示，新目录的不显示，掩盖了链接已悬空）。
- **证据**：`loadDocumentText` 四个调用点（`MoltenDocument.swift:104/338/480`、`MoltenWorkspaceViewController.swift:556`）没有一个在保存路径上；保存完成回调 `MoltenDocument.swift:171-179` 只调 `noteDocumentSaved()`（即 `refreshFileTree()`）。`MoltenAssetSchemeHandler.swift:18` 的 `guard let directory` 失败就直接 `didFailWithError`。
- **修法**：给 `MoltenEditorViewController` 加 `noteDocumentURLChanged()` 重设 `documentDirectory`，在 `save(to:ofType:for:)` 完成回调里（`:173`，与 `savedText` 更新同处）调用，且必须覆盖 `.autosaveInPlaceOperation`——那正是 Drafts 版 ⌘N 创建文件的路径。
- **工作量**：微

### A8. `replaceAll` / `countMatches` 在小写串上算 ProseMirror 偏移，U+0130 导致跨节点替换 【回归】
`Editor/src/main.js:822`（`replaceAll`）、`:657-662`（`countMatches`）
- **用户影响**：文本节点里在匹配位置之前出现 `İ`（土耳其大写点 I）时，`to` 越过节点末尾，事务跨段落边界删改；两个及以上时 `tr.insertText` 抛 RangeError，被 `MoltenEditorViewController.swift:274` 的 `(try? result.get()) as? Int ?? 0` 吞成"0 处替换"。
- **证据**：全 BMP 枚举确认 `toLowerCase()` 只有 U+0130 会改变长度（→ 2 单元）。`"İstanbul"` 找 `"stanbul"`：真实偏移 1，`indexOf` 返回 2，push 出 `{from: pos+2, to: pos+9}` 对着一个 8 字符节点。
- **修法**：不要在折叠串上取下标。在**原串**上逐位置比较 `text.substr(i, term.length).toLowerCase() === needle`，长度取实际匹配切片而非 `term.length`；`countMatches` 同改，否则计数和替换会互相打架。
- **工作量**：小

### A9. 崩溃恢复文件被当成"磁盘上已保存"的基线，恢复出来的内容被静默丢弃 【既有】
`Shared/Document/MoltenDocument.swift:102-103`
- **用户影响**：崩溃后重启，未命名文档带着 500 字回来并显示 "Edited"；此时随手打一个字再删掉（或 ⌘Z/⌘⇧Z），`applyBodyText`(`:305`) 判定 `isEquivalentToSavedFile` 为真 → `.changeCleared`，⌘W 无提示关闭、不写盘、AppKit 删掉恢复文件，500 字全没。
- **证据**：写侧已经有对称的护栏并且注释点名了这个风险（`:168-171`，`saveOperation != .autosaveElsewhereOperation`），读侧没有任何对应判断——这个不对称本身是最强证据。
- **修法**：覆写 `init(for:withContentsOf:ofType:)` 记录 `isReadingAutosavedContents`（或在 `read(from url:)` 里比对 `autosavedContentsFileURL`），该情况下跳过 `:102-103` 两行赋值。补一条回归测试：读入恢复字节 → 断言 `isDocumentEdited` → 经 `editorTextDidChange` 往返一次 → 仍然 edited。
- **工作量**：中

### A10. PDF 导出与打印直接快照实时编辑面，长代码块丢行、聚焦模式导出成灰字
`Mac/Export/MoltenExporter.swift:138`、`:159`
- **用户影响**：粘一段 400 行代码围栏、不滚动进去，导出 PDF —— 代码块只剩滚动过视口的那些行，无任何提示。开着 ⌥⌘F 导出，`Editor/public/index.html:46-48` 的 `opacity: 0.3` 没有 print override，整页是鬼影；`index.html:23` 的 `padding: … 40vh` 变成末尾一屏空白。
- **证据**：`webViewForExport` 就是 `MoltenEditorViewController.swift:238` 的 `var webViewForExport: WKWebView { webView }`，实时编辑视图。HTML 导出（`:12`）和图片卡都走 `fetchContentHTML`/`getContentHTML`——本波次重写 `getContentHTML` 的理由（`main.js:694-698` 注释：CodeMirror 虚拟化行）字面适用于 PDF，但 PDF 被漏掉了。`grep '@media print'` 在 `Editor/public` 和 `Editor/src` 零命中。
- **修法**：把 `selfContainedHTML(bodyHTML: expandTOC(in: getContentHTML()))` 渲染到离屏 WKWebView 再 `createPDF`/`printOperation`（图片卡导出已有这套模式）。最低成本：给 `index.html` 加 `@media print` 块，重置聚焦模式透明度、去掉 `40vh`、隐藏 `.milkdown-block-handle` / `milkdown-toolbar`。
- **工作量**：中（离屏方案）/ 小（仅 print 样式）

---

## (B) 值得做

| # | 问题 | 位置 | 为什么用户在意 | 修法 | 工作量 |
|---|---|---|---|---|---|
| B1 | 渲染进程在导出之外死掉时 `isRendering` 永远卡在 true | `MoltenImageCardExportView.swift:251` | 面板永远转圈、Export 永远灰（`:169`）、无任何错误提示，只能 Cancel | `webViewWebContentProcessDidTerminate`(`:259`) 自己复位 UI，`!pending.isEmpty` 只保留给结算 completion 的那半 | 微 |
| B2 | ZIP 用 UTF-8 文件名却不置语言编码位 | `MoltenImageCardTypes.swift:235`、`:250` | 中文文档名导出 zip，在 Windows/Python 解出乱码；文件夹模式却是对的，两种输出自相矛盾 | 两处 `appendUInt16(0)` 改 `appendUInt16(0x0800)`；顺手把 `:230`/`:273-274` 的 trapping 转换改成 `UInt16(exactly:)` + throw | 微 |
| B3 | `expandTOC` 把生成的 nav 当成正则模板 | `MoltenExporter.swift:84` | 标题里的 `$5`、`\` 在导出的目录里被静默吞掉（正文标题正常） | `NSRegularExpression.escapedTemplate(for: nav)`，或改用 `range(of:options:.regularExpression)` + `replaceSubrange` | 微 |
| B4 | `expandTOC` 重复 HTML 转义 | `MoltenExporter.swift:76` | `# Q&A` 的目录项显示成字面量 `Q&amp;A` | 直接用已是合法 HTML 的 `inner`（去标签）作链接文本，不再二次转义 | 微 |
| B5 | 首次运行标志先于展示判断被消费 | `MoltenAppDelegate.swift:48` | 全新安装用 Finder 双击 .md 启动（DMG 用户最可能的首次动作），欢迎文档永远不会出现 | 把 `set(true, forKey:)` 移到 `:50` 的 `documents.isEmpty` guard 之后 | 微 |
| B6 | `.txt` 到处列出但打不开 | `MoltenProjectStore.swift:9` vs `Mac/App/Info.plist` / `MoltenDocument.swift:38` | 项目面板/Quick Open/文件树里点一个 `.txt` 弹"无法打开纯文本格式"，像 app 坏了 | 二选一：`CFBundleDocumentTypes` + `readableTypes` 加 `public.plain-text`（更好，`decodeText` 已能处理），或从 `supportedExtensions` 去掉 `"txt"` | 微 |
| B7 | Check for Updates 检查中不置灰 | `MoltenAppDelegate.swift:101` | 重复点击被 Sparkle 静默吞掉并打日志，而非菜单变灰 | `validateMenuItem` 里对 `checkForUpdates(_:)` 返回 `updaterController.updater.canCheckForUpdates` | 微 |
| B8 | release 断言只验签名不验能跑 | `scripts/release.sh:81` | 正是这套闸门放过了 A1 和 A2；`--verify --deep --strict` 对一个 SIGABRT 的二进制返回 0 | 打包前加冒烟启动（后台跑 3 秒、退出即失败并打印 stderr）+ grep 展开后的 bundle id | 小 |
| B9 | 导出期间外观选项仍可改，`captureAll` 无 generation 守卫 | `MoltenImageCardExportView.swift:288`；`card.html:1455` | 同一个导出文件夹里出现两种像素尺寸，接缝处段落重复，尾部空白卡 | Swift：`export()` 开头 `pendingOptionsWork?.cancel()`，外观控件加 `.disabled(model.isRendering \|\| model.isExporting)`；JS：`captureAll` 起始快照 `state.pages`/`state.options` 并记 `renderGeneration` | 小 |
| B10 | Quick Open / 全文搜索不进子目录 | `MoltenProjectStore.swift:109` | README:34/42 承诺"跨项目搜索"；`notes/idea.md` 在 ⌥⌘2 里看得见，⇧⌘P 却说不存在 | 给 `markdownFiles(inFolder:)` 做递归变体，复用 `MoltenFileTree` 的 maxDepth/maxNodes 预算；`MoltenFuzzyMatch` 改为对项目相对路径打分 | 小 |
| B11 | 查找替换没有大小写开关，Replace All 现在恒不区分 | `main.js:816`、`:849`、`:644`；`MoltenWorkspaceViewController.swift:740` | 搜 `US` 会连正文里的 `us` 一起替换；`iPhone` 类大小写修正无法完成 | 加 "Aa" 复选框，把 `caseSensitive` 穿过 `find`/`countMatches`/`replaceNext`/`replaceAll` 四个桥接方法 | 小 |
| B12 | 计数/替换不跨 mark，导航却跨 | `main.js:655`、`:817`（`if (!node.isText) return`）vs `:644`（`window.find`） | `the **quick** fox` 搜 `quick fox`：标签红字 "0 matches"、Replace All 蜂鸣，回车却能选中它——正好推翻本波"让 find/count/replace 一致"的目标 | 用 `node.textBetween(0, node.content.size, "\n", "￼")` 把块级文本摊平后再搜，同时保留位置映射 | 中 |
| B13 | 测试跑的 JS bundle 从不由测试构建 | `project.yml:22`（无 `preBuildScripts`，`grep shellScript project.pbxproj` 零命中） | 改了 `Editor/src/main.js` 不重建就跑测试，23 个 WKWebView 测试对着旧产物全绿 | 加 pre-build run-script 跑 `scripts/build-editor.sh`（inputs `Editor/src/**`，output `Resources/dist/editor.js`）；再让 `build.mjs` 打一个源码 hash 戳，用一条 Swift 测试断言它匹配 | 小 |
| B14 | 没有任何测试注册桥接消息处理器 | `MoltenEditorViewController.swift:391`；`Tests/MoltenEditorBridgeTests.swift:22-25` 用裸 `WKWebView` | 把 `main.js:487` 的 `"normalized"` 改名，87 个测试照样全绿——本波旗舰修复会静默蒸发，autosave-in-place 重新开始改写用户只是打开过的文件 | 一个集成测试类：真 `WKUserContentController.add(handler, name:"molten")`，断言 `ready` 先到、`setMarkdown("* a\n")` 产生恰好一条带 `markdown == "- a\n"` 的 `normalized`、change 去抖在上限内送达、`setMarkdown` 期间挂起的旧 timer 不会投递旧内容 | 中 |
| B15 | 保存/关闭路径（曾发过硬挂起的那条）零覆盖 | `MoltenDocument.swift:215`、`:229` | `:147-156` 的 DEADLOCK RULE 只靠注释守着；所有文档测试都用 `editorViewController == nil` 的裸文档，`:233` 的 guard 永远短路，`:245` 的 `.changeDone` 从未被触达 | 一条带真实 window controller 的集成测试：canClose 回调 5s 内触发、`save(to:)` 后盘上字节含刚输入的文本 | 中 |
| B16 | 桥接测试靠固定 sleep，若干测试不断言任何东西 | `Tests/MoltenEditorBridgeTests.swift:422`（`RunLoop.main.run(until: +2)`）、`:306/:327/:390`；`:93`、`:211`、`:251-252` | 旗舰导出测试的全部前置只有 2 秒睡眠；机器一忙就无关失败。类无 `tearDown`，21 个 webView 全程驻留 | 用已有的 `waitUntil` 换掉固定睡眠；加 `tearDown` 置空 webView；`waitUntil` 的 poll 改 `try?`；给空断言测试补真实断言 | 中 |
| B17 | 分页拆块走 `textContent`，内联标记/链接/行内数学全丢 | `card.html:988`、`:891`、`:908` | 一段超过整张卡的 3000 字中文长段（含 `**重点**` 和链接）导出后全部变成无格式纯文本，**包括第一张卡**；同样内容短一点就正常 | 改成节点级拆分：遍历 `childNodes`，只在单个子节点本身过高时才下沉到文本节点，逐段克隆外层元素链 | 大 |
| B18 | 每次放弃的 ⌘N 都在 Drafts 里留一个 0 字节文件 | `MoltenDocumentController.swift:24`（清理只在 open **失败**分支 `:34-36`） | ⌘N 后改主意 ⌘W，文件永久留下；`New Note.md` / `New Note 2.md` … 无限累积并进入 Quick Open/文件树语料 | 记录本次创建的 draft URL，在文档关闭且从未编辑、文件仍为 0 字节时删除（复用 `:34` 的 `data.isEmpty` 判断）；或把建文件推迟到首次 `.changeDone` | 小 |
| B19 | `enterSourceMode` 在异步回调里才置 `isSourceMode` | `MoltenWorkspaceViewController.swift:486-487` vs guard `:475` | 长按 ⌘/ 会重复走进入路径，模式停在最后一个回调而非按键次数决定的位置，first responder 被反复抢回 | 加 `isEnteringSourceMode` 同步标志，扩展 `:475` 的 guard，并让 `toggleSourceMode` 把"进入中"当作"已在 source" | 小 |
| B20 | 字数统计重写悄悄改了 CJK 字符数 | `MoltenWorkspaceViewController.swift:233-244` | 新 switch 只排除 `" \t\r\u{0B}\u{0C}\u{A0}`，旧代码排除整个 `whitespacesAndNewlines`；U+3000 全角缩进（中文正文标配）现在每段多算一个字符 | 把这段循环抽成 `MoltenWordCount.statistics(_:) -> (words, characters, paragraphs)`，补 U+3000/U+2003、`"a\n\nb"`、CRLF、空串等用例 | 小 |
| B21 | `selfContainedHTML` 内联 editor.css 时带进 60 个相对路径 KaTeX 字体 | `MoltenExporter.swift:95`、`:117-120` | 含数学公式的导出 HTML 全部 404 到 `<保存目录>/assets/KaTeX_*.woff2`（而 `assets` 恰好是默认图片目录名），公式退化成 fallback 字体 | 把 `url("./assets/X")` 重写成 base64 data URI（仅 woff2 约 1 MB），或在正文不含 `.katex` 时剥掉 `@font-face` 块 | 中 |

---

## (C) 可选

- **C1** Sparkle 嵌套组件丢 hardened runtime 标志（`release.sh:67`、`:70`）——公证是明确的 out of scope，XPC 助手是独立进程不受 library validation 约束，今天不影响运行。等 A1 的 runtime 策略定下来后一起处理。
- **C2** `MoltenDraftsStore.resolveFolderURL` 每次调用泄漏一个 sandbox extension（`MoltenDraftsStore.swift:49`）——API 卫生问题，三行可修（缓存已解析 URL），但触发需要单进程内几千次 ⌘N。
- **C3** `canClose` 的 `refreshTextFromEditor` 无超时（`MoltenDocument.swift:220`、`:229`）——真实缺失的健壮性护栏，但没有可复现的挂起场景；`docs/PERF.md:23` 实测 431 KB 是 102.6 ms。要做就是加 1.5 秒 watchdog + `resumed` 一次性标志。
- **C4** Gatekeeper 首次运行文案过时（`release.sh:9` 写着 `/Applications/Molten.app`、`:177` 推荐 macOS 15 已移除的"右键 → 打开"）；README 无首次启动章节，且特性列表仍写"20 MB 上限"（本波已降到 4 MB）。纯文档，顺手改。
- **C5** 行内数学导出为渲染公式、显示公式（`$$…$$`）导出为 LaTeX 代码块（`main.js:708`）——Crepe 把 math block 转成了 `code_block`，源码完整保留可往返，是保真度差距而非损坏；修法本质是加功能（在代码块循环里特判 `language === "latex"`，读 `.preview-panel .preview` 或用已打包的 `katex.renderToString`）。
- **C6** 无 Help 菜单、Welcome 文档不可重开（`MoltenAppDelegate.swift:41`、`:135-146`）——`NSApp.helpMenu` 从未赋值；任务列表/表格/代码块/数学只存在于 `/` 斜杠菜单，Format 菜单无入口。
- **C7** 两条测试补强：组件挂载断言只覆盖代码块（`Tests/MoltenEditorBridgeTests.swift:430` 的表格断言用裸 gfm toDOM 就能过；`:151-152` 的图片断言在 `proxyDomURL` 失效时**更容易**通过）；图片路径三段编解码链（`MoltenDocument.swift:348-353` → `main.js:409` → `MoltenAssetSchemeHandler.swift:47`）无端到端测试，`imageFolderName` 的消毒分支（`"a/b"`、`".."`、`""`）零覆盖——这条是安全相关路径。

---

## 明确不值得做

- **`captureAll` 改流式**（`card.html:1455`）：`capturePage` 是真的死代码（Swift 侧 switch 无 `case "page"`），但整条 finding 没有复现、没有实测峰值内存，200 张卡是社交卡片功能的极端假设。等真有用户报导出 OOM 再说，先做 B1（卡死复位）就够。
- **A3 之外再动 `enterSourceMode` 的时序**：把 `isSourceMode` 提前到 `:475` 同步翻转会让 pull 自己的 `editorTextDidChange`(`:484`) 撞上 `MoltenDocument.swift:300` 的新 guard 被丢弃——那正是本波已经踩过一次的坑。用 B19 的额外标志，别动主标志。
- **`splitTextElement` 的节点级重写（B17）先别排期**：验证过程中推翻了它的第二个例子（blockquote 包 pre 并不会被摊平，而是走 `:1033` 的 fallback 被裁——那是 A5 的失败模式）。真实爆炸半径只有"单块超过整张卡"，等 A4/A5 修完再看是否还值得付这个大工作量。
- **JS bundle 拆分、窗口 frame autosave 共享、Quick Open 模糊匹配优化**：按 brief 属于既定取舍，无人提出，也没人应该提。
- **公证 / 真实 Team ID 签名**：无 Apple 开发者账号，超出范围；A1/A2 的修法都不依赖它。

---

## 立即应该发的补丁版本

**是的，必须马上发 v0.5.1，而且这是全部工作里唯一有时间压力的部分。**

已发布的 v0.5.0 资产是死的：`dist/Vellumi-0.5.0.app.zip` 解出的 app 在 dyld 阶段就 abort（实测），且它的签名 entitlements 里是字面量 `$(PRODUCT_BUNDLE_IDENTIFIER)-spks/-spki`。0.4.2 用户一旦点更新，会把能用的版本换成打不开的。

v0.5.1 的最小内容：
1. **A1** —— 让它能启动（去掉 `--options runtime`，或加 `disable-library-validation`）
2. **A2** —— 改签 `.xcent`，让更新链在 0.5.1 之后还活着
3. **B8** —— 加冒烟启动断言，否则同类问题一定会再发一次
4. **A3**（三行）和 **A7**（一行）如果当天能测完，一并带上

发布前先做：**从 GitHub Releases 撤下或替换 v0.5.0 的 zip/DMG，并把 `appcast.xml` 里的 0.5.0 条目摘掉**——在 0.5.1 就绪之前，让 0.4.2 用户检查更新时什么都拿不到，好过拿到打不开的东西。

其余 A 项（A4/A5 图片卡截断、A6 Quick Open、A8 replaceAll、A9 崩溃恢复、A10 PDF）走 v0.5.2，不要为了赶 0.5.1 塞进去 —— 0.5.1 越小，越不可能再翻车。

## 需要 owner 拍板的

1. **hardened runtime 的去留**：现在就退回不带 runtime（0.4.2 已验证可启动，路径最短），还是保留 runtime + `disable-library-validation`（为将来公证留位，但那个 entitlement 本身在公证审查时是要解释的）？这决定了 A1 的具体改法，也连带决定 C1 做不做。
2. **v0.5.0 已发布资产怎么处理**：直接删除，还是保留 tag 但把 appcast 条目摘掉？如果已经有人下载，是否需要在 README/Release notes 里写一句说明。
3. **`.txt` 到底支不支持（B6）**：加 `public.plain-text` 让列表变诚实，还是从 `supportedExtensions` 里删掉 `txt`。前者更符合"Markdown 编辑器"的用户预期，但会引入一类没有 front matter、可能带 CRLF 的输入。
4. **导出保真度的目标线（A10 / B21 / C5）**：PDF 是走"离屏渲染清洗后 HTML"（和 HTML/图片卡统一，成本中等，一次解决三个问题），还是只加 `@media print` 打补丁（成本小，代码块虚拟化丢行仍在）。
5. **Typora 式规范化的不动点是否需要保证**：`editorDidNormalize` 把规范化结果当作干净基线（`MoltenDocument.swift:324`）只有在规范化幂等时才安全，目前无任何测试验证这一点。要不要把幂等性测试（`setMarkdown(x); y=getMarkdown(); setMarkdown(y); assert getMarkdown()==y`，覆盖嵌套列表/表格/脚注/mermaid/任务列表）列为发布闸门。

## 关于被推翻的三条

三条 REFUTED 的驳回我都认同，尤其 `pendingImageSaves` 那条 —— `MoltenEditorViewController.swift:413-427` 确实在所有分支上都用 `path ?? NSNull()` 回了 `resolveImageSave`，"永久泄漏 promise"不成立。没有需要翻案的。