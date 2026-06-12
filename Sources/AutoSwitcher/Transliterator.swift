import Foundation

/// Транслитерация кириллицы в латиницу.
/// Близко к ГОСТ 7.79-2000 (система Б), привычно для большинства.
enum Transliterator {

    private static let map: [Character: String] = [
        "а":"a", "б":"b", "в":"v", "г":"g", "д":"d", "е":"e", "ё":"yo",
        "ж":"zh", "з":"z", "и":"i", "й":"y", "к":"k", "л":"l", "м":"m",
        "н":"n", "о":"o", "п":"p", "р":"r", "с":"s", "т":"t", "у":"u",
        "ф":"f", "х":"kh", "ц":"ts", "ч":"ch", "ш":"sh", "щ":"shch",
        "ъ":"", "ы":"y", "ь":"", "э":"e", "ю":"yu", "я":"ya",

        "А":"A", "Б":"B", "В":"V", "Г":"G", "Д":"D", "Е":"E", "Ё":"Yo",
        "Ж":"Zh", "З":"Z", "И":"I", "Й":"Y", "К":"K", "Л":"L", "М":"M",
        "Н":"N", "О":"O", "П":"P", "Р":"R", "С":"S", "Т":"T", "У":"U",
        "Ф":"F", "Х":"Kh", "Ц":"Ts", "Ч":"Ch", "Ш":"Sh", "Щ":"Shch",
        "Ъ":"", "Ы":"Y", "Ь":"", "Э":"E", "Ю":"Yu", "Я":"Ya"
    ]

    static func cyrillicToLatin(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count * 2)
        for c in s {
            if let r = map[c] {
                out += r
            } else {
                out.append(c)
            }
        }
        return out
    }
}
