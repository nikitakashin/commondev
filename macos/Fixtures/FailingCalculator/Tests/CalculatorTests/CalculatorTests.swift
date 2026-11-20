import XCTest
@testable import Calculator

final class CalculatorTests: XCTestCase {
    func testAddingTwoNumbers() {
        XCTAssertEqual(Calculator.add(2, 3), 5)
    }
}
