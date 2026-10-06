import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Pap.er-style wallpaper browser. The bar icon exists on every monitor's
// bar; clicking it targets that monitor. Wallpapers are applied per monitor
// through the `paper-background` IPC target of the xuanyao.background clone.
Panel {
  id: root
  moduleName: "xuanyao.paper"
  ipcTarget: "xuanyao.paper"
  manageIpc: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string downloadDir: Model.expandHome(setting("downloadDir", "~/Pictures/Wallpapers/Paper"), home)
  readonly property string overridesPath: home + "/.local/state/omarchy/current/backgrounds.json"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- target screen
  readonly property var barScreen: button.QsWindow.window ? button.QsWindow.window.screen : null
  property string targetName: ""
  readonly property var targetScreen: screenByName(targetName) || barScreen
  readonly property string targetOrientation: Model.screenOrientation(targetScreen)

  function screenByName(name) {
    var list = Quickshell.screens
    for (var i = 0; i < list.length; i++) if (list[i].name === name) return list[i]
    return null
  }

  // ---- view state
  property string tab: "discover"          // discover | search | downloaded
  property string sorting: "toplist"       // toplist | hot | date_added | random
  property string orientationMode: "fit"   // fit | landscape | portrait | any
  property string query: ""
  readonly property string orientation: orientationMode === "fit" ? targetOrientation : orientationMode

  // ---- remote results
  property var remoteItems: []
  property int page: 0
  property int lastPage: 1
  property string seed: ""
  property bool loading: false
  property string errorText: ""
  property int requestSerial: 0

  // ---- local library
  property var localItems: []
  readonly property var localById: {
    var map = {}
    for (var i = 0; i < localItems.length; i++) map[localItems[i].id] = localItems[i].path
    return map
  }
  readonly property var visibleLocal: localItems.filter(function(it) { return Model.matchesOrientation(it, root.orientation) })
  readonly property var gridItems: tab === "downloaded" ? visibleLocal : remoteItems

  // ---- per-screen state
  property var overrides: ({})
  property string globalBackground: ""
  property var downloading: ({})
  property string statusText: ""

  function currentFor(name) {
    return overrides[name] || globalBackground
  }

  // ---------------------------------------------------------------- remote
  function resetAndFetch() {
    remoteItems = []
    page = 0
    lastPage = 1
    seed = ""
    errorText = ""
    requestSerial += 1
    loading = false
    if (tab === "search" && query.trim() === "") return
    if (tab !== "downloaded") fetchMore()
  }

  function fetchMore() {
    if (loading || tab === "downloaded" || page >= lastPage) return
    var size = Model.physicalSize(targetScreen)
    var atleast = orientation === "portrait"
      ? Math.min(size.w, size.h) + "x" + Math.max(size.w, size.h)
      : (orientation === "landscape" ? Math.max(size.w, size.h) + "x" + Math.min(size.w, size.h) : "")
    var url = Model.searchUrl({
      sorting: tab === "search" ? (sorting === "toplist" ? "relevance" : sorting) : sorting,
      topRange: setting("topRange", "1M"),
      categories: setting("categories", "100"),
      orientation: orientation,
      atleast: atleast,
      query: tab === "search" ? query.trim() : "",
      seed: seed,
      page: page + 1
    })
    var serial = requestSerial
    loading = true
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      if (serial !== root.requestSerial) return
      root.loading = false
      if (xhr.status !== 200) {
        root.errorText = xhr.status === 429 ? "Wallhaven rate limit hit, try again in a moment." : "Could not reach Wallhaven (" + xhr.status + ")."
        return
      }
      try {
        var data = JSON.parse(xhr.responseText)
        var mapped = (data.data || []).map(Model.mapWallhaven)
        root.remoteItems = root.remoteItems.concat(mapped)
        root.page = data.meta ? data.meta.current_page : root.page + 1
        root.lastPage = data.meta ? data.meta.last_page : root.page
        if (data.meta && data.meta.seed) root.seed = data.meta.seed
        if (root.remoteItems.length === 0) root.errorText = "Nothing found."
      } catch (e) {
        root.errorText = "Unexpected response from Wallhaven."
      }
    }
    xhr.open("GET", url)
    xhr.send()
  }

  // ---------------------------------------------------------------- local
  function scanLocal() {
    if (!scanProc.running) scanProc.running = true
  }

  Process {
    id: scanProc
    command: ["bash", "-c",
      "shopt -s nullglob nocaseglob; dir=\"$1\"; mkdir -p \"$dir\"; " +
      "files=( \"$dir\"/*.jpg \"$dir\"/*.jpeg \"$dir\"/*.png \"$dir\"/*.webp ); " +
      "(( ${#files[@]} )) || exit 0; " +
      "ls -t -- \"${files[@]}\" | while IFS= read -r f; do " +
      "  d=$(magick identify -ping -format '%w %h' \"$f[0]\" 2>/dev/null) && printf '%s\\t%s\\n' \"$d\" \"$f\"; " +
      "done", "_", root.downloadDir]
    stdout: StdioCollector {
      onStreamFinished: {
        root.localItems = Model.parseLocal(text)
        if (root.pendingLocalChange) {
          root.pendingLocalChange = false
          root.applyRandomLocal()
        }
      }
    }
  }

  // ---------------------------------------------------------------- apply
  function applyPath(path, screenName) {
    if (!path || !screenName) return
    var map = Object.assign({}, overrides)
    map[screenName] = path
    overrides = map
    Quickshell.execDetached(["omarchy-shell", "-q", "paper-background", "setFor", screenName, path])
    statusText = "Set on " + screenName
  }

  function applyItem(item, allScreens) {
    var names = allScreens ? Quickshell.screens.map(function(s) { return s.name }) : [targetScreen ? targetScreen.name : ""]
    var local = item.remote ? localById[item.id] : item.path
    if (local) {
      for (var i = 0; i < names.length; i++) applyPath(local, names[i])
      return
    }
    download(item, names)
  }

  function resetScreen(screenName) {
    var map = Object.assign({}, overrides)
    delete map[screenName]
    overrides = map
    Quickshell.execDetached(["omarchy-shell", "-q", "paper-background", "clearFor", screenName])
    statusText = screenName + " follows the theme background"
  }

  function download(item, applyTo) {
    if (!item.remote || downloading[item.id] || localById[item.id]) return
    var d = Object.assign({}, downloading)
    d[item.id] = true
    downloading = d
    statusText = "Downloading " + item.width + "×" + item.height + "…"
    downloadJob.createObject(root, {
      item: item,
      applyTo: applyTo || [],
      dest: root.downloadDir + "/" + Model.fileNameFor(item)
    })
  }

  function deleteLocal(item) {
    if (!item.path) return
    Quickshell.execDetached(["rm", "-f", "--", item.path])
    localItems = localItems.filter(function(it) { return it.path !== item.path })
    statusText = "Deleted"
  }

  Component {
    id: downloadJob
    Process {
      id: job
      property var item
      property var applyTo: []
      property string dest: ""
      running: true
      command: ["bash", "-c",
        "set -e; mkdir -p \"$(dirname \"$1\")\"; curl -fsSL --max-time 180 -o \"$1.part\" \"$2\"; mv -f \"$1.part\" \"$1\"",
        "_", dest, item.full]
      onExited: function(code) {
        var d = Object.assign({}, root.downloading)
        delete d[job.item.id]
        root.downloading = d
        if (code === 0) {
          var local = Object.assign({}, job.item, { remote: false, path: job.dest, thumb: "file://" + job.dest })
          root.localItems = [local].concat(root.localItems.filter(function(it) { return it.id !== local.id }))
          root.statusText = "Saved to " + root.downloadDir.replace(root.home, "~")
          for (var i = 0; i < job.applyTo.length; i++) root.applyPath(job.dest, job.applyTo[i])
        } else {
          root.statusText = "Download failed"
        }
        job.destroy()
      }
    }
  }

  // ---------------------------------------------------------------- auto-change
  // Shared by every bar instance through a state file; only the instance on
  // the first screen runs the timer, and it changes every screen.
  readonly property string autoPath: home + "/.local/state/omarchy/settings/paper.json"
  property var auto: ({ interval: 0, source: "local", last: 0 })
  property bool pendingLocalChange: false
  readonly property bool isLeader: barScreen !== null && Quickshell.screens.length > 0 && barScreen.name === Quickshell.screens[0].name

  function saveAuto(patch) {
    var a = Object.assign({}, auto, patch)
    auto = a
    autoFile.setText(JSON.stringify(a, null, 2) + "\n")
  }

  function setAutoInterval(minutes) {
    // Restart the countdown so enabling doesn't change the wallpaper instantly.
    saveAuto({ interval: minutes, last: Date.now() })
    statusText = minutes > 0 ? "Auto-change every " + Model.intervalLabel(minutes) : "Auto-change off"
  }

  function changeAllScreens() {
    saveAuto({ last: Date.now() })
    if (auto.source === "online") {
      var list = Quickshell.screens
      for (var i = 0; i < list.length; i++) randomOn(list[i].name)
      statusText = "Fetching new wallpapers…"
    } else {
      pendingLocalChange = true
      scanLocal()
    }
  }

  // Pick a random downloaded wallpaper per screen, matching its orientation.
  // Prefers one that is neither on this screen now nor picked for another
  // screen this round; a screen with no matching download is left alone.
  function applyRandomLocal() {
    var list = Quickshell.screens
    var used = []
    var missing = []
    for (var i = 0; i < list.length; i++) {
      var name = list[i].name
      var o = Model.screenOrientation(list[i])
      var current = currentFor(name)
      var matching = localItems.filter(function(it) { return it.orientation === o })
      if (matching.length === 0) {
        missing.push(name + " (" + o + ")")
        continue
      }
      var pool = matching.filter(function(it) { return it.path !== current && used.indexOf(it.path) < 0 })
      if (pool.length === 0) pool = matching.filter(function(it) { return it.path !== current })
      if (pool.length === 0) continue
      var pick = pool[Math.floor(Math.random() * pool.length)]
      used.push(pick.path)
      applyPath(pick.path, name)
    }
    statusText = missing.length > 0
      ? "No downloaded wallpaper for " + missing.join(", ")
      : "Changed wallpapers from downloads"
  }

  FileView {
    id: autoFile
    path: root.autoPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var a = JSON.parse(text() || "{}") || {}
        root.auto = {
          interval: Number(a.interval) || 0,
          source: a.source === "online" ? "online" : "local",
          last: Number(a.last) || 0
        }
      } catch (e) {}
    }
  }

  Timer {
    interval: 60 * 1000
    repeat: true
    triggeredOnStart: true
    running: root.isLeader && root.auto.interval > 0
    onTriggered: {
      if (Date.now() - root.auto.last >= root.auto.interval * 60 * 1000) root.changeAllScreens()
    }
  }

  // ---------------------------------------------------------------- state files
  FileView {
    id: overridesFile
    path: root.overridesPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.overrides = JSON.parse(text() || "{}") || {} } catch (e) { root.overrides = {} }
    }
    onLoadFailed: root.overrides = {}
  }

  Process {
    id: globalProc
    command: ["readlink", "-f", root.home + "/.local/state/omarchy/current/background"]
    stdout: StdioCollector {
      onStreamFinished: root.globalBackground = String(text || "").trim()
    }
  }

  // ---------------------------------------------------------------- lifecycle
  onOpenedChanged: if (opened) {
    if (targetName === "" && barScreen) targetName = barScreen.name
    overridesFile.reload()
    if (!globalProc.running) globalProc.running = true
    scanLocal()
    if (remoteItems.length === 0 && tab !== "downloaded") resetAndFetch()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  } else {
    statusText = ""
  }

  // Re-query whenever anything that shapes the remote results changes.
  onOrientationChanged: if (opened && tab !== "downloaded") resetAndFetch()
  onSortingChanged: if (opened) resetAndFetch()
  onTabChanged: {
    if (grid) grid.contentY = 0
    if (tab === "downloaded") scanLocal()
    else resetAndFetch()
    if (tab === "search") Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function openFor(screenName) {
    targetName = screenName
    if (!opened) open()
  }

  // Download a random wallpaper fitting the named monitor and apply it there.
  function randomOn(screenName) {
    var screen = screenByName(screenName) || barScreen
    if (!screen) return
    var o = Model.screenOrientation(screen)
    var size = Model.physicalSize(screen)
    var url = Model.searchUrl({
      sorting: "random",
      categories: setting("categories", "100"),
      orientation: o,
      atleast: o === "portrait" ? Math.min(size.w, size.h) + "x" + Math.max(size.w, size.h) : Math.max(size.w, size.h) + "x" + Math.min(size.w, size.h),
      page: 1
    })
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE || xhr.status !== 200) return
      try {
        var list = JSON.parse(xhr.responseText).data || []
        if (list.length > 0) root.download(Model.mapWallhaven(list[0]), [screen.name])
      } catch (e) {}
    }
    xhr.open("GET", url)
    xhr.send()
  }

  // Open the popup on the bar of the named monitor (falls back to this one).
  function openOn(screenName) {
    var peers = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    for (var i = 0; i < peers.length; i++) {
      var p = peers[i]
      if (p && p !== root && p.barScreen && p.barScreen.name === screenName && typeof p.openFor === "function") {
        if (opened) close()
        p.openFor(screenName)
        return
      }
    }
    openFor(screenName)
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.openFor(root.barScreen ? root.barScreen.name : "") }
    function close(): void { root.close() }
    function toggle(): void { root.opened ? root.close() : root.openFor(root.barScreen ? root.barScreen.name : "") }
    function openOn(screen: string): void { root.openOn(screen) }
    function random(screen: string): void { root.randomOn(screen) }
    function next(): void { root.changeAllScreens() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰸉"
    tooltipText: root.barScreen ? "Wallpaper for " + root.barScreen.name : "Wallpaper"
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (root.barScreen) root.resetScreen(root.barScreen.name)
        return
      }
      // Clicking on a monitor's bar targets that monitor.
      root.targetName = root.barScreen ? root.barScreen.name : ""
      root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(760))
    contentHeight: root.targetOrientation === "portrait"
      ? panel.fittedContentHeight(Style.space(1150), Style.space(1150))
      : panel.fittedContentHeight(Style.space(720), Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "1") root.tab = "discover"
        else if (t === "2") root.tab = "search"
        else if (t === "3") root.tab = "downloaded"
        else if (t === "/") root.tab = "search"
        else if (t === "r" || t === "R") root.resetAndFetch()
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(10)

        // ---- header: title + monitor map
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(12)

          ColumnLayout {
            spacing: Style.space(2)
            Text {
              text: "Paper"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }
            Text {
              text: root.targetScreen
                ? root.targetScreen.name + " · " + Model.physicalSize(root.targetScreen).w + "×" + Model.physicalSize(root.targetScreen).h + " · " + root.targetOrientation
                : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Item { Layout.fillWidth: true }

          ScreenMap {
            Layout.alignment: Qt.AlignVCenter
          }
        }

        // ---- tabs + orientation
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)

          ButtonGroup {
            focusable: false
            foreground: root.foreground
            fontFamily: root.fontFamily
            value: root.tab
            options: [
              { value: "discover", label: "Discover", icon: "󰋑" },
              { value: "search", label: "Search", icon: "󰍉" },
              { value: "downloaded", label: "Downloaded", icon: "󰇚" }
            ]
            onChanged: function(v) { root.tab = v }
          }

          Item { Layout.fillWidth: true }

          ButtonGroup {
            focusable: false
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            value: root.orientationMode
            options: [
              { value: "fit", label: "Fit screen", tooltip: "Match the target monitor's orientation" },
              { value: "landscape", label: "Landscape" },
              { value: "portrait", label: "Portrait" },
              { value: "any", label: "All", tooltip: "Any orientation" }
            ]
            onChanged: function(v) { root.orientationMode = v }
          }
        }

        // ---- sub toolbar
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)

          ButtonGroup {
            visible: root.tab === "discover"
            focusable: false
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            value: root.sorting
            options: [
              { value: "toplist", label: "Top" },
              { value: "hot", label: "Hot" },
              { value: "date_added", label: "Latest" },
              { value: "random", label: "Random" }
            ]
            onChanged: function(v) {
              if (v === root.sorting && v === "random") root.resetAndFetch()
              root.sorting = v
            }
          }

          TextField {
            id: searchField
            visible: root.tab === "search"
            Layout.fillWidth: true
            placeholderText: "Search Wallhaven (e.g. mountains, city night, minimal) and press Enter"
            foreground: root.foreground
            font.family: root.fontFamily
            onAccepted: {
              root.query = text
              root.resetAndFetch()
            }
            Keys.onEscapePressed: root.close()
          }

          Text {
            visible: root.tab === "downloaded"
            text: root.visibleLocal.length + " of " + root.localItems.length + " wallpapers · " + root.downloadDir.replace(root.home, "~")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideMiddle
            Layout.fillWidth: true
          }

          Item { Layout.fillWidth: root.tab === "discover" }

          PanelActionButton {
            iconText: "󰑐"
            tooltipText: root.tab === "downloaded" ? "Rescan folder" : "Refresh"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.tab === "downloaded" ? root.scanLocal() : root.resetAndFetch()
          }

          PanelActionButton {
            visible: root.tab === "downloaded"
            iconText: "󰉋"
            tooltipText: "Open folder"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: Quickshell.execDetached(["xdg-open", root.downloadDir])
          }

          PanelActionButton {
            iconText: "󰦛"
            tooltipText: "Reset " + (root.targetScreen ? root.targetScreen.name : "") + " to theme background"
            foreground: root.foreground
            fontFamily: root.fontFamily
            visible: root.targetScreen && root.overrides[root.targetScreen.name] !== undefined
            onClicked: root.resetScreen(root.targetScreen.name)
          }
        }

        // ---- grid
        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          GridView {
            id: grid
            anchors.fill: parent
            clip: true
            model: root.gridItems
            boundsBehavior: Flickable.StopAtBounds
            readonly property int columns: root.orientation === "portrait" ? 5 : 3
            readonly property real tileRatio: root.orientation === "portrait" ? 16 / 9 : (root.orientation === "landscape" ? 9 / 16 : 1)
            cellWidth: Math.floor(width / columns)
            cellHeight: Math.round(cellWidth * tileRatio)
            cacheBuffer: cellHeight * 2
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            onAtYEndChanged: if (atYEnd && root.tab !== "downloaded") root.fetchMore()
            onContentHeightChanged: if (contentHeight <= height && root.tab !== "downloaded") Qt.callLater(root.fetchMore)

            delegate: Tile {
              required property var modelData
              item: modelData
              width: grid.cellWidth
              height: grid.cellHeight
            }

            footer: Item {
              width: grid.width
              height: Style.space(40)
              Text {
                anchors.centerIn: parent
                visible: root.loading
                text: "Loading…"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          Text {
            anchors.centerIn: parent
            width: parent.width * 0.8
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: !root.loading && root.gridItems.length === 0
            text: root.errorText !== "" ? root.errorText
              : root.tab === "search" ? "Type a search and press Enter."
              : root.tab === "downloaded" ? (root.localItems.length === 0 ? "Nothing downloaded yet." : "No " + root.orientation + " wallpapers downloaded.")
              : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        // ---- auto-change
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            text: "󰑖 Auto-change"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          ButtonGroup {
            focusable: false
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            value: String(root.auto.interval)
            options: [
              { value: "0", label: "Off" },
              { value: "30", label: "30m" },
              { value: "60", label: "1h" },
              { value: "180", label: "3h" },
              { value: "1440", label: "Daily" }
            ]
            onChanged: function(v) { root.setAutoInterval(parseInt(v, 10)) }
          }

          Item { Layout.fillWidth: true }

          Text {
            text: "from"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          ButtonGroup {
            focusable: false
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            value: root.auto.source
            options: [
              { value: "local", label: "Downloaded" },
              { value: "online", label: "Online" }
            ]
            onChanged: function(v) { root.saveAuto({ source: v }) }
          }

          PanelActionButton {
            iconText: "󰒭"
            tooltipText: "Change all screens now"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.changeAllScreens()
          }
        }

        // ---- footer
        RowLayout {
          Layout.fillWidth: true
          Text {
            Layout.fillWidth: true
            text: root.statusText !== "" ? root.statusText
              : "Click: set on " + (root.targetScreen ? root.targetScreen.name : "screen") + " · Shift+click: all screens · Wallpapers from wallhaven.cc"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // ------------------------------------------------------------------ components

  // Miniature of the monitor layout. Each monitor shows its wallpaper; click
  // one to make it the target.
  component ScreenMap: Item {
    id: map
    readonly property var screens: Quickshell.screens
    readonly property var bounds: {
      var minX = 1e9, minY = 1e9, maxX = -1e9, maxY = -1e9
      for (var i = 0; i < screens.length; i++) {
        var s = screens[i]
        minX = Math.min(minX, s.x); minY = Math.min(minY, s.y)
        maxX = Math.max(maxX, s.x + s.width); maxY = Math.max(maxY, s.y + s.height)
      }
      return { x: minX, y: minY, w: Math.max(1, maxX - minX), h: Math.max(1, maxY - minY) }
    }
    readonly property real scaleFactor: Style.space(64) / bounds.h
    implicitWidth: bounds.w * scaleFactor
    implicitHeight: bounds.h * scaleFactor

    Repeater {
      model: map.screens
      Rectangle {
        id: mini
        required property var modelData
        readonly property bool isTarget: root.targetScreen && root.targetScreen.name === modelData.name
        x: (modelData.x - map.bounds.x) * map.scaleFactor + 2
        y: (modelData.y - map.bounds.y) * map.scaleFactor + 2
        width: modelData.width * map.scaleFactor - 4
        height: modelData.height * map.scaleFactor - 4
        color: Qt.darker(root.foreground, 4)
        border.width: isTarget ? 2 : 1
        border.color: isTarget ? root.accent : Qt.darker(root.foreground, 2.5)
        radius: 3
        clip: true

        Image {
          anchors.fill: parent
          anchors.margins: mini.border.width
          source: root.currentFor(mini.modelData.name) ? "file://" + root.currentFor(mini.modelData.name) : ""
          sourceSize.width: 240
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          opacity: mini.isTarget ? 1 : 0.55
        }

        Rectangle {
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.margins: mini.border.width
          height: label.implicitHeight + 2
          color: Qt.rgba(0, 0, 0, 0.55)
          Text {
            id: label
            anchors.centerIn: parent
            text: mini.modelData.name
            color: "white"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption * 0.85
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.targetName = mini.modelData.name
        }
      }
    }
  }

  component Tile: Item {
    id: tile
    property var item
    readonly property bool isLocal: !item.remote || !!root.localById[item.id]
    readonly property bool busy: !!root.downloading[item.id]
    readonly property string localPath: item.remote ? (root.localById[item.id] || "") : item.path
    readonly property var usedOn: {
      var out = []
      if (!localPath) return out
      var list = Quickshell.screens
      for (var i = 0; i < list.length; i++) if (root.currentFor(list[i].name) === localPath) out.push(list[i].name)
      return out
    }

    Rectangle {
      id: frame
      anchors.fill: parent
      anchors.margins: Style.space(4)
      color: Qt.darker(root.foreground, 5)
      radius: 4
      clip: true
      border.width: tile.usedOn.length > 0 ? 2 : 0
      border.color: root.accent

      Image {
        id: img
        anchors.fill: parent
        anchors.margins: frame.border.width
        source: tile.item.thumb
        sourceSize.width: 480
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        smooth: true
        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 180 } }
      }

      Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: hover.containsMouse ? 0.25 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }
      }

      // resolution + state badges
      Rectangle {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: Style.space(6)
        visible: hover.containsMouse || tile.usedOn.length > 0
        radius: 3
        color: Qt.rgba(0, 0, 0, 0.6)
        width: info.implicitWidth + Style.space(10)
        height: info.implicitHeight + Style.space(4)
        Text {
          id: info
          anchors.centerIn: parent
          text: (tile.usedOn.length > 0 ? "● " + tile.usedOn.join(", ") + "  " : "")
            + (hover.containsMouse ? tile.item.width + "×" + tile.item.height : "")
          color: "white"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Style.space(6)
        visible: tile.item.remote && tile.isLocal && !hover.containsMouse
        text: "󰄬"
        color: "white"
        style: Text.Outline
        styleColor: Qt.rgba(0, 0, 0, 0.6)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        anchors.centerIn: parent
        visible: tile.busy
        text: "󰇚 downloading"
        color: "white"
        style: Text.Outline
        styleColor: Qt.rgba(0, 0, 0, 0.7)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onClicked: function(mouse) {
          if (mouse.button === Qt.MiddleButton) {
            if (tile.item.page) Qt.openUrlExternally(tile.item.page)
            return
          }
          root.applyItem(tile.item, (mouse.modifiers & Qt.ShiftModifier) !== 0)
        }
      }

      // hover actions
      Row {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Style.space(4)
        spacing: Style.space(2)
        visible: hover.containsMouse || actionHover.hovered

        HoverHandler { id: actionHover }

        TileAction {
          visible: tile.item.remote && !tile.isLocal && !tile.busy
          icon: "󰇚"
          onActivated: root.download(tile.item, [])
        }
        TileAction {
          icon: "󰍹"
          onActivated: root.applyItem(tile.item, true)
        }
        TileAction {
          visible: !tile.item.remote
          icon: "󰆴"
          onActivated: root.deleteLocal(tile.item)
        }
      }
    }
  }

  component TileAction: Rectangle {
    id: action
    property string icon: ""
    signal activated()
    width: Style.space(26)
    height: Style.space(26)
    radius: 4
    color: actionMouse.containsMouse ? Qt.rgba(0, 0, 0, 0.8) : Qt.rgba(0, 0, 0, 0.55)
    Text {
      anchors.centerIn: parent
      text: action.icon
      color: "white"
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    MouseArea {
      id: actionMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: action.activated()
    }
  }
}
