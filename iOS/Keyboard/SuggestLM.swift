import Foundation

/// The English words for the suggestion bar: ways to finish the word being typed, and next words, ranked by the
/// words before the cursor. Katz back-off over word triples, pairs and single words counted in FineWeb and Reddit
/// (Tools/suggest: pack_lm.py builds SuggestEN.bin, README.md has the benchmark against the system keyboard).
/// Memory-mapped: opening the keyboard reads nothing, a lookup touches a few pages.
final class SuggestLM {
    static let shared = SuggestLM()
    private static let discount = 0.75

    private var data: NSData?
    private var base: UnsafeRawPointer?
    private(set) var wordCount: Int
    private var triCount = 0, total = 1.0
    private var keyOffs = 0, blob = 0, uni = 0, biStart = 0, biTotal = 0, biBeta = 0, biIds = 0, biCounts = 0
    private var triKeys = 0, triStart = 0, triTotal = 0, triBeta = 0, triIds = 0, triCounts = 0
    private var top = 0   // the 64 most common words: next-word candidates in any context

    init(bundle: Bundle = .main) {
        let url = bundle.url(forResource: "SuggestEN", withExtension: "bin") ?? Bundle(for: SuggestLM.self).url(forResource: "SuggestEN", withExtension: "bin")
        let d = url.flatMap { try? NSData(contentsOf: $0, options: .alwaysMapped) }
        guard let d, d.length > 32, String(decoding: Data(bytes: d.bytes, count: 8), as: UTF8.self) == "VKLM0002" else {
            data = nil; base = nil; wordCount = 0; return
        }
        data = d; base = d.bytes
        let h = { (i: Int) in Int(d.bytes.load(fromByteOffset: 8 + 4 * i, as: UInt32.self)) }
        let n = h(0), nTri = h(1), nBi = h(2), nTriE = h(3), blobBytes = h(4)
        wordCount = n; triCount = nTri; total = Double(h(5))
        let nCtx = n + 2
        func align(_ x: Int) -> Int { (x + 3) & ~3 }
        var o = 8 + 24
        keyOffs = o; o += 4 * (n + 1)
        blob = o; o = align(o + blobBytes)
        uni = o; o += 4 * n
        biStart = o; o += 4 * (nCtx + 1)
        biTotal = o; o += 4 * nCtx
        biBeta = o; o += 4 * nCtx
        biIds = o; o += 2 * nBi
        biCounts = o; o = align(o + 2 * nBi)
        triKeys = o; o += 4 * nTri
        triStart = o; o += 4 * (nTri + 1)
        triTotal = o; o += 4 * nTri
        triBeta = o; o += 4 * nTri
        triIds = o; o += 2 * nTriE
        triCounts = o; o = align(o + 2 * nTriE)
        top = o; o += 2 * 64
        if o != d.length { data = nil; base = nil; wordCount = 0 }   // not the layout this code reads
    }

    var isEmpty: Bool { wordCount == 0 }

    // MARK: the file

    private func u32(_ section: Int, _ i: Int) -> Int { Int(base!.load(fromByteOffset: section + 4 * i, as: UInt32.self)) }
    private func u16(_ section: Int, _ i: Int) -> Int { Int(base!.load(fromByteOffset: section + 2 * i, as: UInt16.self)) }
    /// A pair's or triple's count, kept as round(ln(count) * 2000).
    private func count(_ section: Int, _ i: Int) -> Double { exp(Double(u16(section, i)) / 2000) }
    private func f32(_ section: Int, _ i: Int) -> Double { Double(base!.load(fromByteOffset: section + 4 * i, as: Float32.self)) }

    /// A word's key bytes (lowercase), up to its display form.
    private func key(_ id: Int) -> UnsafeRawBufferPointer {
        let s = u32(keyOffs, id), e = u32(keyOffs, id + 1)
        var k = s
        while k < e, base!.load(fromByteOffset: blob + k, as: UInt8.self) != 9 { k += 1 }
        return UnsafeRawBufferPointer(start: base! + blob + s, count: k - s)
    }

    /// How a word shows: "I", "YouTube", "don't".
    func form(_ id: Int) -> String {
        let s = u32(keyOffs, id), e = u32(keyOffs, id + 1)
        let all = UnsafeRawBufferPointer(start: base! + blob + s, count: e - s)
        if let tab = all.firstIndex(of: 9) { return String(decoding: all[(tab + 1)...], as: UTF8.self) }
        return String(decoding: all, as: UTF8.self)
    }

    /// The first id whose key is >= `k` (byte order).
    private func lowerBound(_ k: [UInt8]) -> Int {
        var lo = 0, hi = wordCount
        while lo < hi {
            let mid = (lo + hi) / 2
            if key(mid).lexicographicallyPrecedes(k) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func bytes(_ s: String) -> [UInt8] { Array(s.lowercased().replacingOccurrences(of: "’", with: "'").utf8) }

    /// The ids of the words that start with `prefix` (a contiguous range: keys are byte-sorted).
    private func range(_ prefix: [UInt8]) -> Range<Int> { lowerBound(prefix)..<lowerBound(prefix + [0xFF]) }

    func id(_ word: String) -> Int? {
        guard !isEmpty else { return nil }
        let k = Self.bytes(word), i = lowerBound(k)
        return i < wordCount && key(i).elementsEqual(k) ? i : nil
    }

    /// How often the word was seen (0 when it isn't a word here).
    func count(_ word: String) -> Int { id(word).map { u32(uni, $0) } ?? 0 }

    /// Whether the typed letters are a word on its way rather than a typo of `word` (a fix that isn't one of the
    /// ways to finish them): after `before`, the words they start are at least 2% as likely as the fix, about how
    /// often a word gets a typo ("spee" → speed after "high", not "see"; "helpi" → helping, not "help"; but
    /// "teh" → the, not Tehran), or the fix isn't English.
    func prefersFinishing(_ prefix: String, over word: String, before: String) -> Bool {
        guard !isEmpty else { return false }
        let k = Self.bytes(prefix), r = range(k)
        guard !r.isEmpty, !Self.bytes(word).starts(with: k) else { return false }
        guard let fix = id(word) else { return true }
        let ctx = context(before)
        var finishing = 0.0, pFix = 0.0
        scan(r, ctx) { _, p in finishing += p }
        scan(fix..<fix + 1, ctx) { _, p in pFix = p }
        return finishing >= 0.02 * pFix
    }

    // MARK: the model

    private func p1(_ w: Int) -> Double { Double(u32(uni, w)) / total }

    /// The first index of a run of ids (sorted) whose id is >= w.
    private func lower(_ ids: Int, _ run: Range<Int>, _ w: Int) -> Int {
        var lo = run.lowerBound, hi = run.upperBound
        while lo < hi {
            let mid = (lo + hi) / 2
            if u16(ids, mid) < w { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func triIndex(_ a: Int, _ b: Int) -> Int? {
        let k = a << 16 | b
        var lo = 0, hi = triCount
        while lo < hi {
            let mid = (lo + hi) / 2, x = u32(triKeys, mid)
            if x == k { return mid }
            if x < k { lo = mid + 1 } else { hi = mid }
        }
        return nil
    }

    /// P(w | the context), from the counts of (last, w) and (before, last, w) when they were kept (nil when not).
    private func p(_ w: Int, _ ctx: Context, pair: Double?, triple: Double?) -> Double {
        guard let b = ctx.last else { return p1(w) }
        let n = u32(biTotal, b)
        let p2 = n == 0 ? p1(w) : pair.map { ($0 - Self.discount) / Double(n) } ?? f32(biBeta, b) * p1(w)
        guard let t = ctx.tri else { return p2 }
        return triple.map { ($0 - Self.discount) / Double(u32(triTotal, t)) } ?? f32(triBeta, t) * p2
    }

    /// Every word id in `r` (a run of the vocabulary) with its P(w | context): one walk along the context's pairs and
    /// triples, which are sorted by id, so no word costs a search.
    private func scan(_ r: Range<Int>, _ ctx: Context, _ body: (Int, Double) -> Void) {
        let bi = ctx.last.map { u32(biStart, $0)..<u32(biStart, $0 + 1) } ?? 0..<0
        let tri = ctx.tri.map { u32(triStart, $0)..<u32(triStart, $0 + 1) } ?? 0..<0
        var i = lower(biIds, bi, r.lowerBound), j = lower(triIds, tri, r.lowerBound)
        for w in r {
            while i < bi.upperBound, u16(biIds, i) < w { i += 1 }
            while j < tri.upperBound, u16(triIds, j) < w { j += 1 }
            let pair = i < bi.upperBound && u16(biIds, i) == w ? count(biCounts, i) : nil
            let triple = j < tri.upperBound && u16(triIds, j) == w ? count(triCounts, j) : nil
            body(w, p(w, ctx, pair: pair, triple: triple))
        }
    }

    // MARK: the context

    /// The two tokens before the cursor's word as ids: words, <s> after . ! ? or a new line, <,> after , ; :.
    struct Context {
        var before: Int?, last: Int?
        var tri: Int? = nil   // the triple table's row for (before, last), looked up once
    }

    func context(_ text: String) -> Context {
        guard !isEmpty else { return Context() }
        let sentence = wordCount, comma = wordCount + 1
        let tail = text.suffix(120)
        var toks: [Int?] = tail.count == text.count ? [sentence] : []   // a cut tail starts mid-sentence
        var word = "", first = tail.count != text.count   // the cut's first word may be partial: dropped
        func endWord() {
            if !word.isEmpty { if !first { toks.append(id(word)) }; word = "" }
            first = false
        }
        for ch in tail {
            if ch.isLetter || ((ch == "'" || ch == "’") && !word.isEmpty) { word.append(ch); continue }
            endWord()
            switch ch {
            case ".", "!", "?", "\n": toks = [sentence]
            case ",", ";", ":": toks = [comma]
            case " ": break
            default: if !("\"“(['‘".contains(ch) && toks == [sentence]) { toks = [nil] }   // a quote or bracket can open a sentence
            }
        }
        endWord()
        // an unknown word ends the context: nothing before it counts
        if let i = toks.lastIndex(where: { $0 == nil }) { toks = Array(toks[(i + 1)...]) }
        var c = Context(before: toks.count >= 2 ? toks[toks.count - 2] : nil, last: toks.last ?? nil)
        if let a = c.before, let b = c.last { c.tri = triIndex(a, b) }
        return c
    }

    // MARK: suggestions

    /// The best ways to finish `prefix` after `before` (the text before the word), most likely first, as they show
    /// ("I", "don't"). The prefix itself isn't one of them.
    func completions(_ prefix: String, before: String, limit: Int) -> [String] {
        guard !isEmpty, !prefix.isEmpty else { return [] }
        let k = Self.bytes(prefix), r = range(k)
        guard !r.isEmpty else { return [] }
        var best: [(Double, Int)] = []
        scan(r, context(before)) { w, s in
            if best.count == limit, s <= best[limit - 1].0 { return }
            if key(w).elementsEqual(k) { return }
            let at = best.firstIndex { s > $0.0 } ?? best.count
            best.insert((s, w), at: at)
            if best.count > limit { best.removeLast() }
        }
        return best.map { form($0.1) }
    }

    /// The likeliest next words after `before` (which ends with a space): the context's pairs (a triple kept for a
    /// word is always kept as a pair too), and the most common words.
    func nextWords(before: String, limit: Int) -> [String] {
        guard !isEmpty else { return [] }
        let ctx = context(before)
        var best: [(Double, Int)] = []
        func consider(_ w: Int, _ s: Double) {
            if best.count == limit, s <= best[limit - 1].0 { return }
            if best.contains(where: { $0.1 == w }) { return }
            let at = best.firstIndex { s > $0.0 } ?? best.count
            best.insert((s, w), at: at)
            if best.count > limit { best.removeLast() }
        }
        if let b = ctx.last {
            let bi = u32(biStart, b)..<u32(biStart, b + 1)
            let tri = ctx.tri.map { u32(triStart, $0)..<u32(triStart, $0 + 1) } ?? 0..<0
            var j = tri.lowerBound
            for i in bi {
                let w = u16(biIds, i)
                while j < tri.upperBound, u16(triIds, j) < w { j += 1 }
                let triple = j < tri.upperBound && u16(triIds, j) == w ? count(triCounts, j) : nil
                consider(w, p(w, ctx, pair: count(biCounts, i), triple: triple))
            }
        }
        for k in 0..<64 {
            let w = u16(top, k)
            scan(w..<w + 1, ctx) { w, s in consider(w, s) }
        }
        return best.map { form($0.1) }
    }
}
