# Spanish (es) localization

Spanish is a required app language, like Simplified Chinese. CI fails when a key in a
bundled string catalog has no `es` value or when a translation in any language uses other
format specifiers than its English text (`scripts/check_localization_completeness.py`).
Text passed to `localizedAppText(_:de:ja:zh:es:)` needs an `es` value in
`TypeWhisper/Resources/Localizable.xcstrings` under the English text, or an inline `es:`
argument when the English literal interpolates values (`scripts/check_localized_app_text.py`).

The first Spanish translation was made with AI assistance and has not been reviewed by a
native speaker yet.

## Style

- Neutral international Spanish, informal "tú" ("Elige", "Presiona", "tu Mac").
- Sentence case for titles, buttons and menu items, not English title case.
- Opening "¿" and "¡". Keep the quote characters and "…" of the English text.
- Keep product, provider, model and plugin names, code, URLs, file extensions, format
  specifiers (`%@`, `%lld`, `%1$@`) and key symbols (⌘ ⌥ ⌃ ⇧) unchanged.
- Prefer words that read naturally in Spain and Latin America ("archivo", "app", "agregar",
  "presionar", "cargos") and avoid regional ones ("ordenador", "fichero", "coger", "computadora",
  "celular", "costes").

## Glossary

| English | Spanish |
| --- | --- |
| dictation / dictate | dictado / dictar |
| transcription, transcript / transcribe | transcripción / transcribir |
| raw transcript | transcripción sin procesar |
| speech-to-text / text-to-speech | voz a texto / texto a voz |
| engine / model / provider | motor / modelo / proveedor |
| plugin / add-on / integration | plugin / complemento / integración |
| workflow / trigger | flujo de trabajo / activador |
| prompt (prompt action) | prompt (acción de prompt) |
| snippet / dictionary / term / correction | fragmento / diccionario / término / corrección |
| history / statistics | historial / estadísticas |
| Recorder / recording | grabadora / grabación |
| speaker (person) / speaker detection | hablante / detección de hablantes |
| indicator, Notch, Overlay | indicador, Notch, Superpuesto |
| shortcut, hotkey | atajo, atajo de teclado |
| Push-to-Talk / Toggle / Hybrid | Presionar para hablar / Alternar / Híbrido |
| press / hold a key | presionar / mantener presionada |
| Command, Option, Control, Shift | Comando, Opción, Control, Mayúsculas |
| Return / Enter / Escape / Space | Retorno / Intro / Esc / Espacio |
| clipboard / paste | portapapeles / pegar |
| Settings / System Settings | Ajustes / Ajustes del Sistema |
| Privacy & Security / Accessibility / Input Monitoring | Privacidad y seguridad / Accesibilidad / Monitorización de entrada |
| Screen Recording / Microphone | Grabación de pantalla / Micrófono |
| setup wizard | asistente de configuración |
| Welcome to TypeWhisper | Te damos la bienvenida a TypeWhisper |
| Done (button) / OK | Listo / Aceptar |
| Delete / Remove / Add | Eliminar / Quitar / Agregar |
| Enable / Disable; On / Off | Activar / Desactivar; Activado / Desactivado |
| download / unload a model | descargar / liberar un modelo |
| default / custom | predeterminado / personalizado |
| fallback | respaldo |
| live / streaming, real-time | en vivo / en tiempo real |
| local / cloud / on-device | local / en la nube / en el dispositivo |
| API key / endpoint / token | clave de API / endpoint / token |
| license / Supporter / Premium | licencia / Supporter / Premium |
| Individual / Team / Enterprise / Lifetime | Individual / Equipo / Empresa / vitalicia |
| Whisper Mode | modo Whisper |
| Keychain | llavero |
| Couldn't … / Failed to … | No se pudo … |
| This can't be undone. | Esta acción no se puede deshacer. |
