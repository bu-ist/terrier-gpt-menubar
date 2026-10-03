import AppKit
import Foundation

/// Backs the "Ask TerrierGPT" entries in every app's Services menu.
///
/// This is the cheapest possible integration surface: any app that can put text on a
/// pasteboard — Mail, Preview, Pages, Xcode, a PDF, a web page — gets a TerrierGPT entry for
/// free, with no per-app scripting and no Automation permission.
///
/// The `@objc` method names here must match the `NSMessage` values in `NSServices` in
/// `TerrierGPTMenu-Info.plist`, or the menu item appears and does nothing.
final class TerrierServicesProvider: NSObject {

    /// Services menu → "Ask TerrierGPT".
    @objc func askTerrierGPT(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        handle(pasteboard: pasteboard, instruction: PromptComposer.defaultInstruction, error: error)
    }

    /// Services menu → "Summarize with TerrierGPT".
    @objc func summarizeWithTerrierGPT(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        handle(
            pasteboard: pasteboard,
            instruction: "Summarize the following content. Lead with the single most important point, then give the supporting detail as short bullets.",
            error: error
        )
    }

    /// Services menu → "Explain with TerrierGPT".
    @objc func explainWithTerrierGPT(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        handle(
            pasteboard: pasteboard,
            instruction: "Explain the following content plainly, and call out anything in it that is likely to be misunderstood.",
            error: error
        )
    }

    private func handle(
        pasteboard: NSPasteboard,
        instruction: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            error.pointee = "No text was selected." as NSString
            return
        }

        // Services callbacks arrive on the main thread, but the coordinator is `@MainActor`
        // and the compiler can't see that from an `@objc` entry point.
        Task { @MainActor in
            let source = FrontmostAppTracker.shared.previousAppName ?? "Selection"
            CaptureCoordinator.shared.instruction = instruction
            CaptureCoordinator.shared.add(CapturedContext(
                source: .clipboard,
                title: source,
                detail: "\(text.count) characters",
                body: text
            ))
            CaptureCoordinator.shared.copyPrompt()

            if !AuthManager.shared.showPanel() {
                CaptureCoordinator.shared.show(Toast(
                    kind: .info,
                    title: "Prompt ready on the clipboard",
                    detail: "Click the sparkles icon in the menu bar, then press ⌘V."
                ))
            }
        }
    }
}
