import SwiftUI

struct GesturesView: View {
  @AppStorage(PreferenceKey.swipeGestures.rawValue) private var swipeGestures = false
  @State private var caption = GesturesView.caption(for: ShortcutsManager.shared.load(for: .move))

  static func caption(for move: UserShortcut?) -> String {
    let base = "Swipe on a title bar or Dock icon."
    guard let flags = StrokeLogic.anywhereModifier(for: move) else { return base }
    let key = KeyboardShortcut(keyCode: nil, modifierFlags: flags).displayString
    return "\(base) Hold \(key) to swipe anywhere on the window."
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      PreferenceToggle(
        isOn: $swipeGestures,
        title: "Swipe gestures",
        subtitle: "Minimise, maximise, halves",
        icon: "hand.point.up.left"
      )

      Text(caption)
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .onReceive(NotificationCenter.default.publisher(for: .shortcutsDidChange)) { _ in
      caption = GesturesView.caption(for: ShortcutsManager.shared.load(for: .move))
    }
  }
}

#Preview {
  GesturesView().padding().frame(width: 300)
}
