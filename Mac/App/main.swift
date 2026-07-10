import AppKit

// main.swift top level runs on the main thread; assert it for the actor system.
let delegate = MainActor.assumeIsolated { MoltenAppDelegate() }
MainActor.assumeIsolated {
    // Instantiating our subclass FIRST makes it the shared controller.
    _ = MoltenDocumentController()
    NSApplication.shared.delegate = delegate
}
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
