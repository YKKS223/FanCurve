import Foundation
import FanCurveKit

/// Records temperatures and fan speeds to a TSV, reading only.
///
/// This exists to answer one question that cannot be answered while anything is driving the
/// fans: with `F%dMd` at its firmware default and `F%dTg` at 0, does the Mac's own controller
/// actually spin the fans up under sustained load? Every value here comes from a read; this
/// command never calls an SMC write path, and never talks to the daemon.
enum Watch {

    private struct Sample {
        let elapsed: Double
        let cpu, gpu, soc, ssd, ambient, systemMax: Double
        let rpm: [Int: Double]
        let target: [Int: Double]
        let mode: [Int: UInt8]
        let watts: Double
    }

    static func run(seconds: Int, path: String) -> Int32 {
        let catalog = SensorCatalog()
        catalog.discover()
        let fc = FanController()
        fc.enumerateFans()

        guard !catalog.sensors.isEmpty else {
            print("温度センサーを検出できませんでした。")
            return 1
        }

        print("記録を開始します（読み取りのみ・\(seconds) 秒・Ctrl-C で中断）")
        print("出力: \(path)")
        print("センサー \(catalog.sensors.count) 個 / ファン \(fc.fans.count) 基\n")

        let fanIndices = fc.fans.map(\.index)
        var header = ["elapsed", "time", "cpu", "gpu", "soc", "ssd", "ambient", "sysmax", "watts", "ftst"]
        for i in fanIndices { header += ["f\(i)_rpm", "f\(i)_tg", "f\(i)_md"] }

        guard FileManager.default.createFile(atPath: path, contents: nil),
              let handle = FileHandle(forWritingAtPath: path) else {
            print("ファイルを作成できません: \(path)")
            return 1
        }
        func emit(_ line: String) {
            handle.write((line + "\n").data(using: .utf8)!)
        }
        emit(header.joined(separator: "\t"))

        let started = Date()
        var samples: [Sample] = []
        let formatter = ISO8601DateFormatter()

        while Date().timeIntervalSince(started) < Double(seconds) {
            let readings = catalog.readAll()
            let elapsed = Date().timeIntervalSince(started)
            func groupMax(_ g: SensorGroup) -> Double { catalog.maxOf(group: g, in: readings) ?? -1 }

            var rpm: [Int: Double] = [:], target: [Int: Double] = [:], mode: [Int: UInt8] = [:]
            for i in fanIndices {
                rpm[i] = fc.actualRPM(i)
                target[i] = fc.targetRPM(i)
                mode[i] = fc.modeByte(i)
            }

            let s = Sample(elapsed: elapsed,
                           cpu: groupMax(.cpu), gpu: groupMax(.gpu), soc: groupMax(.soc),
                           ssd: groupMax(.ssd), ambient: groupMax(.ambient),
                           systemMax: catalog.systemMax(in: readings) ?? -1,
                           rpm: rpm, target: target, mode: mode,
                           watts: SMC.shared.readDouble("PSTR") ?? -1)
            samples.append(s)

            var row = [String(format: "%.0f", s.elapsed), formatter.string(from: Date())]
            row += [s.cpu, s.gpu, s.soc, s.ssd, s.ambient, s.systemMax, s.watts]
                .map { String(format: "%.1f", $0) }
            row.append(String(fc.forceTestValue() ?? 255))
            for i in fanIndices {
                row += [String(format: "%.0f", rpm[i] ?? 0),
                        String(format: "%.0f", target[i] ?? 0),
                        String(mode[i] ?? 0)]
            }
            emit(row.joined(separator: "\t"))

            if Int(elapsed) % 10 == 0 {
                let fans = fanIndices.map { String(format: "fan%d %4.0f rpm", $0, rpm[$0] ?? 0) }
                    .joined(separator: "  ")
                print(String(format: "%4.0f s  最高 %5.1f °C  CPU %5.1f  %5.1f W  %@",
                             elapsed, s.systemMax, s.cpu, s.watts, fans))
                fflush(stdout)
            }
            Thread.sleep(forTimeInterval: 1.0)
        }

        handle.closeFile()
        summarise(samples, fanIndices: fanIndices, path: path)
        return 0
    }

    private static func summarise(_ samples: [Sample], fanIndices: [Int], path: String) {
        guard !samples.isEmpty else { return }
        print("\n=== まとめ ===")
        print(String(format: "サンプル数        : %d 個 (%.0f 秒)", samples.count, samples.last!.elapsed))
        print(String(format: "システム最高温度  : %.1f °C (平均 %.1f °C)",
                     samples.map(\.systemMax).max() ?? 0,
                     samples.map(\.systemMax).reduce(0, +) / Double(samples.count)))
        print(String(format: "最大消費電力      : %.1f W", samples.map(\.watts).max() ?? 0))

        for i in fanIndices {
            let speeds = samples.compactMap { $0.rpm[i] }
            let peak = speeds.max() ?? 0
            print(String(format: "fan%d 最大回転数   : %.0f rpm", i, peak))

            // The number that matters: how hot it got before the firmware did anything.
            if let firstSpin = samples.first(where: { ($0.rpm[i] ?? 0) > 100 }) {
                print(String(format: "fan%d 回り始め     : %.0f 秒時点 / そのとき %.1f °C",
                             i, firstSpin.elapsed, firstSpin.systemMax))
            } else {
                let hottest = samples.map(\.systemMax).max() ?? 0
                print(String(format: "fan%d 回り始め     : 一度も回らず（最高 %.1f °C まで到達）", i, hottest))
            }

            let modes = Set(samples.compactMap { $0.mode[i] })
            print("fan\(i) F\(i)Md        : \(modes.sorted().map(String.init).joined(separator: ", "))")
        }
        print("\nTSV: \(path)")
    }
}
