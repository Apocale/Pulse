import AppKit

/// Une image en octets RGBA, sRGB, 8 bits : le terrain commun d'un rendu et
/// d'une référence relue, quelle que soit la façon dont chacun a été encodé.
struct Pixels: Equatable {
    let largeur: Int
    let hauteur: Int
    let octets: [UInt8]

    init(largeur: Int, hauteur: Int, octets: [UInt8]) {
        self.largeur = largeur
        self.hauteur = hauteur
        self.octets = octets
    }

    init?(_ image: CGImage) {
        let l = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: l * h * 4)
        let dessine: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: l, height: h,
                                          bitsPerComponent: 8, bytesPerRow: l * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: l, height: h))
            return true
        }
        guard dessine else { return nil }
        self.init(largeur: l, hauteur: h, octets: buffer)
    }

    init?(png url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(png: data)
    }

    init?(png data: Data) {
        guard let image = NSBitmapImageRep(data: data)?.cgImage else { return nil }
        self.init(image)
    }

    func image() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(octets) as CFData) else { return nil }
        return CGImage(width: largeur, height: hauteur, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: largeur * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func png() -> Data? {
        image().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }

    /// Combien de pixels opaques satisfont `test` (rouge, vert, bleu).
    func compte(_ test: (Int, Int, Int) -> Bool) -> Int {
        var total = 0
        for i in stride(from: 0, to: octets.count, by: 4) where octets[i + 3] > 200 {
            let r = Int(octets[i]), g = Int(octets[i + 1]), b = Int(octets[i + 2])
            if test(r, g, b) { total += 1 }
        }
        return total
    }

    /// Les pixels dont un canal s'écarte de plus de `seuil` niveaux, le plus
    /// grand écart, et la carte de l'écart : l'attendu pâli, les pixels
    /// différents en rouge.
    func ecart(avec attendu: Pixels, seuil: Int) -> (differents: Int, pire: Int, carte: Data?) {
        if octets == attendu.octets { return (0, 0, nil) }
        var differents = 0, pire = 0
        var carte = [UInt8](repeating: 0, count: octets.count)
        octets.withUnsafeBufferPointer { a in
            attendu.octets.withUnsafeBufferPointer { b in
                for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
                    var ecart = 0
                    for c in 0..<4 { ecart = max(ecart, abs(Int(a[i + c]) - Int(b[i + c]))) }
                    pire = max(pire, ecart)
                    if ecart > seuil {
                        differents += 1
                        carte[i] = 255; carte[i + 1] = 0; carte[i + 2] = 0; carte[i + 3] = 255
                    } else {
                        let gris = UInt8((Int(b[i]) + Int(b[i + 1]) + Int(b[i + 2])) / 9 + 170)
                        carte[i] = gris; carte[i + 1] = gris; carte[i + 2] = gris; carte[i + 3] = 255
                    }
                }
            }
        }
        let image = Pixels(largeur: largeur, hauteur: hauteur, octets: carte)
        return (differents, pire, differents > 0 ? image.png() : nil)
    }
}
