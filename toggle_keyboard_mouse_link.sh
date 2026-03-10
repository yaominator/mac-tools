#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Toggle Keyboard & Mouse Link
# @raycast.mode compact

# Optional parameters:
# @raycast.icon ⌨️
# @raycast.description Toggle Universal Control keyboard & mouse link
# @raycast.packageName Display

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

osascript -l JavaScript <<'ENDSCRIPT'
ObjC.import('Cocoa');
ObjC.bindFunction('AXUIElementPerformAction', ['int', ['id', 'id']]);
ObjC.bindFunction('AXUIElementCreateApplication', ['id', ['unsigned int']]);
ObjC.bindFunction('AXUIElementCopyAttributeValue', ['int', ['id', 'id', 'id*']]);

function getAttr(el, name) {
    const $v = Ref();
    if ($.AXUIElementCopyAttributeValue(el, name, $v) !== 0) return null;
    try { return $v[0].js; } catch(e) { return null; }
}

function run(_) {
    const $children = Ref();

    const pid = $.NSRunningApplication
        .runningApplicationsWithBundleIdentifier('com.apple.controlcenter')
        .firstObject.processIdentifier;
    const app = $.AXUIElementCreateApplication(pid);

    // Find the Display menu bar extra
    $.AXUIElementCopyAttributeValue(app, 'AXChildren', $children);
    let displayItem = null;

    for (const menuBar of $children[0].js) {
        const $items = Ref();
        $.AXUIElementCopyAttributeValue(menuBar, 'AXChildren', $items);
        if (typeof $items[0] !== 'function') continue;
        for (const item of $items[0].js) {
            if (getAttr(item, 'AXIdentifier') === 'com.apple.menuextra.display') {
                displayItem = item;
                break;
            }
        }
        if (displayItem) break;
    }

    if (!displayItem) {
        console.log('Error: Display menu bar icon not found');
        return 1;
    }

    // Open the Display panel
    $.AXUIElementPerformAction(displayItem, 'AXPress');
    delay(0.5);

    // Get the opened window
    $.AXUIElementCopyAttributeValue(app, 'AXWindows', $children);
    if (typeof $children[0] !== 'function' || $children[0].js.length === 0) {
        console.log('Error: Display panel did not open');
        return 1;
    }

    // Find any universalcontrol-device-* checkbox
    const device = findUCDevice($children[0].js, 5);

    if (!device) {
        dismiss();
        console.log('No linked device found');
        return 1;
    }

    const name = getAttr(device, 'AXDescription') || 'unknown';
    const wasConnected = getAttr(device, 'AXValue') === 1;

    $.AXUIElementPerformAction(device, 'AXPress');
    delay(0.3);
    dismiss();

    console.log((wasConnected ? 'Disconnected: ' : 'Connected: ') + name);
    return 0;
}

function findUCDevice(elements, maxDepth) {
    if (maxDepth <= 0) return null;
    for (const el of elements) {
        const ident = getAttr(el, 'AXIdentifier') || '';
        if (getAttr(el, 'AXRole') === 'AXCheckBox' && ident.startsWith('universalcontrol-device-')) {
            return el;
        }
        const children = getAttr(el, 'AXChildren');
        if (children && children.length > 0) {
            const found = findUCDevice(children, maxDepth - 1);
            if (found) return found;
        }
    }
    return null;
}

function dismiss() {
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateKeyboardEvent(null, 53, true));
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateKeyboardEvent(null, 53, false));
}
ENDSCRIPT
