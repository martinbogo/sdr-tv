import Foundation

/// A program to record, from the guide or "Record This Program".
struct ScheduledRecording: Codable, Identifiable, Hashable {
    enum State: String, Codable { case scheduled, recording, done, failed, missed }

    var id = UUID()
    var channelID: String          // "6.1"
    var channelName: String
    var rf: Int
    var program: Int
    var title: String
    var start: Date
    var end: Date
    var state: State = .scheduled
    var file: String?
    var note: String?

    /// Recording starts a minute early and runs two minutes over (broadcast schedules drift).
    static let preRoll: TimeInterval = 60, postRoll: TimeInterval = 120
    var recordFrom: Date { start.addingTimeInterval(-Self.preRoll) }
    var recordUntil: Date { end.addingTimeInterval(Self.postRoll) }
}

/// The schedule, kept in Application Support/SDR TV/recordings.json.
final class RecordingSchedule {
    private(set) var items: [ScheduledRecording] = []
    private let url = Library.folder.appendingPathComponent("recordings.json")

    init() {
        if let d = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([ScheduledRecording].self, from: d) { items = list }
        // anything that should have run while the app was not running was missed
        for i in items.indices where items[i].state == .scheduled && items[i].recordUntil < Date() {
            items[i].state = .missed; items[i].note = "SDR TV was not running"
        }
        for i in items.indices where items[i].state == .recording {
            items[i].state = .failed; items[i].note = "SDR TV quit during the recording"
        }
        save()
    }

    func save() { if let d = try? JSONEncoder().encode(items) { try? d.write(to: url) } }

    func add(_ r: ScheduledRecording) { items.append(r); items.sort { $0.start < $1.start }; save() }
    func remove(_ id: UUID) { items.removeAll { $0.id == id }; save() }
    func update(_ r: ScheduledRecording) { if let i = items.firstIndex(where: { $0.id == r.id }) { items[i] = r; save() } }

    func scheduled(channelID: String, start: Date) -> ScheduledRecording? {
        items.first { $0.channelID == channelID && abs($0.start.timeIntervalSince(start)) < 60 && ($0.state == .scheduled || $0.state == .recording) }
    }

    /// Scheduled recordings on another RF channel at the same time (one tuner receives one RF channel).
    func conflicts(with r: ScheduledRecording) -> [ScheduledRecording] {
        items.filter { $0.id != r.id && ($0.state == .scheduled || $0.state == .recording) && $0.rf != r.rf
            && $0.recordFrom < r.recordUntil && r.recordFrom < $0.recordUntil }
    }

    /// Old finished entries are dropped after two weeks.
    func prune() {
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        let before = items.count
        items.removeAll { $0.end < cutoff && $0.state != .scheduled }
        if items.count != before { save() }
    }
}
