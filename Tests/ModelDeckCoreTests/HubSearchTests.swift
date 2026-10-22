import XCTest
@testable import ModelDeckCore

final class HubSearchTests: XCTestCase {
    func testSearchUsesFixedHostAndEscapesTermsAsOneBoundedParameter() throws {
        let query = "qwen &filter=private/#?"
        let url = try HuggingFaceCatalog.searchURL(query: query, format: .gguf, limit: 9999)
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "https"); XCTAssertEqual(parts.host, "huggingface.co"); XCTAssertEqual(parts.path, "/api/models")
        XCTAssertEqual(parts.queryItems?.filter { $0.name == "search" }.map(\.value), [query])
        XCTAssertEqual(parts.queryItems?.filter { $0.name == "filter" }.map(\.value), ["gguf"])
        XCTAssertEqual(parts.queryItems?.first { $0.name == "limit" }?.value, "20")
        for invalid in ["", " q ", "qwen\nllama", String(repeating: "x", count: 129)] {
            XCTAssertThrowsError(try HuggingFaceCatalog.searchURL(query: invalid))
        }
    }
    func testSearchResultsPreserveOrderValidateIDsAndKeepMissingMetadataUnknown() throws {
        let input = Data(#"[{"id":"org/Qwen-GGUF","downloads":1200,"likes":7,"tags":["gguf"],"pipeline_tag":"text-generation","gated":false},{"id":"org/MLX","library_name":"mlx","gated":"auto"},{"id":"org/Qwen-GGUF","downloads":999},{"id":"../bad"},{"id":"org/disabled","disabled":true},{"id":"org/private","private":true},{"id":"https://other.example/org/model"}]"#.utf8)
        let found = try HuggingFaceCatalog.parseSearch(input)
        XCTAssertEqual(found.map(\.repository), ["org/Qwen-GGUF", "org/MLX"])
        XCTAssertEqual(found[0].downloads, 1200); XCTAssertEqual(found[0].format, "GGUF")
        XCTAssertNil(found[1].downloads); XCTAssertEqual(found[1].format, "MLX"); XCTAssertTrue(found[1].gated)
        XCTAssertEqual(try HuggingFaceCatalog.parseSearch(Data("[]".utf8)).count, 0)
        XCTAssertThrowsError(try HuggingFaceCatalog.parseSearch(Data(#"{"error":"not a result list"}"#.utf8)))
    }
    func testSearchResultsAreBounded() throws {
        let data = try JSONSerialization.data(withJSONObject: (0..<100).map { ["id": "org/model-\($0)"] })
        XCTAssertEqual(try HuggingFaceCatalog.parseSearch(data).count, 20)
    }
}
