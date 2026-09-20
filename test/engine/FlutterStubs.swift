// FlutterStubs.swift — minimal Flutter embedding stubs so the plugin's iOS
// Swift sources (NativeVideoPlayerApi, AV1SoftwarePlayer) compile as a
// headless macOS CLI test. Mirrors only the API surface the plugin touches.
import Foundation

typealias FlutterResult = (Any?) -> Void

struct FlutterError: Error {
    let code: String
    let message: String?
    let details: Any?
}

struct FlutterMethodCall {
    let method: String
    let arguments: Any?
}

protocol FlutterBinaryMessenger {}

class FlutterMethodChannel {
    let name: String
    init(name: String, binaryMessenger: FlutterBinaryMessenger) {
        self.name = name
    }
    func setMethodCallHandler(_ handler: ((FlutterMethodCall, @escaping FlutterResult) -> Void)?) {}
    func invokeMethod(_ method: String, arguments: Any?) {}
}

let FlutterMethodNotImplemented: Any? = nil
