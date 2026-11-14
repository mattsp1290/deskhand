/// A window title that `measured` may report (contract 6.7, D9). ``Measured`` and ``DragEnd`` take
/// a title only as this type, and a title read from the Mac becomes one only through
/// ``AppPolicy/windowTitle(_:of:)``, which leaves out the title of an app whose windows screenshots
/// hide or that is not identified. So no result, error or record can carry a title the frames hide,
/// whichever path built its `measured`. The other way to make one is a literal in source, which
/// cannot hold a title read at run time.
///
/// At most ``Measured/maxWindowTitleLength`` Unicode scalar values, which is what the schema's
/// `maxLength` counts: a longer title is cut there, since a cut by grapheme clusters could exceed it.
public struct WindowTitle: Hashable, Sendable, ExpressibleByStringLiteral {
    public let text: String

    fileprivate init(cutting title: String) {
        text = String(String.UnicodeScalarView(title.unicodeScalars.prefix(Measured.maxWindowTitleLength)))
    }

    /// A title written in source, as tests and examples write one. `StaticString`, so a `String`
    /// read at run time cannot be passed here.
    public init(stringLiteral literal: StaticString) { self.init(cutting: literal.description) }
}

extension AppPolicy {
    /// `title`, read from a window of `app`, as `measured` may report it: `nil` when screenshots
    /// leave out `app`'s windows (the capture exclusion list and deskhand itself) or `app` has no
    /// bundle identifier, so a title the frames hide is never sent (contract 6.7).
    public func windowTitle(_ title: String?, of app: AppRef?) -> WindowTitle? {
        guard let title, let bundleID = app?.bundleID.flatMap(BundleID.init), !excludesFromCapture(bundleID) else {
            return nil
        }
        return WindowTitle(cutting: title)
    }
}
