import UIKit
import WebKit

// MARK: - Cache Handler
class CacheSchemeHandler: NSObject, WKURLSchemeHandler {
    // MARK: - Properties
    private let cacheDirectory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()
    
    // Concurrent URLSession for better performance
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8 // Allow up to 8 concurrent connections
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil // We handle our own caching
        return URLSession(configuration: config, delegate: nil, delegateQueue: OperationQueue())
    }()
    
    // Track active tasks for cancellation
    private var activeTasks = NSMapTable<WKURLSchemeTask, URLSessionDataTask>.strongToStrongObjects()
    private let taskLock = NSLock()
    
    // Concurrent queue for I/O operations
    private let ioQueue = DispatchQueue(label: "com.cachehandler.io", qos: .userInitiated, attributes: .concurrent)
    
    // Deduplication: Track ongoing downloads to avoid duplicate requests
    private var ongoingDownloads = [String: [(task: WKURLSchemeTask, cachePath: URL?)]]()
    private let downloadLock = NSLock()
    
    // MARK: - WKURLSchemeHandler Methods
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        
        // Generate cache-safe filename from URL (handles query parameters)
        let cacheFileName = generateCacheFileName(from: url)
        let cachePath = cacheDirectory.appendingPathComponent(cacheFileName)
        
        print("######## url: \(url)     ##########")
        print("######## cacheFileName: \(cacheFileName)     ##########")

        // Determine if this should be cached based on file extension or MIME type
        let shouldCache = shouldCacheResource(fileName: cacheFileName, url: url)
        
        let finalCachePath = shouldCache ? cachePath : nil
        
        // Try serving from cache first (on concurrent queue)
        if shouldCache {
            ioQueue.async { [weak self] in
                guard let self = self else { return }
                if FileManager.default.fileExists(atPath: cachePath.path),
                   let data = try? Data(contentsOf: cachePath) {
                    let mimeType = self.mimeType(for: cacheFileName)
                    let response = URLResponse(
                        url: url,
                        mimeType: mimeType,
                        expectedContentLength: data.count,
                        textEncodingName: "utf-8"
                    )
                    
                    DispatchQueue.main.async {
                        urlSchemeTask.didReceive(response)
                        urlSchemeTask.didReceive(data)
                        urlSchemeTask.didFinish()
                        print("✅ Served from cache: \(cacheFileName)")
                    }
                } else {
                    // Not in cache, fetch it
                    self.fetchAndReturn(url: url, task: urlSchemeTask, cachePath: finalCachePath)
                }
            }
        } else {
            // Don't cache, fetch directly
            fetchAndReturn(url: url, task: urlSchemeTask, cachePath: nil)
        }
    }
    
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        taskLock.lock()
        defer { taskLock.unlock() }
        
        // Cancel the associated URLSessionDataTask
        if let dataTask = activeTasks.object(forKey: urlSchemeTask) {
            dataTask.cancel()
            activeTasks.removeObject(forKey: urlSchemeTask)
            print("🚫 Cancelled task for: \(urlSchemeTask.request.url?.lastPathComponent ?? "unknown")")
        }
    }
    
    // MARK: - Private Methods
    
    /// Generates a cache-safe filename from URL, handling query parameters and special characters
    private func generateCacheFileName(from url: URL) -> String {
        // Get the path component
        var pathComponent = url.path.isEmpty ? "/" : url.path
        if pathComponent.hasPrefix("/") {
            pathComponent = String(pathComponent.dropFirst())
        }
        
        // If there are query parameters, append a hash of them
        var cacheKey = pathComponent.isEmpty ? "index" : pathComponent
        
        if let query = url.query, !query.isEmpty {
            // Create a hash of the query string for a shorter, filesystem-safe filename
            let queryHash = String(query.hash & 0x7FFFFFFF) // Ensure positive number
            cacheKey += "_\(queryHash)"
        }
        
        // Replace special filesystem characters
        cacheKey = cacheKey.replacingOccurrences(of: "/", with: "_")
        cacheKey = cacheKey.replacingOccurrences(of: "\\", with: "_")
        cacheKey = cacheKey.replacingOccurrences(of: ":", with: "_")
        cacheKey = cacheKey.replacingOccurrences(of: "*", with: "_")
        cacheKey = cacheKey.replacingOccurrences(of: "?", with: "_")
        cacheKey = cacheKey.replacingOccurrences(of: "\"", with: "_")
        cacheKey = cacheKey.replacingOccurrences(of: "<", with: "_")
        cacheKey = cacheKey.replacingOccurrences(of: ">", with: "_")
        cacheKey = cacheKey.replacingOccurrences(of: "|", with: "_")
        
        // Limit filename length (some filesystems have limits)
        if cacheKey.count > 200 {
            let hash = cacheKey.hash
            let ext = (cacheKey as NSString).pathExtension
            cacheKey = cacheKey.prefix(150) + "_\(String(hash & 0x7FFFFFFF))"
            if !ext.isEmpty {
                cacheKey += ".\(ext)"
            }
        }
        
        // If no extension, try to infer from path
        if (cacheKey as NSString).pathExtension.isEmpty {
            let lastPath = url.lastPathComponent
            let ext = (lastPath as NSString).pathExtension
            if !ext.isEmpty {
                cacheKey += ".\(ext)"
            }
        }
        
        return cacheKey.isEmpty ? "unknown_\(url.hash)" : cacheKey
    }
    
    /// Determines if a resource should be cached based on filename and URL
    private func shouldCacheResource(fileName: String, url: URL) -> Bool {
        // Check file extension
        let ext = (fileName as NSString).pathExtension.lowercased()
        let shouldCacheExtensions = ["js", "css", "woff", "woff2", "ttf", "eot", "png", "jpg", "jpeg", "gif", "svg", "json"]
        
        if shouldCacheExtensions.contains(ext) {
            return true
        }
        
        // Check if URL path contains common asset patterns
        let path = url.path.lowercased()
        if path.contains("/static/") || 
           path.contains("/assets/") || 
           path.contains("/build/") ||
           path.contains("/dist/") ||
           path.contains("/public/") {
            return true
        }
        
        // Don't cache HTML pages or root requests
        if ext == "html" || ext == "htm" || fileName == "index" {
            return false
        }
        
        // Cache if URL has a clear resource pattern
        let resourcePatterns = ["chunk", "bundle", "vendor", "main"]
        for pattern in resourcePatterns {
            if fileName.lowercased().contains(pattern) {
                return true
            }
        }
        
        return false
    }
    
    private func fetchAndReturn(url: URL, task urlSchemeTask: WKURLSchemeTask, cachePath: URL?) {
        // Convert custom scheme → https
        let actualURLString = url.absoluteString.replacingOccurrences(of: "myapp://", with: "https://")
        guard let actualURL = URL(string: actualURLString) else {
            urlSchemeTask.didFailWithError(NSError(domain: "InvalidURL", code: -1, userInfo: nil))
            return
        }
        
        let urlKey = actualURL.absoluteString
        
        // Check if this URL is already being downloaded (deduplication)
        downloadLock.lock()
        if ongoingDownloads[urlKey] != nil {
            // Add this task to waiting list
            ongoingDownloads[urlKey]?.append((task: urlSchemeTask, cachePath: cachePath))
            downloadLock.unlock()
            print("⏳ Deduplicating download: \(url.lastPathComponent)")
            return
        } else {
            // Start new download
            ongoingDownloads[urlKey] = [(task: urlSchemeTask, cachePath: cachePath)]
            downloadLock.unlock()
        }
        
        print("🌐 Fetching: \(actualURL.absoluteString)")
        
        var request = URLRequest(url: actualURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        
        let dataTask = urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            // Get all waiting tasks for this URL
            self.downloadLock.lock()
            let waitingTasks = self.ongoingDownloads[urlKey] ?? []
            self.ongoingDownloads.removeValue(forKey: urlKey)
            self.downloadLock.unlock()
            
            if let error = error {
                print("❌ Error fetching \(url.lastPathComponent): \(error.localizedDescription)")
                // Notify all waiting tasks of the failure
                DispatchQueue.main.async {
                    for (task, _) in waitingTasks {
                        task.didFailWithError(error)
                    }
                }
                return
            }
            
            guard let data = data, let response = response else {
                let error = NSError(domain: "CacheError", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])
                DispatchQueue.main.async {
                    for (task, _) in waitingTasks {
                        task.didFailWithError(error)
                    }
                }
                return
            }
            
            // Save to cache if applicable (on I/O queue)
            if let cachePath = cachePath {
                self.ioQueue.async(flags: .barrier) {
                    do {
                        try data.write(to: cachePath, options: .atomic)
                        print("💾 Cached: \(cachePath.lastPathComponent) (\(data.count) bytes)")
                    } catch {
                        print("⚠️ Failed to cache: \(error.localizedDescription)")
                    }
                }
            }
            
            // Respond to all waiting tasks
            DispatchQueue.main.async {
                for (task, _) in waitingTasks {
                    self.taskLock.lock()
                    self.activeTasks.removeObject(forKey: task)
                    self.taskLock.unlock()
                    
                    task.didReceive(response)
                    task.didReceive(data)
                    task.didFinish()
                }
                print("✅ Delivered to \(waitingTasks.count) task(s): \(url.lastPathComponent)")
            }
        }
        
        // Track the task for cancellation
        taskLock.lock()
        activeTasks.setObject(dataTask, forKey: urlSchemeTask)
        taskLock.unlock()
        
        dataTask.resume()
    }
    
    private func mimeType(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "js":
            return "application/javascript"
        case "css":
            return "text/css"
        case "html", "htm":
            return "text/html"
        case "json":
            return "application/json"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "svg":
            return "image/svg+xml"
        case "woff":
            return "font/woff"
        case "woff2":
            return "font/woff2"
        case "ttf":
            return "font/ttf"
        case "eot":
            return "application/vnd.ms-fontobject"
        default:
            return "application/octet-stream"
        }
    }
}

// MARK: - View Controller
class ViewController: UIViewController, WKNavigationDelegate {
    var webView: WKWebView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = UIColor.blue
        setupWebView()
        loadAirbnb()
    }
    
    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(CacheSchemeHandler(), forURLScheme: "myapp")
        config.websiteDataStore = WKWebsiteDataStore.default() // allow cookies/service workers
        
        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)
    }
    
    private func loadAirbnb() {
        // Convert real URL to custom scheme for interception
        let httpsURL = "https://www.dbs.com.sg/personal/deposits/default.page" //"https://www.airbnb.com.sg"
        let myAppURLString = httpsURL.replacingOccurrences(of: "https://", with: "myapp://")
        
        if let myAppURL = URL(string: myAppURLString) {
            let request = URLRequest(url: myAppURL)
            webView.load(request)
            print("🌐 Loading Airbnb via custom scheme: \(myAppURLString)")
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("✅ Airbnb loaded successfully")
    }
}
