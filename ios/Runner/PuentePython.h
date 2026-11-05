#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Python embebido (Python.xcframework de BeeWare). Es el equivalente de Chaquopy en Android:
/// llama a puente.llamar(modulo, funcion, datos_json) y devuelve el JSON de respuesta.
@interface PuentePython : NSObject

+ (NSString *)llamar:(NSString *)modulo funcion:(NSString *)funcion datos:(NSString *)datos;

@end

NS_ASSUME_NONNULL_END
