# Prepara el proyecto de Xcode para Python embebido. Se ejecuta en GitHub Actions (macOS)
# antes de `flutter build ios`, porque desde Windows no se puede abrir Xcode.
#
# Requiere en ios/: Python.xcframework, utils_python.sh, app/ (código .py) y app_packages/.
require 'xcodeproj'

proyecto = Xcodeproj::Project.open(File.join(__dir__, 'Runner.xcodeproj'))
objetivo = proyecto.targets.find { |t| t.name == 'Runner' }
raiz = proyecto.main_group
runner = raiz.find_subpath('Runner', false)

def referencia(grupo, ruta, tipo = nil)
  existente = grupo.files.find { |f| f.path == ruta }
  return existente if existente

  ref = grupo.new_reference(ruta)
  ref.last_known_file_type = tipo if tipo
  ref
end

# 1. Código nativo propio (Swift y el puente en Objective-C)
%w[Filtros.swift Medicion.swift Canales.swift PuentePython.m].each do |nombre|
  ref = referencia(runner, nombre)
  objetivo.source_build_phase.add_file_reference(ref, true)
end
referencia(runner, 'PuentePython.h')
referencia(runner, 'Runner.entitlements')

# 2. Python.xcframework: enlazar e incrustar en la app
python = referencia(raiz, 'Python.xcframework', 'wrapper.xcframework')
objetivo.frameworks_build_phase.add_file_reference(python, true)
incrustar = objetivo.copy_files_build_phases.find { |f| f.name == 'Embed Frameworks' }
unless incrustar
  incrustar = objetivo.new_copy_files_build_phase('Embed Frameworks')
  incrustar.symbol_dst_subfolder_spec = :frameworks
end
archivo = incrustar.add_file_reference(python, true)
archivo.settings = { 'ATTRIBUTES' => %w[CodeSignOnCopy RemoveHeadersOnCopy] }

# 3. Recursos: nuestro código Python y los paquetes (reportlab, pillow, chardet)
%w[app app_packages].each do |carpeta|
  ref = referencia(raiz, carpeta, 'folder')
  objetivo.resources_build_phase.add_file_reference(ref, true)
end

# 4. Copia la biblioteca estándar y convierte cada .so en framework (iOS no carga .so sueltos)
unless objetivo.shell_script_build_phases.any? { |f| f.name == 'Instalar Python' }
  fase = objetivo.new_shell_script_build_phase('Instalar Python')
  fase.shell_script = <<~SH
    set -e
    source "$PROJECT_DIR/utils_python.sh"
    install_python Python.xcframework app_packages
  SH
  objetivo.build_phases.delete(fase)
  objetivo.build_phases.insert(objetivo.build_phases.index(objetivo.resources_build_phase) + 1, fase)
end

# 5. Ajustes de compilación
objetivo.build_configurations.each do |config|
  s = config.build_settings
  s['FRAMEWORK_SEARCH_PATHS'] = ['$(inherited)', '$(PROJECT_DIR)']
  s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  s['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end

proyecto.save
puts 'Proyecto de Xcode listo para Python'
