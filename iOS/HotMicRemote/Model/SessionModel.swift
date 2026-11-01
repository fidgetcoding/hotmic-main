import AVFoundation
import Observation
import SessionKit

/// Everything the screens show, and the glue between the session client and the audio engine.
@MainActor @Observable
final class SessionModel {
    enum Phase: Equatable { case home, connecting, waiting, joined, denied(String), unreachable }

    var name: String {
        didSet {
            Identity.name = name
            client?.setName(name)
        }
    }
    var nearby: [NearbyHost] = []
    var phase: Phase = .home
    /// Who we're trying to reach, for the waiting screen.
    var hostLabel = ""
    var welcome: Welcome?
    var reconnecting = false
    var interrupted = false
    var status: Status?
    var takes: [TakeNotice] = []
    var level: Float = 0
    /// The singer's choice; only engages while headphones are actually plugged in.
    var headphonesMode = false { didSet { applyMode() } }
    var headphonesConnected = AudioEngine.headphonesConnected
    var beatVolume: Float = 0.8 { didSet { audio.setBeatVolume(beatVolume) } }
    /// A problem worth a sentence on the home screen (mic permission, audio failure).
    var problem: String?
    var showScanner = false
    /// Opened from a link or the Camera app before the singer had a name: joins once they add one.
    var pendingInvite: JoinInvite?
    /// Nearby: six digits the host should see too.
    var approvalCode = ""
    /// A link or QR code waiting for the singer's yes: joining starts the mic.
    var inviteToConfirm: JoinInvite?

    var hasName: Bool { !NameRules.clean(name).isEmpty }
    var beatOnPhone: Bool { headphonesMode && headphonesConnected }
    /// Headphones mode was asked for but the beat would come out of the phone's speaker.
    var headphonesMissing: Bool { headphonesMode && !headphonesConnected }

    @ObservationIgnored private let audio = AudioEngine()
    @ObservationIgnored private let browser = SessionBrowser()
    @ObservationIgnored private var client: SessionClient?
    @ObservationIgnored private var micRunning = false
    @ObservationIgnored private var appliedHeadphones = false
    /// Arrived while the scanner sheet was up; asked once that sheet has gone.
    @ObservationIgnored private var scannedInvite: JoinInvite?

    init() {
        name = Identity.name
        browser.onChange = { [weak self] hosts in MainActor.assumeIsolated { self?.nearby = hosts } }
        audio.onLevel = { [weak self] level in MainActor.assumeIsolated { self?.level = level } }
        audio.onRouteChange = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.headphonesConnected = AudioEngine.headphonesConnected
                self.applyMode()
            }
        }
        audio.onInterrupted = { [weak self] on in MainActor.assumeIsolated { self?.interrupted = on } }
        browser.start()
    }

    // MARK: - joining

    func join(_ invite: JoinInvite) {
        guard hasName else { pendingInvite = invite; return }
        pendingInvite = nil
        showScanner = false
        hostLabel = invite.hostName
        connect { $0.join(invite) }
    }

    func join(_ host: NearbyHost) {
        guard hasName else { return }
        hostLabel = host.name
        connect { $0.join(host) }
    }

    /// Opened by the Camera app scanning the Mac's QR code (or any hotmic:// link).
    func open(_ url: URL) {
        guard let invite = JoinInvite(url: url) else { return }
        ask(invite)
    }

    /// Nothing joins, and the mic stays off, until the singer says yes.
    func ask(_ invite: JoinInvite) {
        if showScanner {
            scannedInvite = invite
            showScanner = false
        } else {
            inviteToConfirm = invite
        }
    }

    func scannerDismissed() {
        inviteToConfirm = scannedInvite ?? inviteToConfirm
        scannedInvite = nil
    }

    func confirmInvite() {
        guard let invite = inviteToConfirm else { return }
        inviteToConfirm = nil
        if phase != .home { leave() }
        join(invite)
    }

    func leave() {
        client?.leave()
        client = nil
        stopMic()
        phase = .home
        welcome = nil
        reconnecting = false
        interrupted = false
        status = nil
    }

    private func connect(_ start: @escaping (SessionClient) -> Void) {
        problem = nil
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                problem = "Hot Mic needs the microphone. Turn it on in Settings › Hot Mic."
                return
            }
            if client != nil { leave() }
            let rate: Double
            do { rate = try audio.prepareSession() } catch {
                problem = "Couldn't open the microphone: \(error.localizedDescription)"
                return
            }
            headphonesConnected = AudioEngine.headphonesConnected
            let client = SessionClient(name: NameRules.clean(name), identity: Identity.session,
                                       sampleRate: rate, headphones: beatOnPhone)
            client.hostKeys = SavedHostKeys()
            client.onState = { [weak self] state in MainActor.assumeIsolated { self?.handle(state) } }
            client.onStatus = { [weak self] status in MainActor.assumeIsolated { self?.status = status } }
            client.onTake = { [weak self] take in MainActor.assumeIsolated { self?.takes.insert(take, at: 0) } }
            let beat = audio.beat
            client.onBeat = { beat.push($0) }
            self.client = client
            appliedHeadphones = beatOnPhone
            takes = []
            status = nil
            phase = .connecting
            start(client)
        }
    }

    private func handle(_ state: SessionClient.State) {
        switch state {
        case .idle:
            break
        case .connecting:
            if phase != .joined { phase = .connecting }
        case let .waitingForApproval(code):
            approvalCode = code
            phase = .waiting
        case let .joined(welcome):
            self.welcome = welcome
            reconnecting = false
            phase = .joined
            if !micRunning { startMic(from: welcome.nextFrame) }
        case .reconnecting:
            reconnecting = true
        case let .denied(reason):
            client = nil
            stopMic()
            reconnecting = false
            phase = .denied(reason)
        case .unreachable:
            // Joined already: the client keeps trying and keeps every frame for the resend.
            if phase == .joined { reconnecting = true } else { phase = .unreachable }
        }
    }

    // MARK: - audio

    /// Starts on the first welcome and runs until leave: reconnects don't stop the stream.
    private func startMic(from frame: UInt64) {
        guard let client else { return }
        audio.onPacket = { client.send($0) }
        do {
            try audio.start(firstFrame: frame)
            micRunning = true
            audio.setHeadphones(beatOnPhone)
            audio.setBeatVolume(beatVolume)
        } catch {
            problem = "Couldn't start the microphone: \(error.localizedDescription)"
        }
    }

    private func stopMic() {
        guard micRunning else {
            // Left before the host let us in: the session was opened for the Hello's sample rate.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        micRunning = false
        audio.stop()
        audio.onPacket = nil
        level = 0
    }

    private func applyMode() {
        let on = beatOnPhone
        if micRunning { audio.setHeadphones(on) }
        guard on != appliedHeadphones else { return }
        appliedHeadphones = on
        client?.setHeadphones(on)
    }
}
