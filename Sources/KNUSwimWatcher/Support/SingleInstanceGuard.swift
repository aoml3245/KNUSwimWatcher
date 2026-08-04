import Darwin
import Foundation

final class SingleInstanceGuard {
    static let shared = SingleInstanceGuard()

    private var lockFileDescriptor: Int32 = -1

    private init() {}

    func acquire() -> Bool {
        if lockFileDescriptor >= 0 {
            return true
        }

        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.woni.KNUSwimWatcher.single-instance.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            // Do not prevent the app from running if the lock file itself is unavailable.
            return true
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return false
        }

        lockFileDescriptor = descriptor
        return true
    }

    deinit {
        guard lockFileDescriptor >= 0 else { return }
        _ = flock(lockFileDescriptor, LOCK_UN)
        Darwin.close(lockFileDescriptor)
    }
}
