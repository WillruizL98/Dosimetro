import AVFoundation
import Flutter
import UIKit

/// Mismos canales que MainActivity.kt, para que el código de Flutter sea igual en las dos plataformas.
final class Canales: NSObject, FlutterStreamHandler, UIDocumentInteractionControllerDelegate {
    static let compartido = Canales()
    private let colaPython = DispatchQueue(label: "dosimetro.python")
    private var medidor: MedidorCorto?
    private var visor: UIDocumentInteractionController?

    static func registrar(_ mensajero: FlutterBinaryMessenger) {
        let c = compartido
        FlutterMethodChannel(name: "dosimetro/medicion", binaryMessenger: mensajero).setMethodCallHandler(c.medicion)
        FlutterMethodChannel(name: "dosimetro/calibracion", binaryMessenger: mensajero).setMethodCallHandler(c.calibracion)
        FlutterMethodChannel(name: "dosimetro/python", binaryMessenger: mensajero).setMethodCallHandler(c.python)
        FlutterMethodChannel(name: "dosimetro/sistema", binaryMessenger: mensajero).setMethodCallHandler(c.sistema)
        FlutterEventChannel(name: "dosimetro/niveles", binaryMessenger: mensajero).setStreamHandler(c)
    }

    // MARK: niveles en vivo

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        Medicion.compartida.oyente = { events($0) }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        Medicion.compartida.oyente = nil
        return nil
    }

    // MARK: medición

    private func medicion(_ llamada: FlutterMethodCall, _ resultado: @escaping FlutterResult) {
        let args = llamada.arguments as? [String: Any] ?? [:]
        switch llamada.method {
        case "iniciar":
            Medicion.compartida.arrancar(args["cfg"] as? String ?? "{}")
            resultado(nil)
        case "detener":
            Medicion.compartida.detener()
            resultado(nil)
        case "pausar":
            Medicion.compartida.pausar(args["pausa"] as? Bool ?? false)
            resultado(nil)
        case "marcar":
            Medicion.compartida.marcar(args["texto"] as? String ?? "")
            resultado(nil)
        case "estado":
            resultado(Medicion.compartida.estado())
        case "audifono":
            resultado(Canales.salidaAudifonos())
        case "volumen":
            let v = AVAudioSession.sharedInstance().outputVolume
            resultado(["actual": Int((v * 16).rounded()), "maximo": 16])
        default:
            resultado(FlutterMethodNotImplemented)
        }
    }

    static func salidaAudifonos() -> String? {
        for salida in AVAudioSession.sharedInstance().currentRoute.outputs {
            switch salida.portType {
            case .headphones: return "cable"
            case .usbAudio: return "usb"
            case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "bluetooth"
            default: continue
            }
        }
        return nil
    }

    // MARK: calibración

    private func calibracion(_ llamada: FlutterMethodCall, _ resultado: @escaping FlutterResult) {
        let args = llamada.arguments as? [String: Any] ?? [:]
        switch llamada.method {
        case "medirMicrofono":
            let m = MedidorCorto()
            medidor = m
            m.medir(segundos: args["segundos"] as? Int ?? 10) { [weak self] valores, error in
                self?.medidor = nil
                if let valores { resultado(valores) } else {
                    resultado(FlutterError(code: "CALIBRACION", message: error, details: nil))
                }
            }
        case "tono", "detenerTono", "medirAudifono":
            // En iPhone el nivel de los audífonos lo calcula el sistema (app Salud).
            resultado(FlutterError(code: "IOS", message: "En iPhone los audífonos no se calibran: el nivel lo mide el sistema.", details: nil))
        default:
            resultado(FlutterMethodNotImplemented)
        }
    }

    // MARK: Python

    private func python(_ llamada: FlutterMethodCall, _ resultado: @escaping FlutterResult) {
        let args = llamada.arguments as? [String: Any] ?? [:]
        let modulo = args["modulo"] as? String ?? ""
        let funcion = args["funcion"] as? String ?? ""
        let datos = args["datos"] as? String ?? "null"
        // Python corre en una cola aparte para no congelar la interfaz.
        colaPython.async {
            let respuesta = PuentePython.llamar(modulo, funcion: funcion, datos: datos)
            DispatchQueue.main.async { resultado(respuesta) }
        }
    }

    // MARK: sistema

    private func sistema(_ llamada: FlutterMethodCall, _ resultado: @escaping FlutterResult) {
        let args = llamada.arguments as? [String: Any] ?? [:]
        switch llamada.method {
        case "directorio":
            // Documentos: los PDF y CSV también se ven en la app Archivos
            resultado(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path)
        case "permisos":
            AVAudioSession.sharedInstance().requestRecordPermission { ok in
                DispatchQueue.main.async { resultado(ok) }
            }
        case "compartir":
            guard let raiz = Canales.controladorVisible() else { resultado(false); return }
            let url = URL(fileURLWithPath: args["ruta"] as? String ?? "")
            let hoja = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            hoja.popoverPresentationController?.sourceView = raiz.view
            raiz.present(hoja, animated: true)
            resultado(true)
        case "abrir":
            let url = URL(fileURLWithPath: args["ruta"] as? String ?? "")
            let v = UIDocumentInteractionController(url: url)
            v.delegate = self
            visor = v
            resultado(v.presentPreview(animated: true))
        default:
            resultado(FlutterMethodNotImplemented)
        }
    }

    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        Canales.controladorVisible() ?? UIViewController()
    }

    static func controladorVisible() -> UIViewController? {
        let ventana = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        var c = ventana?.rootViewController
        while let siguiente = c?.presentedViewController { c = siguiente }
        return c
    }
}
