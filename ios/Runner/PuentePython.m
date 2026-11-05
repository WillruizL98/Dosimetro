#import "PuentePython.h"
#import <Python/Python.h>

@implementation PuentePython

static BOOL iniciado = NO;
static NSString *errorInicio = nil;

/// JSON de error con la misma forma que devuelve puente.py.
static NSString *respuestaError(NSString *mensaje) {
    NSData *datos = [NSJSONSerialization dataWithJSONObject:@{@"ok": @NO, @"error": mensaje} options:0 error:nil];
    return [[NSString alloc] initWithData:datos encoding:NSUTF8StringEncoding];
}

/// Texto de la excepción de Python pendiente (y la limpia).
static NSString *excepcionPython(void) {
    PyObject *exc = PyErr_GetRaisedException();
    if (exc == NULL) return @"error desconocido";
    PyObject *texto = PyObject_Str(exc);
    NSString *mensaje = @"error desconocido";
    if (texto != NULL) {
        const char *c = PyUnicode_AsUTF8(texto);
        if (c != NULL) mensaje = [NSString stringWithUTF8String:c];
        Py_DECREF(texto);
    }
    Py_DECREF(exc);
    return mensaje;
}

/// Arranca el intérprete una sola vez, igual que el testbed de Python-Apple-support:
/// biblioteca estándar en <app>/python, paquetes en app_packages y nuestro código en app.
+ (nullable NSString *)iniciar {
    if (iniciado) return errorInicio;
    iniciado = YES;

    NSString *recursos = [[NSBundle mainBundle] resourcePath];
    PyStatus estado;
    PyPreConfig preconfig;
    PyConfig config;

    PyPreConfig_InitIsolatedConfig(&preconfig);
    PyConfig_InitIsolatedConfig(&config);
    preconfig.utf8_mode = 1;
    config.buffered_stdio = 0;
    config.write_bytecode = 0; // el paquete firmado no se puede modificar
    config.install_signal_handlers = 0;

    estado = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(estado)) {
        errorInicio = [NSString stringWithFormat:@"No se pudo preparar Python: %s", estado.err_msg];
        PyConfig_Clear(&config);
        return errorInicio;
    }

    NSString *home = [recursos stringByAppendingPathComponent:@"python"];
    wchar_t *whome = Py_DecodeLocale([home UTF8String], NULL);
    estado = PyConfig_SetString(&config, &config.home, whome);
    PyMem_RawFree(whome);
    if (!PyStatus_Exception(estado)) estado = PyConfig_Read(&config);
    if (!PyStatus_Exception(estado)) estado = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(estado)) {
        errorInicio = [NSString stringWithFormat:@"No se pudo iniciar Python: %s", estado.err_msg];
        return errorInicio;
    }

    // site.addsitedir(app_packages) y sys.path.insert(0, app)
    NSString *paquetes = [recursos stringByAppendingPathComponent:@"app_packages"];
    NSString *app = [recursos stringByAppendingPathComponent:@"app"];
    PyObject *site = PyImport_ImportModule("site");
    PyObject *r = site ? PyObject_CallMethod(site, "addsitedir", "s", [paquetes UTF8String]) : NULL;
    Py_XDECREF(r);
    Py_XDECREF(site);
    PyObject *sys = PyImport_ImportModule("sys");
    PyObject *ruta = sys ? PyObject_GetAttrString(sys, "path") : NULL;
    if (ruta != NULL) {
        PyObject *texto = PyUnicode_FromString([app UTF8String]);
        PyList_Insert(ruta, 0, texto);
        Py_DECREF(texto);
        Py_DECREF(ruta);
    }
    Py_XDECREF(sys);
    if (PyErr_Occurred()) errorInicio = [NSString stringWithFormat:@"Python sin rutas: %@", excepcionPython()];

    // Libera el GIL: cada llamada lo toma con PyGILState_Ensure.
    PyEval_SaveThread();
    return errorInicio;
}

+ (NSString *)llamar:(NSString *)modulo funcion:(NSString *)funcion datos:(NSString *)datos {
    @synchronized (self) {
        NSString *error = [self iniciar];
        if (error != nil) return respuestaError(error);

        PyGILState_STATE gil = PyGILState_Ensure();
        NSString *respuesta = nil;
        PyObject *puente = PyImport_ImportModule("puente");
        if (puente != NULL) {
            PyObject *r = PyObject_CallMethod(puente, "llamar", "sss",
                                              [modulo UTF8String], [funcion UTF8String], [datos UTF8String]);
            if (r != NULL) {
                const char *c = PyUnicode_AsUTF8(r);
                if (c != NULL) respuesta = [NSString stringWithUTF8String:c];
                Py_DECREF(r);
            }
            Py_DECREF(puente);
        }
        if (respuesta == nil) respuesta = respuestaError(excepcionPython());
        PyGILState_Release(gil);
        return respuesta;
    }
}

@end
