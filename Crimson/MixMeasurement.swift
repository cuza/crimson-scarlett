import AVFoundation
import CoreAudio
import ScarlettKit

/// Measures the device's mix levels, which its firmware won't report: a quiet tone plays on the last
/// playback channel the device meters, each mixer input in turn is switched to it, and the mix meters show how much
/// reaches every mix. Outputs are muted and every mixer input is restored afterwards.
@MainActor
enum MixMeasurement {
    enum Failure: Error { case noAudioDevice, readFailed }

    /// Mix levels as `[mixerInput][mix]` dB, nil where nothing arrives. `original` is the device state
    /// read just before, used to put mixer inputs and mutes back.
    static func measure(session: DeviceSession, original: DeviceReadback,
                        progress: @escaping (Double) -> Void) async throws -> [[Double?]] {
        let model = session.model
        let tone = try TonePlayer(deviceName: model.name, meteredChannels: model.pcmMeterCount)
        let toneSource = Source.pcm(tone.channel + 1)
        typealias P = Gen1Protocol

        func muteAll(_ muted: [Bool]) -> [ControlRequest] {
            model.outputPairs.indices.flatMap { p in (0...1).map { P.outputMute(pair: p, channel: $0, muted: muted[p]) } }
        }
        func setInput(_ i: Int, _ s: Source) -> ControlRequest { P.mixerInputSource(input: i, value: model.value(of: s)) }

        // Restore runs whatever happens below.
        func restore() async {
            tone.stop()
            await session.sendUntracked(original.mixerInputs.enumerated().map { setInput($0, $1) }
                                        + muteAll(original.outputMuted))
        }

        await session.sendUntracked(muteAll(Array(repeating: true, count: model.outputPairs.count))
                                    + (0..<model.matrixInputs).map { setInput($0, .off) })
        do {
            try tone.start()
            try await Task.sleep(for: .milliseconds(400))
            guard let reference = await session.readMeters()?.level(of: toneSource, model: model), reference > -60
            else { throw Failure.readFailed }

            var rows: [[Double?]] = []
            for i in 0..<model.matrixInputs {
                await session.sendUntracked([setInput(i, toneSource)])
                try await Task.sleep(for: .milliseconds(120))
                _ = await session.readMeters()              // clear peaks from before the switch
                try await Task.sleep(for: .milliseconds(150))
                guard let m = await session.readMeters() else { throw Failure.readFailed }
                rows.append(m.mixes.prefix(model.mixCount).map { $0 > -95 ? $0 - reference : nil })
                await session.sendUntracked([setInput(i, .off)])
                progress(Double(i + 1) / Double(model.matrixInputs))
            }
            await restore()
            return rows
        } catch {
            await restore()
            throw error
        }
    }
}

/// A 1 kHz tone at -12 dBFS on one output channel only: the last one the device meters, so the tone's level
/// can be read back as the reference. The device meters at most 8 playback channels.
@MainActor
private final class TonePlayer {
    /// Shared with the audio thread, which only advances the phase.
    private final class Phase: @unchecked Sendable { var value = 0.0 }

    let channel: Int
    private let engine = AVAudioEngine()

    init(deviceName: String, meteredChannels: Int) throws {
        guard var device = Self.outputDevice(named: deviceName) else { throw MixMeasurement.Failure.noAudioDevice }
        let unit = engine.outputNode.audioUnit!
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        let channels = hardware.channelCount
        channel = min(Int(channels), meteredChannels) - 1
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
        else { throw MixMeasurement.Failure.noAudioDevice }
        let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channelLayout: layout)
        let source = AVAudioSourceNode(format: format,
                                       renderBlock: Self.renderTone(rate: hardware.sampleRate, channel: channel))
        engine.attach(source)
        engine.connect(source, to: engine.outputNode, format: format)
    }

    /// Built outside the main actor: Core Audio calls it on its own audio thread.
    private nonisolated static func renderTone(rate: Double, channel: Int) -> AVAudioSourceNodeRenderBlock {
        let phase = Phase()
        return { _, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for f in 0..<Int(frames) {
                let v = Float(0.25 * sin(phase.value))
                phase.value += 2 * .pi * 1000 / rate
                for (c, b) in buffers.enumerated() { b.mData!.assumingMemoryBound(to: Float.self)[f] = c == channel ? v : 0 }
            }
            return noErr
        }
    }

    func start() throws { try engine.start() }
    func stop() { engine.stop() }

    private static func outputDevice(named name: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        return ids.first { id in
            var cfName: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                         mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &cfName) == noErr,
                  let deviceName = cfName?.takeRetainedValue() as String?, deviceName.contains(name) else { return false }
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize)
            return streamSize > 0
        }
    }
}
