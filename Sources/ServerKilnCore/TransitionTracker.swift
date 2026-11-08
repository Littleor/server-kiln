import Foundation

public enum ServerActivity: String, Codable, Sendable {
    case busy, idle, cpuOnly, offline
}

public struct ActivityTransition: Equatable, Sendable {
    public var serverID: UUID
    public var from: ServerActivity
    public var to: ServerActivity
}

/// Debounces activity changes: a new state must be observed `requiredStreak`
/// times in a row before it becomes the confirmed state and a transition is
/// reported. The very first observation is adopted silently.
public struct TransitionTracker: Sendable {
    public var requiredStreak: Int
    private var confirmed: [UUID: ServerActivity] = [:]
    private var pending: [UUID: (ServerActivity, Int)] = [:]

    public init(requiredStreak: Int = 2) {
        self.requiredStreak = max(1, requiredStreak)
    }

    public mutating func observe(_ id: UUID, _ activity: ServerActivity) -> ActivityTransition? {
        guard let current = confirmed[id] else {
            confirmed[id] = activity
            return nil
        }
        if activity == current {
            pending[id] = nil
            return nil
        }
        let streak = (pending[id]?.0 == activity ? pending[id]!.1 : 0) + 1
        if streak >= requiredStreak {
            confirmed[id] = activity
            pending[id] = nil
            return ActivityTransition(serverID: id, from: current, to: activity)
        }
        pending[id] = (activity, streak)
        return nil
    }

    public mutating func forget(_ id: UUID) {
        confirmed[id] = nil
        pending[id] = nil
    }
}
