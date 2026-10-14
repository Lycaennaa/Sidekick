import AppKit

@MainActor
enum NewFileNamePrompt {
    static func run(
        in directory: URL,
        fileStore: NewFileStore
    ) {
        let field = NSTextField(string: "New File")
        field.isEditable = true
        field.isSelectable = true
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        let locationText = "Location: \(directory.standardizedFileURL.path)"
        var informativeText = "Enter a filename, including any extension.\n\(locationText)"

        while true {
            let alert = NSAlert()
            alert.messageText = "Create New File"
            alert.informativeText = informativeText
            alert.accessoryView = field
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")
            alert.layout()
            alert.window.initialFirstResponder = field
            NSApp.activate()
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
            alert.window.makeKeyAndOrderFront(nil)
            _ = alert.window.makeFirstResponder(field)
            field.selectText(nil)

            guard alert.runModal() == .alertFirstButtonReturn else { return }

            do {
                _ = try fileStore.createEmptyFile(in: directory, named: field.stringValue)
                return
            } catch NewFileError.nameAlreadyExists(let name) {
                informativeText = "An item named ‘\(name)’ already exists. Choose another name.\n\(locationText)"
            } catch NewFileError.invalidName {
                informativeText = "Enter a valid filename without a slash.\n\(locationText)"
            } catch {
                presentError(error)
                return
            }
        }
    }


    private static func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        NSApp.activate()
        alert.runModal()
    }
}
