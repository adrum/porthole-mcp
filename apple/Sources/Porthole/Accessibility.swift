#if DEBUG
import Foundation
import CoreGraphics

/// A rendered window as RGBA pixels, for measuring text contrast.
final class PixelBuffer {
    let width: Int
    let height: Int
    /// Pixels per point.
    let scale: CGFloat
    private var data: [UInt8]

    init?(_ image: CGImage, scale: CGFloat) {
        width = image.width
        height = image.height
        self.scale = scale
        data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { return nil }
    }

    /// Foreground, background and WCAG contrast ratio of the pixels in a
    /// rect (window points, top-left origin). The background is the most
    /// common color. "Ink" is every pixel that differs from it noticeably;
    /// the foreground is the ink pixel at the 90th percentile of contrast, so
    /// anti-aliased glyph edges and stray outliers don't decide the result.
    func contrast(in rect: CGRect) -> [String: Any]? {
        let x0 = max(0, Int((rect.minX * scale).rounded(.down)))
        let y0 = max(0, Int((rect.minY * scale).rounded(.down)))
        let x1 = min(width, Int((rect.maxX * scale).rounded(.up)))
        let y1 = min(height, Int((rect.maxY * scale).rounded(.up)))
        guard x1 - x0 >= 2, y1 - y0 >= 2 else { return nil }
        var counts: [UInt32: Int] = [:]
        var pixels: [UInt32] = []
        pixels.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 {
            // A bitmap context's memory starts with the image's top row.
            let row = y * width * 4
            for x in x0..<x1 {
                let i = row + x * 4
                guard data[i + 3] > 8 else { continue }
                let rgb = (UInt32(data[i]) << 16) | (UInt32(data[i + 1]) << 8) | UInt32(data[i + 2])
                pixels.append(rgb)
                // Group near-identical shades (4 bits a channel) to find the background.
                counts[Self.bucket(rgb), default: 0] += 1
            }
        }
        guard !pixels.isEmpty, let bgBucket = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        // The background's own average color, from the pixels in its bucket.
        var sum = (0, 0, 0), n = 0
        for p in pixels where Self.bucket(p) == bgBucket {
            sum.0 += Int(p >> 16); sum.1 += Int((p >> 8) & 0xFF); sum.2 += Int(p & 0xFF); n += 1
        }
        let bg = (UInt32(sum.0 / n) << 16) | (UInt32(sum.1 / n) << 8) | UInt32(sum.2 / n)
        let lbg = Self.luminance(bg)
        var ink: [(ratio: Double, rgb: UInt32)] = []
        for p in pixels {
            let r = Self.ratio(Self.luminance(p), lbg)
            if r >= 1.25 { ink.append((r, p)) }
        }
        guard ink.count >= max(3, pixels.count / 200) else { return ["bg": Self.hex(bg)] }
        ink.sort { $0.ratio < $1.ratio }
        let fg = ink[min(ink.count - 1, Int(Double(ink.count) * 0.9))]
        return ["fg": Self.hex(fg.rgb), "bg": Self.hex(bg), "ratio": (fg.ratio * 100).rounded() / 100]
    }

    private static func bucket(_ rgb: UInt32) -> UInt32 {
        ((rgb >> 20) & 0xF) << 8 | ((rgb >> 12) & 0xF) << 4 | ((rgb >> 4) & 0xF)
    }

    private static func luminance(_ rgb: UInt32) -> Double {
        func lin(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin((rgb >> 16) & 0xFF) + 0.7152 * lin((rgb >> 8) & 0xFF) + 0.0722 * lin(rgb & 0xFF)
    }

    /// WCAG 2 contrast ratio of two relative luminances.
    static func ratio(_ la: Double, _ lb: Double) -> Double {
        (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func hex(_ rgb: UInt32) -> String {
        String(format: "#%06X", rgb)
    }
}

/// Roles whose text is worth a contrast measurement.
let textBearingRoles: Set<String> = ["text", "button", "link", "textfield", "securefield", "textarea", "tab", "menuitem", "checkbox", "row", "cell"]

/// Fill `a11y.contrast` for text-bearing nodes from a rendered window.
func measureContrast(_ root: Node, pixels: PixelBuffer?) {
    guard let pixels else { return }
    root.walk { n in
        guard textBearingRoles.contains(n.role), n.name != nil || n.value != nil,
              n.a11y?["noText"] as? Bool != true,
              // Pixels at a covered node's center belong to whatever covers it.
              !n.covered else { return }
        let visible = n.frame.intersection(root.frame)
        guard visible.isUsable, let c = pixels.contrast(in: visible) else { return }
        var a = n.a11y ?? [:]
        a["contrast"] = c
        n.a11y = a
    }
}
#endif
