import Foundation

public enum CoreResources {
    /// resource bundle that works both under `swift run` and inside the assembled .app.
    public static var bundle: Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Companion_CompanionCore.bundle"),
           let b = Bundle(url: url) {
            return b
        }
        return Bundle.module
    }
}
