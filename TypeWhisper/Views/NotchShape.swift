import SwiftUI

/// Shape that mimics the MacBook notch silhouette with a straight top edge and smooth bottom "ears".
struct NotchShape: Shape {
    var bottomCornerRadius: CGFloat

    init(bottomCornerRadius: CGFloat = 14) {
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: CGFloat {
        get { bottomCornerRadius }
        set { bottomCornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomCornerRadius))

        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.minX + bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
