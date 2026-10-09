import QtQuick
import Quickshell
import "custom"

ShellRoot {
    Item {
        Component.onCompleted: {
            XLog.info("ui", "smoke line one token=CANARYQMLTOKEN1234567890abcdefXYZ");
            XLog.warn("ui", "smoke line two\nwith a newline");
            XLog.debug("ui", "debug line must stay hidden");
            quit.start();
        }
        Timer { id: quit; interval: 1800; onTriggered: Qt.quit() }
    }
}
