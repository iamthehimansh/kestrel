import Foundation
import KestrelKeymap

/// Owns the engine and its clock: feeds events in, flushes ops to the sink, and runs the
/// ~120 Hz tick that turbo/swipe/macro/stick-look need. All engine access happens on `queue`.
public final class Driver {
    public let engine: KeymapEngine
    private let sink: TouchSink
    private let queue = DispatchQueue(label: "kestrel.driver", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let start = DispatchTime.now().uptimeNanoseconds
    public var onError: ((Error) -> Void)?
    /// When set, every input event is also recorded (for `kestrel play --record`).
    public let recorder: InputRecorder?

    public init(engine: KeymapEngine, sink: TouchSink, recorder: InputRecorder? = nil) {
        self.engine = engine
        self.sink = sink
        self.recorder = recorder
    }

    private var nowMs: Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }

    public func post(_ event: InputEvent) {
        recorder?.record(event)
        queue.async { [self] in flush(engine.handle(event, at: nowMs)) }
    }

    /// Plays a recording back in real time through the engine and sink, then lifts every
    /// finger. Blocks the calling thread for the recording's duration.
    public func replay(_ recording: InputRecording) {
        startTicking()
        let t0 = DispatchTime.now()
        for e in recording.entries {
            let due = t0 + .nanoseconds(Int(e.t * 1_000_000))
            let wait = Int64(due.uptimeNanoseconds) - Int64(DispatchTime.now().uptimeNanoseconds)
            if wait > 0 { usleep(UInt32(min(wait / 1000, Int64(UInt32.max)))) }
            post(e.event)
        }
        // Let the last gestures (swipes, macros) finish.
        usleep(1_000_000)
    }

    public func startTicking(hz: Double = 120) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1 / hz, leeway: .microseconds(500))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.flush(self.engine.tick(at: self.nowMs))
        }
        t.resume()
        timer = t
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            flush(engine.handle(.reset, at: nowMs))
        }
        sink.close()
    }

    public func sync<T>(_ body: (KeymapEngine) -> T) -> T { queue.sync { body(engine) } }

    private func flush(_ ops: [TouchOp]) {
        guard !ops.isEmpty else { return }
        do { try sink.send(ops) } catch { onError?(error) }
    }
}
