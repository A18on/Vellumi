import os

enum MoltenLog {
    private static let subsystem = "com.aaron.vellumi"

    static let document = Logger(subsystem: subsystem, category: "document")
    static let editor = Logger(subsystem: subsystem, category: "editor")
}
