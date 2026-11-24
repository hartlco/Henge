import SwiftUI
import UIKit
import GameController

/// What this device is, for what the app says and suggests.
enum Device {
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    static let name = isPad ? "iPad" : "iPhone"

    /// A Mac's screen that fills this device on its side: 1920 wide, as tall as the shape asks. iPads and
    /// squarer phones (iPhone Duo, about 1.46:1) would get bars above and below at 16:9. Phones wider
    /// than 16:9 come out at 1920×1080, as before.
    static var fittingScreen: (width: Int, height: Int) {
        let size = UIScreen.main.bounds.size
        let shape = max(size.width, size.height) / max(min(size.width, size.height), 1)
        return (1920, min(max(Int((1920 / shape / 8).rounded()) * 8, 1080), 1440))
    }

    /// Preserve the iPad's shape while reducing the virtual GPU's pixel work.
    static var performanceScreen: (width: Int, height: Int) {
        let fit = fittingScreen
        return (1600, Int((Double(fit.height) * 5 / 6 / 8).rounded()) * 8)
    }

    /// The panel itself, on its side: every physical pixel, and its real size in mm so that macOS
    /// sees a Retina density and draws at 2x (looks like half the pixels, sharp as the iPad's own UI).
    /// Every iPad with an M chip is 264 ppi.
    static var retinaScreen: (width: Int, height: Int) {
        let n = UIScreen.main.nativeBounds.size
        return (Int(max(n.width, n.height)), Int(min(n.width, n.height)))
    }
    static var retinaMM: (width: Int, height: Int) {
        let s = retinaScreen
        return (Int((Double(s.width) / 264 * 25.4).rounded()), Int((Double(s.height) / 264 * 25.4).rounded()))
    }

    /// How much memory to suggest for a new Mac: what leaves this device room for iOS.
    static var suggestedRAMGB: Int {
        let mb = ProcessInfo.processInfo.physicalMemory >> 20
        // m4 fork: an 8 GB iPad (7.4 GB usable) thrashes and kills the Mac at 6 GB: 16 GB devices only.
        // A 6 GB device (5.7 GB usable) could not build a 4 GB Mac, and installed a 3 GB one (#70); 4 GB devices, 2.
        return mb >= 14_000 ? 8 : mb >= 10_000 ? 6 : mb >= 7_000 ? 4 : mb >= 5_000 ? 3 : 2
    }

    /// The choices for a Mac's memory, in GB.
    static let memoryChoices = 1...16

    /// What a choice risks on this device, if anything. An install always gets at least 2 GB (Installer.install).
    static func memoryNote(_ gb: Int) -> String? {
        if gb < 4 { return "macOS has little room under 4 GB, so it can be very slow." }
        if gb > suggestedRAMGB { return "More than \(suggestedRAMGB) GB is a lot for this \(name): iOS may close Henge when macOS gets busy." }
        return nil
    }

    /// The virtual CPU offers Armv8.5 instructions (core/sysreg.c), and macOS uses them. They run as
    /// they are, so the chip needs them too: A14, M1 and later, which is iPhone13,x and iPad13,x up.
    static let chipTooOld: Bool = {
        let model = HengeLog.deviceModel
        guard model.hasPrefix("iPhone") || model.hasPrefix("iPad"),
              let major = Int(model.drop { !$0.isNumber }.prefix { $0.isNumber }) else { return false }
        return major < 13
    }()

    static let chipTooOldText = "macOS won't run on this \(name). Henge needs an A14 or M1 chip or newer."

    /// What this device is called and the chip it has, for a Mac that reports its host
    /// (MacSettingsView → About This Mac). The table and the icon-snapping live in
    /// DeviceIdentity.swift (pure Foundation, so the Mac tests can compile it).
    static var modelIdentifier: String { HengeLog.deviceModel }
    static var marketingName: String { DeviceIdentity.name(modelIdentifier) }
    static var chipName: String? { DeviceIdentity.chip(modelIdentifier) }

    /// The model identifier to report for a matching icon: the real one when the guest
    /// macOS knows it, else the newest equivalent it recognises (see DeviceIdentity).
    static func snappedModelIdentifier(forOS osName: String?) -> String {
        DeviceIdentity.snappedIdentifier(modelIdentifier, forOS: osName)
    }
}

/// A physical keyboard. iOS and the Mac's USB keyboard use the same HID codes for each key.
enum HardwareKeys {
    private static var mapper = HardwareShortcutMapper()
    private static var lastKey: CFTimeInterval = 0

    /// With the on-screen keyboard's view holding the keyboard, iOS may also offer a hardware key as
    /// text, and again as it repeats. The Mac has the key already, and repeats it itself.
    static var keyJustPressed: Bool {
        mapper.hasHeldKey || CACurrentMediaTime() - lastKey < 0.1
    }

    /// Sends the presses that are keys, and returns the rest.
    static func send(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        var rest = Set<UIPress>()
        // A chord can arrive in one unordered Set. Press modifiers first and
        // release them last so the guest sees the intended shortcut.
        let ordered = presses.sorted { a, b in
            let aCode = a.key?.keyCode.rawValue ?? 0
            let bCode = b.key?.keyCode.rawValue ?? 0
            let aModifier = (0xe0...0xe7).contains(aCode)
            let bModifier = (0xe0...0xe7).contains(bCode)
            if aModifier != bModifier { return down ? aModifier : !aModifier }
            return aCode < bCode
        }
        let defaults = UserDefaults.standard
        for press in ordered {
            guard let raw = press.key?.keyCode.rawValue, raw >= 0x04, raw <= 0xe7 else {
                rest.insert(press)
                continue
            }
            let usage = UInt8(raw)
            let events = mapper.event(usage, down: down) { shortcut in
                // The keys above the on-screen keyboard can already be holding a modifier in the Mac.
                StickyKeys.shared.down.isEmpty && defaults.bool(forKey: shortcut.defaultsKey)
            }
            for event in events {
                henge_vm_key_hid(event.usage, event.down ? 1 : 0)
            }
            if usage < 0xe0 { lastKey = CACurrentMediaTime() }
            if !down && usage < 0xe0 { StickyKeys.shared.releaseAll() } // one key after a tap on ⌃, ⌥ or ⌘
        }
        return rest
    }

    /// iPadOS can keep a key's release when it takes over, as it does for ⌘-Tab: the Mac must not
    /// go on thinking the key is down.
    static func releaseAll() {
        for event in mapper.releaseAll() { henge_vm_key_hid(event.usage, 0) }
    }
}

/// Asks iPadOS to hand the pointer over, so a trackpad or mouse drives only the Mac's pointer. It does
/// that only for an app filling the screen. SwiftUI has no way to ask, so the answer is added to the
/// class of the window's root view controller, which is who iPadOS asks.
enum PointerLock {
    private static var wanted = false
    private static var patched: Set<ObjectIdentifier> = []

    static func set(_ on: Bool) {
        wanted = on
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            guard let root = window.rootViewController else { continue }
            let kind: AnyClass = type(of: root)
            if patched.insert(ObjectIdentifier(kind)).inserted {
                let answer: @convention(block) (UIViewController) -> Bool = { vc in wanted && fillsScreen(vc.viewIfLoaded?.window) }
                class_replaceMethod(kind, #selector(getter: UIViewController.prefersPointerLocked), imp_implementationWithBlock(answer), "B@:")
            }
            root.setNeedsUpdateOfPrefersPointerLocked()
            if window.isKeyWindow {
                let ask = on && fillsScreen(window)
                if ask != lastAsked {
                    lastAsked = ask
                    HengeLog.log("input", "pointer lock \(ask ? "asked for" : "not asked for"): window \(Int(window.bounds.width))x\(Int(window.bounds.height)) of \(Int(window.screen.bounds.width))x\(Int(window.screen.bounds.height))")
                }
            }
        }
    }
    private static var lastAsked: Bool?

    /// Only an app that fills the screen asks for the lock. In a Stage Manager window iPadOS can grant it and still
    /// move its hidden pointer to the screen's edges, bringing out the stage strip and the dock at every move; there
    /// the Mac's pointer follows the iPad's instead (AbsolutePointer).
    static func fillsScreen(_ window: UIWindow?) -> Bool {
        guard let window else { return false }
        let mine = window.bounds.size, screen = window.screen.bounds.size
        return abs(mine.width - screen.width) < 1 && abs(mine.height - screen.height) < 1
    }

    /// Whether iPadOS has the pointer locked to the Mac right now.
    static var isLocked: Bool {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .contains { $0.activationState == .foregroundActive && $0.pointerLockState?.isLocked == true }
    }
}

/// A Magic Keyboard's trackpad or a mouse, while a Mac is running. GameController gives the raw motion,
/// which macOS then accelerates as it would for its own mouse.
final class HardwareMouse {
    static let shared = HardwareMouse()
    static let speedKey = "henge.mouse.speed"
    static let reverseKey = "henge.mouse.reverse"
    static let scrollSpeedKey = "henge.mouse.scrollSpeed"
    static let twoFingerScrollKey = "henge.mouse.twoFingerScroll"

    private var observers: [NSObjectProtocol] = []
    private var mice: [GCMouse] = []
    private var buttons = PhysicalMouseButtons(swapsRightAndMiddle: false)
    private var buttonsLogged = 0
    private var restX: Float = 0, restY: Float = 0
    private var speed: Float = 1
    private var scrollScale: Float = 1
    private var twoFingerScroll = false
    private var wheel = ScrollWheel()
    private let scrollFingers = ScrollFingers()
    /// Click steadying. Pressing a trackpad rolls the finger a little, and iPadOS reports that as motion just
    /// before, during and after the press; a Mac's own trackpad drops it. The steps sent lately, to take back at a
    /// press, and the motion held back while a button is down, until it is clearly a drag.
    private var recentSteps: [(t: CFTimeInterval, x: Int32, y: Int32)] = []
    private var heldSteps: [(x: Int32, y: Int32)] = []
    private var heldX: Int32 = 0, heldY: Int32 = 0
    private var dragging = false
    private static let undoWindow: CFTimeInterval = 0.06
    private static let undoLimit: Int32 = 6   // pixels: more than this before a press was meant
    private static let dragStart: Int32 = 8   // pixels with a button down before it counts as a drag

    func start() {
        guard observers.isEmpty else { PointerLock.set(true); return }
        let defaults = UserDefaults.standard
        speed = defaults.object(forKey: Self.speedKey) == nil ? 1 : Float(defaults.double(forKey: Self.speedKey))
        updateScrollSettings()
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateScrollSettings()
        })
        releaseButtons()
        let swapButtons = defaults.bool(forKey: PhysicalMouseButtons.swapKey)
        buttons = PhysicalMouseButtons(swapsRightAndMiddle: swapButtons)
        buttonsLogged = 0
        HengeLog.log("input", "physical mouse: swap right/middle \(swapButtons ? "on" : "off")")
        GCMouse.mice().forEach(attach)
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            if let mouse = note.object as? GCMouse { self?.attach(mouse) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let mouse = note.object as? GCMouse else { return }
            self.releaseButtons()
            self.mice.removeAll { $0 === mouse }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIPointerLockState.didChangeNotification, object: nil, queue: .main) { note in
            // The scene comes in the user info: the notification's object isn't it.
            let scene = note.userInfo?[UIPointerLockState.sceneUserInfoKey] as? UIScene
            let locked = scene?.pointerLockState?.isLocked ?? false
            HengeLog.log("input", "pointer lock: \(locked ? "on" : "off")")
        })
        PointerLock.set(true)
    }

    func stop() {
        PointerLock.set(false)
        releaseButtons()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for mouse in mice {
            guard let input = mouse.mouseInput else { continue }
            input.mouseMovedHandler = nil
            input.leftButton.pressedChangedHandler = nil
            input.rightButton?.pressedChangedHandler = nil
            input.middleButton?.pressedChangedHandler = nil
            input.scroll.xAxis.valueChangedHandler = nil
            input.scroll.yAxis.valueChangedHandler = nil
        }
        mice.removeAll()
    }

    func releaseButtons() {
        for button in buttons.releaseAll() { henge_vm_mouse_button(button, 0) }
        recentSteps.removeAll()
        resetDrag()
        wheel = ScrollWheel()
        scrollFingers.end()
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput, !mice.contains(where: { $0 === mouse }) else { return }
        mice.append(mouse)
        HengeLog.log("input", "mouse: \(mouse.vendorName ?? "?"), right button \(input.rightButton != nil), middle \(input.middleButton != nil)")
        input.mouseMovedHandler = { [weak self] _, dx, dy in self?.moved(dx, dy) }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(0, pressed) }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(1, pressed) }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(2, pressed) }
        // The combined callback carries the previous value of the other axis.
        // Each axis callback identifies the delta that actually belongs to this sample.
        input.scroll.xAxis.valueChangedHandler = { [weak self, weak input] _, value in
            guard let input else { return }
            self?.scrolled(dx: 0, dy: value, time: input.lastEventTimestamp, stopped: value == 0 && input.scroll.yAxis.value == 0)
        }
        input.scroll.yAxis.valueChangedHandler = { [weak self, weak input] _, value in
            guard let input else { return }
            self?.scrolled(dx: value, dy: 0, time: input.lastEventTimestamp, stopped: value == 0 && input.scroll.xAxis.value == 0)
        }
    }

    /// GameController's Y runs upward. What doesn't make a whole step yet waits for the next move.
    /// While iPadOS won't lock the pointer, the Mac's pointer follows the iPad's (AbsolutePointer) instead.
    private func moved(_ dx: Float, _ dy: Float) {
        guard !AbsolutePointer.inUse else { return }
        restX += dx * speed
        restY -= dy * speed
        let x = restX.rounded(), y = restY.rounded()
        guard x != 0 || y != 0 else { return }
        restX -= x
        restY -= y
        step(Int32(x), Int32(y))
    }

    private func step(_ x: Int32, _ y: Int32) {
        if !buttons.held.isEmpty && !dragging {
            heldSteps.append((x, y))
            heldX += x
            heldY += y
            guard max(abs(heldX), abs(heldY)) > Self.dragStart else { return }
            // A drag after all: the held motion goes now, in the steps it came in.
            dragging = true
            for held in heldSteps { henge_vm_mouse_move(held.x, held.y) }
            heldSteps.removeAll()
            return
        }
        let now = CACurrentMediaTime()
        recentSteps.append((now, x, y))
        recentSteps.removeAll { now - $0.t > Self.undoWindow }
        henge_vm_mouse_move(x, y)
    }

    /// At a press: take back the last few steps if they add up to only a nudge, the finger rolling as it pressed.
    /// Sent back step by step, newest first, so macOS's pointer acceleration treats them the same as on the way.
    private func steadyForPress() {
        let now = CACurrentMediaTime()
        let nudge = recentSteps.filter { now - $0.t <= Self.undoWindow }
        recentSteps.removeAll()
        let sumX = nudge.reduce(Int32(0)) { $0 + $1.x }, sumY = nudge.reduce(Int32(0)) { $0 + $1.y }
        guard !nudge.isEmpty, max(abs(sumX), abs(sumY)) <= Self.undoLimit else { return }
        for back in nudge.reversed() { henge_vm_mouse_move(-back.x, -back.y) }
    }

    private func button(_ physicalButton: Int32, _ pressed: Bool) {
        let wasUp = buttons.held.isEmpty
        guard let guestButton = buttons.event(physicalButton, pressed: pressed) else { return }
        if buttonsLogged < 32 {
            buttonsLogged += 1
            HengeLog.log("input", "physical mouse button: raw=\(physicalButton) guest=\(guestButton) \(pressed ? "down" : "up")")
        }
        if pressed && wasUp {
            resetDrag()
            if !AbsolutePointer.inUse { steadyForPress() }
        } else if !pressed && buttons.held.isEmpty {
            recentSteps.removeAll()
            resetDrag()
        }
        henge_vm_mouse_button(guestButton, pressed ? 1 : 0)
        if !pressed { StickyKeys.shared.releaseAll() }
    }

    private func resetDrag() {
        dragging = false
        heldSteps.removeAll()
        heldX = 0
        heldY = 0
    }

    private func updateScrollSettings() {
        let defaults = UserDefaults.standard
        let configured = defaults.object(forKey: Self.scrollSpeedKey) == nil
            ? 0.3 : defaults.double(forKey: Self.scrollSpeedKey)
        let scale = Float(configured.isFinite ? min(max(configured, 0.1), 1.5) : 0.3)
        let newScale = (defaults.bool(forKey: Self.reverseKey) ? -scale : scale) / 0.3
        let newMode = defaults.bool(forKey: Self.twoFingerScrollKey)
        if observers.isEmpty || newMode != twoFingerScroll {
            HengeLog.log("input", "hardware scrolling: \(newMode ? "two-finger gesture" : "wheel steps")")
        }
        if newMode != twoFingerScroll || newScale != scrollScale {
            scrollFingers.end()
            wheel = ScrollWheel()
        }
        twoFingerScroll = newMode
        scrollScale = newScale
    }

    private func scrolled(dx: Float, dy: Float, time: TimeInterval, stopped: Bool) {
        if !twoFingerScroll {
            let step = wheel.move(dx: dx, dy: dy, scale: scrollScale, at: CACurrentMediaTime())
            if step.x != 0 || step.y != 0 { henge_vm_scroll_step(step.x, step.y) }
        } else if stopped {
            scrollFingers.releaseSoon(at: time)
        } else {
            // The host reports content motion. Guest fingers move in the opposite direction.
            scrollFingers.move(dx: dx * -40 * scrollScale, dy: dy * -40 * scrollScale, at: time)
        }
    }
}

/// In a window (Stage Manager, or iPadOS's windowed apps) iPadOS won't lock the pointer, so the iPad's pointer
/// stays on screen and the Mac's has to follow it: over the Mac's screen, the pointer's place goes to the Mac's
/// absolute pointer (a USB tablet), and the iPad's own is hidden there (Trackpad's pointer style). Clicks and
/// scrolling still come from GameController.
enum AbsolutePointer {
    /// Where the Mac's screen is, in the session's coordinates (the window's); nil when it isn't on this
    /// screen (an external display) or there is no session.
    static var screen: CGRect?
    private static var lastInUse: Bool?

    static var inUse: Bool {
        let now = Device.isPad && screen != nil && !PointerLock.isLocked
        if now != lastInUse {
            lastInUse = now
            HengeLog.log("input", "absolute pointer: \(now ? "on (the pointer isn't locked)" : "off")")
        }
        return now
    }

    /// The iPad's pointer is at p: put the Mac's there too, if p is over the Mac's screen.
    static func move(to p: CGPoint) {
        guard inUse, let screen, screen.width > 0, screen.height > 0, screen.contains(p) else { return }
        henge_vm_pointer_at(Double((p.x - screen.minX) / screen.width), Double((p.y - screen.minY) / screen.height))
    }
}
