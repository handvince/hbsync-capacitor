import Foundation
import Capacitor
import Network
import UIKit

/// HbSync — liaison iPad ↔ iPad pour Taguage live (hôte) et Temps de jeu (client).
///
/// - Découverte automatique en Bonjour (type « _hbsync._tcp »), sans adresse IP à saisir.
/// - Transport TCP, sur le Wi-Fi du routeur OU en direct entre iPads (includePeerToPeer).
/// - Messages : un objet JSON par ligne (NDJSON, UTF-8).
/// - Le module ne connaît rien du handball et ne fait aucune reconnexion de lui-même :
///   il signale les changements d'état (événement "state") et l'app décide.
///
/// Méthodes : startHost, stopHost, startBrowse, stopBrowse, connect, disconnect, send, status.
/// Événements : "state", "message", "peerFound", "peerLost".
@objc(HbSyncPlugin)
public class HbSyncPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "HbSyncPlugin"
    public let jsName = "HbSync"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "startHost", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopHost", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startBrowse", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopBrowse", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "connect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "disconnect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "send", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "status", returnType: CAPPluginReturnPromise)
    ]

    static let serviceType = "_hbsync._tcp"
    /// Taille maximale d'une ligne JSON (protection contre un flux corrompu).
    static let maxLine = 1_000_000

    private let queue = DispatchQueue(label: "fr.handvince.hbsync")

    // Rôle et état (lus/écrits uniquement sur `queue`)
    private var role = "none"            // "host" | "client" | "none"
    private var state = "idle"           // idle | listening | searching | connecting | connected | failed

    // Hôte
    private var listener: NWListener?
    private var hostName = ""
    private var hostWanted = false

    // Client
    private var browser: NWBrowser?
    private var browseWanted = false
    private var peers = Set<String>()    // noms de service visibles
    private var targetPeer: String?

    // Connexion active (côté hôte ou client) et tampon de réception
    private var connection: NWConnection?
    private var rxBuffer = Data()

    private var observersInstalled = false

    // MARK: - Paramètres réseau communs

    private static func makeParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true   // liaison directe entre iPads, sans routeur
        return params
    }

    // MARK: - Méthodes exposées à la page

    @objc func startHost(_ call: CAPPluginCall) {
        let name = call.getString("name") ?? "Taguage live – \(UIDevice.current.name)"
        installObservers()
        queue.async {
            self.stopBrowseInternal()
            self.closeConnection(notify: false)
            self.role = "host"
            self.hostName = name
            self.hostWanted = true
            self.startListener()
            call.resolve(["state": self.state])
        }
    }

    @objc func stopHost(_ call: CAPPluginCall) {
        queue.async {
            self.hostWanted = false
            self.listener?.cancel()
            self.listener = nil
            self.closeConnection(notify: false)
            self.role = "none"
            self.setState("idle")
            call.resolve()
        }
    }

    @objc func startBrowse(_ call: CAPPluginCall) {
        installObservers()
        queue.async {
            if self.role == "host" {
                self.hostWanted = false
                self.listener?.cancel()
                self.listener = nil
                self.closeConnection(notify: false)
            }
            self.role = "client"
            self.browseWanted = true
            self.startBrowser()
            call.resolve(["peers": Array(self.peers)])
        }
    }

    @objc func stopBrowse(_ call: CAPPluginCall) {
        queue.async {
            self.stopBrowseInternal()
            call.resolve()
        }
    }

    @objc func connect(_ call: CAPPluginCall) {
        guard let peerId = call.getString("peerId"), !peerId.isEmpty else {
            call.reject("peerId manquant")
            return
        }
        installObservers()
        queue.async {
            self.role = "client"
            self.targetPeer = peerId
            self.closeConnection(notify: false)
            // Point d'accès Bonjour sans interface imposée : iOS choisit le routeur ou le direct.
            let endpoint = NWEndpoint.service(name: peerId, type: HbSyncPlugin.serviceType,
                                              domain: "local.", interface: nil)
            let conn = NWConnection(to: endpoint, using: HbSyncPlugin.makeParameters())
            self.setState("connecting", detail: peerId)
            self.attach(conn)
            call.resolve()
        }
    }

    @objc func disconnect(_ call: CAPPluginCall) {
        queue.async {
            self.targetPeer = nil
            self.closeConnection(notify: false)
            self.setState(self.browseWanted ? "searching" : "idle")
            call.resolve()
        }
    }

    @objc func send(_ call: CAPPluginCall) {
        guard let message = call.getObject("message") else {
            call.reject("message manquant")
            return
        }
        guard JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message, options: []) else {
            call.reject("message non convertible en JSON")
            return
        }
        data.append(0x0A) // fin de ligne NDJSON
        queue.async {
            guard let conn = self.connection, self.state == "connected" else {
                call.reject("not_connected")
                return
            }
            conn.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    call.reject("send_failed: \(error.localizedDescription)")
                } else {
                    call.resolve()
                }
            })
        }
    }

    @objc func status(_ call: CAPPluginCall) {
        queue.async {
            call.resolve([
                "role": self.role,
                "state": self.state,
                "peers": Array(self.peers),
                "peer": self.targetPeer ?? ""
            ])
        }
    }

    // MARK: - Hôte

    private func startListener() {
        listener?.cancel()
        listener = nil
        do {
            let l = try NWListener(using: HbSyncPlugin.makeParameters())
            l.service = NWListener.Service(name: hostName, type: HbSyncPlugin.serviceType)
            l.stateUpdateHandler = { [weak self] st in
                guard let self = self else { return }
                switch st {
                case .ready:
                    if self.connection == nil { self.setState("listening") }
                case .failed(let error):
                    self.setState("failed", detail: "listener: \(error.localizedDescription)")
                    self.retryListener()
                case .waiting(let error):
                    self.setState("failed", detail: "listener: \(error.localizedDescription)")
                    self.retryListener()
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                guard let self = self else { return }
                // Une seule liaison en v1 : la plus récente remplace l'ancienne
                // (utile quand l'ancienne est morte sans l'avoir signalé).
                self.closeConnection(notify: false)
                self.setState("connecting", detail: conn.endpoint.debugDescription)
                self.attach(conn)
            }
            listener = l
            l.start(queue: queue)
        } catch {
            setState("failed", detail: "listener: \(error.localizedDescription)")
            retryListener()
        }
    }

    private func retryListener() {
        listener?.cancel()
        listener = nil
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.hostWanted, self.listener == nil else { return }
            self.startListener()
        }
    }

    // MARK: - Client

    private func startBrowser() {
        browser?.cancel()
        browser = nil
        let b = NWBrowser(for: .bonjour(type: HbSyncPlugin.serviceType, domain: nil),
                          using: HbSyncPlugin.makeParameters())
        b.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            switch st {
            case .ready:
                if self.connection == nil { self.setState("searching") }
            case .failed:
                self.browser?.cancel()
                self.browser = nil
                self.queue.asyncAfter(deadline: .now() + 1.0) {
                    if self.browseWanted && self.browser == nil { self.startBrowser() }
                }
            default:
                break
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            var names = Set<String>()
            for r in results {
                if case let .service(name, _, _, _) = r.endpoint { names.insert(name) }
            }
            for n in names.subtracting(self.peers) {
                self.emit("peerFound", ["peerId": n, "name": n])
            }
            for n in self.peers.subtracting(names) {
                self.emit("peerLost", ["peerId": n, "name": n])
            }
            self.peers = names
        }
        browser = b
        b.start(queue: queue)
    }

    private func stopBrowseInternal() {
        browseWanted = false
        browser?.cancel()
        browser = nil
        peers.removeAll()
    }

    // MARK: - Connexion (commune)

    private func attach(_ conn: NWConnection) {
        connection = conn
        rxBuffer = Data()
        conn.stateUpdateHandler = { [weak self, weak conn] st in
            guard let self = self, let conn = conn, conn === self.connection else { return }
            switch st {
            case .ready:
                self.setState("connected", detail: self.targetPeer ?? conn.endpoint.debugDescription)
                self.receive(on: conn)
            case .waiting(let error):
                // Réseau indisponible : on abandonne cette tentative, l'app relancera.
                self.dropConnection(reason: error.localizedDescription)
            case .failed(let error):
                self.dropConnection(reason: error.localizedDescription)
            case .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak conn] data, _, isComplete, error in
            guard let self = self, let conn = conn, conn === self.connection else { return }
            if let data = data, !data.isEmpty {
                self.rxBuffer.append(data)
                self.extractLines()
            }
            if isComplete {
                self.dropConnection(reason: "fermée par l'autre iPad")
                return
            }
            if let error = error {
                self.dropConnection(reason: error.localizedDescription)
                return
            }
            self.receive(on: conn)
        }
    }

    private func extractLines() {
        while let nl = rxBuffer.firstIndex(of: 0x0A) {
            let line = rxBuffer.subdata(in: rxBuffer.startIndex..<nl)
            rxBuffer.removeSubrange(rxBuffer.startIndex...nl)
            guard !line.isEmpty else { continue }
            if let obj = try? JSONSerialization.jsonObject(with: line, options: []) as? [String: Any] {
                emit("message", ["message": obj])
            }
        }
        if rxBuffer.count > HbSyncPlugin.maxLine { rxBuffer.removeAll() }
    }

    /// Perte de la connexion en cours : hôte → retour à l'écoute ; client → "failed".
    private func dropConnection(reason: String) {
        closeConnection(notify: false)
        if role == "host" {
            setState(listener != nil ? "listening" : "failed", detail: reason)
            if listener == nil && hostWanted { retryListener() }
        } else {
            setState("failed", detail: reason)
        }
    }

    private func closeConnection(notify: Bool) {
        if let c = connection {
            c.stateUpdateHandler = nil
            c.cancel()
        }
        connection = nil
        rxBuffer = Data()
        if notify { setState(role == "host" ? "listening" : "idle") }
    }

    // MARK: - Retour au premier plan

    private func installObservers() {
        DispatchQueue.main.async {
            guard !self.observersInstalled else { return }
            self.observersInstalled = true
            NotificationCenter.default.addObserver(self, selector: #selector(self.onForeground),
                                                   name: UIApplication.willEnterForegroundNotification,
                                                   object: nil)
        }
    }

    /// iOS peut couper l'écoute et la recherche en arrière-plan : on les relance au retour.
    @objc private func onForeground() {
        queue.async {
            if self.hostWanted { self.startListener() }
            if self.browseWanted { self.startBrowser() }
        }
    }

    // MARK: - Événements vers la page

    private func setState(_ s: String, detail: String = "") {
        state = s
        emit("state", ["state": s, "role": role, "detail": detail])
    }

    private func emit(_ event: String, _ data: [String: Any]) {
        DispatchQueue.main.async {
            self.notifyListeners(event, data: data)
        }
    }
}
