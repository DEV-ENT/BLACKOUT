import XCTest
@testable import BlackoutCore

/// Same values as Android's ProtocolTest.mailboxes (and Python, see spec/FORMAT.md "Mailboxes").
final class MailboxTests: XCTestCase {
    func testMailboxes() {
        XCTAssertEqual(GroupCrypto(code: "test-group-1").mailbox, 0xa8d0)
        XCTAssertEqual(GroupCrypto(code: GroupCrypto.publicCode).mailbox, 0x0794)
        XCTAssertEqual(GroupCrypto(code: "test-group-1").receipts().mailbox, 0xa8d0) // receipts go to the group's mailbox
        let id = Packet.newId(mailbox: 0xa8d0)
        XCTAssertNotNil(id.range(of: "^a8d0[0-9a-f]{12}$", options: .regularExpression))
        XCTAssertEqual(Packet.mailbox(of: id), 0xa8d0)
        XCTAssertNotEqual(Packet.newId(mailbox: 0xa8d0), Packet.newId(mailbox: 0xa8d0))
        XCTAssertEqual(Packet.newId(mailbox: 0x0794).prefix(4), "0794")
    }
}
