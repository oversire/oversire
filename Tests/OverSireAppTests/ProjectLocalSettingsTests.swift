import OverSireCore
import XCTest
@testable import OverSireApp

final class ProjectLocalSettingsTests: XCTestCase {
    private let project = ProjectSummary(ref: ProjectRef(account: AccountID(provider: ProviderID(rawValue: "plane"), id: "ocral"), id: "p1", key: "OVERSIRE"),
                                         identifier: "OVERSIRE", title: "OverSire", url: "https://plane/OVERSIRE", closed: false)

    private func decode(_ json: String) throws -> ProjectsConfig {
        try JSONDecoder().decode(ProjectsConfig.self, from: Data(json.utf8))
    }

    func testDecodeWithoutSettings() throws {
        let c = try decode("{}")
        XCTAssertTrue(c.settings.isEmpty)
        XCTAssertEqual(c.local("oversire"), ProjectLocalSettings())
    }

    func testDecodeWithSettings() throws {
        let c = try decode(#"{"settings":{"OVERSIRE":{"icon":"repo:oversire/oversire","github":["oversire"],"muted":true}}}"#)
        let l = c.local("oversire")
        XCTAssertEqual(l.icon, .repo("oversire/oversire"))
        XCTAssertEqual(l.github, ["oversire"])
        XCTAssertTrue(l.muted)
        XCTAssertFalse(l.hidden)
    }

    func testIconChoiceRoundTrip() throws {
        for i in [IconChoice.auto, .upload, .tracker, .repo("a/b"), .org("a"), .letter] {
            XCTAssertEqual(IconChoice(raw: i.raw), i)
        }
        XCTAssertEqual(IconChoice(raw: "unknown"), .auto)
    }

    func testMigrateRootsKeepsTheOldEntry() {
        var c = ProjectsConfig()
        c.orca.roots[project.ref.storeKey] = "/src/oversire"
        c.migrateRoots([project])
        XCTAssertEqual(c.local("OVERSIRE").orcaRoot, "/src/oversire")
        XCTAssertEqual(c.orca.roots[project.ref.storeKey], "/src/oversire")
        XCTAssertEqual(c.orcaRoot(project), "/src/oversire")
    }

    func testSetOrcaRootWritesBothPlaces() {
        var c = ProjectsConfig()
        c.setOrcaRoot(project, "/x")
        XCTAssertEqual(c.local("OVERSIRE").orcaRoot, "/x")
        XCTAssertEqual(c.orca.roots[project.ref.storeKey], "/x")
    }

    func testCategoryOverride() {
        var c = ProjectsConfig()
        let o = StatusOption(id: "s1", name: "QA", color: "#000", group: "started")
        XCTAssertEqual(c.category(o, project: "OVERSIRE"), o.category)
        var l = c.local("OVERSIRE")
        l.categories["s1"] = .review
        c.setLocal("OVERSIRE", l)
        XCTAssertEqual(c.category(o, project: "oversire"), .review)
    }

    func testBranchName() {
        let item = Item(id: "1", key: "OVERSIRE-55", title: "Project settings: page!", url: "", statusOptionId: nil, fields: [:],
                        assignees: [], labels: [], author: nil, updatedBy: nil, updatedAt: .now, activityAt: .now,
                        commentCount: 0, lastComment: nil, mentionsMe: false)
        var l = ProjectLocalSettings()
        XCTAssertEqual(l.branch(for: item), "oversire-55/project-settings-page")
        l.branchTemplate = "feat/{KEY}"
        XCTAssertEqual(l.branch(for: item), "feat/OVERSIRE-55")
    }
}
