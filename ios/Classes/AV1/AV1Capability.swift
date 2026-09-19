// AV1Capability.swift — runtime AV1 hardware-decode probe.
//
// ADDITIVE file. Decides whether a source must use the software path.
// Everything else keeps flowing to AVPlayer untouched.

import AVFoundation
import VideoToolbox

enum AV1Capability {
    /// True when the device can hardware-decode AV1 (A17 Pro / M3 and newer).
    /// On such devices AVPlayer handles AV1 natively and we never engage the
    /// software player.
    static var hasHardwareDecoder: Bool {
        VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }
}
