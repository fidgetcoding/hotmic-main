// hm-capture — Spike 0 (T0.1)
// Records the default mic and a Core Audio process tap of a DAW (or all system audio)
// through ONE private aggregate device, so both land on the same clock, sample-aligned.
//
// usage: hm-capture --out <dir> [--seconds N] [--bundle com.ableton.live] [--global]

import AppKit
import AVFoundation
import CoreAudio
import Foundation

// MARK: - args

struct Options {
    var out = URL(fileURLWithPath: "capture-\(Int(Date().timeIntervalSince1970))")
    var seconds = 20.0
    var bundle = "com.ableton.live"
    var global = false
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--out": o.out = URL(fileURLWithPath: it.next() ?? o.out.path)
        case "--seconds": o.seconds = Double(it.next() ?? "") ?? o.seconds
        case "--bundle": o.bundle = it.next() ?? o.bundle
        case "--global": o.global = true
        default: fail("unknown arg \(a)")
        }
    }
    return o
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("hm-capture: \(msg)\n".utf8))
    exit(1)
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr { fail("\(what) failed (OSStatus \(status))") }
}

// MARK: - Core Audio property helpers

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func readValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                  qualifier: Any? = nil, initial: T) -> T {
    var addr = address(selector, scope)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status: OSStatus
    if var q = qualifier as? pid_t {
        status = AudioObjectGetPropertyData(object, &addr, UInt32(MemoryLayout<pid_t>.size), &q, &size, &value)
    } else {
        status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    }
    check(status, "get property \(selector)")
    return value
}

func deviceUID(_ device: AudioObjectID) -> String {
    let uid: CFString = readValue(device, kAudioDevicePropertyDeviceUID, initial: "" as CFString)
    return uid as String
}

func deviceName(_ device: AudioObjectID) -> String {
    let name: CFString = readValue(device, kAudioObjectPropertyName, initial: "" as CFString)
    return name as String
}

/// Channel count of each input stream, in stream order.
func inputStreamChannels(_ device: AudioObjectID) -> [Int] {
    var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    check(AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size), "stream config size")
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw), "stream config")
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.map { Int($0.mNumberChannels) }
}

// MARK: - setup

let opts = parseOptions()
try? FileManager.default.createDirectory(at: opts.out, withIntermediateDirectories: true)

let system = AudioObjectID(kAudioObjectSystemObject)
let micDevice: AudioObjectID = readValue(system, kAudioHardwarePropertyDefaultInputDevice, initial: 0)
let outDevice: AudioObjectID = readValue(system, kAudioHardwarePropertyDefaultOutputDevice, initial: 0)
let micChannels = inputStreamChannels(micDevice)

// Tap: one DAW process, or everything the Mac plays.
let tapDescription: CATapDescription
var tapSource = "global"
if opts.global {
    tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
} else {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: opts.bundle).first else {
        fail("\(opts.bundle) is not running (use --global to tap all system audio)")
    }
    let process: AudioObjectID = readValue(system, kAudioHardwarePropertyTranslatePIDToProcessObject,
                                           qualifier: app.processIdentifier, initial: 0)
    if process == kAudioObjectUnknown { fail("\(opts.bundle) has no audio process object yet — press play once") }
    tapDescription = CATapDescription(stereoMixdownOfProcesses: [process])
    tapSource = "\(opts.bundle) pid \(app.processIdentifier)"
}
tapDescription.uuid = UUID()
tapDescription.isPrivate = true
tapDescription.muteBehavior = .unmuted

var tapID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "AudioHardwareCreateProcessTap")

// Aggregate: the mic is the clock master; the tap is drift-compensated onto it.
let aggregateUID = "io.bluegum.hotmic.spike.\(UUID().uuidString)"
let aggregateDescription: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Hot Mic Spike",
    kAudioAggregateDeviceUIDKey: aggregateUID,
    kAudioAggregateDeviceMainSubDeviceKey: deviceUID(micDevice),
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID(micDevice)]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                       kAudioSubTapUIDKey: tapDescription.uuid.uuidString]],
]
var aggregate = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate),
      "AudioHardwareCreateAggregateDevice")

let sampleRate: Float64 = readValue(aggregate, kAudioDevicePropertyNominalSampleRate, initial: 0)
let aggregateChannels = inputStreamChannels(aggregate)
print("mic:       \(deviceName(micDevice)) streams \(micChannels)")
print("output:    \(deviceName(outDevice))")
print("tap:       \(tapSource)")
print("aggregate: \(Int(sampleRate)) Hz, input streams \(aggregateChannels)")

// MARK: - writers

/// Assumption checked by inspect.py: aggregate input = mic streams first, then tap streams.
final class Writers {
    var files: [AVAudioFile] = []
    var formats: [AVAudioFormat] = []
    var frames = 0
    var firstHostTime: UInt64 = 0
    var firstSampleTime: Float64 = 0

    init(channels: [Int], micStreamCount: Int, rate: Double, dir: URL) {
        for (i, ch) in channels.enumerated() {
            let name = i < micStreamCount ? "mic\(i).wav" : "session\(i - micStreamCount).wav"
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                AVNumberOfChannelsKey: ch, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            ]
            do {
                let file = try AVAudioFile(forWriting: dir.appendingPathComponent(name), settings: settings,
                                           commonFormat: .pcmFormatFloat32, interleaved: true)
                files.append(file)
                formats.append(file.processingFormat)
            } catch { fail("open \(name): \(error)") }
        }
    }

    func write(_ input: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        if frames == 0 { firstHostTime = time.pointee.mHostTime; firstSampleTime = time.pointee.mSampleTime }
        for (i, src) in list.enumerated() where i < files.count {
            let ch = Int(src.mNumberChannels)
            let count = Int(src.mDataByteSize) / (MemoryLayout<Float>.size * max(ch, 1))
            guard count > 0, let data = src.mData,
                  let buf = AVAudioPCMBuffer(pcmFormat: formats[i], frameCapacity: AVAudioFrameCount(count))
            else { continue }
            buf.frameLength = AVAudioFrameCount(count)
            memcpy(buf.mutableAudioBufferList.pointee.mBuffers.mData, data, Int(src.mDataByteSize))
            try? files[i].write(from: buf)
            if i == 0 { frames += count }
        }
    }
}

let writers = Writers(channels: aggregateChannels, micStreamCount: micChannels.count, rate: sampleRate, dir: opts.out)
let ioQueue = DispatchQueue(label: "hm-capture.io", qos: .userInteractive)
var procID: AudioDeviceIOProcID?
check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, ioQueue) { _, input, inputTime, _, _ in
    writers.write(input, inputTime)
}, "AudioDeviceCreateIOProcIDWithBlock")

// MARK: - run

check(AudioDeviceStart(aggregate, procID), "AudioDeviceStart")
print("recording \(opts.seconds)s → \(opts.out.path)")
Thread.sleep(forTimeInterval: opts.seconds)
check(AudioDeviceStop(aggregate, procID), "AudioDeviceStop")
ioQueue.sync {}

writers.files.forEach { $0.close() }  // finalizes WAV headers
AudioDeviceDestroyIOProcID(aggregate, procID!)
AudioHardwareDestroyAggregateDevice(aggregate)
AudioHardwareDestroyProcessTap(tapID)

let meta: [String: Any] = [
    "sample_rate": sampleRate, "frames": writers.frames,
    "mic_device": deviceName(micDevice), "mic_streams": micChannels,
    "output_device": deviceName(outDevice), "tap": tapSource,
    "aggregate_streams": aggregateChannels,
    "first_host_time": writers.firstHostTime, "first_sample_time": writers.firstSampleTime,
]
let json = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
try json.write(to: opts.out.appendingPathComponent("meta.json"))
print("done: \(writers.frames) frames (\(String(format: "%.2f", Double(writers.frames) / sampleRate))s)")
