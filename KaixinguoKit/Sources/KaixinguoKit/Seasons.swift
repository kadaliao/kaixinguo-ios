import Foundation
import Openhongguo

private let numerals = "[0-9一二两三四五六七八九十百零〇]+"

/// Reads 3, 三, 十一 or 二十三.
public func chineseNumber(_ s: String) -> Int {
    if let n = Int(s) {
        return n
    }
    let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
    var n = 0, cur = 0
    for r in s {
        switch r {
        case "十":
            n += max(cur, 1) * 10
            cur = 0
        case "百":
            n += max(cur, 1) * 100
            cur = 0
        default:
            cur = digits[r] ?? 0
        }
    }
    return n + cur
}

/// The groups of the last match of `pattern` in `s`.
private func lastMatch(_ pattern: String, in s: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = s as NSString
    guard let m = re.matches(in: s, range: NSRange(location: 0, length: ns.length)).last else { return nil }
    return (0..<m.numberOfRanges).map { i in
        let r = m.range(at: i)
        return r.location == NSNotFound ? "" : ns.substring(with: r)
    }
}

/// Gives each season its number and puts them in order. The server sends
/// the numbers to some devices and not to others; without them, the titles
/// tell (持械入宋：第三季), and the one title without a number is the first
/// season (浅浅归聿, 浅浅归聿第二季). Failing that, the seasons keep the
/// server's order and are numbered by it.
public func numberSeasons(_ input: [Season]) -> [Season] {
    var out = input
    // A season's number in its title: 第三季, 第 3 部.
    let mark = "第\\s*(\(numerals))\\s*[季部]"
    for i in out.indices where out[i].index <= 0 {
        out[i].index = 0
        if let m = lastMatch(mark, in: out[i].title) {
            out[i].index = chineseNumber(m[1])
        }
    }
    var used = Set<Int>()
    var missing = -1
    var distinct = true
    for (i, se) in out.enumerated() {
        if se.index <= 0 && missing == -1 {
            missing = i
        } else if se.index <= 0 {
            distinct = false // more than one without a number
        } else if used.contains(se.index) {
            distinct = false
        }
        used.insert(se.index)
    }
    if missing >= 0 && distinct && !used.contains(1) {
        out[missing].index = 1
    }
    var seen = Set<Int>()
    let ok = out.allSatisfy { se in se.index > 0 && seen.insert(se.index).inserted }
    if ok {
        return out.enumerated().sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }.map(\.element)
    }
    for i in out.indices {
        out[i].index = i + 1
    }
    return out
}

/// Puts the seasons of a series in order, where its first season is, and
/// leaves the other cards where they are.
public func orderSeasons(_ cards: [Card]) -> [Card] {
    // A title that ends with its season, as 持械入宋：第三季.
    let pattern = "^(.*?)第(\(numerals))季$"
    var first: [String: Int] = [:]
    var keys: [(group: Int, season: Int, at: Int)] = []
    for (i, k) in cards.enumerated() {
        guard let m = lastMatch(pattern, in: k.title) else {
            keys.append((i, 0, i))
            continue
        }
        let g = first[m[1]] ?? i
        first[m[1]] = g
        keys.append((g, chineseNumber(m[2]), i))
    }
    return keys.sorted { ($0.group, $0.season, $0.at) < ($1.group, $1.season, $1.at) }.map { cards[$0.at] }
}
