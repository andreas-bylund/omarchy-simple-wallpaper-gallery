import QtQuick
// Namespaced: Button and TextField exist here as well as in qs.Ui, and the
// ones this widget wants are Omarchy's. Leaving it unqualified would make
// import order — not intent — decide which class each of them resolves to.
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button plus popup for picking a wallpaper. Everything that touches the
// filesystem (listing images, generating thumbnails, walking folders) lives
// in bin/wallpaper-gallery, so the QML stays a view over it and the plugin
// remains testable from a terminal.
Panel {
  id: root
  moduleName: "bylund.wallpaper-gallery"
  ipcTarget: "bylund.wallpaper-gallery"
  // The base class's handler covers open/close/toggle; this plugin adds a few
  // of its own to the same target, so it owns the whole handler instead.
  manageIpc: false

  // Qt.resolvedUrl percent-encodes the path, which has to be undone before it
  // can be executed: a home directory with an å in it would otherwise arrive
  // as %C3%A5 and nothing would run at all.
  readonly property string cli: decodeURIComponent(
    Qt.resolvedUrl("bin/wallpaper-gallery").toString().replace(/^file:\/\//, ""))

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool barVertical: bar ? bar.vertical === true : false

  readonly property string glyphGallery: String.fromCodePoint(0xF02E9)
  readonly property string glyphCog: String.fromCodePoint(0xF0493)
  readonly property string glyphRefresh: String.fromCodePoint(0xF0450)
  readonly property string glyphFolder: String.fromCodePoint(0xF024B)
  readonly property string glyphCheck: String.fromCodePoint(0xF012C)

  // The gallery: rows of {path, thumb, name} from the list command.
  property var images: []
  property bool listing: false
  property string currentBackground: ""
  // The same file as currentBackground, named through the theme's stable
  // source directory rather than the live copy that theme switches replace.
  property string currentBackgroundAlt: ""
  property string notice: ""

  // The current theme's own backgrounds, shown as a section of their own.
  // Ones already in the main grid would just repeat, so only the remainder
  // shows — and the section disappears entirely when the chosen folder IS
  // the theme's backgrounds folder.
  property var themeImages: []
  readonly property var themeVisible: {
    var seen = {}
    for (var i = 0; i < images.length; i++) seen[images[i].path] = true
    var rest = []
    for (var j = 0; j < themeImages.length; j++) {
      if (!seen[themeImages[j].path]) rest.push(themeImages[j])
    }
    return rest
  }

  property bool settingsOpen: false

  // Keyboard cursor over the grid. Like the mouse cursor it only appears
  // once you reach for it.
  property bool cursorActive: false
  property int cursorIndex: 0

  readonly property string folder: String(setting("folder", "") || "")
  readonly property bool includeSubfolders: setting("includeSubfolders", false) === true
  readonly property int gridColumns: Math.max(2, Math.min(5, Number(setting("columns", 3)) || 3))
  readonly property bool keepAcrossThemes: setting("keepAcrossThemes", false) === true

  onFolderChanged: if (opened) refresh()
  onIncludeSubfoldersChanged: if (opened) refresh()
  // A theme switch puts the theme's own background up; the hook puts the
  // gallery pick back afterwards. The hook file itself is the on/off state,
  // so syncing on every settings echo keeps it truthful even when the toggle
  // is flipped from a terminal with `omarchy bar set`.
  onKeepAcrossThemesChanged: syncHook()

  function syncHook() {
    Quickshell.execDetached([cli, "hook", keepAcrossThemes ? "on" : "off"])
  }

  // Widget settings live in shell.json, which the shell owns; `omarchy bar
  // set` is the supported way in, and the change comes back to us as
  // `settings`, which the bindings above follow.
  function persist(key, value) {
    if (bar) bar.run("omarchy bar set " + moduleName + " " + key + " "
      + Util.shellQuote(JSON.stringify(value)) + " --json")
  }

  // A generation pass is due whenever a listing still has thumbnails missing,
  // but only once for a given result. Keying the guard on how many are missing
  // rather than on the folder alone means a rescan after dropping new
  // wallpapers in generates theirs too, while a pass that changes nothing — no
  // vipsthumbnail, or an image vips will not read — is not retried forever.
  property string thumbedKey: ""
  property int thumbedMissing: -1
  property bool themeThumbed: false

  // Rows are "<thumbnail>\t<path>" with the path last, so a tab inside a
  // filename cannot shift the columns. An empty thumbnail field means none is
  // cached yet: the original is shown meanwhile, and how many rows are in that
  // state is what tells the caller whether a generation pass is worth running.
  function parseRows(text) {
    var rows = String(text || "").split("\n")
    var items = []
    var missing = 0
    for (var i = 0; i < rows.length; i++) {
      if (!rows[i]) continue
      var cut = rows[i].indexOf("\t")
      if (cut < 0) continue
      var thumb = rows[i].substring(0, cut)
      var path = rows[i].substring(cut + 1)
      if (!path) continue
      if (!thumb) missing++
      items.push({ path: path, thumb: thumb || path, name: path.split("/").pop() })
    }
    return { items: items, missing: missing }
  }

  function refresh() {
    if (!themeProc.running) themeProc.running = true
    if (!currentProc.running) currentProc.running = true
    if (folder === "") { images = []; return }
    if (listProc.running) return
    notice = ""
    listing = true
    listProc.command = [cli, "list", folder, includeSubfolders ? "1" : "0"]
    listProc.running = true
  }

  function apply(path) {
    // Optimistic: the symlink read would say the same thing a beat later,
    // and the highlight moving on click is the confirmation people look for.
    // The read still follows, so a set that failed takes the badge back
    // instead of leaving it on a wallpaper that never went up.
    currentBackground = path
    Quickshell.execDetached([cli, "set", path])
    currentSoon.restart()
  }

  function applyRandom() {
    if (folder === "") { open(); return }
    Quickshell.execDetached([cli, "random", folder, includeSubfolders ? "1" : "0"])
    currentSoon.restart()
  }

  function openSettings() {
    settingsOpen = true
    // Filled here rather than bound, since typing in the field would break a
    // binding on the first keystroke and leave it stale from then on.
    pathField.text = folder
    // On a panel that is already open the focusTarget binding above has
    // nothing to trigger it, so the field is focused directly. It is only
    // just becoming visible, hence the deferral.
    Qt.callLater(function() { if (root.settingsOpen) pathField.forceActiveFocus() })
  }

  function closeSettings() {
    settingsOpen = false
    // The path field held the keyboard; hand it back or the panel's own
    // shortcuts stay dead for the rest of the visit.
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function chooseFolder(path) {
    var trimmed = String(path || "").trim()
    if (trimmed === "" || trimmed === folder) { closeSettings(); return }
    notice = ""
    persist("folder", trimmed)
    closeSettings()
  }

  function indexOfCurrent() {
    for (var i = 0; i < images.length; i++) {
      if (images[i].path === currentBackground) return i
    }
    return -1
  }

  function moveCursor(dx, dy) {
    if (images.length === 0) return
    if (!cursorActive) {
      // The first press shows the cursor where a picker would put it: on the
      // wallpaper already in use.
      cursorActive = true
      cursorIndex = Math.max(0, indexOfCurrent())
    } else {
      // Horizontal movement stays on its row: `l` at the right edge should
      // stop there rather than wrap round to the start of the next one.
      var row = Math.floor(cursorIndex / gridColumns)
      var lastOnRow = Math.min(images.length - 1, row * gridColumns + gridColumns - 1)
      var next = Math.max(row * gridColumns, Math.min(lastOnRow, cursorIndex + dx))
      cursorIndex = Math.max(0, Math.min(images.length - 1, next + dy * gridColumns))
    }
    grid.positionViewAtIndex(cursorIndex, GridView.Contain)
  }

  onOpenedChanged: {
    if (opened) {
      thumbedKey = ""
      thumbedMissing = -1
      themeThumbed = false
      cursorActive = false
      refresh()
      // Regenerating the hook and keep-links on every visit keeps them
      // current after plugin updates and newly installed themes.
      if (keepAcrossThemes) syncHook()
      // With no folder chosen there is nothing else the panel can usefully
      // show, so it opens straight into the settings.
      if (folder === "") openSettings()
    } else {
      settingsOpen = false
    }
  }

  // Setting a wallpaper changes the symlink out from under us; re-read it once
  // the detached process has had a moment.
  Timer {
    id: currentSoon
    interval: 400
    onTriggered: if (!currentProc.running) currentProc.running = true
  }

  Process {
    id: listProc
    running: false
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.listing = false
      if (exitCode !== 0) {
        root.images = []
        root.notice = "Could not read " + root.folder
        return
      }
      var parsed = root.parseRows(listOut.text)
      root.images = parsed.items
      if (root.cursorIndex >= parsed.items.length) root.cursorIndex = Math.max(0, parsed.items.length - 1)

      var key = root.folder + "|" + root.includeSubfolders
      if (parsed.missing > 0 && !thumbsProc.running
          && (key !== root.thumbedKey || parsed.missing !== root.thumbedMissing)) {
        root.thumbedKey = key
        root.thumbedMissing = parsed.missing
        thumbsProc.command = [root.cli, "thumbs", root.folder, root.includeSubfolders ? "1" : "0"]
        thumbsProc.running = true
      }
    }
  }

  Process {
    id: thumbsProc
    running: false
    // Relisting swaps the freshly cached thumbnails in for the originals.
    onExited: if (root.opened) root.refresh()
  }

  Process {
    id: themeProc
    running: false
    command: [root.cli, "theme-list"]
    stdout: StdioCollector { id: themeOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var parsed = root.parseRows(themeOut.text)
      root.themeImages = parsed.items
      if (parsed.missing > 0 && !root.themeThumbed && !themeThumbsProc.running) {
        root.themeThumbed = true
        themeThumbsProc.running = true
      }
    }
  }

  Process {
    id: themeThumbsProc
    running: false
    command: [root.cli, "theme-thumbs"]
    onExited: if (root.opened && !themeProc.running) themeProc.running = true
  }

  Process {
    id: currentProc
    running: false
    command: [root.cli, "current"]
    stdout: StdioCollector { id: currentOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var lines = String(currentOut.text || "").split("\n").filter(function(line) { return line !== "" })
      root.currentBackground = lines.length > 0 ? lines[0] : ""
      root.currentBackgroundAlt = lines.length > 1 ? lines[1] : ""
    }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    // Scriptable equivalents of the panel's own controls.
    function random(): void { root.applyRandom() }
    function refresh(): void { root.refresh() }
    function status(): string {
      return JSON.stringify({
        folder: root.folder,
        images: root.images.length,
        current: root.currentBackground,
        settingsOpen: root.settingsOpen,
        cli: root.cli
      })
    }
  }

  // One thumbnail cell, shared by the main grid and the theme section.
  component WallpaperCell: Item {
    id: cell
    required property var modelData
    required property int index
    property real cellW: 0
    property real cellH: 0
    property bool underCursor: false
    width: cellW
    height: cellH

    // Theme wallpapers are listed through the theme's source directory while
    // Omarchy's own tools set the background to the live copy, so the marker
    // matches either name for the same file.
    readonly property bool isCurrent: cell.modelData.path === root.currentBackground
      || (root.currentBackgroundAlt !== "" && cell.modelData.path === root.currentBackgroundAlt)

    Item {
      anchors.fill: parent
      anchors.margins: Style.space(3)

      Image {
        anchors.fill: parent
        source: Util.fileUrl(cell.modelData.thumb)
        // Decode at roughly cell size: full-resolution originals only pass
        // through here until their thumbnails are cached.
        sourceSize.width: Math.max(1, Math.round(cell.cellW * 2))
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        smooth: true
        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }

        // A cached thumbnail deleted behind the index's back would otherwise
        // leave an empty tile; fall back to the original once.
        onStatusChanged: {
          if (status === Image.Error && cell.modelData.thumb !== cell.modelData.path) {
            source = Util.fileUrl(cell.modelData.path)
          }
        }
      }

      Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: cell.isCurrent ? Math.max(2, Style.space(2)) : 1
        border.color: cell.isCurrent ? Color.accent
          : (cellMouse.containsMouse || cell.underCursor) ? root.foreground
          : Util.alpha(root.foreground, 0.25)
      }

      // Badge marking the wallpaper in use, so the accent border still reads
      // on themes where accent sits close to foreground.
      Rectangle {
        visible: cell.isCurrent
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Style.space(4)
        width: Style.space(18)
        height: width
        radius: width / 2
        color: Color.accent

        Text {
          anchors.centerIn: parent
          text: root.glyphCheck
          color: Color.background
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      MouseArea {
        id: cellMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.apply(cell.modelData.path)
      }
    }
  }

  WidgetButton {
    id: button
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    tooltipText: "Wallpaper gallery"
    fixedWidth: root.barVertical ? -1 : barGlyph.implicitWidth + Style.space(12)
    fixedHeight: root.barVertical ? Style.bar.iconSlot : -1

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.applyRandom()
      else if (buttonCode === Qt.RightButton) { if (!root.opened) root.open(); root.openSettings() }
      else root.toggle()
    }

    Text {
      id: barGlyph
      anchors.centerIn: parent
      text: root.glyphGallery
      color: button.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    // The panel forces focus onto this when it opens. In the settings view
    // the path field is the only thing to type into, so it takes the focus
    // and the key catcher blocks itself out of the way.
    focusTarget: root.settingsOpen ? pathField : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(body.implicitHeight, Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The path field owns the keyboard while it has focus, or typing a
      // folder name would fire the panel's shortcuts. Everywhere else the
      // catcher stays live, so Escape and "," work in the settings view too.
      blocked: pathField.activeFocus
      // The grid cursor belongs to the grid; while settings are showing, the
      // keys that drive it do nothing rather than moving a hidden selection.
      onMoveRequested: function(dx, dy) { if (!root.settingsOpen) root.moveCursor(dx, dy) }
      onActivateRequested: {
        if (!root.settingsOpen && root.cursorActive && root.images[root.cursorIndex])
          root.apply(root.images[root.cursorIndex].path)
      }
      // A ladder out, so Escape never closes more than you meant.
      onCloseRequested: if (root.settingsOpen) root.closeSettings(); else root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === ",") { if (root.settingsOpen) root.closeSettings(); else root.openSettings() }
        else if (t === "r") root.refresh()
        else if (t === "s") root.applyRandom()
      }

      Column {
        id: body
        width: parent.width
        spacing: Style.space(10)

        // Header: what you are looking at on the left, refresh and the gear
        // on the right.
        Item {
          width: parent.width
          implicitHeight: Math.max(titleText.implicitHeight, headerButtons.implicitHeight)

          Text {
            id: titleText
            anchors.left: parent.left
            anchors.right: headerButtons.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.settingsOpen ? "Gallery settings"
              : (root.images.length > 0 ? "Wallpapers · " + root.images.length : "Wallpapers")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.weight: Font.DemiBold
            elide: Text.ElideRight
          }

          Row {
            id: headerButtons
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Button {
              iconText: root.glyphRefresh
              iconSpinning: root.listing
              tooltipText: "Rescan folder"
              visible: !root.settingsOpen
              onClicked: root.refresh()
            }

            Button {
              iconText: root.glyphCog
              active: root.settingsOpen
              tooltipText: "Settings"
              onClicked: {
                if (root.settingsOpen) root.closeSettings()
                else root.openSettings()
              }
            }
          }
        }

        Text {
          width: parent.width
          visible: root.notice !== ""
          text: root.notice
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        // === The gallery ===
        GridView {
          id: grid
          visible: !root.settingsOpen && root.images.length > 0
          width: parent.width
          cellWidth: Math.floor(width / root.gridColumns)
          cellHeight: Math.round(cellWidth * 9 / 16)
          // The theme section below needs its share of the panel's height cap.
          height: Math.min(Math.ceil(root.images.length / root.gridColumns),
            root.themeVisible.length > 0 ? 4 : 5) * cellHeight
          clip: true
          model: root.images
          interactive: contentHeight > height
          boundsBehavior: Flickable.StopAtBounds
          cacheBuffer: cellHeight * 6
          QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

          delegate: WallpaperCell {
            cellW: grid.cellWidth
            cellH: grid.cellHeight
            underCursor: root.cursorActive && index === root.cursorIndex
          }
        }

        // === The current theme's own backgrounds ===
        Column {
          visible: !root.settingsOpen && root.themeVisible.length > 0
          width: parent.width
          spacing: Style.space(4)

          Text {
            text: "Theme backgrounds"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.weight: Font.DemiBold
          }

          GridView {
            id: themeGrid
            width: parent.width
            cellWidth: Math.floor(width / root.gridColumns)
            cellHeight: Math.round(cellWidth * 9 / 16)
            height: Math.min(Math.ceil(root.themeVisible.length / root.gridColumns), 2) * cellHeight
            clip: true
            model: root.themeVisible
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            cacheBuffer: cellHeight * 4
            QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

            delegate: WallpaperCell {
              cellW: themeGrid.cellWidth
              cellH: themeGrid.cellHeight
            }
          }
        }

        // Empty states: no folder yet, or a folder with nothing in it.
        Column {
          visible: !root.settingsOpen && root.images.length === 0
          width: parent.width
          spacing: Style.space(8)
          padding: Style.space(6)

          Text {
            width: parent.width - parent.padding * 2
            text: root.folder === "" ? "No wallpaper folder chosen yet."
              : (root.listing ? "Scanning " + root.folder + "…"
                              : "No images found in " + root.folder + ".")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
          }

          Button {
            visible: root.folder === ""
            text: "Choose a folder"
            iconText: root.glyphFolder
            onClicked: root.openSettings()
          }
        }

        // === Settings: the toggles and the wallpaper folder ===
        Column {
          visible: root.settingsOpen
          width: parent.width
          spacing: Style.space(10)

          Toggle {
            width: parent.width
            label: "Include subfolders"
            description: "Also show images inside folders within the wallpaper folder."
            checked: root.includeSubfolders
            onClicked: root.persist("includeSubfolders", !root.includeSubfolders)
          }

          Toggle {
            width: parent.width
            label: "Keep wallpaper across theme switches"
            description: "Re-applies your last pick from this gallery after a theme change swaps in the theme's own background."
            checked: root.keepAcrossThemes
            onClicked: root.persist("keepAcrossThemes", !root.keepAcrossThemes)
          }

          Text {
            text: "Wallpaper folder"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.weight: Font.DemiBold
          }

          // Type the path, press Enter or Use. `text` is deliberately not
          // bound to `folder`: typing would break the binding anyway, so the
          // field is filled explicitly whenever the settings view opens.
          Item {
            width: parent.width
            implicitHeight: Math.max(pathField.implicitHeight, useButton.implicitHeight)

            TextField {
              id: pathField
              anchors.left: parent.left
              anchors.right: useButton.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              placeholderText: "~/Pictures/wallpapers"
              onAccepted: root.chooseFolder(text)
            }

            Button {
              id: useButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "Use"
              iconText: root.glyphCheck
              bordered: true
              onClicked: root.chooseFolder(pathField.text)
            }
          }

          Text {
            width: parent.width
            text: "A path starting with ~ or $HOME is expanded."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
        }
      }
    }
  }
}
