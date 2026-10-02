// Modified by Michael Wong for Voiceling, 2026; originally from Yaprflow (Apache-2.0). See NOTICE.

import SwiftUI

@main
struct VoicelingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
