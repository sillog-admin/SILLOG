import WebKit
import SillogCore

/// Translates the bundled web views (graph, calendar) in place: text nodes, a few attributes and canvas text
/// are looked up in the same table as `tr()`, so the JS keeps its Korean source strings.
enum WebL10n {
    static func install(on controller: WKUserContentController) {
        let table = L10n.current == .en ? L10n.english : [:]
        guard let data = try? JSONSerialization.data(withJSONObject: table),
              let json = String(data: data, encoding: .utf8) else { return }
        let source = "window.SILLOG_LANG = '\(L10n.current.rawValue)'; window.__SL_EN = \(json);\n" + script
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    private static let script = #"""
    (() => {
      const exact = new Map(), patterns = [];
      for (const [k, v] of Object.entries(window.__SL_EN || {})) {
        if (!k.includes('%@')) { exact.set(k, v); continue; }
        const parts = k.split('%@').map(p => p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
        patterns.push([new RegExp('^' + parts.join('(.+?)') + '$', 's'), v, k.length]);
      }
      if (!exact.size && !patterns.length) return;
      patterns.sort((a, b) => b[2] - a[2]);
      const fill = (f, args) => { let i = 0; return f.replace(/%(\d+\$)?@/g, (_, p) => args[p ? parseInt(p) - 1 : i++] ?? ''); };
      const HANGUL = /[가-힣]/;
      // Canvas labels are drawn every frame; remember each lookup.
      const memo = new Map();
      const t = s => {
        if (typeof s !== 'string' || !HANGUL.test(s)) return s;
        if (memo.has(s)) return memo.get(s);
        const out = lookup(s);
        memo.set(s, out);
        return out;
      };
      const lookup = s => {
        const core = s.trim().replace(/\s+/g, ' ');
        let hit = exact.get(core);
        if (hit === undefined) for (const [re, v] of patterns) { const m = core.match(re); if (m) { hit = fill(v, m.slice(1)); break; } }
        if (hit === undefined) return s;
        const lead = s.match(/^\s*/)[0], tail = s.match(/\s*$/)[0];
        return lead + hit + tail;
      };
      window.slT = t;
      const ATTRS = ['title', 'placeholder', 'aria-label', 'alt'];
      const walk = node => {
        if (node.nodeType === 3) { const v = t(node.nodeValue); if (v !== node.nodeValue) node.nodeValue = v; return; }
        if (node.nodeType !== 1 || node.tagName === 'SCRIPT' || node.tagName === 'STYLE') return;
        for (const a of ATTRS) { const old = node.getAttribute(a); if (old) { const v = t(old); if (v !== old) node.setAttribute(a, v); } }
        node.childNodes.forEach(walk);
      };
      new MutationObserver(list => {
        for (const m of list) {
          if (m.type === 'childList') m.addedNodes.forEach(walk); else walk(m.target);
        }
      }).observe(document, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ATTRS });
      document.addEventListener('DOMContentLoaded', () => { walk(document.documentElement); document.title = t(document.title); });
      const proto = CanvasRenderingContext2D.prototype;
      for (const name of ['fillText', 'strokeText', 'measureText']) {
        const original = proto[name];
        proto[name] = function (text, ...rest) { return original.call(this, t(String(text)), ...rest); };
      }
    })();
    """#
}
