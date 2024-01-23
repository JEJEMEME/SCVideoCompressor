import XCTest
@testable import SCVideoCompressor

class SCVideoCompressorTests: XCTestCase {

    var videoCompressor: SCVideoCompressor!

    override func setUp() {
        super.setUp()
        videoCompressor = SCVideoCompressor()
    }

    override func tearDown() {
        videoCompressor = nil
        super.tearDown()
    }

    func testCompressVideo() {
        let expectation = XCTestExpectation(description: "Compress Video")
        
        // HTTPS URL 지정
        let videoURL = URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!
        
        downloadVideo(from: videoURL) { result in
            print(result)
            switch result {
            case .success(let localURL):
                let config = SCVideoCompressor.CompressionConfig()
                Task {
                    do {
                        let compressedURL = try await self.videoCompressor.compressVideo(localURL, config: config)
                        XCTAssertNotNil(compressedURL)
                        expectation.fulfill()
                    } catch {
                        XCTFail("Error compressing video: \(error)")
                    }
                }
                
            case .failure(let error):
                XCTFail("Error downloading video: \(error)")
            }
        }
        
        wait(for: [expectation], timeout: 60.0)
    }

    func downloadVideo(from url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let task = URLSession.shared.downloadTask(with: url) { tempLocalURL, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let tempLocalURL = tempLocalURL else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            
            do {
                // 로컬 디렉토리에 최종 파일 URL 정의 (MP4 확장자 사용)
                let fileManager = FileManager.default
                let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let videoFileName = UUID().uuidString + ".mp4"
                let localURL = documentsPath.appendingPathComponent(videoFileName)

                // 임시 파일을 최종 위치로 이동
                if fileManager.fileExists(atPath: localURL.path) {
                    try fileManager.removeItem(at: localURL)
                }
                try fileManager.moveItem(at: tempLocalURL, to: localURL)

                completion(.success(localURL))
            } catch {
                completion(.failure(error))
            }
        }

        task.resume()
    }


}
