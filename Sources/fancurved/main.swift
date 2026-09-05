import Foundation
import FanCurveKit

setvbuf(stdout, nil, _IOLBF, 0)

let configPath = ProcessInfo.processInfo.environment["FANCURVE_CONFIG"] ?? AppConfig.defaultPath
let socketPath = ProcessInfo.processInfo.environment["FANCURVE_SOCKET"] ?? IPC.socketPath

/// Only one instance may drive the SMC at a time.
///
/// With `ThrottleInterval=1`, launchd restarts this daemon in ~0.12 s — fast enough that the
/// replacement was observed starting while the outgoing one was still writing its release.
/// Two processes writing fan keys at once is a bug factory, so the new instance waits for the
/// old one's lock instead, and gives up to let launchd retry if it never comes.
func acquireInstanceLock(path: String, timeout: Double) -> Int32? {
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return nil }
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
        usleep(50_000)
    } while Date() < deadline
    close(fd)
    return nil
}

let lockPath = ProcessInfo.processInfo.environment["FANCURVE_LOCK"] ?? "/var/run/fancurved.lock"
guard let instanceLock = acquireInstanceLock(path: lockPath, timeout: 25) else {
    FileHandle.standardError.write(
        "先行するデーモンが終了しないためロックを取得できませんでした。launchd の再試行に任せます。\n"
            .data(using: .utf8)!)
    exit(1)
}

let daemon = Daemon(configPath: configPath)

if geteuid() != 0 {
    daemon.log("警告: root で実行されていません。読み取りのみ可能で、ファン制御はできません。")
}

do {
    try daemon.start()
} catch {
    daemon.log("起動失敗: \(error)")
    exit(1)
}

// FANCURVE_VERBOSE=1 logs every request; useful when checking that the GUI is talking to us.
let verbose = ProcessInfo.processInfo.environment["FANCURVE_VERBOSE"] == "1"

let server = SocketServer(path: socketPath) { request in
    if verbose { daemon.log("要求: \(request.cmd.rawValue)") }
    return daemon.handle(request)
}

do {
    try server.start()
    daemon.log("ソケット待ち受け開始: \(socketPath)")
} catch {
    daemon.log("ソケットを開けません: \(error)")
    daemon.shutdown()
    exit(1)
}

var signalSources: [DispatchSourceSignal] = []

// Restore firmware fan control on any orderly exit, including launchd's SIGTERM.
var didCleanUp = false
let cleanUpLock = NSLock()
func cleanUp() {
    cleanUpLock.lock(); defer { cleanUpLock.unlock() }
    guard !didCleanUp else { return }
    didCleanUp = true
    daemon.shutdown()
    server.stop()
}

for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        daemon.log("シグナル \(sig) を受信、終了します")
        cleanUp()
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

atexit { cleanUp() }

daemon.log("fancurved \(IPC.version) 稼働中 (pid \(getpid()))")
dispatchMain()
