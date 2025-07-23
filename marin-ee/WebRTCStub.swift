#if !canImport(WebRTC)
import Foundation
import UIKit
import AVFoundation
import CoreMedia
import SwiftUI

// MARK: - Minimal WebRTC stubs for build without actual dependency

enum RTCPeerConnectionState { case connected, failed }

struct RTCIceServer { var urlStrings: [String] }
struct RTCConfiguration { var iceServers: [RTCIceServer] = [] }
struct RTCMediaConstraints {
    init(mandatoryConstraints: [String: String]?, optionalConstraints: [String: String]?) {}
}

class RTCIceCandidate {
    var sdpMid: String?
    var sdpMLineIndex: Int32 = 0
    var sdp: String = ""
    init() {}
}

class RTCVideoTrack {
    func add(_ view: RTCMTLVideoView) {}
}

class RTCMediaStream {
    func addVideoTrack(_ track: RTCVideoTrack) {}
    var videoTracks: [RTCVideoTrack] { [] }
}

class RTCPeerConnection {}

extension RTCPeerConnection {
    func add(_ stream: RTCMediaStream) {}
    func close() {}
}

protocol RTCPeerConnectionDelegate {}

class RTCPeerConnectionFactory {
    func peerConnection(with config: RTCConfiguration,
                        constraints: RTCMediaConstraints,
                        delegate: RTCPeerConnectionDelegate?) -> RTCPeerConnection { RTCPeerConnection() }
    func videoSource() -> AVCaptureVideoDataOutput { AVCaptureVideoDataOutput() }
    func videoTrack(with source: AVCaptureVideoDataOutput, trackId: String) -> RTCVideoTrack { RTCVideoTrack() }
    func mediaStream(withStreamId id: String) -> RTCMediaStream { RTCMediaStream() }
}

class RTCCameraVideoCapturer {
    init(delegate: AVCaptureVideoDataOutput) {}
    static func captureDevices() -> [AVCaptureDevice] { [] }
    static func supportedFormats(for device: AVCaptureDevice) -> [AVCaptureDevice.Format] { [] }
    var delegate: AVCaptureVideoDataOutput?
    func startCapture(with device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int) {}
    func stopCapture() {}
}

class RTCMTLVideoView: UIView {}
#endif 