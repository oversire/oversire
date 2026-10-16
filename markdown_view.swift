import Cocoa
import WebKit

// Markdown with markdown-it and highlight.js from the app bundle. No network.
// Rendered mode shows the document. Code mode shows the Markdown source, highlighted.
final class MarkdownView: NSView, WKNavigationDelegate {
    enum Mode: Int { case rendered, code }

    var onHeight: ((CGFloat) -> Void)?
    private(set) var contentHeight: CGFloat = 0
    private(set) var text = ""
    private(set) var mode = Mode.rendered
    private let web: WheelPassingWebView
    private var ready = false

    init(width: CGFloat) {
        let cfg = WKWebViewConfiguration()
        let relay = HeightRelay()
        cfg.userContentController.add(relay, name: "height")
        web = WheelPassingWebView(frame: NSRect(x: 0, y: 0, width: width, height: 20), configuration: cfg)
        super.init(frame: web.frame)
        relay.view = self
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        addSubview(web)
        web.loadHTMLString(MarkdownView.page, baseURL: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, mode: Mode) {
        guard text != self.text || mode != self.mode else { return }
        if text != self.text { contentHeight = 0 }
        self.text = text
        self.mode = mode
        if ready { render() }
    }

    private func render() {
        guard let json = try? JSONSerialization.data(withJSONObject: [text]),
              let arg = String(data: json, encoding: .utf8) else { return }
        web.evaluateJavaScript("render(\(arg)[0], \(mode.rawValue))")
    }

    fileprivate func reported(_ h: CGFloat) {
        let h = ceil(h)
        guard abs(h - contentHeight) > 1 else { return }
        contentHeight = h
        onHeight?(h)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        render()
    }

    // Links open in the browser. The view itself never navigates.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // The scripts and styles load once, from Contents/Resources/markdown.
    private static let page: String = {
        func asset(_ name: String) -> String {
            let dir = Bundle.main.resourceURL?.appendingPathComponent("markdown")
            return dir.flatMap { try? String(contentsOf: $0.appendingPathComponent(name), encoding: .utf8) } ?? ""
        }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>\(asset("github.min.css"))</style>
        <style>@media (prefers-color-scheme: dark) { \(asset("github-dark.min.css")) }</style>
        <style>
        :root { color-scheme: light dark; }
        html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
        body { font: 12.5px/1.5 -apple-system, system-ui, sans-serif; color: #1f2328; -webkit-user-select: text; }
        @media (prefers-color-scheme: dark) { body { color: #e6edf3; } a { color: #58a6ff; } }
        #root > :first-child { margin-top: 0; }
        #root > :last-child { margin-bottom: 0; }
        h1, h2, h3, h4 { margin: 14px 0 6px; line-height: 1.25; }
        h1 { font-size: 17px; } h2 { font-size: 15px; } h3 { font-size: 13.5px; } h4 { font-size: 12.5px; }
        p, ul, ol, blockquote, table, pre { margin: 0 0 8px; }
        ul, ol { padding-left: 20px; }
        li.task-list-item { list-style: none; margin-left: -18px; }
        li.task-list-item input { margin: 0 6px 0 0; vertical-align: -1px; }
        a { color: #0969da; text-decoration: none; }
        code { font: 11.5px ui-monospace, SFMono-Regular, Menlo, monospace; background: rgba(127,127,127,.15);
               padding: 1px 4px; border-radius: 4px; }
        pre { padding: 8px 10px; border-radius: 6px; overflow-x: auto; background: rgba(127,127,127,.1); }
        pre code, pre.hljs code { background: none; padding: 0; }
        pre.hljs { background: rgba(127,127,127,.1); }
        pre.src { white-space: pre-wrap; word-break: break-word; }
        blockquote { padding: 0 10px; border-left: 3px solid rgba(127,127,127,.4); opacity: .85; }
        table { border-collapse: collapse; display: block; overflow-x: auto; max-width: 100%; }
        th, td { border: 1px solid rgba(127,127,127,.3); padding: 3px 8px; vertical-align: top; }
        th { background: rgba(127,127,127,.08); text-align: left; }
        td.short, th.short { white-space: nowrap; }
        hr { border: 0; border-top: 1px solid rgba(127,127,127,.3); }
        img { max-width: 100%; }
        </style>
        <script>\(asset("highlight.min.js"))</script>
        <script>\(asset("markdown-it.min.js"))</script>
        <script>\(asset("markdown-it-task-lists.min.js"))</script>
        </head><body><div id="root"></div>
        <script>
        function block(html) { return '<pre class="hljs"><code>' + html + '</code></pre>'; }
        const md = window.markdownit({ html: false, linkify: true, breaks: false,
          highlight: function (src, lang) {
            try {
              if (lang && hljs.getLanguage(lang)) return block(hljs.highlight(src, { language: lang, ignoreIllegals: true }).value);
              return block(hljs.highlightAuto(src).value);
            } catch (e) { return ''; }
          } });
        if (window.markdownitTaskLists) md.use(window.markdownitTaskLists);
        const root = document.getElementById('root');
        function report() { window.webkit.messageHandlers.height.postMessage(root.getBoundingClientRect().height); }
        function render(src, mode) {
          if (mode === 1) {
            root.innerHTML = '<pre class="hljs src"><code>' + hljs.highlight(src, { language: 'markdown' }).value + '</code></pre>';
          } else {
            root.innerHTML = md.render(src);
            // Short cells, for example keys like TREBI-297, do not wrap.
            root.querySelectorAll('td, th').forEach(c => { if (c.textContent.trim().length <= 14) c.classList.add('short'); });
          }
          report();
        }
        new ResizeObserver(report).observe(root);
        </script></body></html>
        """
    }()
}

// The page fits its content, so vertical wheel events go to the scroll view around it.
private final class WheelPassingWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) { nextResponder?.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
}

// The content controller keeps its handlers. A weak link avoids a cycle with the view.
private final class HeightRelay: NSObject, WKScriptMessageHandler {
    weak var view: MarkdownView?
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if let h = message.body as? Double { view?.reported(CGFloat(h)) }
    }
}
