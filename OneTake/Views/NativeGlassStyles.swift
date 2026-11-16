import SwiftUI

extension View {
    @ViewBuilder
    func nativeGlassCircleButton() -> some View {
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        } else {
            self
                .padding(8)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    @ViewBuilder
    func nativeGlassCapsuleButton(tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                self
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .tint(tint)
            } else {
                self
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
            }
        } else {
            self
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background((tint ?? .black).opacity(tint == nil ? 0.45 : 0.28), in: Capsule())
        }
    }

    @ViewBuilder
    func nativeGlassCapsuleSurface() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func nativeGlassRoundedSurface(cornerRadius: CGFloat = 24) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func nativeProminentGlassButton(tint: Color) -> some View {
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(tint)
        } else {
            self
                .foregroundStyle(.white)
                .background(tint, in: Capsule())
        }
    }
}
