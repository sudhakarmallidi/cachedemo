import SwiftUI

struct ContentView: View {
    private let startURL = "https://www.dbs.com.sg/index/default.page" // Replace with your desired URL
    
    var body: some View {
        WebView(urlString: startURL)
            .ignoresSafeArea()
    }
}
