import Foundation

/// How sharp the viewers draw while previewing (the menu in the video toolbar). Lower settings
/// run the effects and the timeline's drawing on a smaller picture, which the viewer then
/// enlarges, so heavy footage plays smoothly. Exports, Copy Frame, and Export Images always use
/// full quality.
nonisolated enum PreviewQuality: String, CaseIterable, Identifiable, Sendable {
    case full
    case half
    case quarter
    case eighth

    var id: Self { self }

    /// How many times smaller the picture's width and height are.
    var divisor: Int {
        switch self {
        case .full: 1
        case .half: 2
        case .quarter: 4
        case .eighth: 8
        }
    }

    /// Short, for the toolbar.
    var title: String {
        switch self {
        case .full: "Full"
        case .half: "1/2"
        case .quarter: "1/4"
        case .eighth: "1/8"
        }
    }

    var menuTitle: String {
        switch self {
        case .full: "Full Quality"
        case .half: "Half (1/2)"
        case .quarter: "Quarter (1/4)"
        case .eighth: "Eighth (1/8)"
        }
    }
}
