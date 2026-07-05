@testable import LiquidCode
import XCTest

final class LocalizationTests: XCTestCase {
    func testLanguageSelectionSupportsOnlyChineseAndEnglishFallbacks() {
        XCTAssertEqual(AppLocalization.languageCode(for: ["zh-Hans-HK"]), "zh-Hans")
        XCTAssertEqual(AppLocalization.languageCode(for: ["zh-Hant-HK"]), "zh-Hans")
        XCTAssertEqual(AppLocalization.languageCode(for: ["zh-Hant-TW"]), "zh-Hans")
        XCTAssertEqual(AppLocalization.languageCode(for: ["en-US"]), "en")
        XCTAssertEqual(AppLocalization.languageCode(for: ["ja-JP", "zh-Hans"]), "en")
    }

    func testSimplifiedChineseLocalizableStringsCoverCoreSurfaces() throws {
        let zhPath = try XCTUnwrap(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let zhBundle = try XCTUnwrap(Bundle(path: zhPath))

        XCTAssertEqual(NSLocalizedString("New Chat", bundle: zhBundle, comment: ""), "新建对话")
        XCTAssertEqual(NSLocalizedString("Ready when you are", bundle: zhBundle, comment: ""), "准备好了，随时开始")
        XCTAssertEqual(NSLocalizedString("Choose Folder…", bundle: zhBundle, comment: ""), "选择文件夹…")
        XCTAssertEqual(NSLocalizedString("Files", bundle: zhBundle, comment: ""), "文件")
        XCTAssertEqual(NSLocalizedString("Skills", bundle: zhBundle, comment: ""), "技能")
        XCTAssertEqual(NSLocalizedString("Settings", bundle: zhBundle, comment: ""), "设置")
        XCTAssertEqual(NSLocalizedString("Claude is still working", bundle: zhBundle, comment: ""), "Claude 仍在工作")
        XCTAssertEqual(NSLocalizedString("Search files...", bundle: zhBundle, comment: ""), "搜索文件…")
        XCTAssertEqual(NSLocalizedString("Create skill", bundle: zhBundle, comment: ""), "新建技能")
        XCTAssertEqual(NSLocalizedString("Find in transcript", bundle: zhBundle, comment: ""), "在对话中查找")
        XCTAssertEqual(NSLocalizedString("No command/url", bundle: zhBundle, comment: ""), "未配置命令或 URL")
        XCTAssertEqual(
            NSLocalizedString(
                "Keychain-backed provider secrets, MCP/Skills panels, file explorer, session export and Liquid Glass panels.",
                bundle: zhBundle,
                comment: ""
            ),
            "基于钥匙串保存供应商密钥，内置 MCP/技能面板、文件浏览器、会话导出和液态玻璃面板。"
        )
    }
}
