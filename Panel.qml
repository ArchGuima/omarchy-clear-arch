import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "archguima.omacleaner"
  ipcTarget: "archguima.omacleaner"

  readonly property string pluginDir: {
    var raw = String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/+$/, "")
    try { return decodeURIComponent(raw) } catch (e) { return raw }
  }
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accentColor: Commons.Color.accent
  readonly property color warningColor: Commons.Color.warning
  readonly property color dimColor: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Semantic state (avoiding Item property names like `state`, `enabled`, `visible`)
  property string cleanStatus: "idle" // idle | scanning | cleaning | done | doneWarnings | cancelled | error
  property int progressPercent: 0
  property int pacnewFoundCount: 0
  property bool authCancelledFlag: false
  property bool hasWarningsFlag: false
  property bool logExpanded: false
  property bool rebootArmed: false

  property var stepSelection: Model.defaultSelection()
  property var stepStatuses: Model.defaultStatuses()
  property var logLines: []
  property var scanInfo: ({
    scanned: false,
    orphansCount: 0,
    pacmanCacheBytes: 0,
    aurCacheBytes: 0,
    journalBytes: 0,
    userCacheBytes: 0,
    pacnewCount: 0,
    totalBytes: 0
  })

  // Keyboard navigation state: 0..steps.length-1 = step rows,
  // steps.length = run button, steps.length+1 = reboot button
  property bool cursorActive: false
  property int cursorIndex: 0

  readonly property var stepsModel: Model.STEPS
  readonly property int totalCursorSlots: stepsModel.length + 2
  readonly property bool cleaning: cleanStatus === "cleaning"
  readonly property bool scanning: scanProc.running
  readonly property int selectedCount: Model.selectedStepIds(stepSelection).length
  readonly property bool allSelected: selectedCount === stepsModel.length

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  readonly property string heroStatusLabel: {
    if (cleanStatus === "cleaning") return strings.t("status.cleaning")
    if (scanning) return strings.t("status.scanning")
    if (cleanStatus === "done") return strings.t("status.done")
    if (cleanStatus === "doneWarnings") return strings.t("status.doneWarnings")
    if (cleanStatus === "cancelled") return strings.t("status.cancelled")
    if (cleanStatus === "error") return strings.t("status.error")
    return strings.t("status.idle")
  }

  readonly property color progressFillColor: {
    if (cleanStatus === "error" || cleanStatus === "cancelled") return urgentColor
    if (cleanStatus === "doneWarnings") return warningColor
    if (cleanStatus === "cleaning" || cleanStatus === "done") return accentColor
    return foreground
  }

  readonly property string barTooltipText: Model.sanitizeText(
    cleaning
      ? strings.t("bar.tooltipCleaning").arg(Commons.I18n.formatNumber(progressPercent))
      : strings.t("bar.tooltipIdle"),
    120
  )

  function refreshScan() {
    if (cleaning || scanProc.running) return
    scanProc.command = ["/usr/bin/bash", root.pluginDir + "/scripts/scan.sh"]
    scanProc.running = true
  }

  function toggleStep(stepId) {
    if (cleaning) return
    var next = Object.assign({}, stepSelection)
    next[stepId] = !next[stepId]
    stepSelection = next
  }

  function setAllSteps(checked) {
    if (cleaning) return
    var next = {}
    for (var i = 0; i < stepsModel.length; i++) {
      next[stepsModel[i].id] = !!checked
    }
    stepSelection = next
  }

  function stepBadgeText(stepId) {
    if (!scanInfo.scanned) return ""
    if (stepId === "orphans") {
      return scanInfo.orphansCount > 0
        ? strings.tn("badge.orphans", scanInfo.orphansCount).arg(Commons.I18n.formatNumber(scanInfo.orphansCount))
        : strings.t("badge.clean")
    }
    if (stepId === "pacman_cache") {
      return scanInfo.pacmanCacheBytes > 0
        ? Model.formatBytes(scanInfo.pacmanCacheBytes, Commons.I18n.formatNumber)
        : strings.t("badge.clean")
    }
    if (stepId === "aur_cache") {
      return scanInfo.aurCacheBytes > 0
        ? Model.formatBytes(scanInfo.aurCacheBytes, Commons.I18n.formatNumber)
        : strings.t("badge.clean")
    }
    if (stepId === "journal") {
      return scanInfo.journalBytes > 0
        ? Model.formatBytes(scanInfo.journalBytes, Commons.I18n.formatNumber)
        : strings.t("badge.clean")
    }
    if (stepId === "user_cache") {
      return scanInfo.userCacheBytes > 0
        ? Model.formatBytes(scanInfo.userCacheBytes, Commons.I18n.formatNumber)
        : strings.t("badge.clean")
    }
    if (stepId === "pacnew") {
      return scanInfo.pacnewCount > 0
        ? strings.tn("badge.files", scanInfo.pacnewCount).arg(Commons.I18n.formatNumber(scanInfo.pacnewCount))
        : strings.t("badge.none")
    }
    return ""
  }

  function startCleanup() {
    if (cleaning) return
    var ids = Model.selectedStepIds(stepSelection)
    if (ids.length === 0) return

    rebootArmed = false
    rebootConfirmTimer.stop()
    authCancelledFlag = false
    hasWarningsFlag = false
    pacnewFoundCount = 0
    progressPercent = 0
    stepStatuses = Model.defaultStatuses()
    logLines = []
    logExpanded = true
    cleanStatus = "cleaning"

    var args = ["/usr/bin/bash", root.pluginDir + "/scripts/omacleaner-runner.sh"]
    for (var i = 0; i < ids.length; i++) args.push(ids[i])
    cleanProc.command = args
    cleanProc.running = true
  }

  function launchInTerminal() {
    if (cleaning) return
    var ids = Model.selectedStepIds(stepSelection)
    if (ids.length === 0) return
    var scriptCmd = "/usr/bin/bash '" + root.pluginDir.replace(/'/g, "'\\''") + "/scripts/omacleaner-terminal.sh'"
    for (var i = 0; i < ids.length; i++) {
      scriptCmd += " " + ids[i]
    }
    terminalProc.command = ["omarchy-launch-floating-terminal-with-presentation", scriptCmd]
    terminalProc.running = true
    root.close()
  }

  function handleRebootClick() {
    if (cleaning) return
    if (!rebootArmed) {
      rebootArmed = true
      rebootConfirmTimer.restart()
      return
    }
    rebootArmed = false
    rebootConfirmTimer.stop()
    rebootProc.command = ["systemctl", "reboot"]
    rebootProc.running = true
  }

  function sendNotification(title, body) {
    var safeTitle = Model.sanitizeText(title, 80)
    var safeBody = Model.sanitizeText(body, 220)
    if (!safeTitle && !safeBody) return
    notifyProc.command = ["omarchy-notification-send", safeTitle, safeBody]
    notifyProc.running = true
  }

  function handleRunnerLine(rawLine) {
    var ev = Model.parseRunnerLine(rawLine)
    if (ev.kind === "empty" || ev.kind === "ignore") return

    if (ev.kind === "auth_cancelled") {
      authCancelledFlag = true
      return
    }

    if (ev.kind === "progress") {
      progressPercent = ev.percent
      return
    }

    if (ev.kind === "step") {
      var nextStatuses = Object.assign({}, stepStatuses)
      if (ev.status === "START") nextStatuses[ev.stepId] = "running"
      else if (ev.status === "DONE") nextStatuses[ev.stepId] = "done"
      else if (ev.status === "WARN") {
        nextStatuses[ev.stepId] = "warn"
        hasWarningsFlag = true
        if (ev.stepId === "pacnew") {
          pacnewFoundCount = Model.clampNonNegativeInt(ev.detail, 100000)
        }
      } else if (ev.status === "ERROR") {
        nextStatuses[ev.stepId] = "error"
      }
      stepStatuses = nextStatuses
      return
    }

    if (ev.kind === "log" && ev.text) {
      logLines = Model.appendLogLine(logLines, ev.text)
    }
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy !== 0) {
      var next = cursorIndex + dy
      if (next < 0) next = totalCursorSlots - 1
      else if (next >= totalCursorSlots) next = 0
      cursorIndex = next
    } else if (dx !== 0 && cursorIndex >= stepsModel.length) {
      cursorIndex = cursorIndex === stepsModel.length ? stepsModel.length + 1 : stepsModel.length
    }
  }

  function activateCursor() {
    if (!cursorActive) return
    if (cursorIndex < stepsModel.length) {
      toggleStep(stepsModel[cursorIndex].id)
    } else if (cursorIndex === stepsModel.length) {
      startCleanup()
    } else if (cursorIndex === stepsModel.length + 1) {
      handleRebootClick()
    }
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      cursorIndex = 0
      rebootArmed = false
      rebootConfirmTimer.stop()
      refreshScan()
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: scanProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.scanInfo = Model.parseScanOutput(text)
    }
  }

  Process {
    id: cleanProc
    stdout: SplitParser {
      onRead: function(line) { root.handleRunnerLine(line) }
    }
    stderr: SplitParser {
      onRead: function(line) { root.handleRunnerLine(line) }
    }
    onExited: function(exitCode) {
      var cancelled = root.authCancelledFlag || exitCode === 126 || exitCode === 127
      var finalizedStatuses = Object.assign({}, root.stepStatuses)
      var statusesChanged = false
      for (var i = 0; i < root.stepsModel.length; i++) {
        var sid = root.stepsModel[i].id
        if (finalizedStatuses[sid] === "running") {
          finalizedStatuses[sid] = cancelled ? "idle" : "error"
          statusesChanged = true
        }
      }
      if (statusesChanged) root.stepStatuses = finalizedStatuses

      if (cancelled) {
        root.cleanStatus = "cancelled"
        root.progressPercent = 0
      } else if (exitCode !== 0) {
        root.cleanStatus = "error"
        root.sendNotification(strings.t("notify.doneTitle"), strings.t("notify.errorBody"))
      } else if (root.hasWarningsFlag) {
        root.cleanStatus = "doneWarnings"
        root.progressPercent = 100
        root.sendNotification(
          strings.t("notify.doneTitle"),
          strings.t("notify.warnBody").arg(Commons.I18n.formatNumber(root.pacnewFoundCount))
        )
      } else {
        root.cleanStatus = "done"
        root.progressPercent = 100
        root.sendNotification(strings.t("notify.doneTitle"), strings.t("notify.doneBody"))
      }
      root.refreshScan()
    }
  }

  Process { id: terminalProc }
  Process { id: notifyProc }
  Process { id: rebootProc }

  Timer {
    id: rebootConfirmTimer
    interval: 4000
    repeat: false
    onTriggered: root.rebootArmed = false
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰃢"
    active: root.cleaning
    activeColor: root.accentColor
    tooltipText: root.barTooltipText
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) {
        if (!root.opened) root.open()
        else root.refreshScan()
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    // Step aside while pkexec / polkit authentication runs so the polkit
    // dialog receives exclusive keyboard & pointer focus cleanly.
    yielding: root.cleaning
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(396))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      implicitHeight: mainColumn.implicitHeight
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(ch) {
        if (ch === "r" || ch === "R") root.refreshScan()
        else if (ch === "a" || ch === "A") root.setAllSteps(!root.allSelected)
        else if (ch === "l" || ch === "L") {
          if (root.logLines.length > 0) root.logExpanded = !root.logExpanded
        }
      }

      Column {
        id: mainColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroTitles.implicitHeight, heroRight.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.cleaning ? "󰝲" : "󰃢"
            color: root.cleaning ? root.accentColor : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            transformOrigin: Item.Center

            RotationAnimation on rotation {
              from: 0
              to: 360
              duration: Style.duration(950)
              loops: Animation.Infinite
              running: root.cleaning && !Style.reduceMotion
              onRunningChanged: if (!running) heroIcon.rotation = 0
            }

            Behavior on color { ColorAnimation { duration: Style.duration(180) } }
          }

          Column {
            id: heroTitles
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(12)
            anchors.right: heroRight.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PlainText {
              text: strings.t("app.title")
              color: root.foreground
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            PlainText {
              text: root.heroStatusLabel.toUpperCase()
              color: root.cleanStatus === "error" || root.cleanStatus === "cancelled"
                ? root.urgentColor
                : (root.cleanStatus === "doneWarnings" ? root.warningColor : root.dimColor)
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.1
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Row {
            id: heroRight
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            PlainText {
              visible: root.scanInfo.scanned
              text: Model.formatBytes(root.scanInfo.totalBytes, Commons.I18n.formatNumber)
              color: root.foreground
              font.pixelSize: Style.font.subtitle
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }

            PanelActionButton {
              iconText: "󰑐"
              tooltipText: strings.t("action.refreshTooltip")
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.cleaning && !root.scanning
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.refreshScan()
            }

            PanelActionButton {
              iconText: "󰆍"
              tooltipText: strings.t("action.terminalTooltip")
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.cleaning && root.selectedCount > 0
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.launchInTerminal()
            }
          }
        }

        // ---------- Progress bar ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(6)

          Rectangle {
            id: progressTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
          }

          Rectangle {
            anchors.left: progressTrack.left
            anchors.verticalCenter: progressTrack.verticalCenter
            height: progressTrack.height
            radius: progressTrack.radius
            color: root.progressFillColor
            width: root.progressPercent > 0
              ? Math.max(progressTrack.height, progressTrack.width * (root.progressPercent / 100))
              : 0

            Behavior on width {
              NumberAnimation {
                duration: Style.duration(220)
                easing.type: Easing.Bezier
                easing.bezierCurve: Style.easeOut
              }
            }
            Behavior on color { ColorAnimation { duration: Style.duration(180) } }
          }
        }

        // ---------- System snapshot ----------
        Row {
          width: parent.width
          spacing: Style.space(18)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: strings.t("stats.orphans")
              value: root.scanInfo.scanned ? Commons.I18n.formatNumber(root.scanInfo.orphansCount) : "—"
            }
            InfoPair {
              label: strings.t("stats.caches")
              value: root.scanInfo.scanned
                ? Model.formatBytes(root.scanInfo.pacmanCacheBytes + root.scanInfo.aurCacheBytes, Commons.I18n.formatNumber)
                : "—"
            }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: strings.t("stats.journal")
              value: root.scanInfo.scanned
                ? Model.formatBytes(root.scanInfo.journalBytes, Commons.I18n.formatNumber)
                : "—"
            }
            InfoPair {
              label: strings.t("stats.pacnew")
              value: root.scanInfo.scanned ? Commons.I18n.formatNumber(root.scanInfo.pacnewCount) : "—"
              valueColor: root.scanInfo.pacnewCount > 0 ? root.warningColor : root.foreground
            }
          }
        }

        PanelSeparator {
          foreground: root.foreground
        }

        // ---------- Steps header ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(stepsHeader.implicitHeight, toggleAllBtn.implicitHeight)

          PanelSectionHeader {
            id: stepsHeader
            text: strings.t("section.steps").toUpperCase()
            foreground: root.foreground
            fontFamily: root.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Button {
            id: toggleAllBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.allSelected ? strings.t("action.selectNone") : strings.t("action.selectAll")
            fontSize: Style.font.caption
            foreground: root.dimColor
            fontFamily: root.fontFamily
            horizontalPadding: Style.space(8)
            verticalPadding: Style.space(3)
            enabled: !root.cleaning
            onClicked: root.setAllSteps(!root.allSelected)
          }
        }

        // ---------- Selectable step list ----------
        Column {
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.stepsModel

            BorderSurface {
              id: stepRow
              required property var modelData
              required property int index

              readonly property string stepId: modelData.id
              readonly property bool checked: root.stepSelection[stepId] === true
              readonly property string runState: root.stepStatuses[stepId] || "idle"
              readonly property bool isHot: (root.cursorActive && root.cursorIndex === index) || rowMouse.containsMouse
              readonly property string badge: root.stepBadgeText(stepId)

              width: parent.width
              implicitHeight: Style.space(34)
              radius: Style.cornerRadius
              color: Style.controlFill(false, isHot, root.foreground, root.accentColor)
              borderSpec: Border.controlSpec(isHot ? "hover-cursor" : "normal", root.foreground, root.accentColor)
              opacity: checked || runState !== "idle" ? 1.0 : 0.65

              Behavior on color { ColorAnimation { duration: Style.duration(100) } }
              Behavior on opacity { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

              Item {
                anchors.fill: parent
                anchors.leftMargin: stepRow.borderLeft + Style.space(10)
                anchors.rightMargin: stepRow.borderRight + Style.space(10)

                Text {
                  id: stepIcon
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(18)
                  horizontalAlignment: Text.AlignHCenter
                  text: stepRow.runState === "running" ? "󰝲"
                    : stepRow.runState === "done" ? "󰄬"
                    : stepRow.runState === "warn" ? "󰀪"
                    : stepRow.runState === "error" ? "󰅖"
                    : stepRow.modelData.icon
                  color: stepRow.runState === "running" ? root.accentColor
                    : stepRow.runState === "done" ? root.accentColor
                    : stepRow.runState === "warn" ? root.warningColor
                    : stepRow.runState === "error" ? root.urgentColor
                    : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                  transformOrigin: Item.Center

                  RotationAnimation on rotation {
                    from: 0
                    to: 360
                    duration: Style.duration(900)
                    loops: Animation.Infinite
                    running: stepRow.runState === "running" && !Style.reduceMotion
                    onRunningChanged: if (!running) stepIcon.rotation = 0
                  }
                }

                PlainText {
                  anchors.left: stepIcon.right
                  anchors.leftMargin: Style.space(8)
                  anchors.right: badgeText.visible ? badgeText.left : stepSwitch.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: strings.t("step." + stepRow.stepId)
                  color: root.foreground
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                PlainText {
                  id: badgeText
                  visible: stepRow.badge !== ""
                  anchors.right: stepSwitch.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: stepRow.badge
                  color: stepRow.stepId === "pacnew" && root.scanInfo.pacnewCount > 0
                    ? root.warningColor
                    : root.dimColor
                  font.pixelSize: Style.font.caption
                }

                ToggleSwitch {
                  id: stepSwitch
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  checked: stepRow.checked
                  busy: root.cleaning
                  interactive: false
                  trackHeight: Math.max(16, Style.space(16))
                  foreground: root.foreground
                  accent: root.accentColor
                }
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: !root.cleaning
                cursorShape: root.cleaning ? Qt.ArrowCursor : Qt.PointingHandCursor
                onEntered: {
                  root.cursorActive = true
                  root.cursorIndex = stepRow.index
                }
                onClicked: root.toggleStep(stepRow.stepId)
              }
            }
          }
        }

        // ---------- Collapsible live log ----------
        Column {
          visible: root.logLines.length > 0
          width: parent.width
          spacing: Style.space(6)

          Button {
            width: parent.width
            leftAlign: true
            iconText: root.logExpanded ? "󰅃" : "󰅀"
            iconSize: Style.font.iconSmall
            text: (root.logExpanded ? strings.t("action.hideLog") : strings.t("action.showLog"))
              .arg(Commons.I18n.formatNumber(root.logLines.length))
            fontSize: Style.font.caption
            foreground: root.dimColor
            fontFamily: root.fontFamily
            horizontalPadding: Style.space(8)
            verticalPadding: Style.space(4)
            onClicked: root.logExpanded = !root.logExpanded
          }

          BorderSurface {
            visible: root.logExpanded
            width: parent.width
            height: Style.space(126)
            radius: Style.cornerRadius
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
            borderSpec: Border.controlSpec("normal", root.foreground, root.accentColor)

            Flickable {
              id: logFlick
              anchors.fill: parent
              anchors.margins: Style.space(8)
              clip: true
              contentWidth: width
              contentHeight: logText.implicitHeight
              flickableDirection: Flickable.VerticalFlick
              boundsBehavior: Flickable.StopAtBounds

              onContentHeightChanged: {
                if (contentHeight > height) contentY = contentHeight - height
              }

              Text {
                id: logText
                width: logFlick.width
                textFormat: Text.PlainText
                text: root.logLines.join("\n")
                color: root.foreground
                opacity: 0.85
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WrapAnywhere
              }
            }
          }
        }

        // ---------- Bottom actions ----------
        Row {
          id: actionRow
          width: parent.width
          spacing: Style.space(8)

          Button {
            id: runBtn
            width: actionRow.width - rebootBtn.width - actionRow.spacing
            iconText: root.cleaning ? "󰝲" : "󰐊"
            iconSpinning: root.cleaning
            iconSize: Style.font.icon
            text: root.cleaning
              ? strings.t("action.running").arg(Commons.I18n.formatNumber(root.progressPercent))
              : strings.t("action.run")
            fontSize: Style.font.bodySmall
            foreground: root.foreground
            accent: root.accentColor
            fontFamily: root.fontFamily
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            bordered: true
            selected: !root.cleaning && root.selectedCount > 0
            enabled: !root.cleaning && root.selectedCount > 0
            opacity: enabled ? 1.0 : 0.55
            hasCursor: root.cursorActive && root.cursorIndex === root.stepsModel.length
            onClicked: root.startCleanup()
            onHovered: function(h) {
              if (h) {
                root.cursorActive = true
                root.cursorIndex = root.stepsModel.length
              }
            }
          }

          Button {
            id: rebootBtn
            iconText: "󰜉"
            iconSize: Style.font.icon
            text: root.rebootArmed ? strings.t("action.rebootConfirm") : strings.t("action.reboot")
            fontSize: Style.font.bodySmall
            foreground: root.rebootArmed ? root.urgentColor : root.foreground
            accent: root.rebootArmed ? root.urgentColor : root.accentColor
            fontFamily: root.fontFamily
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            bordered: true
            active: root.rebootArmed
            enabled: !root.cleaning
            opacity: enabled ? 1.0 : 0.55
            hasCursor: root.cursorActive && root.cursorIndex === root.stepsModel.length + 1
            onClicked: root.handleRebootClick()
            onHovered: function(h) {
              if (h) {
                root.cursorActive = true
                root.cursorIndex = root.stepsModel.length + 1
              }
            }
          }
        }
      }
    }
  }

  component PlainText: Text {
    textFormat: Text.PlainText
    font.family: root.fontFamily
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""
    property color valueColor: root.foreground

    width: parent.width
    spacing: Style.space(8)

    PlainText {
      id: pairLabel
      text: label
      color: root.foreground
      opacity: 0.62
      font.pixelSize: Style.font.bodySmall
    }
    Item {
      width: Math.max(0, parent.width - pairLabel.implicitWidth - pairVal.implicitWidth - parent.spacing * 2)
      height: 1
    }
    PlainText {
      id: pairVal
      text: value
      color: valueColor
      font.pixelSize: Style.font.bodySmall
    }
  }
}
