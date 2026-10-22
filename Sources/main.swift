import Cocoa

// Decaffeinate is a fork of Pilot Light by sudolabs (https://github.com/CyrisXD/pilot-light, MIT).
// It keeps a MacBook awake with the lid closed while you're logged in, switches it to
// Low Power Mode and turns the display off, then puts everything back when the lid opens.
// Logging out, switching users or quitting restores normal lid-close sleep, and so does locking the
// screen when "Keep awake when screen locked" is off.

if CommandLine.arguments.contains("--selftest") { selftest() }

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
