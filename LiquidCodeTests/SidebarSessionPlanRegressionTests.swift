@testable import LiquidCode
import XCTest

final class SidebarSessionPlanRegressionTests: XCTestCase {
    func testSidebarSessionPlanTaskGroupRowsFollowGlobalSessionOrderAndCollapseDuplicateIDs() {
        let project = "/workspace/current"
        let group = makeSidebarTaskGroup(
            id: "current-group",
            projectPath: project,
            sessionIDs: ["third", "first", "second", "first", "missing", "second"]
        )
        let sessions = [
            makeSidebarSession(id: "second", projectDir: project, modifiedAt: Date(timeIntervalSince1970: 20)),
            makeSidebarSession(id: "third", projectDir: project, modifiedAt: Date(timeIntervalSince1970: 30)),
            makeSidebarSession(id: "first", projectDir: project, modifiedAt: Date(timeIntervalSince1970: 10))
        ]

        let plan = buildSidebarSessionPlan(
            sessions: sessions,
            sessionGroups: [group],
            searchText: "",
            showRunningSessionsOnly: false,
            activeSessionIDs: [],
            workingDirectory: project,
            selectedSessionID: nil
        )

        XCTAssertEqual(plan.taskGroups.map(\.id), ["current-group"])
        XCTAssertEqual(plan.taskGroupSessions["current-group"]?.map(\.id), ["second", "third", "first"])
    }

    func testSidebarSessionPlanRendersOnlyWorkingDirectoryTaskGroupsButIndexesEveryProjectGroup() {
        let currentProject = "/workspace/current"
        let otherProject = "/workspace/other"
        let currentGroup = makeSidebarTaskGroup(
            id: "current-group",
            projectPath: currentProject,
            sessionIDs: ["current"]
        )
        let otherGroup = makeSidebarTaskGroup(
            id: "other-group",
            projectPath: otherProject,
            sessionIDs: ["other"]
        )

        let plan = buildSidebarSessionPlan(
            sessions: [
                makeSidebarSession(
                    id: "current",
                    projectDir: currentProject,
                    modifiedAt: Date(timeIntervalSince1970: 20)
                ),
                makeSidebarSession(
                    id: "other",
                    projectDir: otherProject,
                    modifiedAt: Date(timeIntervalSince1970: 10)
                )
            ],
            sessionGroups: [currentGroup, otherGroup],
            searchText: "",
            showRunningSessionsOnly: false,
            activeSessionIDs: [],
            workingDirectory: currentProject,
            selectedSessionID: nil
        )

        XCTAssertEqual(plan.taskGroups.map(\.id), ["current-group"])
        XCTAssertEqual(plan.taskGroupSessions["current-group"]?.map(\.id), ["current"])
        XCTAssertNil(plan.taskGroupSessions["other-group"])
        XCTAssertEqual(plan.projectGroupsByPath[currentProject]?.map(\.id), ["current-group"])
        XCTAssertEqual(plan.projectGroupsByPath[otherProject]?.map(\.id), ["other-group"])
    }

    func testSidebarSessionPlanFiltersBucketsWithoutFilteringTaskGroupMembership() {
        let project = "/workspace/current"
        let group = makeSidebarTaskGroup(
            id: "current-group",
            projectPath: project,
            sessionIDs: ["pinned", "archived", "project", "stopped", "search-miss"]
        )
        let sessions = [
            makeSidebarSession(
                id: "pinned",
                projectDir: project,
                modifiedAt: Date(timeIntervalSince1970: 50),
                preview: "keep pinned",
                pinned: true
            ),
            makeSidebarSession(
                id: "archived",
                projectDir: project,
                modifiedAt: Date(timeIntervalSince1970: 40),
                preview: "keep archived",
                archived: true
            ),
            makeSidebarSession(
                id: "project",
                projectDir: project,
                modifiedAt: Date(timeIntervalSince1970: 30),
                preview: "keep project"
            ),
            makeSidebarSession(
                id: "stopped",
                projectDir: project,
                modifiedAt: Date(timeIntervalSince1970: 20),
                preview: "keep stopped"
            ),
            makeSidebarSession(
                id: "search-miss",
                projectDir: project,
                modifiedAt: Date(timeIntervalSince1970: 10),
                preview: "other text"
            )
        ]

        let plan = buildSidebarSessionPlan(
            sessions: sessions,
            sessionGroups: [group],
            searchText: "keep",
            showRunningSessionsOnly: true,
            activeSessionIDs: ["pinned", "archived", "project"],
            workingDirectory: project,
            selectedSessionID: nil
        )

        XCTAssertEqual(plan.pinned.map(\.id), ["pinned"])
        XCTAssertEqual(plan.archived.map(\.id), ["archived"])
        XCTAssertEqual(plan.projectGroups.map(\.path), [project])
        XCTAssertEqual(plan.projectGroups.first?.sessions.map(\.id), ["project"])
        XCTAssertEqual(
            plan.taskGroupSessions["current-group"]?.map(\.id),
            ["pinned", "archived", "project", "stopped", "search-miss"]
        )
    }

    func testSidebarSessionPlanSortsProjectGroupsByFirstConversationThenLatestAndSessionsByModifiedDate() {
        let alpha = "/workspace/alpha"
        let beta = "/workspace/beta"
        let gamma = "/workspace/gamma"
        let sessions = [
            makeSidebarSession(
                id: "alpha-older",
                projectDir: alpha,
                createdAt: Date(timeIntervalSince1970: 100),
                modifiedAt: Date(timeIntervalSince1970: 300)
            ),
            makeSidebarSession(
                id: "gamma-latest",
                projectDir: gamma,
                createdAt: Date(timeIntervalSince1970: 100),
                modifiedAt: Date(timeIntervalSince1970: 700)
            ),
            makeSidebarSession(
                id: "beta-new-first",
                projectDir: beta,
                createdAt: Date(timeIntervalSince1970: 200),
                modifiedAt: Date(timeIntervalSince1970: 400)
            ),
            makeSidebarSession(
                id: "alpha-newer",
                projectDir: alpha,
                createdAt: Date(timeIntervalSince1970: 110),
                modifiedAt: Date(timeIntervalSince1970: 500)
            )
        ]

        let plan = buildSidebarSessionPlan(
            sessions: sessions,
            sessionGroups: [],
            searchText: "",
            showRunningSessionsOnly: false,
            activeSessionIDs: [],
            workingDirectory: alpha,
            selectedSessionID: nil
        )

        XCTAssertEqual(plan.projectGroups.map(\.path), [beta, gamma, alpha])
        XCTAssertEqual(
            plan.projectGroups.first { $0.path == alpha }?.sessions.map(\.id),
            ["alpha-newer", "alpha-older"]
        )
    }

    private func makeSidebarSession(
        id: String,
        projectDir: String,
        createdAt: Date? = nil,
        modifiedAt: Date,
        preview: String? = nil,
        pinned: Bool = false,
        archived: Bool = false
    ) -> SessionRecord {
        SessionRecord(
            id: id,
            path: nil,
            project: URL(fileURLWithPath: projectDir).lastPathComponent,
            projectDir: projectDir,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            preview: preview ?? id,
            cliResumeID: nil,
            lastCheckpointUUID: nil,
            customTitle: nil,
            pinned: pinned,
            archived: archived,
            isDraft: false
        )
    }

    private func makeSidebarTaskGroup(id: String, projectPath: String, sessionIDs: [String]) -> SessionTaskGroup {
        SessionTaskGroup(
            id: id,
            name: id,
            projectPath: projectPath,
            sessionIDs: sessionIDs,
            isCollapsed: false,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
    }
}
