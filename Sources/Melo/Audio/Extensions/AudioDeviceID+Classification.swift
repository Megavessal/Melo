// Melo/Audio/Extensions/AudioDeviceID+Classification.swift
import AppKit
import AudioToolbox

// MARK: - Device Classification

nonisolated extension AudioDeviceID {
    func isAggregateDevice() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var classID: AudioClassID = 0
        var size = UInt32(MemoryLayout<AudioClassID>.size)
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &classID)
        guard err == noErr else { return false }
        return classID == kAudioAggregateDeviceClassID
    }

    func isVirtualDevice() -> Bool {
        readTransportType() == .virtual
    }

    /// Returns the UIDs of an aggregate device's constituent hardware sub-devices,
    /// in the aggregate's channel order, or `nil` if this is not an aggregate.
    ///
    /// Used to *flatten* a user-created aggregate before wrapping it in Melo's own
    /// private aggregate: CoreAudio does not allow an aggregate device to contain another
    /// aggregate as a sub-device (the wrapping aggregate ends up reporting 0 output
    /// channels), so the sub-devices must be expanded into Melo's aggregate directly.
    func aggregateSubDeviceUIDs() -> [String]? {
        guard isAggregateDevice() else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(self, &address) else { return nil }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr else { return nil }

        // kAudioAggregateDevicePropertyFullSubDeviceList returns a +1-retained CFArray of
        // CFString UIDs; takeRetainedValue transfers ownership to ARC.
        var unmanaged: Unmanaged<CFArray>?
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &unmanaged)
        guard err == noErr, let uids = unmanaged?.takeRetainedValue() as? [String], !uids.isEmpty else {
            return nil
        }
        return uids
    }

    func isBluetoothDevice() -> Bool {
        let t = readTransportType()
        return t == .bluetooth || t == .bluetoothLE
    }

    func isHidden() -> Bool {
        (try? readBool(kAudioDevicePropertyIsHidden)) ?? false
    }
}

// MARK: - AutoEQ Eligibility

extension AudioDeviceID {
    /// Returns `true` when Melo should offer AutoEQ headphone correction for this
    /// output.
    ///
    /// An AutoEQ profile is a headphone measurement corrected toward a
    /// head-related target. Applied to a loudspeaker it is not a small
    /// improvement in the wrong direction — it is the wrong correction, and it
    /// makes the speaker measurably worse. So this asks "is there reason to
    /// believe this is a personal listening device, and no reason to believe
    /// otherwise", and answers only the parts CoreAudio can actually answer.
    ///
    /// **What this deliberately cannot know, and what that costs.** CoreAudio
    /// exposes nothing that separates a two-channel USB DAC feeding headphones
    /// from one feeding desktop speakers, and nothing that separates a Bluetooth
    /// headset from a Bluetooth speaker when neither name says so. The decisive
    /// Bluetooth signal is the peer's Bluetooth minor device class (Headphones /
    /// Hands-free versus Loudspeaker), which lives in IOBluetooth rather than
    /// CoreAudio and is not read here.
    ///
    /// So this rule still offers the picker on `Bose SoundLink Mini II`,
    /// `Sonos Roam`, `Genelec 8010` and `KRK Rokit 5` — real loudspeakers whose
    /// names say nothing. `autoEQEligibilityKnownLimitations` in
    /// `scripts/verify-volume-and-eq.py` pins that behaviour so the gap is
    /// visible and dated rather than discovered again.
    ///
    /// The permissive branch is kept because a false negative here is
    /// **unrecoverable**: `DeviceRow.swift` and `AudioEngine.applyAutoEQToTap`
    /// both hard-gate on this one Bool, so a device Melo refuses has no way to
    /// be told otherwise. The fix that would let this exclude by default is a
    /// per-device user override, and it needs `SettingsManager`, `DeviceRow`
    /// and `AutoEQPicker` — see the round-2 report.
    func supportsAutoEQ() -> Bool {
        Self.autoEQEligibility(
            name: (try? readDeviceName()) ?? "",
            transport: readTransportType(),
            isAggregate: isAggregateDevice(),
            outputChannelCount: outputChannelCount(),
            inputChannelCount: autoEQInputChannelCount(),
            builtInHeadphonesActive: builtInHasHeadphonesActive()
        )
    }

    /// The eligibility rule with the CoreAudio reads hoisted out, so the
    /// vocabulary and the ordering can be exercised without a live device — the
    /// same reason `iconSymbol(forName:transport:)` below is a static.
    ///
    /// Order matters twice. The name is read before the structural facts,
    /// because a name that says what a thing is beats a channel count that
    /// only says what shape it is. And within the name, **the loudspeaker
    /// vocabulary is read first**, because it is made of form-factor words
    /// while the headphone vocabulary also carries brands: `Beats Pill Speaker`
    /// is a Bluetooth speaker, and "beats" must not outvote "speaker".
    static func autoEQEligibility(
        name: String,
        transport: TransportType,
        isAggregate: Bool,
        outputChannelCount: Int,
        inputChannelCount: Int,
        builtInHeadphonesActive: Bool
    ) -> Bool {
        // An aggregate or multi-output device is several outputs at once. One
        // headphone correction cannot be right for all of them, and Melo wraps
        // aggregates in its own aggregate anyway.
        if isAggregate { return false }

        switch transport {
        case .hdmi, .displayPort, .airPlay, .virtual, .aggregate:
            // A television, a projector, a receiver, an AirPlay speaker, a
            // loopback device. None of these is worn on a head.
            return false
        case .thunderbolt:
            // Nothing that goes over your ears connects by Thunderbolt. A
            // Thunderbolt audio device is a studio interface or a display, and
            // the interface is the "feeding monitors" case exactly.
            return false
        case .builtIn:
            // The only positive evidence macOS gives away for free: the active
            // data source is the headphone jack.
            return builtInHeadphonesActive
        default:
            break
        }

        if nameIndicatesLoudspeaker(name) { return false }
        if nameIndicatesHeadphones(name) { return true }

        // A pair of headphones is one stereo pair. More output channels than
        // that is a multichannel interface or a surround device. `0` means the
        // stream configuration could not be read, which is not evidence.
        if outputChannelCount > 2 { return false }

        // A device that *captures* stereo is an audio interface or a
        // speakerphone, not a headset: a headset's microphone is mono. This is
        // what catches the two-channel interfaces — `Scarlett Solo USB`,
        // `MOTU M2` — that the output-channel test walks straight past, and it
        // is the "interface feeding monitors" case at its most common size.
        // A headset with a genuine stereo microphone is the false negative this
        // buys. How common that is has not been measured here — one output
        // device on this machine and no survey — so the mitigation is the
        // ordering above: any such device whose name says "headset" or
        // "headphones" never reaches this line.
        if inputChannelCount > 1 { return false }

        // USB, Bluetooth, Bluetooth LE, unknown, with a name that says nothing
        // either way. See the note on `supportsAutoEQ()`.
        return true
    }

    /// Words that mean "worn on a head", plus the two brands that only make
    /// them. Checked *after* `nameIndicatesLoudspeaker`: the brands are weaker
    /// evidence than a form factor, and `Beats Pill Speaker` is a speaker.
    static func nameIndicatesHeadphones(_ name: String) -> Bool {
        let (padded, tokens) = normalizedNameParts(name)
        if !tokens.isDisjoint(with: headphoneWords) { return true }
        return headphonePhrases.contains { padded.contains(" \($0) ") }
    }

    /// Form-factor words that mean "sits in a room". See `loudspeakerWords`.
    static func nameIndicatesLoudspeaker(_ name: String) -> Bool {
        let (padded, tokens) = normalizedNameParts(name)
        if !tokens.isDisjoint(with: loudspeakerWords) { return true }
        return loudspeakerPhrases.contains { padded.contains(" \($0) ") }
    }

    // Token matching rather than `localizedCaseInsensitiveContains`, so "tv"
    // matches "Living Room TV" and not "Sony MDR-1AM2 TV-less Edition", and so
    // hyphens and punctuation in product names do not hide a word.
    private static func normalizedNameParts(_ name: String) -> (padded: String, tokens: Set<String>) {
        let folded = name
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        var cleaned = ""
        cleaned.reserveCapacity(folded.count)
        for character in folded {
            cleaned.append(character.isLetter || character.isNumber ? character : " ")
        }
        let tokens = cleaned.split(separator: " ").map(String.init)
        return (" " + tokens.joined(separator: " ") + " ", Set(tokens))
    }

    private static let headphoneWords: Set<String> = [
        "headphone", "headphones", "headset", "headsets",
        "earphone", "earphones", "earbud", "earbuds", "earpiece",
        "airpod", "airpods", "beats", "iem", "iems", "buds"
    ]

    private static let headphonePhrases: [String] = [
        "in ear", "on ear", "over ear"
    ]

    /// Words that mean "sits in a room". Includes the product names the
    /// original rule hardcoded — HomePod, Apple TV, Studio Display, Pro Display
    /// XDR — which `homepod`, `tv` and `display` all cover.
    ///
    /// **`monitor` was here and has been removed.** A studio monitor is a
    /// loudspeaker, but "monitor" in a CoreAudio device name is far more often
    /// part of a headphone product name — `Beyerdynamic DT 990 Studio Monitor`
    /// is headphones, and the rule refused it. Against that, none of the real
    /// monitors a Mac actually sees (`Genelec 8010`, `KRK Rokit 5`) carry the
    /// word at all; they arrive named after the interface in front of them. It
    /// bought false negatives and caught nothing. `receiver` went with it for
    /// the same reason, minus the false negatives.
    private static let loudspeakerWords: Set<String> = [
        "speaker", "speakers", "loudspeaker", "loudspeakers",
        "soundbar", "soundbars", "subwoofer", "woofer",
        "display", "displays",
        "tv", "television", "homepod", "homepods"
    ]

    private static let loudspeakerPhrases: [String] = [
        "sound bar", "apple tv", "studio display", "pro display xdr"
    ]

    /// Total input channels across this device's input streams.
    ///
    /// Written here rather than beside `outputChannelCount()` in
    /// `AudioDeviceID+Streams.swift` only because that file belongs to another
    /// piece this round. If both survive, they should be one function taking a
    /// scope.
    ///
    /// Returns `0` when the stream configuration cannot be read, which
    /// `autoEQEligibility` treats as absence of evidence rather than as
    /// evidence of absence.
    func autoEQInputChannelCount() -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var mutableSize = size
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &mutableSize, list) == noErr else {
            return 0
        }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Checks if the built-in audio device currently has headphones plugged in
    /// by reading the active data source ID.
    func builtInHasHeadphonesActive() -> Bool {
        guard let sourceID: UInt32 = try? read(
            kAudioDevicePropertyDataSource,
            scope: .output,
            defaultValue: 0
        ), sourceID != 0 else {
            return false
        }

        // 0x6864706E = 'hdpn' — CoreAudio-internal FourCC for headphones, language-independent
        return sourceID == 0x6864706E
    }
}
// MARK: - Device Icon

extension AudioDeviceID {
    func readDeviceIcon() -> NSImage? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIcon,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = UInt32(MemoryLayout<Unmanaged<CFURL>?>.size)
        var iconURL: Unmanaged<CFURL>?
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &iconURL)

        // CoreAudio returns CF objects with +1 retain; takeRetainedValue transfers ownership to ARC
        guard err == noErr, let url = iconURL?.takeRetainedValue() as URL? else {
            return nil
        }

        return NSImage(contentsOf: url)
    }

    /// Returns an appropriate SF Symbol name based on device name and transport type.
    /// Used as fallback when kAudioDevicePropertyIcon is not available.
    func suggestedIconSymbol() -> String {
        let name = (try? readDeviceName()) ?? ""
        let transport = readTransportType()
        return Self.iconSymbol(forName: name, transport: transport)
    }

    /// Pure name + transport → SF Symbol mapping, extracted from `suggestedIconSymbol()`
    /// so the user-visible device-name cascade is unit-testable without a live device.
    static func iconSymbol(forName name: String, transport: TransportType) -> String {
        // AirPods variants
        if name.contains("AirPods Pro") { return "airpodspro" }
        if name.contains("AirPods Max") { return "airpodsmax" }
        if name.contains("AirPods") { return "airpods.gen3" }

        // HomePod variants
        if name.contains("HomePod mini") { return "homepodmini" }
        if name.contains("HomePod") { return "homepod" }

        // Apple TV
        if name.contains("Apple TV") { return "appletv" }

        // Beats
        if name.contains("Beats") { return "beats.headphones" }
        
        // Mac variants
        if name.contains("Mac Studio") { return "macstudio" }
        if name.contains("Mac mini") { return "macmini" }
        if name.contains("MacBook") { return "macbook" }
        if name.contains("iMac") { return "desktopcomputer" }
        
        // Display speakers
        if name.contains("Studio Display") { return "display" }
        if name.contains("Pro Display XDR") { return "display" }

        // Fall back to transport type default
        return transport.defaultIconSymbol
    }

    /// Returns an appropriate SF Symbol name for input devices based on device name and transport type.
    /// Used as fallback when kAudioDevicePropertyIcon is not available.
    func suggestedInputIconSymbol() -> String {
        let name = (try? readDeviceName()) ?? ""
        let transport = readTransportType()

        // iPhone (Continuity Camera)
        if name.contains("iPhone") { return "iphone" }

        // iPad
        if name.contains("iPad") { return "ipad" }

        // AirPods variants (work as both input/output)
        if name.contains("AirPods Pro") { return "airpodspro" }
        if name.contains("AirPods Max") { return "airpodsmax" }
        if name.contains("AirPods") { return "airpods.gen3" }

        // Beats
        if name.contains("Beats") { return "beats.headphones" }

        // MacBook built-in
        if name.contains("MacBook") { return "macbook" }
        
        // Display mic
        if name.contains("Studio Display") { return "display" }
        if name.contains("Pro Display XDR") { return "display" }

        // Transport-based fallbacks
        switch transport {
        case .builtIn:
            return "mic"
        case .usb:
            return "cable.connector"
        case .bluetooth, .bluetoothLE:
            return "mic"
        default:
            return "mic"
        }
    }
}
