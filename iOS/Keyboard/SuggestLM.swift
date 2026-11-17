import Foundation

/// The English words for the suggestion bar: ways to finish the word being typed, and next words, ranked by the
/// words before the cursor. Katz back-off over word triples, pairs and single words counted in FineWeb and Reddit
/// (Tools/suggest: pack_lm.py builds SuggestEN.bin, README.md has the benchmark against the system keyboard).
/// Memory-mapped: opening the keyboard reads nothing, a lookup touches a few pages.
final class SuggestLM {
    static let shared = SuggestLM(name: "SuggestEN", network: "SuggestNN", networkShare: 0.5)
    /// The same for Vietnamese (syllables; SuggestVI.bin and its network SuggestVINN.bin).
    static let vietnamese = SuggestLM(name: "SuggestVI", network: "SuggestVINN", networkShare: 0.5)   // 0.25-0.75 all within noise
    private let networkName: String
    private static let discount = 0.75
    /// The share of a word's probability that comes from the next-word network (SuggestNN), which reads further
    /// back than two words; the rest is the counts'. Tuned on the benchmarks' dev sets.
    private let networkShare: Double
    private(set) lazy var nn: SuggestNN? = { let n = SuggestNN(name: networkName, words: self); return n.isEmpty ? nil : n }()
    private lazy var wordOfNetworkId: [Int] = {   // the network's ids back to word ids
        guard let nn else { return [] }
        var m = [Int](repeating: -1, count: nn.V)
        for w in 0..<wordCount { let k = nn.networkId(w); if k > 0 { m[k] = w } }
        return m
    }()

    private var data: NSData?
    private var base: UnsafeRawPointer?
    private(set) var wordCount: Int
    private var triCount = 0, total = 1.0
    private var keyOffs = 0, blob = 0, uni = 0, biStart = 0, biTotal = 0, biBeta = 0, biIds = 0, biCounts = 0
    private var triKeys = 0, triStart = 0, triTotal = 0, triBeta = 0, triIds = 0, triCounts = 0
    private var top = 0   // the 64 most common words: next-word candidates in any context

    init(name: String, network: String, networkShare: Double, bundle: Bundle = .main) {
        networkName = network; self.networkShare = networkShare
        let url = bundle.url(forResource: name, withExtension: "bin") ?? Bundle(for: SuggestLM.self).url(forResource: name, withExtension: "bin")
        let d = url.flatMap { try? NSData(contentsOf: $0, options: .alwaysMapped) }
        guard let d, d.length > 32, String(decoding: Data(bytes: d.bytes, count: 8), as: UTF8.self) == "VKLM0002" else {
            data = nil; base = nil; wordCount = 0; return
        }
        data = d; base = d.bytes
        madvise(UnsafeMutableRawPointer(mutating: d.bytes), d.length, MADV_WILLNEED)   // read ahead, without waiting
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

    /// Maps both languages' files and their networks' (cheap: no reading) and has the OS read them ahead in the
    /// background (madvise), so a first suggestion doesn't page in ~50 MB on the main thread. Main thread only:
    /// the lazy network isn't thread-safe.
    static func prepare() { for lm in [shared, vietnamese] where !lm.isEmpty { _ = lm.nn } }

    // MARK: the file

    private func u32(_ section: Int, _ i: Int) -> Int { Int(base!.load(fromByteOffset: section + 4 * i, as: UInt32.self)) }
    private func u16(_ section: Int, _ i: Int) -> Int { Int(base!.load(fromByteOffset: section + 2 * i, as: UInt16.self)) }
    /// A pair's or triple's count, kept as round(ln(count) * 2000).
    private func count(_ section: Int, _ i: Int) -> Double { exp(Double(u16(section, i)) / 2000) }
    private func f32(_ section: Int, _ i: Int) -> Double { Double(base!.load(fromByteOffset: section + 4 * i, as: Float32.self)) }

    /// How a word shows: "I", "YouTube", "don't".
    func form(_ id: Int) -> String {
        let s = u32(keyOffs, id), e = u32(keyOffs, id + 1)
        let all = UnsafeRawBufferPointer(start: base! + blob + s, count: e - s)
        if let tab = all.firstIndex(of: 9) { return String(decoding: all[(tab + 1)...], as: UTF8.self) }
        return String(decoding: all, as: UTF8.self)
    }

    /// A word's key against `k`, in byte order (<0, 0, >0). memcmp, not Sequence comparisons: generic code is slow
    /// in debug builds, where the timing tests run.
    private func compare(_ id: Int, _ k: [UInt8]) -> Int {
        let s = u32(keyOffs, id), e = u32(keyOffs, id + 1)
        let p = base! + blob + s
        let len = memchr(p, 9, e - s).map { UnsafeRawPointer($0) - p } ?? e - s
        let c = k.withUnsafeBytes { memcmp(p, $0.baseAddress!, min(len, k.count)) }
        return c != 0 ? Int(c) : len - k.count
    }

    /// The first id whose key is >= `k` (byte order).
    private func lowerBound(_ k: [UInt8]) -> Int {
        var lo = 0, hi = wordCount
        while lo < hi {
            let mid = (lo + hi) / 2
            if compare(mid, k) < 0 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.utf8.count)
        for b in s.utf8 {   // plain ASCII (most English, every Telex key) without Foundation's work
            guard b < 0x80 else { return Array(s.lowercased().replacingOccurrences(of: "’", with: "'").precomposedStringWithCanonicalMapping.utf8) }
            out.append(b >= 65 && b <= 90 ? b + 32 : b)
        }
        return out
    }

    /// The ids of the words that start with `prefix` (a contiguous range: keys are byte-sorted).
    private func range(_ prefix: [UInt8]) -> Range<Int> { lowerBound(prefix)..<lowerBound(prefix + [0xFF]) }

    func id(_ word: String) -> Int? {
        guard !isEmpty else { return nil }
        let k = Self.bytes(word), i = lowerBound(k)
        return i < wordCount && compare(i, k) == 0 ? i : nil
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

    /// P(w) blended with the network's guess (nnp: its distribution after the same text).
    private func blend(_ p: Double, _ w: Int, _ nnp: UnsafePointer<Float>?) -> Double {
        guard let nnp, let nn else { return p }
        let k = nn.networkId(w)
        return (1 - networkShare) * p + networkShare * (k > 0 ? Double(nnp[k]) : 0)
    }

    // MARK: the context

    /// The two tokens before the cursor's word as ids: words, <s> after . ! ? or a new line, <,> after , ; :.
    struct Context {
        var before: Int?, last: Int?
        var tri: Int? = nil   // the triple table's row for (before, last), looked up once
    }

    private var lastContext: (text: String, ctx: Context)?   // a word's keystrokes all share the text before it

    func context(_ text: String) -> Context {
        guard !isEmpty else { return Context() }
        if let c = lastContext, c.text == text { return c.ctx }
        let c = readContext(text)
        lastContext = (text, c)
        return c
    }

    private func readContext(_ text: String) -> Context {
        let sentence = wordCount, comma = wordCount + 1
        let tail = text.suffix(120)
        var toks: [Int?] = tail.count == text.count ? [sentence] : []   // a cut tail starts mid-sentence
        var word = String.UnicodeScalarView(), first = tail.count != text.count   // the cut's first word may be partial: dropped
        func endWord() {
            if !word.isEmpty { if !first { toks.append(id(String(word))) }; word = String.UnicodeScalarView() }
            first = false
        }
        // by scalar, not Character: grapheme breaking costs more than the rest (a combining mark is a letter's part)
        for ch in tail.unicodeScalars {
            if ch.properties.isAlphabetic || ch.properties.generalCategory == .nonspacingMark
                || ((ch == "'" || ch == "’") && !word.isEmpty) { word.append(ch); continue }
            endWord()
            switch ch {
            case ".", "!", "?", "\n": toks = [sentence]
            case ",", ";", ":": toks = [comma]
            case " ": break
            default: if !("\"“(['‘".unicodeScalars.contains(ch) && toks == [sentence]) { toks = [nil] }   // a quote or bracket can open a sentence
            }
        }
        endWord()
        // an unknown word ends the context: nothing before it counts
        if let i = toks.lastIndex(where: { $0 == nil }) { toks = Array(toks[(i + 1)...]) }
        var c = Context(before: toks.count >= 2 ? toks[toks.count - 2] : nil, last: toks.last ?? nil)
        if let a = c.before, let b = c.last { c.tri = triIndex(a, b) }
        return c
    }

    // MARK: slips

    /// A word's letters from its taps, read back: every word whose letters each lie near their tap (as many letters as
    /// taps: slips onto a neighbour, not missed or extra keys), with log closeness (a 2D Gaussian per tap, spread in
    /// key widths and heights as the engine's TouchModel) and log P(word | before). Best first by their sum. Words
    /// with more than `maxSlips` letters off their nearest key aren't looked at.
    struct Reading { let word: String; let id: Int; let closeness: Double; let likelihood: Double; var score: Double { closeness + likelihood } }

    func readTaps(_ taps: [(x: Float, y: Float)], keys: [VKKeyRect], before: String, maxSlips: Int = 2, limit: Int = 4,
                  sigma: Float = 0.35, sigmaY: Float = 0.25) -> [Reading] {
        guard !isEmpty, !taps.isEmpty, taps.count < 24 else { return [] }
        // per tap: the letters close enough to have been meant (within ~3 spreads), closest first
        var near: [[(UInt8, Double)]] = []
        for t in taps {
            var c: [(UInt8, Double)] = []
            for k in keys {
                let dx = (t.x - (k.x + k.w / 2)) / (k.w * sigma), dy = (t.y - (k.y + k.h / 2)) / (k.h * sigmaY)
                let s = -0.5 * Double(dx * dx + dy * dy)
                if s > -4.5 { c.append((UInt8(bitPattern: k.letter), s)) }
            }
            c.sort { $0.1 > $1.1 }
            near.append(c)
        }
        var found: [(Int, Double)] = [], prefix: [UInt8] = []
        func walk(_ i: Int, _ closeness: Double, _ slips: Int) {
            if i == taps.count {
                let w = lowerBound(prefix)
                if w < wordCount, compare(w, prefix) == 0 { found.append((w, closeness)) }
                return
            }
            for (j, (letter, s)) in near[i].enumerated() {
                let sl = slips + (j == 0 ? 0 : 1)
                if sl > maxSlips { continue }
                prefix.append(letter)
                if lowerBound(prefix) < lowerBound(prefix + [0xFF]) { walk(i + 1, closeness + s, sl) }   // some word starts so
                prefix.removeLast()
            }
        }
        walk(0, 0, 0)
        guard !found.isEmpty else { return [] }
        let p = probabilities(found.map { form($0.0) }, before: before)
        return zip(found, p).map { Reading(word: form($0.0.0), id: $0.0.0, closeness: $0.0.1, likelihood: log(max($0.1, 1e-12))) }
            .sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    // MARK: suggestions

    /// The best ways to finish `prefix` after `before` (the text before the word), most likely first, as they show
    /// ("I", "don't"). The prefix itself isn't one of them.
    func completions(_ prefix: String, before: String, limit: Int) -> [String] {
        guard !isEmpty, !prefix.isEmpty else { return [] }
        let k = Self.bytes(prefix), r = range(k)
        guard !r.isEmpty else { return [] }
        var best: [(Double, Int)] = []
        let nnp = nn?.next(after: before)
        scan(r, context(before)) { w, p in
            let s = blend(p, w, nnp)
            if best.count == limit, s <= best[limit - 1].0 { return }
            if compare(w, k) == 0 { return }
            let at = best.firstIndex { s > $0.0 } ?? best.count
            best.insert((s, w), at: at)
            if best.count > limit { best.removeLast() }
        }
        return best.map { form($0.1) }
    }

    /// P(word) after `before` for each word, as the bar ranks them (counts and network blended); 0 for a word it
    /// doesn't know.
    func probabilities(_ words: [String], before: String) -> [Double] {
        guard !isEmpty else { return words.map { _ in 0 } }
        let ctx = context(before), nnp = nn?.next(after: before)
        return words.map { word in
            guard let w = id(word) else { return 0 }
            var r = 0.0
            scan(w..<w + 1, ctx) { w, p in r = blend(p, w, nnp) }
            return r
        }
    }

    /// The likeliest next words after `before` (which ends with a space): the context's pairs (a triple kept for a
    /// word is always kept as a pair too), the most common words, and the network's favourites.
    func nextWords(before: String, limit: Int) -> [String] {
        guard !isEmpty else { return [] }
        let ctx = context(before), nnp = nn?.next(after: before)
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
                consider(w, blend(p(w, ctx, pair: count(biCounts, i), triple: triple), w, nnp))
            }
        }
        var extra = (0..<64).map { u16(top, $0) }
        if let nnp, let nn {   // the network's 16 likeliest words
            var picks: [(Float, Int)] = []
            for k in 4..<nn.V where picks.count < 16 || nnp[k] > picks[15].0 {
                picks.append((nnp[k], k)); picks.sort { $0.0 > $1.0 }
                if picks.count > 16 { picks.removeLast() }
            }
            extra += picks.compactMap { wordOfNetworkId[$0.1] >= 0 ? wordOfNetworkId[$0.1] : nil }
        }
        for w in extra {
            scan(w..<w + 1, ctx) { w, p in consider(w, blend(p, w, nnp)) }
        }
        return best.map { form($0.1) }
    }
}
