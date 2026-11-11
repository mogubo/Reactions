# Investigación: reacciones reales de iMessage en iOS 6

Estado: ver **0. Verificado** (capturas del 2026-11-11). El resto es hipótesis basada en código público.

## 0. Verificado (iPhone 5 iOS 6.1.2 + MacBook Air macOS 27.3, misma cuenta; emisor iOS 27 en es_ES)

* `chat.db` del Mac: las reacciones tienen `associated_message_guid = p:0/<GUID>` y tipos 2000 ❤️, 2001 👍, 2006 🔥
  (`associated_message_emoji`), 3000 quitar ❤️. Los GUID de destino son exactamente los `guid` de `sms.db` del
  iPhone 5 (Mensaje1 7A755F24…, Mensaje2 06430095…, Mensaje3 D8933C7D…), y el GUID de cada reacción es el mismo
  en el Mac y en el iPhone 5.
* `Agent.log` del iPhone 5: **iOS 27 NO envía `amk`, `amt` ni `ame` al iPhone 5**. Envía `t` (texto en el idioma
  del emisor), `gid`, `gv="8"`, `v="1"`, `pv=0`, `p` y, **solo en las reacciones**, `amrlc=0` y
  `amrln=9223372036854775807`. Ningún mensaje normal capturado (4) lleva `amrlc`/`amrln`; los normales llevan `r`.
* `arc`/`are` ("IA8T"/"dd85"), `aogre`/`aogrs` y las claves `CloudKit*` aparecen tanto en reacciones como en
  mensajes normales: no sirven para distinguirlos.
* El texto se decodifica en `JWDecodeDictionary` (IMFoundation) llamado desde `iMessage.imservice`
  (`MessageServiceSession`).
* Hipótesis siguiente: el emisor quita `amk`/`amt` porque el iPhone 5 no declara soporte al registrarse en IDS
  (`FTRegistrationMessage`); en rustpush el registro declara p. ej. `supports-emoji-tapbacks`.

## 1. Fuentes

| Proyecto | Qué aporta | Fiabilidad para nosotros |
|---|---|---|
| [OpenBubbles/rustpush](https://github.com/OpenBubbles/rustpush) (`src/imessage/rawmessages.rs`, `src/imessage/messages.rs`) | Implementación completa del protocolo iMessage (cliente propio, no usa Apple). **Envía y recibe reacciones reales.** Define el formato exacto del mensaje de reacción. | Alta: es código que funciona contra iPhones actuales. |
| [photon-hq/imessage-kit](https://github.com/photon-hq/imessage-kit) (`src/domain/reaction.ts`) | Lee la base de datos `chat.db` de Messages en macOS. Confirma los **códigos de tipo** (2000–2007 / 3000–3007) y que Apple guarda el GUID del mensaje destino, el emoji y el rango. **No envía reacciones** (eso lo reserva para su producto de pago). | Media: confirma el modelo de datos, no el formato de red. |
| [JJTech0130/pypush](https://github.com/JJTech0130/pypush) | Capa APNs (la conexión push de Apple) y un proxy APNs. | Útil solo para la conexión, no para el contenido. |
| [mautrix/imessage](https://github.com/mautrix/imessage) | Puente que usa un Mac/iPhone con jailbreak como intermediario. | No documenta el formato de red. |

No se ha encontrado ningún tweak previo para iOS ≤ 9 que haga esto de forma real.

## 2. Por qué un proxy de red no sirve

El contenido de cada iMessage va cifrado de extremo a extremo para cada dispositivo (en iOS 6, cifrado "pair": RSA + AES; en iOS moderno además "pair-ec"). Un proxy solo vería la conexión push a `courier.push.apple.com` (con certificados fijados) y bloques cifrados. La única forma de ver el contenido es **dentro del iPhone, después de que `imagent` lo descifra**. Eso hace la Fase 1A.

## 3. Formato de una reacción (según rustpush, a verificar)

Una reacción es un mensaje iMessage normal cuyo contenido (lista de propiedades binaria, comprimida) lleva estas claves:

| Clave | Tipo | Significado |
|---|---|---|
| `t` | texto | Texto de respaldo para dispositivos antiguos (`Loved “hola”`, o el de tu idioma). **Es lo que hoy ve iOS 6.** |
| `amk` | texto | Mensaje al que se reacciona: `p:<parte>/<GUID>` (ej. `p:0/29D1AFE3-0D40-4E2C-B631-A4C8C7D6644C`). Sin `p:` solo en casos especiales (amt 2 / 4000). |
| `amt` | número | Tipo. 2000 ❤️, 2001 👍, 2002 👎, 2003 😂 (HA HA), 2004 ‼️, 2005 ❓, 2006 emoji, 2007 pegatina. **+1000 = quitar** (3000–3007). 1000 = pegatina colocada, 4000 = voto de encuesta. |
| `ame` | texto | El emoji exacto, solo si amt = 2006/3006. |
| `amrlc` | número | Inicio del rango de texto reaccionado (normalmente 0). |
| `amrln` | número | Longitud de ese rango (longitud del texto de la parte). |
| `msi` | datos (plist) | Resumen para la notificación: `ams` = texto reaccionado, `amc` = 1 (9 para apps). |
| `p`, `r`, `gid`, `gv`, `v`, `pv`, `n` | — | Igual que en un mensaje normal (participantes, GUID anterior, GUID del grupo, versiones, nombre del grupo). rustpush envía `gv = "8"`, `v = "1"`, `pv = 0`. |

La **hora exacta** y el **GUID del propio mensaje de reacción** no van dentro de este contenido, sino en el sobre exterior que maneja `imagent` (y que iOS 6 ya guarda en `sms.db`: columnas `guid` y `date`).

El GUID de un mensaje es el mismo en el emisor y en el receptor, así que el `GUID` de `amk` coincide con la columna `guid` de `sms.db` en tu iPhone 5 y con `-[CKIMMessage guid]` en el tweak.

### Lo que esto significa para el tweak

* **Recepción exacta (Fase 1B):** `imagent` de iOS 6 recibe `amk`/`amt`/`ame` pero los ignora y solo guarda `t`. El tweak, desde dentro de `imagent`, puede leerlos y guardar "el mensaje de reacción X apunta a GUID G, parte P, tipo T, emoji E". La app Mensajes lo usa en lugar del texto. **El idioma deja de importar** para los mensajes nuevos.
* **Envío real (Fase 3):** añadir `amk`, `amt`, `amrlc`, `amrln`, `msi` (y `ame`) al contenido del mensaje que `imagent` cifra y envía. Riesgo abierto: si iOS 27 acepta reacciones de un dispositivo que se anuncia como iOS 6.
* **Mensajes antiguos:** las reacciones que ya están en `sms.db` solo conservan el texto `t`; para ellas sigue haciendo falta el lector de textos (Fase 2).

## 4. Idiomas (Fase 2)

El texto `t` lo genera **el iPhone que reacciona, en su idioma**. Las frases oficiales hay que sacarlas de los archivos de idioma de un sistema moderno (macOS 27 del MacBook Air), nunca inventarlas.

Idiomas de iOS 6 (ChatKit.framework del iPhone 5, 34): Dutch, English, French, German, Italian, Japanese, Spanish, ar, ca, cs, da, el, en_GB, fi, he, hr, hu, id, ko, ms, no, pl, pt, pt_PT, ro, ru, sk, sv, th, tr, uk, vi, zh_CN, zh_TW.

macOS 27 (`TapbackTextualDescriptions-*.loctable`, 44 idiomas) cubre todos ellos más en_AU/CA/IN/PH, es_419/US, fr_CA, hi, sl, zh_HK. Esas tablas son las descripciones con nombre ("%@ ha reaccionado con %@ a “%@”."), no necesariamente el texto `t` de respaldo: falta comprobarlo con el texto real de `sms.db`.

Añadidos hasta iOS 9.3 (según foros, **sin verificar**): iOS 8 añadió hindi y las variantes chino (Hong Kong), inglés (India) y francés (Canadá).
