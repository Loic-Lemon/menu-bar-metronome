import Foundation

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
}
MetronomeApp.main()
