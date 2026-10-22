import UIKit
import PencilKit

/// PencilKit draws a stroke point thinner than its `size` (Build 51: cut
/// shapes became hairlines), differently per ink. The factor is measured once
/// per ink type on a rendered straight test stroke (alpha coverage across it,
/// relative to the stroke's own opacity) instead of guessed. Shared by the
/// precision eraser (shape pieces as pen ink) and held shapes (preview width
/// = shape width = visible width of the drawn ink).
@MainActor
enum InkWidthCalibration {
    private static var measured: [PKInk.InkType: CGFloat] = [:]

    /// Point size per visible width (1…8) of `type`.
    static func pointScale(_ type: PKInk.InkType) -> CGFloat {
        if let scale = measured[type] { return scale }
        let side: CGFloat = 20
        let probe = stroke((0...20).map { CGPoint(x: CGFloat($0) * 10, y: 0) }, side: side, ink: PKInk(type, color: .black))
        let rect = CGRect(x: 0, y: -40, width: 200, height: 80)
        let drawn = coverage(PKDrawing(strokes: [probe]).image(from: rect, scale: 1), height: rect.height)
        let scale = drawn > 0.5 ? min(8, max(1, side / drawn)) : 1
        measured[type] = scale
        return scale
    }

    /// Constant-size stroke through `points` (control points, page units).
    static func stroke(_ points: [CGPoint], side: CGFloat, ink: PKInk) -> PKStroke {
        let size = CGSize(width: side, height: side)
        let controls = points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.001, size: size,
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: controls, creationDate: Date()))
    }

    /// Covered height (points) of the image's middle column: summed alpha over
    /// the strongest alpha, so translucent inks (highlighter) count fully.
    private static func coverage(_ image: UIImage, height: CGFloat) -> CGFloat {
        guard let cg = image.cgImage, cg.width > 0, cg.height > 0 else { return 0 }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard drawn else { return 0 }
        let column = w / 2
        let alphas = (0..<h).map { Double(pixels[($0 * w + column) * 4 + 3]) / 255 }
        guard let strongest = alphas.max(), strongest > 0.05 else { return 0 }
        return CGFloat(alphas.reduce(0, +) / strongest) * height / CGFloat(h)
    }
}
