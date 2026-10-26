import Foundation

extension String {
    /// Une chaîne C lue dans un tableau rempli par le noyau ou IOKit
    /// (`proc_pidpath`, `getnameinfo`, `io_name_t`) : jusqu'au premier NUL,
    /// en UTF-8 réparé. C'est ce que faisait `String(cString:)` sur un
    /// tableau, déprécié sous Swift 6 ; à la différence de sa version à
    /// pointeur, un tableau plein sans NUL ne fait jamais lire au-delà.
    init(nulTerminated chars: [CChar]) {
        self = String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
