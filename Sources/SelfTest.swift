import AppKit
import Carbon.HIToolbox

enum TilesTest {
    static func run() -> Never {
        var fails = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "ok   " : "FAIL ", what)
            if !ok { fails += 1 }
        }
        // Layouts in Cocoa coordinates on a 1000x800 area.
        let a = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let m = Tiling.master.rects(count: 3, area: a, ratio: 0.6, gap: 0)
        check(m[0] == CGRect(x: 0, y: 0, width: 600, height: 800) && m[1].minY == 400 && m[2].minY == 0,
              "master & stack: master left, stack top to bottom")
        check(Tiling.master.rects(count: 1, area: a, ratio: 0.6, gap: 0) == [a], "one window fills the screen")
        let g = Tiling.grid.rects(count: 3, area: a, ratio: 0.5, gap: 0)
        check(g[2].width == 1000 && g[0].width == 500, "grid: last row stretches")
        check(Tiling.columns.rects(count: 4, area: a, ratio: 0.5, gap: 10)[1].minX == 255, "columns with gaps")
        check(Tiling.rows.rects(count: 2, area: a, ratio: 0.5, gap: 0)[0].minY == 400, "rows: first is on top")
        check(Tiling.monocle.rects(count: 3, area: a, ratio: 0.5, gap: 0).allSatisfy { $0 == a }, "monocle")
        check(Tiling.master.rects(count: 2, area: a, ratio: 0.99, gap: 0)[0].width == 850, "ratio is clamped")

        let tiles = [CGRect(x: 0, y: 0, width: 500, height: 800), CGRect(x: 500, y: 400, width: 500, height: 400),
                     CGRect(x: 500, y: 0, width: 500, height: 400)]
        check(nearest(of: tiles[1], in: "down", among: tiles) == 2, "neighbour below")
        check(nearest(of: tiles[1], in: "left", among: tiles) == 0, "neighbour left")
        check(nearest(of: tiles[0], in: "left", among: tiles) == nil, "nothing further left")

        check(Tiling(key: "cols") == .columns && Tiling(key: "nope") == nil, "layout names")
        let t = Tiler()
        check(!t.perform("dance") && !t.perform("focus sideways") && !t.perform("layout nope"), "unknown actions rejected")
        for (combo, action) in TilesConfig.defaultHotkeys {
            check(HotKeys.parse(combo) != nil, "default hotkey parses: \(combo) → \(action)")
        }

        print(fails == 0 ? "\nall passed" : "\n\(fails) failed")
        exit(fails == 0 ? 0 : 1)
    }
}
