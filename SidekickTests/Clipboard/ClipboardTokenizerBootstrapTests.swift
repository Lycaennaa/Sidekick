import XCTest

@MainActor
final class ClipboardTokenizerBootstrapTests: XCTestCase {
    func testTokenizerPreloadLoadsAndRetainsEncoder() async throws {
        let loader = ControlledTokenizerLoader(encoder: try makeTestO200kBase())
        let tokenizer = ClipboardTokenizer(loader: loader)
        let preload = Task { try await tokenizer.preload() }

        await loader.state.waitUntilStarted()
        let loadCountBeforeRelease = await loader.state.loadCount
        XCTAssertEqual(loadCountBeforeRelease, 1)
        await loader.state.release()
        try await preload.value

        let tokenCount = try await tokenizer.countTokens(in: "hello")
        XCTAssertEqual(tokenCount, 5)
        let loadCountAfterRelease = await loader.state.loadCount
        XCTAssertEqual(loadCountAfterRelease, 1)
        await tokenizer.shutdown()
    }

    func testTokenizerSharesOneBootstrapTask() async throws {
        let loader = ControlledTokenizerLoader(encoder: try makeTestO200kBase())
        let tokenizer = ClipboardTokenizer(loader: loader)
        let first = Task { try await tokenizer.countTokens(in: "hello") }
        let second = Task { try await tokenizer.countTokens(in: "world") }

        await loader.state.waitUntilStarted()
        let loadCountBeforeRelease = await loader.state.loadCount
        XCTAssertEqual(loadCountBeforeRelease, 1)
        await loader.state.release()

        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult, 5)
        XCTAssertEqual(secondResult, 5)
        let loadCountAfterRelease = await loader.state.loadCount
        XCTAssertEqual(loadCountAfterRelease, 1)
    }

    func testTokenizerCancellationCancelsOwnedBootstrapTask() async {
        let loader = BlockingTokenizerLoader()
        let tokenizer = ClipboardTokenizer(loader: loader)
        let task = Task { try await tokenizer.countTokens(in: "hello") }

        await loader.state.waitUntilStarted()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await loader.state.waitUntilCancelled()
    }

    func testTokenizerShutdownCancelsBootstrapAndRejectsFutureRequests() async {
        let loader = BlockingTokenizerLoader()
        let tokenizer = ClipboardTokenizer(loader: loader)
        let task = Task { try await tokenizer.countTokens(in: "hello") }

        await loader.state.waitUntilStarted()
        await tokenizer.shutdown()
        do {
            _ = try await task.value
            XCTFail("Expected shutdown cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await loader.state.waitUntilCancelled()
        do {
            _ = try await tokenizer.countTokens(in: "hello")
            XCTFail("Expected future requests to remain cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let loadCount = await loader.state.loadCount
        XCTAssertEqual(loadCount, 1)
    }
}
