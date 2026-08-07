import Foundation
import WebKit
import Combine

@MainActor
class AuthManager: ObservableObject {
    
    static let shared = AuthManager()
    
    @Published var isAuthenticated: Bool = false
    @Published var isLoading: Bool = true
    @Published var showLoginSheet: Bool = false
    
    let terrierURL = URL(string: "https://terriergpt.bu.edu/")!
    
    private init() {
        Task {
            await checkSession()
        }
    }
    
    func checkSession() async {
        isLoading = true
        
        let store = WKWebsiteDataStore.default()
        let cookies = await store.httpCookieStore.allCookies()
        
        let hasBUSession = cookies.contains { cookie in
            let domain = cookie.domain.lowercased()
            return domain.contains("bu.edu") || domain.contains("terrier")
        }
        
        isAuthenticated = hasBUSession
        isLoading = false
        
        print("¿Hay sesión?: \(hasBUSession)")
    }
    
    func loginSuccess() {
        isAuthenticated = true
        showLoginSheet = false
    }
    
    func logout() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date.distantPast
        )
        
        isAuthenticated = false
        showLoginSheet = true
    }
}
