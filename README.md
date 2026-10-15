# Meeting Assistant by Leonera

App para iPhone (SwiftUI, sin dependencias externas) que graba reuniones largas, las transcribe con Whisper y genera una minuta con un LLM, usando la API de [Groq](https://console.groq.com).

## Funcionalidad

- **Grabación de hasta 3 horas**, también con la pantalla bloqueada o con la app en segundo plano. Se puede pausar y reanudar; si llega una llamada, la grabación se pausa y se reanuda al terminar.
- **Grabación por bloques**: cada 1, 2.5, 5 o 10 minutos (se configura en Ajustes) el clip actual se cierra y se guarda, y la grabación sigue sin cortes en un clip nuevo. Cada clip cerrado se envía a Whisper mientras se sigue grabando.
- **Transcripción con Whisper** (Groq `audio/transcriptions`), un bloque tras otro, con reintentos automáticos ante errores de red o límites de uso. Los bloques que fallan se pueden reintentar a mano.
- **Minuta con un LLM** (Groq `chat/completions`): al terminar la transcripción se envía el prompt (editable) seguido de la transcripción de todos los bloques, separados por `[TRANSCRIPTION CHUNK BOUNDARY]`. El prompt predeterminado define la estructura de la minuta y su última sección es «Acuerdos y asuntos pendientes».
- **Formas de procesar la minuta** (Ajustes › Forma de procesar la minuta, mutuamente excluyentes):
  - *Transcripción completa*: todos los bloques concatenados en una sola petición (lógica original).
  - *Resumir cada bloque*: un resumen por bloque mientras se graba; la minuta se genera con los resúmenes concatenados.
  - *Agrupar bloques (Map-Reduce)*: se unen N bloques consecutivos (configurable), se resume cada grupo y la minuta sintetiza los resúmenes.
  - *Resumen acumulativo*: en orden cronológico, el modelo recibe el resumen acumulado y el siguiente bloque y lo actualiza; la minuta se genera con el resumen final.

  Los bloques ya resumidos muestran el símbolo ☁︎✓ (procesado en la nube) y los resúmenes se ven en la pestaña «Resúmenes». Si Groq devuelve un límite de cuota (429), todo el procesamiento se pausa el tiempo configurado y se reanuda solo (o al volver a abrir la app si iOS la suspendió). Al cambiar la forma de procesar se borran los resúmenes de las reuniones sin minuta y se empieza de nuevo.
- **Pausa preventiva por tokens** (activa por defecto, desactivable): si una respuesta de Groq trae `x-ratelimit-remaining-tokens` menor o igual al umbral configurado (1000 por defecto), todas las peticiones se pausan hasta que el límite se restablezca (`x-ratelimit-reset-tokens`), para no agotar los tokens y evitar bloqueos.
- **Request raw**: un botón discreto (`{} request raw`, debajo de la minuta, o en el menú `…`) muestra la petición HTTP literal enviada al LLM y su respuesta.
- **Ajustes**: API key de Groq (guardada en el llavero), modelo exacto de audio a texto y de LLM (lista obtenida de la API o un ID escrito a mano), tamaño de bloque, idioma de la transcripción, prompt de la minuta y generación automática.
- Copiar y compartir la minuta y la transcripción, reproducir y compartir cada bloque de audio. Los archivos también están visibles en la app Archivos.

### Estructura del código

```
MeetingAssistant/
  App/        Punto de entrada y AppModel (une grabación, almacenamiento y procesamiento)
  Models/     Meeting, AudioChunk y AppSettings (preferencias y prompt predeterminado)
  Services/   AudioChunkRecorder (AVAudioEngine + clips AAC), GroqClient, MeetingProcessor
              (cola de Whisper y minuta), MeetingStore (JSON + audio en Documents), Keychain
  Views/      Lista de reuniones, grabación, detalle (minuta/transcripción), ajustes,
              request raw y un renderizador de Markdown
Config/Info.plist
project.yml   Proyecto de XcodeGen
```

## Compilar en local

```sh
brew install xcodegen
xcodegen generate
open MeetingAssistant.xcodeproj
```

El proyecto se genera con [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml`); el `.xcodeproj` no se versiona. El bundle ID sale del build setting `APP_BUNDLE_ID` (`com.leonardoramirezr.meetingassistantbyleonera`).

## Distribución: build firmado Ad Hoc en cada push

El workflow [`.github/workflows/build.yml`](.github/workflows/build.yml) se ejecuta en cada push (salvo a `gh-pages`) y con `workflow_dispatch`:

1. Comprueba la clave de App Store Connect y que haya al menos un iPhone registrado (`scripts/asc.py`).
2. Hace `xcodebuild archive` con firma automática (`-allowProvisioningUpdates` + clave de API). Xcode registra el App ID y crea los perfiles.
3. Exporta el IPA con `method=release-testing` (Ad Hoc) usando el certificado de distribución gestionado en la nube, y verifica que cada bundle lleva un perfil Ad Hoc (muestra cuántos dispositivos incluye).
4. Publica el IPA en GitHub Pages con un enlace de instalación `itms-services://` y crea la release.
5. Revoca el certificado de desarrollo temporal que xcodebuild crea en cada ejecución.

| Rama | Etiqueta | Release |
|---|---|---|
| `main` | `0.x.0` (incrementa el número intermedio respecto al último tag) | Estable, marcada como *Latest* |
| otras | `build-<run_number>-<sha7>` | Pre-release |

El enlace de instalación aparece en el resumen de cada ejecución y en las notas de la release.

### Secrets necesarios

Configúralos en **Settings › Secrets and variables › Actions** del repositorio (secrets del repositorio, no de una organización):

| Secret | Contenido |
|---|---|
| `ASC_KEY_ID` | Key ID de la clave de API de App Store Connect |
| `ASC_ISSUER_ID` | Issuer ID (App Store Connect › Users and Access › Integrations) |
| `ASC_KEY_P8` | Contenido completo del archivo `.p8` (Team Key con rol **Admin**) |
| `APPLE_TEAM_ID` | Team ID de la cuenta de Apple Developer |

Sin ninguno de los cuatro, el workflow genera un IPA **sin firmar** (artefacto de la ejecución, no instalable). Si solo hay algunos, falla indicando cuáles faltan.

### Activar GitHub Pages

Después del **primer build firmado** (que crea la rama `gh-pages`), ve a **Settings › Pages**, elige **Deploy from a branch**, la rama `gh-pages` y la carpeta `/ (root)`. La portada lista todos los builds y tiene un botón para instalar la última versión estable; cada build tiene su carpeta con el IPA, `manifest.plist`, `index.html` y `build.json`.

Se conservan todas las versiones de `main` y los últimos 20 builds de otras ramas. La rama `gh-pages` se reescribe en cada publicación como un único commit, así que los IPA no se acumulan en el historial.

### Añadir un iPhone

Registra su UDID en [Certificates, Identifiers & Profiles › Devices](https://developer.apple.com/account/resources/devices/list) y haz push: el siguiente build genera un perfil Ad Hoc que ya incluye el dispositivo nuevo. Abre la página de Pages en Safari desde ese iPhone para instalar.

## Uso

1. Abre **Ajustes**, pega tu API key de Groq y pulsa «Guardar, probar y cargar modelos».
2. Elige el modelo de audio a texto (p. ej. `whisper-large-v3-turbo`) y el LLM (p. ej. `openai/gpt-oss-120b`).
3. Pulsa **Grabar reunión**. Al terminar, la minuta se genera sola cuando todos los bloques están transcritos.

> Las reuniones largas producen transcripciones grandes: si Groq responde con un error 413 o 429 por límite de tokens, elige un modelo con más contexto o un plan con límites mayores.
