import Foundation
import AVFoundation
import CoreMedia

public class SCVideoCompressor {
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var compressVideoPaths: [URL] = []
    public var minimumVideoBitrate = 1000 * 200
    private let group = DispatchGroup()
    private let videoCompressQueue = DispatchQueue.init(label: "com.video.compress_queue")
    private lazy var audioCompressQueue = DispatchQueue.init(label: "com.audio.compress_queue")

    public enum VideoCompressorError: Error, LocalizedError {
        case noVideo
        case compressedFailed(_ error: Error)
        case outputPathNotValid(_ path: URL)
        
        public var errorDescription: String? {
            switch self {
            case .noVideo:
                return "No video"
            case .compressedFailed(let error):
                return error.localizedDescription
            case .outputPathNotValid(let path):
                return "Output path is invalid: \(path)"
            }
        }
    }
    public struct CompressionConfig {
        //Tag: video
        
        /// Config video bitrate.
        /// If the input video bitrate is less than this value, it will be ignored.
        /// bitrate use 1000 for 1kbps. https://en.wikipedia.org/wiki/Bit_rate.
        /// Default is 1Mbps
        public var videoBitrate: Int
        /// A key to access the maximum interval between keyframes. 1 means key frames only, H.264 only. Default is 10.
        public var videomaxKeyFrameInterval: Int //
        /// If video's fps less than this value, this value will be ignored. Default is 24.
        public var fps: Float
        //Tag: audio
        /// Sample rate must be between 8.0 and 192.0 kHz inclusive
        /// Default 44100
        public var audioSampleRate: Int
        /// Default is 128_000
        /// If the input audio bitrate is less than this value, it will be ignored.
        public var audioBitrate: Int
        /// Default is mp4
        public var fileType: AVFileType
        /// Scale (resize) the input video
        /// 1. If you need to simply resize your video to a specific size (e.g 320×240), you can use the scale: CGSize(width: 320, height: 240)
        /// 2. If you want to keep the aspect ratio, you need to specify only one component, either width or height, and set the other component to -1
        ///    e.g CGSize(width: 320, height: -1)
        public var scale: CGSize?
        ///  compressed video will be moved to this path. If no value is set, `FYVideoCompressor` will create it for you.
        ///  Default is nil.
        public var outputPath: URL?
        public init() {
            self.videoBitrate = 1000_000
            self.videomaxKeyFrameInterval = 10
            self.fps = 30
            self.audioSampleRate = 44100
            self.audioBitrate = 128_000
            self.fileType = .mp4
            self.scale = nil
            self.outputPath = nil
        }
        
        public init(videoBitrate: Int = 1000_000,
                    videomaxKeyFrameInterval: Int = 10,
                    fps: Float = 24,
                    audioSampleRate: Int = 44100,
                    audioBitrate: Int = 128_000,
                    fileType: AVFileType = .mp4,
                    scale: CGSize? = nil,
                    outputPath: URL? = nil) {
            self.videoBitrate = videoBitrate
            self.videomaxKeyFrameInterval = videomaxKeyFrameInterval
            self.fps = fps
            self.audioSampleRate = audioSampleRate
            self.audioBitrate = audioBitrate
            self.fileType = fileType
            self.scale = scale
            self.outputPath = outputPath
        }
    }
    public func compressVideo(_ url: URL, config: CompressionConfig, endTime: CMTime = CMTime(seconds: 60, preferredTimescale: 600), metadata: [AVMetadataItem] = []) async throws -> URL  {
        let asset = AVAsset(url: url)
        let tracksResult = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracksResult.first else {
            throw VideoCompressorError.noVideo
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let targetSize = _calculateSizeWithScale(config.scale, originalSize: naturalSize)
        let estimatedDataRate = try await videoTrack.load(.estimatedDataRate)
        let codecType = try await videoFirstCodecType(for: videoTrack)
        let targetVideoBitrate: Float
        if Float(config.videoBitrate) > estimatedDataRate {
            let tempBitrate = estimatedDataRate / 4
            targetVideoBitrate = max(tempBitrate, Float(minimumVideoBitrate))
        } else {
            targetVideoBitrate = Float(config.videoBitrate)
        }
        let videoSettings = _createVideoSettingsWithBitrate(targetVideoBitrate,
                                        maxKeyFrameInterval: config.videomaxKeyFrameInterval,
                                        size: targetSize,
                                        codec: codecType)
        var audioTrack: AVAssetTrack?
        var audioSettings: [String: Any]?
        if let adTrack = try await asset.loadTracks(withMediaType: .audio).first {
            // --- Audio ---
            audioTrack = adTrack
            let audioBitrate: Int
            let audioSampleRate: Int
            
            audioBitrate = 128_000
            audioSampleRate = 44100
            audioSettings = try await _createAudioSettingsWithAudioTrack(adTrack, bitrate: Float(audioBitrate), sampleRate: audioSampleRate)
        }
        var _outputPath: URL
        if let outputPath = config.outputPath {
            _outputPath = outputPath
        } else {
            _outputPath = FileManager.tempDirectory(with: "CompressedVideo")
        }
#if DEBUG
        print("************** Video info **************")
        
        print("🎬 Video ")
        print("ORIGINAL:")
        print("video size: \(_sizePerMB(url: url))M")
        print("bitrate: \(estimatedDataRate) b/s")
        print("scale size: \(naturalSize)")
        
        print("TARGET:")
        print("video bitrate: \(targetVideoBitrate) b/s")
        print("fps: \(config.fps)")
        print("scale size: (\(targetSize))")
        print("****************************************")
#endif
        do {
            let compressedURL = try await _compress(asset: asset,
                      fileType: .mp4,
                      videoTrack,
                      videoSettings,
                      audioTrack,
                      audioSettings,
                      outputPath: _outputPath,
                      startTime: CMTime(value: 0, timescale: 600),
                      endTime: endTime,
                      metadata: metadata)
            return compressedURL
        } catch {
            throw error
        }
    }
    
    private func _calculateSizeWithScale(_ scale: CGSize?, originalSize: CGSize) -> CGSize {
        guard let scale = scale else {
            return originalSize
        }
        if scale.width == -1 && scale.height == -1 {
            return originalSize
        } else if scale.width != -1 && scale.height != -1 {
            return scale
        } else if scale.width == -1 {
            let targetWidth = Int(scale.height * originalSize.width / originalSize.height)
            return CGSize(width: CGFloat(targetWidth), height: scale.height)
        } else {
            let targetHeight = Int(scale.width * originalSize.height / originalSize.width)
            return CGSize(width: scale.width, height: CGFloat(targetHeight))
        }
    }
    
    private func _createVideoSettingsWithBitrate(_ bitrate: Float,
                                                maxKeyFrameInterval: Int,
                                                size: CGSize, 
                                                codec: AVVideoCodecType) -> [String: Any] {
        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoMaxKeyFrameIntervalKey: maxKeyFrameInterval
        ]

        if codec == .h264 {
            compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compressionProperties[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        }

        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
    }
    
    private func videoFirstCodecType(for track: AVAssetTrack) async throws -> AVVideoCodecType {
        let formatDescriptions = try await track.load(.formatDescriptions)
        let codecs = formatDescriptions.compactMap { CMFormatDescriptionGetMediaSubType($0) }
        if codecs.contains(kCMVideoCodecType_HEVC) {
            return .hevc
        } else {
            return .h264
        }
    }


    private func _createAudioSettingsWithAudioTrack(_ audioTrack: AVAssetTrack, bitrate: Float, sampleRate: Int) async throws -> [String: Any] {
        let formatDescriptions = try await audioTrack.load(.formatDescriptions)

        #if DEBUG
        if let formatDescription = formatDescriptions.first {
            print("🔊 Audio")
            print("ORIGINAL:")
            if let streamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
                print("sampleRate: \(streamBasicDescription.pointee.mSampleRate)")
                print("channels: \(streamBasicDescription.pointee.mChannelsPerFrame)")
                print("formatID: \(streamBasicDescription.pointee.mFormatID)")
            }
            
            print("TARGET:")
            print("bitrate: \(bitrate)")
            print("sampleRate: \(sampleRate)")
        }
        #endif
        
        var audioChannelLayout = AudioChannelLayout()
        memset(&audioChannelLayout, 0, MemoryLayout<AudioChannelLayout>.size)
        audioChannelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: bitrate,
            AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: Data(bytes: &audioChannelLayout, count: MemoryLayout<AudioChannelLayout>.size)
        ]
    }

    private func _compress(asset: AVAsset,
                           fileType: AVFileType,
                           _ videoTrack: AVAssetTrack,
                           _ videoSettings: [String: Any],
                           _ audioTrack: AVAssetTrack?,
                           _ audioSettings: [String: Any]?,
                           outputPath: URL,
                           startTime: CMTime, // Added start time parameter
                           endTime: CMTime,   // Added end time parameter
                           metadata: [AVMetadataItem] = []) async throws -> URL {
        // video
        let videoOutput = AVAssetReaderTrackOutput.init(track: videoTrack,
                                                        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                                                            kCVPixelFormatType_32BGRA])
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        videoInput.transform = preferredTransform
        do {
            guard FileManager.default.isValidDirectory(atPath: outputPath) else {
                throw VideoCompressorError.outputPathNotValid(outputPath)
            }
            let assetDuration = try await asset.load(.duration) //asset.duration
            var outputPath = outputPath
            let videoName = UUID().uuidString + ".\(fileType.fileExtension)"
            let adjustedStartTime = min(startTime, assetDuration)
            var adjustedEndTime = min(endTime, assetDuration)
            if adjustedEndTime <= adjustedStartTime {
                adjustedEndTime = assetDuration
            }
            let timeRange = CMTimeRange(start: adjustedStartTime, end: adjustedEndTime)
            outputPath.appendPathComponent("\(videoName)")
            
            // store urls for deleting
            compressVideoPaths.append(outputPath)
            
            let reader = try AVAssetReader(asset: asset)
            let writer = try AVAssetWriter(url: outputPath, fileType: fileType)
            self.reader = reader
            self.writer = writer
            //
            // 메타데이터 추가
            writer.metadata = metadata
            reader.timeRange = timeRange
            
            // video output
            if reader.canAdd(videoOutput) {
                reader.add(videoOutput)
                videoOutput.alwaysCopiesSampleData = false
            }
            if writer.canAdd(videoInput) {
                writer.add(videoInput)
            }
            
            // audio output
            var audioInput: AVAssetWriterInput?
            var audioOutput: AVAssetReaderTrackOutput?
            if let audioTrack = audioTrack, let audioSettings = audioSettings {
                // Specify the number of audio channels we want when decompressing the audio from the asset to avoid error when handling audio data.
                // It really matters when the audio has more than 2 channels, e.g: 'http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4'
                audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
                                                                                   AVNumberOfChannelsKey: 2])
                let adInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput = adInput
                if reader.canAdd(audioOutput!) {
                    reader.add(audioOutput!)
                }
                if writer.canAdd(adInput) {
                    writer.add(adInput)
                }
            }
            
#if DEBUG
            let startTime = Date()
#endif
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    // ... AVAssetReader 및 AVAssetWriter 설정 ...
                    
                    reader.startReading()
                    writer.startWriting()
                    writer.startSession(atSourceTime: CMTime.zero)
                    
                    // output video
                    group.enter()
                    _outputVideoDataByReducingFPS(videoInput: videoInput,
                                                 videoOutput: videoOutput,
                                                 frameIndexArr: []) {
                        self.group.leave()
                    }
                    
                    
                    // output audio
                    if let realAudioInput = audioInput, let realAudioOutput = audioOutput {
                        group.enter()
                        // todo: drop audio sample buffer
                        _outputAudioData(realAudioInput, audioOutput: realAudioOutput, frameIndexArr: []) {
                            self.group.leave()
                        }
                    }
                    
                    // 완료 핸들러
                    group.notify(queue: .main) {
                        switch writer.status {
                        case .writing, .completed:
                            writer.finishWriting {
#if DEBUG
                        let endTime = Date()
                        let elapse = endTime.timeIntervalSince(startTime)
                        print("******** Compression finished ✅**********")
                        print("Compressed video:")
                        print("time: \(elapse)")
                        print("size: \(self._sizePerMB(url: outputPath))M")
                        print("path: \(outputPath)")
                        print("******************************************")
#endif
                                continuation.resume(returning: outputPath)
                            }
                        default:
                            if let error = writer.error {
                                continuation.resume(throwing: error)
                            } else {
                                let unknownError = NSError(domain: "VideoCompression", code: 0, userInfo: [NSLocalizedDescriptionKey: "Unknown compression error"])
                                    continuation.resume(throwing: VideoCompressorError.compressedFailed(unknownError))
                                
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func _outputVideoDataByReducingFPS(videoInput: AVAssetWriterInput,
                                              videoOutput: AVAssetReaderTrackOutput,
                                              frameIndexArr: [Int],
                                              completion: @escaping(() -> Void)) {
        var counter = 0
        var index = 0
        
        videoInput.requestMediaDataWhenReady(on: videoCompressQueue) {
            while videoInput.isReadyForMoreMediaData {
                if let buffer = videoOutput.copyNextSampleBuffer() {
                    if frameIndexArr.isEmpty {
                        videoInput.append(buffer)
                    } else {
                        if index < frameIndexArr.count {
                            let frameIndex = frameIndexArr[index]
                            if counter == frameIndex {
                                index += 1
                                videoInput.append(buffer)
                            }
                            counter += 1
                        } else {
                            // Drop this frame
                            CMSampleBufferInvalidate(buffer)
                        }
                    }
                    
                } else {
                    videoInput.markAsFinished()
                    completion()
                    break
                }
            }
        }
    }
    
    
    private func _sizePerMB(url: URL?) -> Double {
        guard let filePath = url?.path else {
            return 0.0
        }
        do {
            let attribute = try FileManager.default.attributesOfItem(atPath: filePath)
            if let size = attribute[FileAttributeKey.size] as? NSNumber {
                return size.doubleValue / 1000000.0
            }
        } catch {
            print("Error: \(error)")
        }
        return 0.0
    }
    private func _outputAudioData(_ audioInput: AVAssetWriterInput,
                                 audioOutput: AVAssetReaderTrackOutput,
                                 frameIndexArr: [Int],
                                 completion:  @escaping(() -> Void)) {
        
        var counter = 0
        var index = 0
        
        audioInput.requestMediaDataWhenReady(on: audioCompressQueue) {
            while audioInput.isReadyForMoreMediaData {
                if let buffer = audioOutput.copyNextSampleBuffer() {
                    
                    if frameIndexArr.isEmpty {
                        audioInput.append(buffer)
                        counter += 1
                    } else {
                        // append first frame
                        if index < frameIndexArr.count {
                            let frameIndex = frameIndexArr[index]
                            if counter == frameIndex {
                                index += 1
                                audioInput.append(buffer)
                            }
                            counter += 1
                        } else {
                            // Drop this frame
                            CMSampleBufferInvalidate(buffer)
                        }
                    }
                    
                } else {
                    audioInput.markAsFinished()
                    completion()
                    break
                }
            }
        }
    }

}
