<p align="center"><img src="Design/icon.png" width="128" alt="Icono de XTermX"></p>
<h1 align="center">XTermX</h1>
<p align="center"><b>Tus agentes, lado a lado. Tus terminales, estés donde estés.</b></p>
<p align="center">Terminal nativa para Mac · Nodo Linux · Sesiones remotas cifradas</p>
<p align="center"><a href="README.md">English</a> · <a href="README.pt-BR.md">Português</a> · <b>Español</b> · <a href="README.zh-CN.md">简体中文</a> · <a href="https://cassel.us">C. Cassel</a></p>

XTermX es un espacio de trabajo de terminales para quienes trabajan con agentes de programación. Ejecuta Claude Code, Codex, Gemini CLI y otras herramientas en paralelo, asigna un nombre a cada panel, identifica quién necesita tu atención y mantén tu trabajo a la vista.

**La app para Mac, el nodo Linux y las bibliotecas compartidas de este repositorio son de código abierto bajo MIT. La app iOS y su companion para Apple Watch se desarrollan por separado y siguen siendo propietarios. Su lanzamiento en la App Store está previsto; todavía no hay un enlace público de descarga en la tienda.**

Si quieres usar el companion oficial, consulta esta página para encontrar el enlace de la App Store cuando se publique. Para compilar la app de escritorio o ejecutar un nodo Linux hoy, consulta [Compilar y ejecutar](#compilar-y-ejecutar).

## Un vistazo a XTermX

Estas imágenes son **vistas previas ilustrativas de la documentación**, renderizadas fuera de pantalla a partir de datos ficticios con la paleta de XTermX. Explican el flujo de trabajo; no son capturas de un escritorio personal ni reproducciones exactas de una versión publicada. No muestran sesiones, cuentas, carpetas ni datos de uso reales. [Cómo se generan](Design/previews/README.md).

![Espacio de trabajo ilustrativo con cuatro paneles de terminal y tareas ficticias](Design/previews/workspace-demo.png)

Nombra los paneles **API**, **Interfaz**, **Pruebas** o **Revisión**. Mantén un agente en ejecución junto a sus pruebas, cambia de panel con el teclado e identifica cuál está esperando tu respuesta.

![Vista Home ilustrativa con contadores de actividad y un gráfico de tokens ficticios](Design/previews/home-demo.png)

Home organiza los estados de las terminales, los límites de los proveedores, los gráficos de uso local y la actividad reciente en secciones. Los límites del proveedor y las estimaciones locales de tokens proceden de fuentes distintas; la app mantiene visible esa diferencia.

## Qué puedes hacer

### Trabajar con varios paneles

- Organiza terminales en pestañas de espacios de trabajo y divídelas horizontal o verticalmente.
- Asigna nombres propios a los paneles y cambia rápidamente por nombre o enfoque reciente.
- Ajusta los separadores, iguala el diseño, maximiza un panel o intercámbialo con un vecino.
- Inicia CLIs instaladas desde un catálogo de 28 agentes, detectados en tu `PATH`.
- Usa la paleta de comandos, la navegación por teclado, la escritura simultánea y las Control Rooms.
- Elige entre diez temas, ajusta el contraste, atenúa paneles inactivos y personaliza atajos.
- Busca contenido de terminal, usa el dictado del Mac y guarda diseños de espacios de trabajo.

### Seguir el trabajo de los agentes

Las integraciones con Claude Code y Codex pueden mostrar el estado de la sesión, herramientas recientes, tareas, tokens y solicitudes que necesitan una respuesta. La vista de chat agrupa las transcripciones compatibles mientras la terminal sigue disponible debajo.

Home y Usage muestran el historial local y gráficos. Los porcentajes del plan aparecen cuando la integración del agente proporciona los datos del proveedor. Las estimaciones derivadas del número de tokens **no son** el total facturado de tu suscripción.

Las notificaciones opcionales pueden enviarse a macOS, Telegram o Slack. Tú configuras los servicios externos; no son necesarios para usar la terminal normalmente.

### Conectar otras máquinas

El Mac puede alojar terminales y conectarse a otros nodos XTermX. El nodo de línea de comandos para Linux ejecuta PTYs, el servidor remoto y el servidor de herramientas para agentes sin una app de escritorio. Las conexiones Mac ↔ Linux, Mac ↔ Mac y Linux ↔ Linux usan el mismo protocolo.

Empareja mediante un código QR o enlace. Conecta en tu LAN o mediante una red que proporciones, como una VPN. XTermX no ofrece un relay alojado ni un servicio de VPN.

El Mac también incluye un cliente SSH, comprobaciones de confianza de claves del host, un explorador SFTP y un editor de texto para archivos remotos.

### Continuar desde las apps complementarias

La app iOS, distribuida por separado, puede seguir las mismas sesiones del host, enviar texto y respuestas rápidas, responder a solicitudes compatibles de los agentes y adjuntar archivos cuando el host lo permite. Los diseños amplios pueden mostrar dos terminales en paralelo. El companion del Watch ofrece una vista compacta de sesiones y acciones rápidas.

**Este repositorio no incluye el código de las aplicaciones iOS/Watch ni el material de firma.** Abrir el protocolo y las bibliotecas compartidas no convierte esas aplicaciones en código abierto. La disponibilidad en la App Store se anunciará por separado.

## Flujo de trabajo habitual

1. Abre XTermX en el Mac e inicia un espacio de trabajo para tu proyecto.
2. Inicia tus agentes instalados y asigna nombres útiles a sus paneles.
3. Mantén las terminales visibles o abre Home para reunir actividad y solicitudes.
4. Opcionalmente, conecta otra máquina XTermX desde **Machines → Add machine**.
5. Cuando el companion esté disponible, empareja desde **Remote access** para seguir las sesiones del host.

Las cuentas, suscripciones e instalaciones de las CLIs son tuyas. XTermX no incluye suscripciones a proveedores ni evita sus límites.

## Compilar y ejecutar

[Descargar la compilación de desarrollo para Mac](https://github.com/cassel/xtermx-core/releases/tag/dev-2026.10.19-0910) — universal Apple Silicon + Intel, macOS 15+. Tiene firma ad-hoc y **no está notarizada por Apple**; macOS puede bloquear la primera apertura. Las instrucciones para compilar siguen abajo. No incluye las apps propietarias de iOS/Watch.

### Mac

Requisitos: **macOS 15 o posterior**, **Xcode 26 o posterior** y **XcodeGen**. Swift Package Manager resuelve las dependencias.

```bash
git clone https://github.com/cassel/xtermx-core.git
cd xtermx-core
xcodegen generate
open XTermX.xcodeproj
```

Selecciona **XTermX-macOS**, elige tu propio equipo Apple en Signing & Capabilities y ejecuta. No se incluyen certificados de desarrollador, perfiles de aprovisionamiento ni claves privadas.

Para comprobar la compilación local sin firma:

```bash
xcodebuild -project XTermX.xcodeproj -scheme XTermX-macOS \
  -destination 'platform=macOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

Consulta [desarrollo y distribución](docs/BUILDING.md) para compilar la CLI, ejecutar pruebas y crear una distribución notarizada para Mac.

### Linux

Usa Swift 6.2+ o Docker, una cuenta de usuario Linux y las dependencias descritas en el instalador. El script instala un binario e inicia un servicio systemd de usuario cuando está disponible; revísalo antes de ejecutarlo en tu máquina.

```bash
git clone https://github.com/cassel/xtermx-core.git
cd xtermx-core
XTERMX_ADDRESSES="node.example.com" ./Server/install.sh
```

Los procesos de terminal se ejecutan como ese usuario Linux y usan sus herramientas y credenciales. Esta publicación inicial de código fuente no adjunta binarios Linux. Debes validar la compatibilidad en tu distribución.

Para compilar la CLI manualmente:

```bash
cd Packages/XTermXKit
swift build -c release --product xtermx
.build/release/xtermx --help
```

## Emparejamiento y permisos

En el Mac, abre el menú del globo o pulsa **⌘⇧G**, activa el acceso remoto y empareja mediante el enlace o QR mostrado. Trata ese código como una credencial: compártelo solo con dispositivos de confianza y no lo incluyas en capturas.

- El historial conserva los dispositivos después de desconectarse; una entrada offline no indica una conexión activa.
- Los paneles pueden compartirse como **View & control**, **View only** o **Private**.
- El host controla la creación remota de terminales, la recepción de archivos y los permisos de Control Rooms.
- Recibir archivos requiere habilitación. El host establece el límite de adjuntos en Ajustes → Acceso remoto (500 MB por archivo de forma predeterminada), con una cuota total de almacenamiento opcional. Los cambios llegan inmediatamente a los dispositivos enlazados. Las cargas antiguas de Salas y archivos siguen limitadas a 4 MB.
- **Forget all devices** cambia el secreto de emparejamiento y exige emparejar de nuevo.

Los frames de terminal usan cifrado autenticado ChaCha20-Poly1305, nonces nuevos por conexión y contadores contra replay. Los puertos son **47820** para WebSocket y **47821** para el transporte HTTP compatible con Watch; Bonjour anuncia `_xtermx._tcp`. La conectividad depende de tu LAN/VPN/firewall. No presupongas que los nombres `.local` funcionan fuera de tu LAN.

Consulta [SECURITY.md](SECURITY.md) antes de informar de un problema de seguridad. La descripción procede de la implementación; no se afirma que exista una auditoría de seguridad independiente.

## Herramientas para agentes de programación

El servidor MCP local permite que agentes compatibles soliciten trabajo con alcance limitado. Habilitar paneles creados por agentes es opcional. Las solicitudes para iniciar un panel de agente requieren aprobación humana; los agentes no pueden cerrar paneles mediante `pane_close`.

| Herramientas | Función |
|---|---|
| `pane_spawn` | Solicitar otro panel de agente con aprobación |
| `pane_list`, `pane_read`, `pane_send`, `pane_shell` | Consultar o controlar paneles dentro del alcance del agente |
| `pane_wait`, `pane_report`, `pane_reports` | Esperar trabajo y recopilar resultados |
| `room_members`, `room_read`, `room_send`, `room_reply` | Coordinar agentes en una Control Room asignada |
| `pane_agents`, `machine_check`, `budget_check` | Descubrir agentes, consultar la carga del host y el presupuesto |

El endpoint MCP escucha en loopback, usa tokens por panel y rechaza solicitudes con origen de navegador. Un presupuesto desconocido no se considera permiso para continuar.

## Atajos de teclado

Estos son los valores predeterminados; **Settings → Shortcuts** muestra las combinaciones activas.

| Atajo | Acción |
|---|---|
| ⌘T / ⌘N | Nuevo espacio de trabajo / terminal |
| ⌘D / ⌘⇧D | Dividir a la derecha / abajo |
| ⌘] / ⌘[ | Panel siguiente / anterior |
| ⌃ + flecha | Enfocar un panel vecino |
| ⌃⇧ + flecha | Mover el panel a la posición vecina |
| ⌃N | Dividir el panel por su lado más largo |
| ⌃Tab | Cambio rápido de terminal |
| ⌘⇧M / ⌘P | Maximizar / igualar |
| ⌘K | Paleta de comandos |
| ⌘B / ⌘⇧B | Mostrar u ocultar barra lateral / panel derecho |
| ⌘⌥B | Escritura simultánea |
| ⌘⇧G | Acceso remoto y dispositivos |
| ⌘W | Cerrar el panel enfocado |

## Seleccionar texto y abrir enlaces

En Mac, arrastra sobre el texto del terminal y pulsa **⌘C** para copiar, incluso en programas que capturan el ratón, como tmux. Mantén **Control** sobre un enlace para resaltarlo y haz clic para abrirlo en el navegador; **⌘clic** también funciona. Mantén **Option** al hacer clic o arrastrar para enviar el ratón al programa del terminal. Activa la copia automática en **Ajustes → Terminal → Copiar al seleccionar texto**.

## Estructura del proyecto

```text
Apps/macOS/                 Aplicación nativa para Mac y ajustes
Packages/XTermXKit/
  Sources/XTermXKit/        Modelos, protocolo, criptografía, temas, cliente
  Sources/XTermXNIO/        Transporte de red SwiftNIO
  Sources/XTermXHost/       PTYs, servidor, integración de agentes, MCP
  Sources/XTermXTerminalUI/ Renderizado de terminal y bibliotecas SSH
  Sources/xtermx/           CLI para Mac/Linux
  Sources/DocumentationPreview/  Renderizado con datos ficticios
  Tests/                   Pruebas de lógica compartida e integración
Server/                    Instalador Linux, servicio y Dockerfile
Release/mac-release.sh     Firma y notarización para Mac
Design/previews/           Imágenes sintéticas de documentación
```

Las bibliotecas compartidas incluyen soporte condicional para plataformas Apple. El proyecto público de Xcode compila **solo la app Mac**; las aplicaciones iOS y Watch se mantienen fuera de este repositorio.

## Estado y contribuciones

XTermX está en desarrollo activo. El snapshot público inicial procede de una rama de desarrollo con 165 pruebas Swift aprobadas y compilaciones Mac, iOS y Watch correctas en su entorno privado de integración. Eso no certifica todas las configuraciones de dispositivos físicos o Linux. La validación de este árbol público está en [BUILDING.md](docs/BUILDING.md).

Se aceptan informes de errores, mejoras de documentación y contribuciones acotadas. Consulta [CONTRIBUTING.md](CONTRIBUTING.md). Nunca incluyas contenido real de terminal, enlaces de emparejamiento, claves ni datos de cuentas en issues o imágenes públicas.

## Licencia y créditos

Copyright © 2026 **C. Cassel** — [cassel.us](https://cassel.us).

Este repositorio público usa [MIT](LICENSE). La licencia cubre el código y material publicado aquí; no concede derechos sobre el código propietario de las apps iOS/Watch mantenidas por separado ni altera las licencias de las dependencias.

Emulación de terminal: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). SSH: [Citadel](https://github.com/orlandos-nl/Citadel). Red: [SwiftNIO](https://github.com/apple/swift-nio). Generación del proyecto: [XcodeGen](https://github.com/yonaskolb/XcodeGen).
