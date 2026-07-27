import Foundation

struct SemanticModelFile {
    let relativePath: String
    let sha256: String
    let byteCount: Int64
}

enum SemanticTokenizerKind: String {
    case clipBPE
}

struct SemanticModelDescriptor {
    let id: String
    let displayName: String
    let summary: String
    let license: String
    let licenseNotice: String
    let embeddingDimension: Int
    let imageSide: Int
    let contextLength: Int
    let tokenizer: SemanticTokenizerKind
    let imageInputName: String
    let textInputName: String
    let outputName: String
    let files: [SemanticModelFile]

    var totalByteCount: Int64 {
        files.reduce(0) { $0 + $1.byteCount }
    }

    var imagePackageRelativePath: String { "image.mlpackage" }
    var textPackageRelativePath: String { "text.mlpackage" }
    var tokenizerRelativePath: String { "tokenizer/merges.txt" }
}

enum SemanticModelCatalog {
    static let defaultIdentifier = "vitb32-laion2b-fp16"

    static var downloadBase: URL? {
        if let override = UserDefaults.standard.string(forKey: "semanticModelBaseURL"), let url = URL(string: override) {
            return url
        }
        return URL(string: fallbackBase)
    }

    private static let fallbackBase = "https://huggingface.co/suhunhan95/sukurini-models/resolve/main"

    static let all: [SemanticModelDescriptor] = [vitB32Laion2B]

    static func descriptor(id: String) -> SemanticModelDescriptor? {
        all.first { $0.id == id }
    }

    static func resolved(id: String?) -> SemanticModelDescriptor {
        if let id, let found = descriptor(id: id) { return found }
        return all.first { $0.id == defaultIdentifier } ?? all[0]
    }

    static func remoteURL(for descriptor: SemanticModelDescriptor, file: SemanticModelFile) -> URL? {
        guard let base = downloadBase else { return nil }
        return base
            .appendingPathComponent(descriptor.id, isDirectory: true)
            .appendingPathComponent(file.relativePath)
    }

    private static let vitB32Laion2B = SemanticModelDescriptor(
        id: defaultIdentifier,
        displayName: "OpenCLIP ViT-B/32 (LAION-2B)",
        summary: "Balanced quality. 290 MB download.",
        license: "MIT",
        licenseNotice: "OpenCLIP — Copyright (c) 2012-2021 Gabriel Ilharco, Mitchell Wortsman, Nicholas Carlini, Rohan Taori, Achal Dave, Vaishaal Shankar, John Miller, Hongseok Namkoong, Hannaneh Hajishirzi, Ali Farhadi, Ludwig Schmidt. Released under the MIT License.",
        embeddingDimension: 512,
        imageSide: 224,
        contextLength: 77,
        tokenizer: .clipBPE,
        imageInputName: "image",
        textInputName: "text",
        outputName: "final_emb_1",
        files: [
            SemanticModelFile(
                relativePath: "image.mlpackage/Manifest.json",
                sha256: "7ae0b05a145d696dc61d7db72c7b0b5ac6810fa5dd99ecd64fcc5670bd5944c1",
                byteCount: 617
            ),
            SemanticModelFile(
                relativePath: "image.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                sha256: "d4b9a5677de83bcc8220e5fd39fc754a9dddef6f4d8ca04bc2e391f3c1389ff6",
                byteCount: 138_261
            ),
            SemanticModelFile(
                relativePath: "image.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                sha256: "78d9e68dc91dcdcbd1e51372db06e2a26a9daeaf0b206735f8c456dd6df989ef",
                byteCount: 175_712_384
            ),
            SemanticModelFile(
                relativePath: "text.mlpackage/Manifest.json",
                sha256: "eb1f53b4c2620cc8e8e3e5accabb084b74ffd388752b2c01d902359317f2b27a",
                byteCount: 617
            ),
            SemanticModelFile(
                relativePath: "text.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                sha256: "25305532823492c9dbe8ffd23f381843763b9746bd701ee6f747e513c4a6aee4",
                byteCount: 137_570
            ),
            SemanticModelFile(
                relativePath: "text.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                sha256: "35c55701196cd3d6aa9bc89f9052a5e044bc8bd3e08b2a5ed419fc1980397e21",
                byteCount: 126_881_920
            ),
            SemanticModelFile(
                relativePath: "tokenizer/merges.txt",
                sha256: "d308b7377a8ceaa9707a21614fe8c831b9196e197b7aeb69833359362907af02",
                byteCount: 524_605
            )
        ]
    )
}
