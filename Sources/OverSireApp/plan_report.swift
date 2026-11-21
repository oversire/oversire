import Foundation
import OverSireCore

// The plan as JSON, for the read actions epic.show and epic.plan. Days are YYYY-MM-DD in the calendar of the Mac.
extension PlanModel {
    func isoDay(_ day: PlanDay) -> String {
        let cal = Calendar.current
        let d = cal.dateComponents([.year, .month, .day], from: cal.date(byAdding: .day, value: day, to: cal.startOfDay(for: today)) ?? today)
        return String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }

    func isoDay(_ date: Date) -> String { isoDay(PlanGraph.day(date, from: today, calendar: .current)) }

    var relationsJSON: JSONValue {
        .object(["loaded": .int(progress.loaded), "total": .int(progress.total), "failed": .int(progress.failed)])
    }

    /// `end` is the last day of the open work, not the first day after it.
    func forecastJSON(_ e: Epic) -> JSONValue {
        let f = schedule.forecast(e, in: graph, today: today)
        var o: [String: JSONValue] = ["start": .string(isoDay(f.start))]
        if let end = f.end { o["end"] = .string(isoDay(end - 1)) }
        if let late = f.lateBy { o["lateBy"] = .int(late) }
        return .object(o)
    }

    func slotJSON(_ key: String, into o: inout [String: JSONValue]) {
        guard let s = schedule.slots[key.uppercased()] else { return }
        o["start"] = .string(isoDay(s.start))
        o["end"] = .string(isoDay(s.end - 1))
        o["slack"] = .int(s.slack)
        o["critical"] = .bool(s.critical)
    }

    /// The epic, its rollup, its members, its numbered steps and its forecast.
    func epicJSON(_ e: Epic) -> JSONValue {
        let r = snap.rollup(e, now: today)
        let steps = PlanSteps.build(epic: e.id, graph: graph, schedule: schedule)
        var o: [String: JSONValue] = [
            "project": .string(ident), "id": .string(e.id.rawValue), "title": .string(e.title), "state": .string(e.state.rawValue),
            "url": .string(e.url), "forecast": forecastJSON(e), "relations": relationsJSON,
            "progress": .object(["done": .int(r.done), "total": .int(r.total), "open": .int(r.open), "started": .int(r.started),
                                 "readyToClose": .bool(r.readyToClose)]),
        ]
        if let g = e.goal { o["goal"] = .string(g) }
        if let h = e.health { o["health"] = .string(h.rawValue) }
        if let d = e.startDate { o["startDate"] = .string(isoDay(d)) }
        if let d = e.targetDate { o["targetDate"] = .string(isoDay(d)) }
        if let late = r.lateDays { o["lateDays"] = .int(late) }
        o["members"] = .array(snap.members(of: e.id).compactMap { m -> JSONValue? in
            guard let key = m.key else { return nil }
            var row: [String: JSONValue] = ["key": .string(key), "title": .string(title(key))]
            if let s = snap.option(m.state)?.name { row["status"] = .string(s) }
            if let n = graph.nodes[key.uppercased()] { row["state"] = .string(n.state.rawValue) }
            return .object(row)
        })
        o["done"] = .array(steps.done.map(JSONValue.string))
        o["steps"] = .array(steps.open.map { s in
            var row: [String: JSONValue] = ["number": .int(s.number), "key": .string(s.key), "title": .string(stepText(s.key)),
                                            "state": .string(s.state.rawValue)]
            if let n = s.waitsOnStep { row["waitsOnStep"] = .int(n) }
            if let k = s.waitsOnKey { row["waitsOnKey"] = .string(k) }
            slotJSON(s.key, into: &row)
            return .object(row)
        })
        if let next = steps.next { o["next"] = .string(next.key) }
        return .object(o)
    }

    /// "Review desk: 6 of 9 done. 2 days late. Next: Keyboard review."
    func epicText(_ e: Epic) -> String {
        let steps = PlanSteps.build(epic: e.id, graph: graph, schedule: schedule)
        let f = schedule.forecast(e, in: graph, today: today)
        return "\(e.title): " + steps.whereWeAre(rollup: snap.rollup(e, now: today), forecast: f, title: stepText)
    }

    /// The ordered steps of each epic with the slack, the critical path and the forecasts. `only` limits it to one epic.
    func planJSON(only: Epic?) -> JSONValue {
        let epics = only.map { [$0] } ?? graph.epics.filter { !$0.state.isClosed }
        let rows = epics.map { e -> JSONValue in
            let steps = PlanSummary.steps(of: e.id, graph: graph, schedule: schedule).map { k -> JSONValue in
                var row: [String: JSONValue] = ["key": .string(k), "title": .string(stepText(k)),
                                                "state": .string(graph.nodes[k]?.state.rawValue ?? "")]
                let n = graph.nodes[k]
                if let b = n.map({ $0.blockers + $0.external }), !b.isEmpty { row["waitsOn"] = .array(b.map(JSONValue.string)) }
                slotJSON(k, into: &row)
                return .object(row)
            }
            return .object(["id": .string(e.id.rawValue), "title": .string(e.title), "state": .string(e.state.rawValue),
                            "forecast": forecastJSON(e), "steps": .array(steps)])
        }
        let ids = Set(epics.map(\.id))
        let critical = graph.order.filter { k in
            guard let s = schedule.slots[k], s.critical, let e = graph.nodes[k]?.epic else { return false }
            return ids.contains(e)
        }.sorted { (schedule.slots[$0]!.start, $0) < (schedule.slots[$1]!.start, $1) }
        return .object(["project": .string(ident), "end": .string(isoDay(schedule.end - 1)), "relations": relationsJSON,
                        "critical": .array(critical.map(JSONValue.string)), "epics": .array(rows)])
    }

    /// "FAKE: 2 epics, 7 open steps, the work ends Dec 4. Relations 2 of 5 loaded."
    func planText(only: Epic?) -> String {
        let epics = only.map { [$0] } ?? graph.epics.filter { !$0.state.isClosed }
        let open = epics.reduce(0) { $0 + PlanSummary.steps(of: $1.id, graph: graph, schedule: schedule).count }
        var s = "\(only?.title ?? ident): "
        if only == nil { s += "\(epics.count) open epic\(epics.count == 1 ? "" : "s"), " }
        s += "\(open) open step\(open == 1 ? "" : "s")"
        if open > 0 {
            let end = only.flatMap { schedule.forecast($0, in: graph, today: today).end } ?? schedule.end
            s += ", the work ends \(date(end - 1))"
        }
        s += "."
        if progress.loaded < progress.total { s += " Relations \(progress.loaded) of \(progress.total) loaded: the order can change." }
        return s
    }
}
