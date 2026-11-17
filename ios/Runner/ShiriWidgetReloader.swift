import WidgetKit

// Keep WidgetKit imports separate from PhotosUI's UIKit picker overlay.
enum ShiriWidgetReloader {
    static func reload() { WidgetCenter.shared.reloadAllTimelines() }
}
