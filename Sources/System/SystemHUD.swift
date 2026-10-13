import AppKit
import CoreAudio
import CoreGraphics
import IOKit.ps

/// One volume or brightness reading, shown beside the notch for a moment.
struct HUDReading: Equatable {
    enum Kind: Equatable { case volume, brightness }
    var kind: Kind
    var level: Double          // 0...1
    var muted = false

    var symbol: String {
        switch kind {
        case .volume:
            if muted || level <= 0.001 { return "speaker.slash.fill" }
            if level < 0.34 { return "speaker.wave.1.fill" }
            if level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return level < 0.4 ? "sun.min.fill" : "sun.max.fill"
        }
    }
    var percent: Int { muted ? 0 : Int((level * 100).rounded()) }
}

/// Decides whether a stream of readings is a real change (a key press) or just noise
/// (a slow automatic drift, or the first reading after start).
struct LevelWatcher {
    private var samples: [(t: TimeInterval, v: Double)] = []
    let window: TimeInterval
    let threshold: Double

    init(window: TimeInterval = 0.6, threshold: Double = 0.03) {
        self.window = window
        self.threshold = threshold
    }

    /// Feed a reading; returns true when it moved enough, compared with `window` seconds ago.
    mutating func feed(_ v: Double, at t: TimeInterval) -> Bool {
        samples.append((t, v))
        samples.removeAll { t - $0.t > window + 0.3 }
        guard let base = samples.first(where: { t - $0.t <= window }) ?? samples.first else { return false }
        return samples.count > 1 && abs(v - base.v) >= threshold
    }
}

/// Watches the Mac's output volume (CoreAudio, no permission needed) and the built-in display's
/// brightness (polled a few times a second), and reports changes made with the keys.
@MainActor
final class SystemLevels {
    var onChange: ((HUDReading) -> Void)?
    private(set) var running = false

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var lastVolume: (level: Double, muted: Bool)?
    private var deviceChangedAt = Date.distantPast
    private var volumeBlock: AudioObjectPropertyListenerBlock?
    private var deviceBlock: AudioObjectPropertyListenerBlock?
    private var registered: [AudioObjectPropertyAddress] = []

    private var brightnessTimer: Timer?
    private var brightness = BrightnessReader()
    private var watcher = LevelWatcher()
    private var lastBrightness: Double?

    func start() {
        guard !running else { return }
        running = true
        watchDefaultDevice()
        attachToDefaultDevice()
        startBrightness()
    }

    func stop() {
        running = false
        detachFromDevice()
        if let b = deviceBlock {
            var a = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, b)
            deviceBlock = nil
        }
        brightnessTimer?.invalidate(); brightnessTimer = nil
    }

    // MARK: Volume

    private static func address(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private func watchDefaultDevice() {
        var a = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        a.mScope = kAudioObjectPropertyScopeGlobal
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.deviceChangedAt = Date()
                self.attachToDefaultDevice()
            }
        }
        deviceBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, block)
    }

    private func attachToDefaultDevice() {
        detachFromDevice()
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        a.mScope = kAudioObjectPropertyScopeGlobal
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return }
        device = id
        lastVolume = Self.readVolume(device: id)

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.volumeMoved() }
        }
        volumeBlock = block
        // main element, and the two channels for devices that only expose those
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                var addr = Self.address(selector, element: element)
                if AudioObjectHasProperty(id, &addr),
                   AudioObjectAddPropertyListenerBlock(id, &addr, .main, block) == noErr {
                    registered.append(addr)
                }
            }
        }
    }

    private func detachFromDevice() {
        if let block = volumeBlock, device != kAudioObjectUnknown {
            for var a in registered { AudioObjectRemovePropertyListenerBlock(device, &a, .main, block) }
        }
        registered = []
        volumeBlock = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func volumeMoved() {
        guard running, device != kAudioObjectUnknown, let now = Self.readVolume(device: device) else { return }
        defer { lastVolume = now }
        // switching headphones changes the level by itself; that is not a key press
        guard Date().timeIntervalSince(deviceChangedAt) > 0.8 else { return }
        if let last = lastVolume, abs(last.level - now.level) < 0.001, last.muted == now.muted { return }
        onChange?(HUDReading(kind: .volume, level: now.level, muted: now.muted))
    }

    static func readVolume(device: AudioObjectID) -> (level: Double, muted: Bool)? {
        var level: Double?
        var addr = address(kAudioDevicePropertyVolumeScalar)
        if AudioObjectHasProperty(device, &addr) {
            var v = Float32(0); var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v) == noErr { level = Double(v) }
        } else {
            var values: [Double] = []
            for ch in [1, 2] as [AudioObjectPropertyElement] {
                var a = address(kAudioDevicePropertyVolumeScalar, element: ch)
                guard AudioObjectHasProperty(device, &a) else { continue }
                var v = Float32(0); var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr { values.append(Double(v)) }
            }
            if !values.isEmpty { level = values.reduce(0, +) / Double(values.count) }
        }
        guard let level else { return nil }
        var muted = false
        var m = address(kAudioDevicePropertyMute)
        if AudioObjectHasProperty(device, &m) {
            var flag = UInt32(0); var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &m, 0, nil, &size, &flag) == noErr { muted = flag != 0 }
        }
        return (min(max(level, 0), 1), muted)
    }

    // MARK: Brightness

    private func startBrightness() {
        guard brightness.available else { return }
        lastBrightness = brightness.read()
        brightnessTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollBrightness() }
        }
        brightnessTimer?.tolerance = 0.05
    }

    private func pollBrightness() {
        guard running, let v = brightness.read() else { return }
        let moved = watcher.feed(v, at: Date().timeIntervalSinceReferenceDate)
        defer { lastBrightness = v }
        if moved, let last = lastBrightness, abs(last - v) > 0.0005 {
            onChange?(HUDReading(kind: .brightness, level: v))
        }
    }
}

// MARK: - Power

struct PowerState: Equatable {
    var pluggedIn: Bool
    var percent: Int
}

enum PowerEvent: Equatable { case pluggedIn(Int), unplugged(Int), low(Int), critical(Int) }

/// Turns two power readings into the one event worth showing, if any.
enum PowerEvents {
    static func next(from old: PowerState?, to new: PowerState) -> PowerEvent? {
        guard let old else { return nil }
        if old.pluggedIn != new.pluggedIn { return new.pluggedIn ? .pluggedIn(new.percent) : .unplugged(new.percent) }
        guard !new.pluggedIn else { return nil }
        if old.percent > 10, new.percent <= 10 { return .critical(new.percent) }
        if old.percent > 20, new.percent <= 20 { return .low(new.percent) }
        return nil
    }
}

/// Tells us when the charger is plugged in or pulled out, or the battery runs low. Driven by the system
/// (no polling); does nothing on a desktop Mac without a battery.
@MainActor
final class PowerWatcher {
    var onEvent: ((PowerEvent) -> Void)?
    private var source: CFRunLoopSource?
    private var last: PowerState?

    func start() {
        guard source == nil else { return }
        last = Self.read()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let s = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<PowerWatcher>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in me.changed() }
        }, ctx)?.takeRetainedValue() else { return }
        source = s
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode)
    }

    func stop() {
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode) }
        source = nil
    }

    private func changed() {
        guard let now = Self.read() else { return }
        defer { last = now }
        if let e = PowerEvents.next(from: last, to: now) { onEvent?(e) }
    }

    static func read() -> PowerState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return PowerState(pluggedIn: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue, percent: Int((Double(cur) / Double(max) * 100).rounded()))
        }
        return nil
    }
}

/// Reads the built-in display's brightness through the system's display service.
struct BrightnessReader {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private let getFn: GetFn?
    private let display: CGDirectDisplayID?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        getFn = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var n: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &n)
        display = ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    var available: Bool { getFn != nil && display != nil && read() != nil }

    func read() -> Double? {
        guard let getFn, let display else { return nil }
        var v: Float = 0
        return getFn(display, &v) == 0 ? Double(v) : nil
    }
}
