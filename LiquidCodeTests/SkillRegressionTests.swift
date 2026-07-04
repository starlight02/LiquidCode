import XCTest
@testable import LiquidCode

@MainActor
final class SkillRegressionTests: XCTestCase {

    private func makeTempRoot() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
        let root = base.appendingPathComponent("lc-skill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSkillFile(root: URL, name: String, body: String) throws -> URL {
        let dir = root.appendingPathComponent(".claude/skills/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("SKILL.md")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Find the project-scope skill whose on-disk path matches `url`, normalizing
    /// the macOS `/var` ↔ `/private/var` symlink so the enumerator-yielded path
    /// (resolved) compares equal to the path we built (unresolved on the temp base).
    private func loadedSkill(_ model: AppModel, matching url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> SkillInfo {
        let target = url.resolvingSymlinksInPath().path
        let resolve: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        return try XCTUnwrap(model.skills.first { $0.scope == "project" && resolve($0.path) == target },
                             "Loaded skills: \(model.skills.map { "\($0.name)@\($0.path)" })",
                             file: file, line: line)
    }

    /// Toggle an opened, dirty SKILL.md must:
    /// - preserve the unsaved body edit,
    /// - write exactly one canonical `disable_model_invocation:` line,
    /// - remove the legacy `disable-model-invocation:` key,
    /// - reflect canonical content on `selectedSkill` and `filePreview`.
    func testToggleEnabledOnDirtySkillPreservesBodyAndWritesCanonicalKey() throws {
        let fm = FileManager.default
        let root = try makeTempRoot()
        defer { try? fm.removeItem(at: root) }

        let skillURL = try makeSkillFile(root: root, name: "demo", body: """
        ---
        name: demo
        description: demo skill
        disable-model-invocation: false
        ---
        # Demo skill
        original body
        """)

        let model = AppModel()
        model.workingDirectory = root.path
        model.reloadMCPAndSkills()

        let skill = try loadedSkill(model, matching: skillURL)
        XCTAssertFalse(skill.disabled, "legacy `disable-model-invocation: false` should parse as enabled")
        model.selectedSkill = skill
        // Open via the loaded skill's path so `toggleSelectedSkillEnabled` sees
        // `selectedFilePath == skill.path` and honors the dirty `filePreview`.
        model.openFile(skill.path)
        XCTAssertEqual(model.selectedFilePath, skill.path)

        // Simulate unsaved body edits in the FilePreview-backed editor.
        let edited = """
        \(model.filePreview)
        appended unsaved edit line
        """
        model.filePreview = edited
        model.markFilePreviewEdited()
        XCTAssertTrue(model.fileEditDirty)

        model.toggleSelectedSkillEnabled()

        let written = try String(contentsOf: skillURL, encoding: .utf8)
        XCTAssertTrue(written.contains("appended unsaved edit line"), "unsaved body edit must survive toggle")
        XCTAssertEqual(written.components(separatedBy: "\n").filter { $0.hasPrefix("disable_model_invocation:") }.count, 1,
                       "exactly one canonical key")
        XCTAssertFalse(written.contains("disable-model-invocation:"), "legacy key must be removed")
        XCTAssertTrue(written.contains("disable_model_invocation: true"))

        let refreshed = try XCTUnwrap(model.selectedSkill)
        XCTAssertEqual(refreshed.path, skill.path)
        XCTAssertEqual(refreshed.content, model.filePreview)
        XCTAssertEqual(refreshed.content, written)
        XCTAssertTrue(refreshed.disabled)
        XCTAssertFalse(model.fileEditDirty)
    }

    /// Saving an edited SKILL.md must refresh `selectedSkill` name/description from the
    /// new frontmatter written into the file.
    func testSaveSelectedFileRefreshesSkillMetadataAfterFrontmatterEdit() throws {
        let fm = FileManager.default
        let root = try makeTempRoot()
        defer { try? fm.removeItem(at: root) }

        let skillURL = try makeSkillFile(root: root, name: "demo", body: """
        ---
        name: demo
        description: demo skill
        ---
        # Demo skill
        body
        """)

        let model = AppModel()
        model.workingDirectory = root.path
        model.reloadMCPAndSkills()

        let skill = try loadedSkill(model, matching: skillURL)
        model.selectedSkill = skill
        model.openFile(skill.path)

        let renamed = """
        ---
        name: demo2
        description: updated description
        ---
        # Demo skill
        body
        """
        model.filePreview = renamed
        model.markFilePreviewEdited()
        XCTAssertTrue(model.fileEditDirty)

        model.saveSelectedFile()

        let written = try String(contentsOf: skillURL, encoding: .utf8)
        XCTAssertEqual(written, renamed)

        let refreshed = try XCTUnwrap(model.selectedSkill)
        XCTAssertEqual(refreshed.name, "demo2", "selectedSkill name must reflect saved frontmatter")
        XCTAssertEqual(refreshed.description, "updated description", "selectedSkill description must reflect saved frontmatter")
        XCTAssertEqual(refreshed.content, renamed)
        XCTAssertEqual(model.filePreview, renamed)
        XCTAssertFalse(model.fileEditDirty)
    }

    /// The legacy `disable-model-invocation:` key must be honored on load:
    /// `true` parses as disabled, `false` parses as enabled. Guards the
    /// SkillsPanel migration boundary where old skills still carry the hyphenated key.
    func testLegacyDisableKeyParsesAsDisabled() throws {
        let fm = FileManager.default
        let root = try makeTempRoot()
        defer { try? fm.removeItem(at: root) }

        let disabledURL = try makeSkillFile(root: root, name: "legacy-true", body: """
        ---
        name: legacy-true
        description: legacy disabled skill
        disable-model-invocation: true
        ---
        body
        """)
        let enabledURL = try makeSkillFile(root: root, name: "legacy-false", body: """
        ---
        name: legacy-false
        description: legacy enabled skill
        disable-model-invocation: false
        ---
        body
        """)

        let model = AppModel()
        model.workingDirectory = root.path
        model.reloadMCPAndSkills()

        let disabledSkill = try loadedSkill(model, matching: disabledURL)
        XCTAssertTrue(disabledSkill.disabled, "legacy `disable-model-invocation: true` must parse as disabled")

        let enabledSkill = try loadedSkill(model, matching: enabledURL)
        XCTAssertFalse(enabledSkill.disabled, "legacy `disable-model-invocation: false` must parse as enabled")
    }

    func testSkillFrontmatterMetadataParsesForTokenicodeStyleCards() throws {
        let fm = FileManager.default
        let root = try makeTempRoot()
        defer { try? fm.removeItem(at: root) }

        let skillURL = try makeSkillFile(root: root, name: "meta-demo", body: """
        ---
        name: meta-demo
        description: Rich metadata skill
        allowed_tools:
          - Read
          - Write
        model: sonnet
        context: project
        version: 1.2.3
        ---
        body
        """)

        let model = AppModel()
        model.workingDirectory = root.path
        model.reloadMCPAndSkills()

        let skill = try loadedSkill(model, matching: skillURL)
        XCTAssertEqual(skill.allowedTools, ["Read", "Write"])
        XCTAssertEqual(skill.model, "sonnet")
        XCTAssertEqual(skill.context, "project")
        XCTAssertEqual(skill.version, "1.2.3")
    }

    func testUseInInputAndDuplicateSkillActionsMatchTokenicodeMenu() throws {
        let fm = FileManager.default
        let root = try makeTempRoot()
        defer { try? fm.removeItem(at: root) }

        let skillURL = try makeSkillFile(root: root, name: "demo", body: """
        ---
        name: demo
        description: demo skill
        ---
        # Demo
        """)

        let model = AppModel()
        model.workingDirectory = root.path
        model.selectedSessionID = "draft"
        model.reloadMCPAndSkills()

        let skill = try loadedSkill(model, matching: skillURL)
        model.useSkillInComposer(skill)
        XCTAssertEqual(model.composerText, "/demo ")

        model.duplicateSkill(skill)
        XCTAssertNil(model.currentError, model.currentError.map { "\($0.title): \($0.message)" } ?? "")
        let duplicate = try XCTUnwrap(
            model.skills.first { $0.name == "demo-copy" },
            "Loaded skills after duplicate: \(model.skills.map { "\($0.name)@\($0.path)" })"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicate.path))
        let content = try String(contentsOfFile: duplicate.path, encoding: .utf8)
        XCTAssertTrue(content.contains("name: demo-copy"))
        XCTAssertEqual(model.selectedSkill?.name, "demo-copy")
    }
}
