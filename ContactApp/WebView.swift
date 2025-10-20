import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    let urlString: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()

        // Inject script at document start: intercept fetch/XHR and warm cache for chunk*.js
        let js = Self.interceptionAndCachingJS()
        let userScript = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        contentController.addUserScript(userScript)
        contentController.add(context.coordinator, name: "network")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        if let url = URL(string: urlString) {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            webView.load(request)
        }
        webView.isInspectable = true
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // no-op
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "network" else { return }
            
            if let body = message.body as? [String: Any] {
                let type = body["type"] as? String ?? "unknown"
                let url = body["url"] as? String ?? ""
                
                switch type {
                case "cache_put":
                    print("✅ CACHED: \(url)")
                case "cache_hit":
                    print("🎯 CACHE HIT: \(url)")
                case "fetch":
                    print("🌐 FETCH: \(url)")
                case "xhr_open", "xhr_send":
                    print("📡 XHR: \(url)")
                case "error":
                    let error = body["message"] as? String ?? "Unknown error"
                    print("❌ JS ERROR: \(error)")
                default:
                    print("📝 [WebView] \(type): \(url)")
                }
            } else {
                print("📝 [WebView] JS -> native (non-dict):", message.body)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }
    }

    private static func interceptionAndCachingJS() -> String {
        // language=JavaScript
        return "(function(){\n" +
        "try {\n" +
        "  const post = (payload) => { try { window.webkit?.messageHandlers?.network?.postMessage(payload); } catch (_) {} };\n" +
        "  const toAbs = (u) => { try { return new URL(u, location.href).href; } catch (_) { return String(u||''); } };\n" +
        "  const isChunk = (u) => /chunk.*\\.js(\\?.*)?$/i.test(u);\n" +
        "\n" +
        "  const putIfOk = (cache, url, resp) => { try { if (resp && resp.ok) { cache.put(url, resp.clone()); post({ type: 'cache_put', url }); } } catch (_) {} };\n" +
        "  const matchAny = (cache, url) => cache.match(url).then(m => m ? m : cache.match(url.split('?')[0]));\n" +
        "\n" +
        "  // Warm cache for existing script tags and any preload hints\n" +
        "  const warmChunkCache = () => {\n" +
        "    try {\n" +
        "      const scripts = Array.from(document.getElementsByTagName('script'))\n" +
        "        .map(s => s.src).filter(Boolean).map(toAbs).filter(isChunk);\n" +
        "      const preloads = Array.from(document.querySelectorAll(\"link[rel='preload'][as='script']\"))\n" +
        "        .map(l => l.href).filter(Boolean).map(toAbs).filter(isChunk);\n" +
        "      const urls = Array.from(new Set([...scripts, ...preloads]));\n" +
        "      if (urls.length === 0) return;\n" +
        "      caches.open('app-cache').then(cache => {\n" +
        "        urls.forEach(u => {\n" +
        "          fetch(u, { credentials: 'include' }).then(resp => putIfOk(cache, u, resp)).catch(()=>{});\n" +
        "        });\n" +
        "      });\n" +
        "    } catch (_) {}\n" +
        "  };\n" +
        "  if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', warmChunkCache); } else { warmChunkCache(); }\n" +
        "  window.addEventListener('load', warmChunkCache, { once: true });\n" +
        "\n" +
        "  // Observe dynamically added script tags to prefetch chunk files\n" +
        "  try {\n" +
        "    const observer = new MutationObserver((mutations) => {\n" +
        "      for (const m of mutations) {\n" +
        "        for (const n of m.addedNodes) {\n" +
        "          if (!(n && n.tagName === 'SCRIPT' && n.src)) continue;\n" +
        "          const u = toAbs(n.src);\n" +
        "          if (!isChunk(u)) continue;\n" +
        "          const parent = n.parentNode;\n" +
        "          if (!parent) continue;\n" +
        "          // Temporarily remove to avoid network fetch\n" +
        "          parent.removeChild(n);\n" +
        "          caches.open('app-cache').then(async (cache) => {\n" +
        "            try {\n" +
        "              const match = await cache.match(u) || await cache.match(u.split('?')[0]);\n" +
        "              if (match) {\n" +
        "                const text = await match.text();\n" +
        "                const blob = new Blob([text], { type: 'application/javascript' });\n" +
        "                const blobUrl = URL.createObjectURL(blob);\n" +
        "                const s = document.createElement('script');\n" +
        "                // Copy relevant attributes except src\n" +
        "                for (const attr of Array.from(n.attributes)) { if (attr.name.toLowerCase() !== 'src') s.setAttribute(attr.name, attr.value); }\n" +
        "                s.src = blobUrl;\n" +
        "                post({ type: 'cache_serve_script', url: u });\n" +
        "                parent.appendChild(s);\n" +
        "                return;\n" +
        "              }\n" +
        "            } catch (_) {}\n" +
        "            // Fallback: insert original node and prefetch for future\n" +
        "            try { parent.appendChild(n); } catch (_) {}\n" +
        "            fetch(u, { credentials: 'include' }).then(resp => {\n" +
        "              caches.open('app-cache').then(cache2 => putIfOk(cache2, u, resp));\n" +
        "            }).catch(()=>{});\n" +
        "          });\n" +
        "        }\n" +
        "      }\n" +
        "    });\n" +
        "    observer.observe(document.documentElement || document.body, { childList: true, subtree: true });\n" +
        "  } catch (_) {}\n" +
        "\n" +
        "  // Intercept fetch and serve from Cache Storage for chunk scripts\n" +
        "  const originalFetch = window.fetch.bind(window);\n" +
        "  window.fetch = function(input, init){\n" +
        "    try {\n" +
        "      const raw = (typeof input === 'string') ? input : (input && input.url) || '';\n" +
        "      const url = toAbs(raw);\n" +
        "      const method = (init && init.method) || 'GET';\n" +
        "      post({ type: 'fetch', url, method });\n" +
        "      if (isChunk(url) && (!init || !init.method || init.method.toUpperCase() === 'GET')) {\n" +
        "        return caches.open('app-cache').then(cache => {\n" +
        "          return matchAny(cache, url).then(match => {\n" +
        "            if (match) { post({ type: 'cache_hit', url }); return match.clone(); }\n" +
        "            return originalFetch(input, init).then(resp => { putIfOk(cache, url, resp); return resp; });\n" +
        "          });\n" +
        "        });\n" +
        "      }\n" +
        "    } catch (_) {}\n" +
        "    return originalFetch(input, init);\n" +
        "  };\n" +
        "\n" +
        "  // Intercept XMLHttpRequest (log only)\n" +
        "  (function(){\n" +
        "    const OriginalXHR = window.XMLHttpRequest;\n" +
        "    function WrappedXHR(){ const xhr = new OriginalXHR();\n" +
        "      let _url = ''; let _method = 'GET';\n" +
        "      const open = xhr.open; xhr.open = function(method, url){ _method = method; _url = toAbs(url); try { post({ type: 'xhr_open', method, url: _url }); } catch (_) {} return open.apply(xhr, arguments); };\n" +
        "      const send = xhr.send; xhr.send = function(body){ try { post({ type: 'xhr_send', method: _method, url: _url }); } catch (_) {} return send.apply(xhr, arguments); };\n" +
        "      return xhr; }\n" +
        "    WrappedXHR.UNSENT = OriginalXHR.UNSENT; WrappedXHR.OPENED = OriginalXHR.OPENED; WrappedXHR.HEADERS_RECEIVED = OriginalXHR.HEADERS_RECEIVED; WrappedXHR.LOADING = OriginalXHR.LOADING; WrappedXHR.DONE = OriginalXHR.DONE;\n" +
        "    WrappedXHR.prototype = OriginalXHR.prototype;\n" +
        "    window.XMLHttpRequest = WrappedXHR;\n" +
        "  })();\n" +
        "\n" +
        "  // Debug functions for console\n" +
        "  window.debugCache = {\n" +
        "    async list() {\n" +
        "      const cache = await caches.open('app-cache');\n" +
        "      const keys = await cache.keys();\n" +
        "      console.log('📦 Cached files:', keys.map(r => r.url));\n" +
        "      return keys.map(r => r.url);\n" +
        "    },\n" +
        "    async chunks() {\n" +
        "      const cache = await caches.open('app-cache');\n" +
        "      const keys = await cache.keys();\n" +
        "      const chunks = keys.filter(r => isChunk(r.url));\n" +
        "      console.log('🧩 Cached chunks:', chunks.map(r => r.url));\n" +
        "      return chunks.map(r => r.url);\n" +
        "    },\n" +
        "    async clear() {\n" +
        "      await caches.delete('app-cache');\n" +
        "      console.log('🗑️ Cache cleared');\n" +
        "    }\n" +
        "  };\n" +
        "} catch (e) { try { window.webkit?.messageHandlers?.network?.postMessage({ type: 'error', message: String(e) }); } catch (_) {} }\n" +
        "})();"
    }
}


