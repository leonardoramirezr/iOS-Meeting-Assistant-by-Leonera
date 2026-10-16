# CLAUDE.md

## Reglas

- Cada que terminas de hacer una tarea y escribes un resumen de los cambios implementados, incluye el nombre del build con los cambios, por ejemplo `build-30-1bca82e` (en ramas distintas de `main` la etiqueta es `build-<run_number>-<sha7>`; en `main`, `0.x.0`).

## Proyecto

- App iOS en SwiftUI (iOS 17+), sin dependencias externas. El proyecto se genera con XcodeGen (`project.yml`); el `.xcodeproj` no se versiona.
- Nombre visible: «Meeting Assistant by Leonera». Bundle ID: `com.leonardoramirezr.meetingassistantbyleonera` (build setting `APP_BUNDLE_ID`).
- No se puede compilar en Linux: el workflow `.github/workflows/build.yml` (macos-15) es la verificación de compilación. Revisa su resultado después de cada push.
- No usar App Groups ni capacidades que Xcode no pueda registrar solo con la clave de API.
- Textos de la interfaz en español.
