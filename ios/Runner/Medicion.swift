import AVFoundation
import HealthKit
import UIKit

// Equivalente de Medicion.kt: escribe un registro JSON por segundo en el archivo de la sesión.

@inline(__always) func db(_ energia: Double) -> Double { 10 * log10(max(energia, 1e-20)) }
@inline(__always) func red(_ v: Double) -> Double { (v * 10).rounded() / 10 }

/// Nombre del modelo, p. ej. "iPhone14,5" (iPhone 13).
func modeloIPhone() -> String {
    var info = utsname()
    uname(&info)
    let modelo = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    return "Apple \(modelo)"
}

final class Medicion {
    static let compartida = Medicion()

    /// Niveles para la pantalla (≈8 por segundo). Siempre se llama en el hilo principal.
    var oyente: (([String: Any]) -> Void)?
    private var motor: Motor?
    private(set) var configTexto: String?
    private(set) var error: String?
    var activa: Bool { motor != nil }

    func arrancar(_ cfgTexto: String) {
        detener()
        error = nil
        guard let datos = cfgTexto.data(using: .utf8),
              let cfg = try? JSONSerialization.jsonObject(with: datos) as? [String: Any] else { return }
        configTexto = cfgTexto
        motor = (cfg["modo"] as? String) == "audifonos" ? MotorSalud(cfg) : MotorMicrofono(cfg)
        motor?.iniciar()
    }

    func detener() {
        motor?.terminar()
        motor = nil
    }

    func pausar(_ pausa: Bool) { motor?.pausado = pausa }
    func marcar(_ texto: String) { motor?.marca(texto) }

    func estado() -> [String: Any] {
        [
            "activa": activa,
            "pausada": motor?.pausado ?? false,
            "config": (activa ? configTexto : nil) as Any,
            "segundos": motor?.segundos ?? 0,
            "error": error as Any,
        ]
    }

    func fallo(_ mensaje: String) {
        DispatchQueue.main.async {
            self.error = mensaje
            self.oyente?(["error": mensaje])
        }
    }

    func limpiarError() {
        DispatchQueue.main.async {
            self.error = nil
            self.oyente?(["error": NSNull()])
        }
    }

    func emitir(_ datos: [String: Any]) {
        DispatchQueue.main.async { self.oyente?(datos) }
    }
}

class Motor {
    let cfg: [String: Any]
    var pausado = false
    var segundos = 0
    private var archivo: FileHandle?
    private let cerrojo = NSLock()

    init(_ cfg: [String: Any]) { self.cfg = cfg }

    func abrir(_ cabecera: [String: Any]) {
        let ruta = cfg["ruta"] as? String ?? ""
        let gestor = FileManager.default
        try? gestor.createDirectory(atPath: (ruta as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let nuevo = !gestor.fileExists(atPath: ruta) || ((try? gestor.attributesOfItem(atPath: ruta)[.size] as? Int) ?? 0) == 0
        if !gestor.fileExists(atPath: ruta) { gestor.createFile(atPath: ruta, contents: nil) }
        archivo = FileHandle(forWritingAtPath: ruta)
        archivo?.seekToEndOfFile()
        if nuevo { escribir(cabecera) }
    }

    func escribir(_ o: [String: Any]) {
        guard let datos = try? JSONSerialization.data(withJSONObject: o) else { return }
        cerrojo.lock()
        archivo?.write(datos)
        archivo?.write(Data([0x0A]))
        cerrojo.unlock()
    }

    func marca(_ texto: String) { escribir(["t": Date().timeIntervalSince1970, "marca": texto]) }

    func cerrar() {
        cerrojo.lock()
        try? archivo?.close()
        archivo = nil
        cerrojo.unlock()
    }

    func iniciar() {}
    func terminar() {}
}

/// Micrófono en modo "measurement" (sin procesamiento de voz): LA, LC, LZ, LAF máx/mín, LCpico y octavas.
final class MotorMicrofono: Motor {
    private let motor = AVAudioEngine()
    private var offset: Double { cfg["offset"] as? Double ?? 120 }
    private var fs = 48000.0
    private var filtroA = Filtros.ponderacionA(48000)
    private var filtroC = Filtros.ponderacionC(48000)
    private var bandas = Filtros.bandasOctava(48000)
    private var alfa = 0.0
    private var rapidoA = 0.0
    private var sA = 0.0, sC = 0.0, sZ = 0.0, picoC = 0.0
    private var maxF = -Double.infinity, minF = Double.infinity
    private var sB = [Double](repeating: 0, count: 8)
    private var n = 0, enBloque = 0, bloques = 0, descartar = 4
    private var tamBloque = 6000

    private var observadores: [NSObjectProtocol] = []
    private var terminado = false

    override func iniciar() {
        abrir([
            "tipo": "cabecera", "modo": cfg["modo"] as? String ?? "jornada",
            "inicio": Date().timeIntervalSince1970, "offset": offset,
            "fuente": "AVAudioSession measurement", "dispositivo": modeloIPhone(),
            "bandas": Filtros.centrosOctava,
        ])
        observar()
        if let error = arrancarMicrofono() {
            Medicion.compartida.fallo("No se pudo abrir el micrófono: \(error)")
        }
    }

    /// Abre la sesión de audio y el micrófono. Se llama al empezar y cada vez que iOS lo corta.
    /// Devuelve el error, o nil si quedó midiendo.
    private func arrancarMicrofono() -> String? {
        do {
            let sesion = AVAudioSession.sharedInstance()
            // mixWithOthers: se puede poner música en otra app sin que se corte la medición
            try sesion.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetoothA2DP])
            try? sesion.setPreferredSampleRate(48000)
            try sesion.setActive(true)
            let entrada = motor.inputNode
            entrada.removeTap(onBus: 0)
            let formato = entrada.outputFormat(forBus: 0)
            guard formato.sampleRate > 0 else { return "el micrófono no está disponible" }
            if formato.sampleRate != fs || alfa == 0 {
                fs = formato.sampleRate
                filtroA = Filtros.ponderacionA(fs)
                filtroC = Filtros.ponderacionC(fs)
                bandas = Filtros.bandasOctava(fs)
                alfa = 1 - exp(-1 / (0.125 * fs))
                tamBloque = Int(fs / 8)
            }
            // el filtro se vuelve a asentar después de cada corte
            enBloque = 0
            descartar = 4
            reiniciarSegundo()
            entrada.installTap(onBus: 0, bufferSize: 4096, format: formato) { [weak self] buffer, _ in
                self?.procesar(buffer)
            }
            motor.prepare()
            try motor.start()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Llamadas, Siri, alarmas o cambio de audífonos detienen el micrófono: se reanuda solo.
    private func observar() {
        let centro = NotificationCenter.default
        let sesion = AVAudioSession.sharedInstance()
        observadores.append(centro.addObserver(forName: AVAudioSession.interruptionNotification, object: sesion,
                                               queue: .main) { [weak self] aviso in
            guard let self, !self.terminado,
                  let valor = aviso.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let tipo = AVAudioSession.InterruptionType(rawValue: valor) else { return }
            if tipo == .began {
                self.marca("Interrupción (llamada u otra app)")
                Medicion.compartida.emitir(["laf": NSNull(), "segundos": self.segundos])
            } else {
                self.reanudar()
            }
        })
        for nombre in [Notification.Name.AVAudioEngineConfigurationChange, AVAudioSession.mediaServicesWereResetNotification,
                       UIApplication.didBecomeActiveNotification] {
            observadores.append(centro.addObserver(forName: nombre, object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.terminado, !self.motor.isRunning else { return }
                self.reanudar()
            })
        }
    }

    private func reanudar() {
        if motor.isRunning { return }
        if let error = arrancarMicrofono() {
            Medicion.compartida.fallo("La medición quedó en pausa por una llamada u otra app (\(error)). "
                + "Abre la app para que siga.")
        } else {
            marca("Medición reanudada")
            Medicion.compartida.limpiarError()
        }
    }

    private func procesar(_ buffer: AVAudioPCMBuffer) {
        guard let canal = buffer.floatChannelData?[0] else { return }
        for i in 0..<Int(buffer.frameLength) {
            let x = Double(canal[i])
            let a = filtroA.procesar(x)
            let c = filtroC.procesar(x)
            rapidoA += alfa * (a * a - rapidoA)
            sA += a * a; sC += c * c; sZ += x * x
            if abs(c) > picoC { picoC = abs(c) }
            for b in 0..<bandas.count {
                let y = bandas[b].procesar(x)
                sB[b] += y * y
            }
            n += 1
            enBloque += 1
            if enBloque == tamBloque {
                enBloque = 0
                finBloque()
            }
        }
    }

    /// Cada 125 ms: nivel en vivo; cada 8 bloques (1 s): un registro.
    private func finBloque() {
        let laf = db(rapidoA) + offset
        if descartar > 0 {
            descartar -= 1
            reiniciarSegundo()
            return
        }
        maxF = max(maxF, laf); minF = min(minF, laf)
        bloques += 1
        Medicion.compartida.emitir(["laf": laf, "pausada": pausado, "segundos": segundos])
        guard bloques == 8 else { return }
        if !pausado {
            let r: [String: Any] = [
                "t": Date().timeIntervalSince1970,
                "la": red(db(sA / Double(n)) + offset),
                "lc": red(db(sC / Double(n)) + offset),
                "lz": red(db(sZ / Double(n)) + offset),
                "lafmax": red(maxF), "lafmin": red(minF),
                "lcpk": red(20 * log10(max(picoC, 1e-10)) + offset),
                "b": sB.map { red(db($0 / Double(n)) + offset) },
            ]
            escribir(r)
            segundos += 1
        }
        reiniciarSegundo()
    }

    private func reiniciarSegundo() {
        sA = 0; sC = 0; sZ = 0; picoC = 0; n = 0; bloques = 0
        for i in 0..<sB.count { sB[i] = 0 }
        maxF = -Double.infinity; minF = Double.infinity
    }

    override func terminar() {
        terminado = true
        observadores.forEach { NotificationCenter.default.removeObserver($0) }
        observadores = []
        motor.inputNode.removeTap(onBus: 0)
        motor.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        cerrar()
    }
}

/// Modo audífonos en iPhone: el sistema ya mide el nivel de los audífonos y lo guarda en Salud
/// (Exposición a audio de los audífonos). Se leen esas muestras y se escriben segundo a segundo.
final class MotorSalud: Motor {
    private let tienda = HKHealthStore()
    private var temporizador: Timer?
    private var desde = Date()

    override func iniciar() {
        guard HKHealthStore.isHealthDataAvailable(),
              let tipo = HKObjectType.quantityType(forIdentifier: .headphoneAudioExposure) else {
            Medicion.compartida.fallo("Este iPhone no tiene datos de Salud disponibles.")
            return
        }
        abrir([
            "tipo": "cabecera", "modo": "audifonos", "inicio": Date().timeIntervalSince1970,
            "fuente": "Salud (iPhone)", "dispositivo": modeloIPhone(),
        ])
        tienda.requestAuthorization(toShare: [], read: [tipo]) { [weak self] _, error in
            if let error {
                Medicion.compartida.fallo("Sin acceso a Salud: \(error.localizedDescription)")
                return
            }
            DispatchQueue.main.async {
                self?.consultar(tipo)
                self?.temporizador = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                    self?.consultar(tipo)
                }
            }
        }
    }

    private func consultar(_ tipo: HKQuantityType) {
        let filtro = HKQuery.predicateForSamples(withStart: desde, end: nil, options: .strictStartDate)
        let orden = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        let consulta = HKSampleQuery(sampleType: tipo, predicate: filtro, limit: HKObjectQueryNoLimit,
                                     sortDescriptors: orden) { [weak self] _, muestras, _ in
            guard let self, let muestras = muestras as? [HKQuantitySample] else { return }
            var ultimo: Double?
            for m in muestras {
                let nivel = m.quantity.doubleValue(for: .decibelAWeightedSoundPressureLevel())
                let duracion = max(1, Int(m.endDate.timeIntervalSince(m.startDate).rounded()))
                if !self.pausado {
                    let inicio = m.startDate.timeIntervalSince1970
                    for s in 0..<duracion {
                        self.escribir(["t": inicio + Double(s), "la": red(nivel), "aud": "salud"])
                    }
                    self.segundos += duracion
                }
                self.desde = m.endDate.addingTimeInterval(0.001)
                ultimo = nivel
            }
            var datos: [String: Any] = ["audifono": "salud", "segundos": self.segundos]
            if let ultimo { datos["laf"] = ultimo }
            Medicion.compartida.emitir(datos)
        }
        tienda.execute(consulta)
    }

    override func terminar() {
        temporizador?.invalidate()
        cerrar()
    }
}

/// Medición corta para calibrar: LAeq y LZeq en dBFS durante unos segundos.
final class MedidorCorto {
    private let motor = AVAudioEngine()

    func medir(segundos: Int, listo: @escaping ([String: Double]?, String?) -> Void) {
        do {
            let sesion = AVAudioSession.sharedInstance()
            try sesion.setCategory(.record, mode: .measurement)
            try sesion.setActive(true)
            let entrada = motor.inputNode
            let formato = entrada.outputFormat(forBus: 0)
            let filtroA = Filtros.ponderacionA(formato.sampleRate)
            let descarte = Int(formato.sampleRate / 2)
            var sA = 0.0, sZ = 0.0, n = 0, vistos = 0
            entrada.installTap(onBus: 0, bufferSize: 4096, format: formato) { buffer, _ in
                guard let canal = buffer.floatChannelData?[0] else { return }
                for i in 0..<Int(buffer.frameLength) {
                    let x = Double(canal[i])
                    let a = filtroA.procesar(x)
                    vistos += 1
                    if vistos > descarte { sA += a * a; sZ += x * x; n += 1 }
                }
            }
            try motor.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500 + segundos * 1000)) {
                self.motor.inputNode.removeTap(onBus: 0)
                self.motor.stop()
                try? sesion.setActive(false, options: .notifyOthersOnDeactivation)
                listo(n > 0 ? ["la_dbfs": db(sA / Double(n)), "lz_dbfs": db(sZ / Double(n))] : nil,
                      n > 0 ? nil : "No llegó audio del micrófono")
            }
        } catch {
            listo(nil, "No se pudo abrir el micrófono: \(error.localizedDescription)")
        }
    }
}
