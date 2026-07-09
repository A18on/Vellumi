import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ImageCardExportView: View {
    @StateObject private var model: MarkdownImageCardExportModel
    private let onClose: () -> Void

    init(request: MarkdownImageCardExportRequest, onClose: @escaping () -> Void) {
        _model = StateObject(
            wrappedValue: MarkdownImageCardExportModel(
                request: request,
                onExportCompleted: onClose
            )
        )
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 0) {
            controls
                .frame(width: 292)
                .padding(20)

            Divider()

            VStack(spacing: 12) {
                MarkdownImageCardWebView(model: model)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )

                HStack {
                    Button {
                        model.showPreviousPage()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help(L10n.string("export.image.previousPage"))
                    .disabled(model.currentPage == 0 || model.isRendering)

                    Text(
                        String(
                            format: L10n.string("export.image.pageIndicator"),
                            model.currentPage + 1,
                            model.pageCount
                        )
                    )
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                    Button {
                        model.showNextPage()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .help(L10n.string("export.image.nextPage"))
                    .disabled(model.currentPage >= model.pageCount - 1 || model.isRendering)
                }
                .buttonStyle(.bordered)
            }
            .padding(20)
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 920, height: 640)
        .onChange(of: model.theme) { _ in model.optionsDidChange() }
        .onChange(of: model.sizePreset) { _ in model.optionsDidChange() }
        .onChange(of: model.format) { _ in model.optionsDidChange() }
        .onChange(of: model.paragraphIndent) { _ in model.optionsDidChange() }
        .onChange(of: model.watermark) { _ in model.optionsDidChange() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("export.image.title"))
                    .font(.title3.weight(.semibold))
                Text(L10n.string("export.image.subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox(L10n.string("export.image.section.appearance")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L10n.string("export.image.theme"), selection: $model.theme) {
                        ForEach(MarkdownImageCardTheme.allCases) { theme in
                            Text(L10n.string(theme.titleKey)).tag(theme)
                        }
                    }

                    Picker(L10n.string("export.image.size"), selection: $model.sizePreset) {
                        ForEach(MarkdownImageCardSizePreset.allCases) { preset in
                            Text(L10n.string(preset.titleKey)).tag(preset)
                        }
                    }

                    Picker(L10n.string("export.image.format"), selection: $model.format) {
                        ForEach(MarkdownImageCardFormat.allCases) { format in
                            Text(L10n.string(format.titleKey)).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker(L10n.string("export.image.paragraphIndent"), selection: $model.paragraphIndent) {
                        ForEach(MarkdownImageCardParagraphIndent.allCases) { indent in
                            Text(L10n.string(indent.titleKey)).tag(indent)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.top, 4)
            }

            GroupBox(L10n.string("export.image.section.watermark")) {
                TextField(L10n.string("export.image.watermark.placeholder"), text: $model.watermark)
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 4)
            }

            GroupBox(L10n.string("export.image.section.output")) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(L10n.string("export.image.output"), selection: $model.outputMode) {
                        ForEach(MarkdownImageCardOutputMode.allCases) { mode in
                            Text(L10n.string(mode.titleKey)).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .disabled(model.pageCount <= 1)

                    Text(model.pageCount <= 1 ? L10n.string("export.image.output.singleHint") : L10n.string("export.image.output.multiHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }

            if model.isRendering || model.isExporting {
                ProgressView(model.statusText)
                    .controlSize(.small)
            } else if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.statusText.isEmpty {
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack {
                Button(L10n.string("common.cancel")) {
                    model.finish()
                    onClose()
                }
                Spacer()
                Button(L10n.string("export.image.export")) {
                    model.export()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRendering || model.isExporting || !model.isRendererReady)
            }
        }
    }
}

@MainActor
final class MarkdownImageCardExportModel: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Published var theme: MarkdownImageCardTheme = .aurora
    @Published var sizePreset: MarkdownImageCardSizePreset = .story
    @Published var format: MarkdownImageCardFormat = .png
    @Published var paragraphIndent: MarkdownImageCardParagraphIndent = .twoCharacters
    @Published var watermark: String = ""
    @Published var outputMode: MarkdownImageCardOutputMode = .folder
    @Published private(set) var pageCount = 1
    @Published private(set) var currentPage = 0
    @Published private(set) var isRendering = true
    @Published private(set) var isExporting = false
    @Published private(set) var isRendererReady = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusText = L10n.string("export.image.status.loading")

    private let request: MarkdownImageCardExportRequest
    private let onExportCompleted: () -> Void
    private let assetSchemeHandler = MoltenAssetSchemeHandler()
    private var pendingCaptures: [String: (Result<[MarkdownImageCardRenderedPage], Error>) -> Void] = [:]
    private weak var webView: WKWebView?

    init(request: MarkdownImageCardExportRequest, onExportCompleted: @escaping () -> Void) {
        self.request = request
        self.onExportCompleted = onExportCompleted
        assetSchemeHandler.documentDirectory = request.documentURL?.deletingLastPathComponent()
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(self, name: "markmacCard")
        configuration.setURLSchemeHandler(
            assetSchemeHandler,
            forURLScheme: MoltenAssetSchemeHandler.scheme
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView

        guard let rendererURL = Bundle.main.url(
            forResource: "card",
            withExtension: "html",
            subdirectory: "imagecard"
        ),
              let resourceURL = Bundle.main.resourceURL else {
            errorMessage = MarkdownImageCardExportError.missingRendererResource.localizedDescription
            isRendering = false
            return webView
        }

        webView.loadFileURL(rendererURL, allowingReadAccessTo: resourceURL)
        return webView
    }

    func finish() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "markmacCard")
        webView?.navigationDelegate = nil
        webView = nil
        pendingCaptures.removeAll()
    }

    func optionsDidChange() {
        applyOptions(preservePage: true)
    }

    func showPreviousPage() {
        showPage(max(currentPage - 1, 0))
    }

    func showNextPage() {
        showPage(min(currentPage + 1, pageCount - 1))
    }

    func export() {
        guard !isRendering, !isExporting else {
            return
        }

        let targetWindow = webView?.window
        if pageCount <= 1 {
            chooseSingleOutputURL(window: targetWindow) { [weak self] url in
                self?.captureAndWrite(to: url, outputMode: nil)
            }
            return
        }

        switch outputMode {
        case .folder:
            chooseOutputFolder(window: targetWindow) { [weak self] folderURL in
                self?.captureAndWrite(to: folderURL, outputMode: .folder)
            }
        case .zip:
            chooseZipOutputURL(window: targetWindow) { [weak self] url in
                self?.captureAndWrite(to: url, outputMode: .zip)
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let type = payload["type"] as? String else {
            errorMessage = MarkdownImageCardExportError.invalidBridgePayload.localizedDescription
            return
        }

        switch type {
        case "ready":
            break
        case "rendered":
            pageCount = max(Self.intValue(payload["pageCount"]) ?? 1, 1)
            currentPage = min(max(Self.intValue(payload["currentPage"]) ?? 0, 0), pageCount - 1)
            isRendering = false
            isRendererReady = true
            errorMessage = nil
            statusText = String(format: L10n.string("export.image.status.rendered"), pageCount)
            if pageCount <= 1 {
                outputMode = .folder
            }
        case "pageShown":
            pageCount = max(Self.intValue(payload["pageCount"]) ?? pageCount, 1)
            currentPage = min(max(Self.intValue(payload["currentPage"]) ?? currentPage, 0), pageCount - 1)
        case "captureAll":
            completeCapture(payload: payload)
        case "error":
            let requestID = payload["requestID"] as? String
            let message = payload["message"] as? String ?? MarkdownImageCardExportError.invalidBridgePayload.localizedDescription
            if let requestID, let completion = pendingCaptures.removeValue(forKey: requestID) {
                completion(.failure(NSError.markdownImageCard(message)))
            } else {
                errorMessage = message
            }
            isRendering = false
            isExporting = false
            statusText = ""
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isRendererReady = true
        injectContent()
        applyOptions(preservePage: false)
    }

    private func injectContent() {
        let javaScript = "window.markmacCard.setContent(\(request.bodyHTML.javaScriptStringLiteral));"
        webView?.evaluateJavaScript(javaScript) { [weak self] _, error in
            if let error {
                DispatchQueue.main.async {
                    self?.errorMessage = error.localizedDescription
                    self?.isRendering = false
                }
            }
        }
    }

    private func applyOptions(preservePage: Bool) {
        guard isRendererReady else {
            return
        }

        isRendering = true
        errorMessage = nil
        statusText = L10n.string("export.image.status.rendering")

        let size = sizePreset.pixelSize
        let payload: [String: Any] = [
            "theme": theme.rawValue,
            "size": [
                "width": size.width,
                "height": size.height
            ],
            "watermark": watermark,
            "format": format.rawValue,
            "paragraphIndent": paragraphIndent.cssValue,
            "preservePage": preservePage
        ]

        guard let json = Self.jsonLiteral(payload) else {
            errorMessage = MarkdownImageCardExportError.invalidBridgePayload.localizedDescription
            isRendering = false
            return
        }

        webView?.evaluateJavaScript("window.markmacCard.setOptions(\(json));") { [weak self] _, error in
            if let error {
                DispatchQueue.main.async {
                    self?.errorMessage = error.localizedDescription
                    self?.isRendering = false
                }
            }
        }
    }

    private func showPage(_ index: Int) {
        currentPage = index
        webView?.evaluateJavaScript("window.markmacCard.showPage(\(index));")
    }

    private func captureAndWrite(to url: URL, outputMode: MarkdownImageCardOutputMode?) {
        isExporting = true
        errorMessage = nil
        statusText = L10n.string("export.image.status.capturing")

        captureAllPages { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let pages):
                do {
                    try self.write(pages: pages, to: url, outputMode: outputMode)
                    self.statusText = String(format: L10n.string("export.image.status.exported"), pages.count)
                    self.errorMessage = nil
                    self.finish()
                    self.onExportCompleted()
                } catch {
                    self.errorMessage = error.localizedDescription
                    self.statusText = ""
                    self.isExporting = false
                }
            case .failure(let error):
                self.errorMessage = error.localizedDescription
                self.statusText = ""
                self.isExporting = false
            }
        }
    }

    private func captureAllPages(completion: @escaping (Result<[MarkdownImageCardRenderedPage], Error>) -> Void) {
        guard isRendererReady else {
            completion(.failure(MarkdownImageCardExportError.missingRendererResource))
            return
        }

        let requestID = UUID().uuidString
        pendingCaptures[requestID] = completion
        let javaScript = "window.markmacCard.captureAll(\(requestID.javaScriptStringLiteral));"
        webView?.evaluateJavaScript(javaScript) { [weak self] _, error in
            if let error {
                DispatchQueue.main.async {
                    guard let completion = self?.pendingCaptures.removeValue(forKey: requestID) else {
                        return
                    }
                    completion(.failure(error))
                }
            }
        }
    }

    private func completeCapture(payload: [String: Any]) {
        guard let requestID = payload["requestID"] as? String,
              let completion = pendingCaptures.removeValue(forKey: requestID),
              let pagePayloads = payload["pages"] as? [[String: Any]] else {
            errorMessage = MarkdownImageCardExportError.invalidBridgePayload.localizedDescription
            isExporting = false
            return
        }

        do {
            let pages = try pagePayloads.map { pagePayload -> MarkdownImageCardRenderedPage in
                guard let dataURL = pagePayload["dataURL"] as? String else {
                    throw MarkdownImageCardExportError.invalidBridgePayload
                }
                let index = Self.intValue(pagePayload["index"]) ?? 0
                return MarkdownImageCardRenderedPage(
                    index: index,
                    data: try MarkdownImageCardDataURL.decode(dataURL)
                )
            }
            .sorted { $0.index < $1.index }

            completion(.success(pages))
        } catch {
            completion(.failure(error))
        }
    }

    private func write(
        pages: [MarkdownImageCardRenderedPage],
        to url: URL,
        outputMode: MarkdownImageCardOutputMode?
    ) throws {
        let sortedPages = pages.sorted { $0.index < $1.index }
        switch outputMode {
        case nil:
            try sortedPages.first?.data.write(to: url, options: .atomic)
        case .folder:
            for page in sortedPages {
                let fileName = MarkdownImageCardFilenames.pageFileName(
                    baseName: request.defaultBaseName,
                    pageIndex: page.index,
                    pageCount: sortedPages.count,
                    format: format
                )
                try page.data.write(to: url.appendingPathComponent(fileName), options: .atomic)
            }
        case .zip:
            let files = sortedPages.map { page in
                MarkdownImageCardZipWriter.File(
                    path: MarkdownImageCardFilenames.pageFileName(
                        baseName: request.defaultBaseName,
                        pageIndex: page.index,
                        pageCount: sortedPages.count,
                        format: format
                    ),
                    data: page.data
                )
            }
            let archive = try MarkdownImageCardZipWriter().archive(files: files)
            try archive.write(to: url, options: .atomic)
        }
    }

    private func chooseSingleOutputURL(window: NSWindow?, completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = MarkdownImageCardFilenames.singleFileName(
            baseName: request.defaultBaseName,
            format: format
        )
        presentSavePanel(panel, window: window, completion: completion)
    }

    private func chooseZipOutputURL(window: NSWindow?, completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = MarkdownImageCardFilenames.zipFileName(baseName: request.defaultBaseName)
        presentSavePanel(panel, window: window, completion: completion)
    }

    private func chooseOutputFolder(window: NSWindow?, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.string("export.image.folder.message")

        if let window {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                completion(url)
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }

    private func presentSavePanel(_ panel: NSSavePanel, window: NSWindow?, completion: @escaping (URL) -> Void) {
        if let window {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                completion(url)
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private static func jsonLiteral(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private struct MarkdownImageCardWebView: NSViewRepresentable {
    @ObservedObject var model: MarkdownImageCardExportModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        model.makeWebView()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.model.finish()
    }

    final class Coordinator {
        let model: MarkdownImageCardExportModel

        init(model: MarkdownImageCardExportModel) {
            self.model = model
        }
    }
}

private extension NSError {
    static func markdownImageCard(_ message: String) -> NSError {
        NSError(
            domain: "com.aaron.molten.imagecard",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
