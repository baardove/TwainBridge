import AppKit

@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminationInProgress = false

    func applicationWillTerminate(_ notification: Notification) {
        model?.hotKeyService.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        guard let model else { return .terminateNow }
        let hasActiveWork = model.scannerService.activity.isBusy || model.uploadCoordinator.activity.isBusy
        guard hasActiveWork else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Quit while work is active?")
        alert.informativeText = String(localized: "TwainBridge will stop the active scan or upload and preserve recoverable work before quitting.")
        alert.addButton(withTitle: String(localized: "Quit & Preserve Work"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        terminationInProgress = true
        Task { @MainActor [weak self, weak sender] in
            guard let self, let sender else { return }
            let safe = await model.prepareForTermination()
            if safe {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }

            terminationInProgress = false
            let failure = NSAlert()
            failure.alertStyle = .critical
            failure.messageText = String(localized: "Captured pages are not secured yet")
            failure.informativeText = String(localized: "Keep TwainBridge open and retry after checking disk space and permissions. Quitting now may lose pages from the active scan.")
            failure.addButton(withTitle: String(localized: "Keep App Open"))
            failure.addButton(withTitle: String(localized: "Quit Anyway"))
            let quitAnyway = failure.runModal() == .alertSecondButtonReturn
            sender.reply(toApplicationShouldTerminate: quitAnyway)
        }
        return .terminateLater
    }

}
