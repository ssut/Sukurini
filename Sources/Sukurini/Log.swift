import Foundation
import os

enum Log {
    static let subsystem = "sukurini"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let watcher = Logger(subsystem: subsystem, category: "watcher")
    static let statusItem = Logger(subsystem: subsystem, category: "statusItem")
    static let drag = Logger(subsystem: subsystem, category: "drag")
    static let paste = Logger(subsystem: subsystem, category: "paste")
    static let gallery = Logger(subsystem: subsystem, category: "gallery")
    static let thumbnail = Logger(subsystem: subsystem, category: "thumbnail")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let system = Logger(subsystem: subsystem, category: "system")
    static let search = Logger(subsystem: subsystem, category: "search")
    static let ocr = Logger(subsystem: subsystem, category: "ocr")
    static let convert = Logger(subsystem: subsystem, category: "convert")
    static let organize = Logger(subsystem: subsystem, category: "organize")
    static let telemetry = Logger(subsystem: subsystem, category: "telemetry")
    static let semantic = Logger(subsystem: subsystem, category: "semantic")
    static let semanticModel = Logger(subsystem: subsystem, category: "semanticModel")
    static let vectors = Logger(subsystem: subsystem, category: "vectors")
    static let update = Logger(subsystem: subsystem, category: "update")
}
