import Foundation
import ServiceManagement

@MainActor
struct LoginItemService {
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
