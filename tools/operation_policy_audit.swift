import Foundation

@main
struct OperationAudit {
    static func main() {
        for mask in 0..<256 {
            let flags = (0..<8).map { mask & (1 << $0) != 0 }
            let replay = OwnershipReplay()
            replay.loading = flags[0]
            replay.linkBusy = flags[1]
            replay.clockChanging = flags[2]
            IRLink.shared.busy = flags[3]
            AppLink.shared.busy = flags[4]
            AppLink.shared.openForDownload = flags[5]
            replay.appWaiting = flags[6]
            replay.holdForApp = flags[7]
            guard replay.canReplaceDevice == (mask == 0) else { fatalError("Ownership predicate failed for mask \(mask)") }
        }
        print("OWNERSHIP PREDICATE CHECKS PASSED: 256")
        print("Scope: actual extracted predicate with stub state holders; not UIKit integration or a thread-race proof")
    }
}
