import SwiftUI

struct QingTheme {
    let scheme: ColorScheme

    var accent: Color {
        scheme == .dark ? Color(red: 0.62, green: 0.72, blue: 1.0) : Color(red: 0.302, green: 0.420, blue: 0.996)
    }

    var accentText: Color {
        scheme == .dark ? accent : Color(red: 0.22, green: 0.34, blue: 0.82)
    }

    var action: Color {
        scheme == .dark ? accent : Color(red: 0.27, green: 0.38, blue: 0.91)
    }

    var accentInk: Color {
        scheme == .dark ? Color(red: 0.06, green: 0.11, blue: 0.24) : .white
    }

    var primary: Color {
        scheme == .dark ? Color(red: 0.92, green: 0.95, blue: 1.0) : Color(red: 0.08, green: 0.13, blue: 0.23)
    }

    var canvas: Color {
        scheme == .dark ? Color(red: 0.055, green: 0.08, blue: 0.14) : Color(red: 0.976, green: 0.984, blue: 1.0)
    }

    var surface: Color {
        scheme == .dark ? Color(red: 0.09, green: 0.13, blue: 0.21) : .white
    }

    var raisedSurface: Color {
        scheme == .dark ? Color(red: 0.12, green: 0.17, blue: 0.26) : .white
    }

    var subtle: Color {
        scheme == .dark ? Color(red: 0.13, green: 0.19, blue: 0.32) : Color(red: 0.929, green: 0.949, blue: 1.0)
    }

    var hoverSurface: Color {
        scheme == .dark ? Color(red: 0.11, green: 0.17, blue: 0.28) : Color(red: 0.949, green: 0.965, blue: 1.0)
    }

    var line: Color {
        scheme == .dark ? Color.white.opacity(0.11) : Color(red: 0.89, green: 0.92, blue: 0.97)
    }

    var secondary: Color {
        scheme == .dark ? Color(red: 0.66, green: 0.72, blue: 0.83) : Color(red: 0.36, green: 0.42, blue: 0.52)
    }

    var later: Color {
        scheme == .dark ? Color(red: 0.53, green: 0.73, blue: 1.0) : Color(red: 0.176, green: 0.423, blue: 0.823)
    }

    var failureText: Color {
        scheme == .dark ? .orange : Color(red: 0.72, green: 0.22, blue: 0.10)
    }

    var successText: Color {
        scheme == .dark ? Color(red: 0.45, green: 0.79, blue: 0.61) : Color(red: 0.12, green: 0.42, blue: 0.28)
    }

}

struct QingPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.80 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
