import XCTest
@testable import ThreadHangerCore

final class CodexFollowUpQuestionTests: XCTestCase {
    func testRecognizesExplicitRequestsForAReply() {
        for message in [
            "选择框已弹出。我等你选 A 或 B。",
            "你想选 A 还是 B？",
            "你想选 A 还是 B？\n- A\n- B",
            "请在界面中选择 A 或 B。",
            "**请告诉我系统版本。**",
            "为了继续，我需要你确认这两个值。",
            "请选一个：\n- A. 本周\n- B. 上周",
            "Could you confirm the account name?",
            "Please reply with A or B.",
            "Which option would you prefer?",
            "- 请回复 A 或 B。"
        ] {
            XCTAssertTrue(CodexFollowUpQuestion.requiresReply(message), message)
        }
    }

    func testIgnoresRhetoricalQuestionsExamplesAndOptionalOffers() {
        for message in [
            "为什么选 A？因为它运行更快。",
            "你想选 A 还是 B？我已经按 A 执行完毕。",
            "示例：你想选 A 还是 B？",
            "可用选项如下。\n- A\n- B",
            "先用这个例子。\n> 请回复 A 或 B。",
            "运行结果：\n```text\n请回复 A 或 B。\n```",
            "如果有需要，我可以继续整理。",
            "请查看下方日志。",
            "示例：\n    请回复 A 或 B。",
            "Any questions?"
        ] {
            XCTAssertFalse(CodexFollowUpQuestion.requiresReply(message), message)
        }
    }
}
