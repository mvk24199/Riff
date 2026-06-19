import WidgetKit
import SwiftUI

// Top-level WidgetBundle entry point. WidgetKit discovers this via
// the @main attribute and instantiates each widget the extension
// vends. Riff currently ships a single Now Playing widget; future
// additions [e.g. "Today's stations", "Recently played"] can be
// appended to the body.
@main
struct RiffWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
    }
}
