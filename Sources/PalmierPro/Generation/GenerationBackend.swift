import Foundation
import Combine
@preconcurrency import ConvexMobile

/// The RPC layer for the backend
@MainActor
enum GenerationBackend {
    private static var subjects = [String: PassthroughSubject<BackendGenerationJob?, ClientError>]()

    /// Reactive subscription to a single generation job pushed by Convex.
    static func subscribe(
        jobId: String
    ) -> AnyPublisher<BackendGenerationJob?, ClientError>? {
        if let subject = subjects[jobId] {
            return subject.eraseToAnyPublisher()
        }
        let subject = PassthroughSubject<BackendGenerationJob?, ClientError>()
        subjects[jobId] = subject
        return subject.eraseToAnyPublisher()
    }

    /// Uploads a file to backend in three steps (Bypassed: returns local path URL)
    static func uploadReference(
        fileURL: URL,
        contentType: String
    ) async throws -> String {
        return fileURL.absoluteString
    }

    static func submit(
        model: String,
        params: BackendGenerationParams,
        projectId: String? = nil
    ) async throws -> String {
        let jobId = "job-" + UUID().uuidString.prefix(8)
        let subject = PassthroughSubject<BackendGenerationJob?, ClientError>()
        subjects[jobId] = subject
        
        Task {
            // 1. queued
            let queuedJob = BackendGenerationJob(_id: jobId, status: .queued, resultUrls: nil, errorMessage: nil, costCredits: 0, completedAt: nil)
            subject.send(queuedJob)
            
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            // 2. running
            let runningJob = BackendGenerationJob(_id: jobId, status: .running, resultUrls: nil, errorMessage: nil, costCredits: 0, completedAt: nil)
            subject.send(runningJob)
            
            // 3. run local generation
            do {
                let resultURL = try await runLocalGeneration(model: model, params: params)
                
                // 4. succeeded
                let succeededJob = BackendGenerationJob(
                    _id: jobId,
                    status: .succeeded,
                    resultUrls: [resultURL.absoluteString],
                    errorMessage: nil,
                    costCredits: 0,
                    completedAt: Date().timeIntervalSince1970
                )
                subject.send(succeededJob)
            } catch {
                // 5. failed
                let failedJob = BackendGenerationJob(
                    _id: jobId,
                    status: .failed,
                    resultUrls: nil,
                    errorMessage: error.localizedDescription,
                    costCredits: 0,
                    completedAt: Date().timeIntervalSince1970
                )
                subject.send(failedJob)
            }
        }
        
        return jobId
    }

    private static func runLocalGeneration(
        model: String,
        params: BackendGenerationParams
    ) async throws -> URL {
        switch params {
        case .video(let videoParams):
            return try await generateLocalVideo(prompt: videoParams.prompt, model: model)
        case .image(let imageParams):
            return try await generateLocalImage(prompt: imageParams.prompt, model: model)
        case .audio(let audioParams):
            return try await generateLocalAudio(prompt: audioParams.prompt, model: model)
        case .upscale(let upscaleParams):
            return try await generateLocalUpscale(model: model)
        }
    }

    private static func generateLocalVideo(prompt: String, model: String) async throws -> URL {
        let scratchDir = "/Users/yutakawaguchi/Macbook_Code/Tsumugi_Studio/scratch"
        let pythonBin = "/Users/yutakawaguchi/Macbook_Code/Tsumugi_Studio/experiments/video_generation/.venv/bin/python"
        let outputDir = "/Users/yutakawaguchi/Macbook_Code/Tsumugi_Studio/downloads"
        let fileId = UUID().uuidString.prefix(8)
        let outputPath = "\(outputDir)/gen-video-\(fileId).mp4"
        
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        
        let bridgeScript = "\(scratchDir)/generate_video_cli.py"
        let args = [bridgeScript, "--prompt", prompt, "--output", outputPath]
        
        let output = try await runProcess(executable: pythonBin, arguments: args)
        if output.contains("SUCCESS:") || output.contains("FALLBACK_SUCCESS:") {
            return URL(fileURLWithPath: outputPath)
        } else {
            throw NSError(domain: "GenerationBackend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video generation failed: \(output)"])
        }
    }

    private static func generateLocalImage(prompt: String, model: String) async throws -> URL {
        let scratchDir = "/Users/yutakawaguchi/Macbook_Code/Tsumugi_Studio/scratch"
        let pythonBin = "python3"
        let outputDir = "/Users/yutakawaguchi/Macbook_Code/Tsumugi_Studio/downloads"
        let fileId = UUID().uuidString.prefix(8)
        let outputPath = "\(outputDir)/gen-image-\(fileId).png"
        
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        
        let bridgeScript = "\(scratchDir)/generate_image_cli.py"
        let args = [bridgeScript, "--prompt", prompt, "--output", outputPath]
        
        let output = try await runProcess(executable: pythonBin, arguments: args)
        if output.contains("SUCCESS:") || output.contains("FALLBACK_SUCCESS:") {
            return URL(fileURLWithPath: outputPath)
        } else {
            throw NSError(domain: "GenerationBackend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Image generation failed: \(output)"])
        }
    }

    private static func generateLocalAudio(prompt: String, model: String) async throws -> URL {
        let outputDir = "/Users/yutakawaguchi/Macbook_Code/Tsumugi_Studio/downloads"
        let fileId = UUID().uuidString.prefix(8)
        let outputPath = "\(outputDir)/gen-audio-\(fileId).mp3"
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
            "-t", "5", "-c:a", "libmp3lame", outputPath
        ]
        try await Task.detached {
            try process.run()
            process.waitUntilExit()
        }.value
        
        return URL(fileURLWithPath: outputPath)
    }

    private static func generateLocalUpscale(model: String) async throws -> URL {
        let outputDir = "/Users/yutakawaguchi/Macbook_Code/Tsumugi_Studio/downloads"
        let fileId = UUID().uuidString.prefix(8)
        let outputPath = "\(outputDir)/gen-upscale-\(fileId).png"
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-y", "-f", "lavfi", "-i", "color=c=gray:s=1920x1080:d=1",
            "-vframes", "1", outputPath
        ]
        try await Task.detached {
            try process.run()
            process.waitUntilExit()
        }.value
        
        return URL(fileURLWithPath: outputPath)
    }

    private static func runProcess(executable: String, arguments: [String]) async throws -> String {
        return try await Task.detached(priority: .background) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
            
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            
            try process.run()
            process.waitUntilExit()
            
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            if process.terminationStatus != 0 {
                throw NSError(
                    domain: "GenerationBackend",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Process exited with \(process.terminationStatus). Output: \(output)"]
                )
            }
            return output
        }.value
    }
}

// MARK: - Backend generation types

enum BackendGenerationParams: Encodable, ConvexEncodable, Sendable {
    case video(VideoGenerationParams)
    case image(ImageGenerationParams)
    case audio(AudioGenerationParams)
    case upscale(UpscaleGenerationParams)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .video(let p): try c.encode(p)
        case .image(let p): try c.encode(p)
        case .audio(let p): try c.encode(p)
        case .upscale(let p): try c.encode(p)
        }
    }
}

enum BackendGenerationStatus: String, Decodable, Sendable {
    case queued, running, succeeded, failed
}

struct BackendGenerationJob: Decodable, Sendable {
    let _id: String
    let status: BackendGenerationStatus
    let resultUrls: [String]?
    let errorMessage: String?
    let costCredits: Int?
    let completedAt: Double?
}

enum GenerationBackendError: LocalizedError {
    case notConfigured
    case transport(String)
    case api(status: Int, code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Palmier backend not configured."
        case .transport(let s): return s
        case .api(_, _, let message): return message
        }
    }
}

private struct StagingTicket: Decodable, Sendable {
    let uploadUrl: String
}

private struct StagingUploadResponse: Decodable, Sendable {
    let storageId: String
}

private struct UrlResponse: Decodable, Sendable {
    let url: String
}

private struct SubmitGenerationResult: Decodable, Sendable {
    let jobId: String
}

private struct BackendErrorEnvelope: Decodable, Sendable {
    struct Inner: Decodable, Sendable {
        let code: String
        let message: String
    }
    let error: Inner
}
