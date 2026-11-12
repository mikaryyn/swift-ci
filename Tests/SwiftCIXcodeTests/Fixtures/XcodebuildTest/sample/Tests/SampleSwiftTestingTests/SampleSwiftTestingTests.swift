import SampleKit
import Testing

struct SampleError: Error {}

@Suite struct SampleSwiftTestingTests {
    @Test func passes() {
        #expect(sum(1, 2) == 3)
    }

    @Test func failsOnMismatch() {
        #expect(sum(1, 1) == 3, "addition is wrong")
    }

    @Test(.disabled("disabled on purpose"))
    func disabled() {
        #expect(Bool(false))
    }

    @Test(arguments: [1, 2, 3])
    func parameterized(value: Int) {
        #expect(value != 2, "argument 2 is rejected")
    }

    @Test func throwsError() throws {
        throw SampleError()
    }
}
