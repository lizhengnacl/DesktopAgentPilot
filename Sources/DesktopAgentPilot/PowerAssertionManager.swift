import Foundation
import IOKit.pwr_mgt

enum PowerAssertionState {
    case inactive
    case active
    case partial(detail: String)
    case unavailable(detail: String)
}

@MainActor
final class PowerAssertionManager {
    private var idleSleepAssertion: IOPMAssertionID = 0
    private var displaySleepAssertion: IOPMAssertionID = 0
    private(set) var state: PowerAssertionState = .inactive
    var stateChanged: ((PowerAssertionState) -> Void)?
    var isPreventingSleep: Bool {
        idleSleepAssertion != 0 || displaySleepAssertion != 0
    }

    func start() {
        stop(notify: false)

        let reason = "DesktopAgentPilot keeps the local AgentPilot service available while the service is running" as CFString
        let idleResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &idleSleepAssertion
        )
        let displayResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &displaySleepAssertion
        )

        if idleResult != kIOReturnSuccess {
            idleSleepAssertion = 0
        }
        if displayResult != kIOReturnSuccess {
            displaySleepAssertion = 0
        }

        switch (idleResult == kIOReturnSuccess, displayResult == kIOReturnSuccess) {
        case (true, true):
            setState(.active)
        case (true, false):
            setState(.partial(detail: "已阻止系统休眠，未能阻止屏幕关闭"))
        case (false, true):
            setState(.partial(detail: "已阻止屏幕关闭，未能阻止系统休眠"))
        case (false, false):
            setState(.unavailable(detail: "无法创建 macOS 电源断言"))
            return
        }
    }

    func stop() {
        stop(notify: true)
    }

    private func stop(notify: Bool) {
        if idleSleepAssertion != 0 {
            IOPMAssertionRelease(idleSleepAssertion)
            idleSleepAssertion = 0
        }
        if displaySleepAssertion != 0 {
            IOPMAssertionRelease(displaySleepAssertion)
            displaySleepAssertion = 0
        }
        if notify {
            setState(.inactive)
        } else {
            state = .inactive
        }
    }

    private func setState(_ nextState: PowerAssertionState) {
        state = nextState
        stateChanged?(nextState)
    }
}
