import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import QtQuick.Effects

// Keeps a GitHub commit-heatmap wallpaper up to date and twinkles its cells.
//
// bin/commit-wallpaper does the real work (fetch, render, apply) and decides
// whether the wallpaper should be ours at all. This service only schedules
// it: every few minutes for new commits, and whenever the background changes
// so it can follow theme switches. It then animates highlights on top of the
// rendered cells, using the geometry the generator writes to cells.json.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string cacheDir: home + "/.cache/io.github.zenfoco.commit-wallpaper"
  readonly property string backgroundLink: home + "/.local/state/omarchy/current/background"
  readonly property string generator: decodeURIComponent(
    String(Qt.resolvedUrl("bin/commit-wallpaper")).replace(/^file:\/\//, ""))

  // Optional ~/.config/omarchy/commit-wallpaper.json, shared with the generator.
  property var config: ({})
  readonly property int refreshMinutes: Math.max(1, Number(config.refreshMinutes) || 5)
  readonly property int sparkCount: config.sparks === undefined ? 10
    : Math.max(0, Math.min(40, Number(config.sparks) || 0))

  property var grid: null
  property string currentBackground: ""
  readonly property bool active: grid !== null && currentBackground !== "" && currentBackground === grid.image

  // Weighted by level so busier days light up more often.
  readonly property var pool: {
    var out = []
    if (!grid) return out
    for (var i = 0; i < grid.cells.length; i++)
      for (var k = 0; k < grid.cells[i][2]; k++) out.push(grid.cells[i])
    return out
  }

  function pickCell() {
    return pool.length ? pool[Math.floor(Math.random() * pool.length)] : null
  }

  // ------------------------------------------------------------ generator

  property bool rerunQueued: false
  property bool rerunFetch: false

  function generate(fetch) {
    if (generatorProc.running) {
      rerunQueued = true
      rerunFetch = rerunFetch || fetch
      return
    }
    generatorProc.command = fetch ? ["python3", generator] : ["python3", generator, "--no-fetch"]
    generatorProc.running = true
  }

  Process {
    id: generatorProc
    stdout: StdioCollector {
      onStreamFinished: {
        var out = String(text || "").trim()
        if (out.indexOf("Applied") !== -1) console.log("[commit-wallpaper] " + out.split("\n")[0])
      }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err) console.warn("[commit-wallpaper] " + err)
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) console.warn("[commit-wallpaper] generator exited with " + exitCode)
      if (root.rerunQueued) {
        var fetch = root.rerunFetch
        root.rerunQueued = false
        root.rerunFetch = false
        root.generate(fetch)
      }
    }
  }

  Timer {
    interval: root.refreshMinutes * 60 * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.generate(true)
  }

  FileView {
    path: root.home + "/.config/omarchy/commit-wallpaper.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    property bool seen: false
    onLoaded: {
      try { root.config = JSON.parse(text()) || ({}) } catch (e) { root.config = ({}) }
      // The startup run already covers the first read; later edits (another
      // repo, more recent commits) need a rebuild.
      if (seen) root.generate(true)
      seen = true
    }
    onLoadFailed: root.config = ({})
  }

  FileView {
    path: root.cacheDir + "/cells.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.grid = JSON.parse(text()) } catch (e) { root.grid = null }
    }
    onLoadFailed: root.grid = null
  }

  // The shell's background plugin exposes no signal to third-party plugins,
  // so poll the symlink it maintains (it polls it the same way).
  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.backgroundLink]
    stdout: StdioCollector {
      onStreamFinished: {
        var path = String(text || "").trim()
        if (path === root.currentBackground) return
        var first = root.currentBackground === ""
        root.currentBackground = path
        // A theme switch or a manually picked wallpaper: let the generator
        // decide whether to recolor or step aside.
        if (!first) root.generate(false)
      }
    }
  }

  Timer {
    interval: 3000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: if (!readlinkProc.running) readlinkProc.running = true
  }

  // ------------------------------------------------------------ animation

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      visible: root.active
      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      // Click-through, so the desktop's own double-click actions keep working.
      mask: Region {}

      WlrLayershell.namespace: "commit-wallpaper-glow"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      // Pause while the grid is covered by windows.
      readonly property var monitor: Hyprland.monitorFor(modelData)
      readonly property bool desktopVisible: !monitor || !monitor.activeWorkspace
        || monitor.activeWorkspace.toplevels.values.length === 0
      readonly property bool running: root.active && desktopVisible

      // Same mapping as the background's Image.PreserveAspectCrop.
      readonly property real scale: root.grid ? Math.max(width / root.grid.width, height / root.grid.height) : 1
      readonly property real offsetX: root.grid ? (width - root.grid.width * scale) / 2 : 0
      readonly property real offsetY: root.grid ? (height - root.grid.height * scale) / 2 : 0
      readonly property real cellSize: root.grid ? root.grid.cell * scale : 0
      readonly property real cellRadius: root.grid ? root.grid.radius * scale : 0

      Item {
        anchors.fill: parent
        layer.enabled: panel.running
        layer.effect: MultiEffect {
          shadowEnabled: true
          shadowColor: root.grid ? root.grid.accent : "white"
          shadowBlur: 1.0
          blurMax: 32
          shadowHorizontalOffset: 0
          shadowVerticalOffset: 0
          shadowOpacity: 0.9
        }

        // Today's cell breathes slowly.
        Rectangle {
          visible: root.grid !== null && root.grid.today !== null
          x: root.grid && root.grid.today ? panel.offsetX + root.grid.today[0] * panel.scale : 0
          y: root.grid && root.grid.today ? panel.offsetY + root.grid.today[1] * panel.scale : 0
          width: panel.cellSize
          height: panel.cellSize
          radius: panel.cellRadius
          color: root.grid ? root.grid.bright : "white"
          opacity: 0

          SequentialAnimation on opacity {
            running: panel.running
            loops: Animation.Infinite
            NumberAnimation { to: 0.55; duration: 1800; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0.0; duration: 1800; easing.type: Easing.InOutSine }
          }
        }

        Repeater {
          model: root.sparkCount

          Rectangle {
            id: spark
            required property int index

            width: panel.cellSize
            height: panel.cellSize
            radius: panel.cellRadius
            color: root.grid ? root.grid.bright : "white"
            opacity: 0
            visible: opacity > 0

            function fire() {
              var c = root.pickCell()
              if (!c) return
              x = panel.offsetX + c[0] * panel.scale
              y = panel.offsetY + c[1] * panel.scale
              anim.restart()
            }

            SequentialAnimation {
              id: anim
              NumberAnimation { target: spark; property: "opacity"; to: 1; duration: 700; easing.type: Easing.OutSine }
              PauseAnimation { duration: 300 }
              NumberAnimation { target: spark; property: "opacity"; to: 0; duration: 1600; easing.type: Easing.InSine }
              ScriptAction { script: delay.interval = 400 + Math.random() * 5000 }
            }

            Timer {
              id: delay
              interval: 200 + spark.index * 600
              running: panel.running && !anim.running
              onTriggered: spark.fire()
            }

            Connections {
              target: panel
              function onRunningChanged() {
                if (!panel.running) {
                  anim.stop()
                  spark.opacity = 0
                }
              }
            }
          }
        }
      }
    }
  }
}
