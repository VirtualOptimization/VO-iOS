import Foundation

@main
struct OptimizationPollingTests {
    static func main() async throws {
        var checks = 0
        let result: String = try await OptimizationPolling.wait(check: {
            checks += 1
            // More than the former 1,440 checks; also survive several transport failures.
            if checks == 1500 { throw URLError(.timedOut) }
            if checks == 1501 { throw URLError(.notConnectedToInternet) }
            if checks == 1502 { throw OptimizerError.httpError(503) }
            if checks == 1503 { throw OptimizerError.httpError(429) }
            return checks == 1600 ? "saved optimized version" : nil
        }, pause: {})
        precondition(checks == 1600 && result == "saved optimized version")

        for error: Error in [OptimizerError.optimizationFailed, OptimizerError.httpError(401),
                             OptimizerError.httpError(403), OptimizerError.httpError(404),
                             OptimizerError.invalidResponse] {
            var attempts = 0
            do {
                let _: String = try await OptimizationPolling.wait(check: {
                    attempts += 1
                    throw error
                }, pause: { preconditionFailure("Terminal errors must not retry") })
                preconditionFailure("Terminal errors must propagate")
            } catch { precondition(attempts == 1) }
        }
        precondition(!OptimizationPolling.shouldRetry(CancellationError()))
        let task = Task {
            let _: String = try await OptimizationPolling.wait(check: { nil }, pause: {
                try await Task.sleep(for: .seconds(60))
            })
        }
        task.cancel()
        do { try await task.value; preconditionFailure("Cancellation must stop polling") }
        catch is CancellationError { }
        print("PASS: no attempt limit, delayed save, offline/timeout/503/429 recovery, terminal errors and cancellation")
    }
}
