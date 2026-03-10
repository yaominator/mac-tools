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

DEFAULT_DEVICE_NAME="TCR MBP"  # <-- Change to your target Mac name

DEBUG_MODE="false"
DEVICE_NAME=""

for arg in "$@"; do
    if [ "$arg" = "debug" ]; then
        DEBUG_MODE="true"
    else
        DEVICE_NAME="$arg"
    fi
done

DEVICE_NAME="${DEVICE_NAME:-$DEFAULT_DEVICE_NAME}"

# Step 1: Find and dump all menu bar items to locate the UC extra
if [ "$DEBUG_MODE" = "true" ]; then
    echo "[DEBUG] Scanning menu bar items..."
    osascript -l JavaScript <<'DEBUGSCRIPT'
ObjC.import('Cocoa');
ObjC.bindFunction('AXUIElementCreateApplication', ['id', ['unsigned int']]);
ObjC.bindFunction('AXUIElementCopyAttributeValue', ['int', ['id', 'id', 'id*']]);

function run(_) {
    const $attr = Ref();
    const $children = Ref();

    const pid = $.NSRunningApplication
        .runningApplicationsWithBundleIdentifier('com.apple.controlcenter')
        .firstObject.processIdentifier;
    const app = $.AXUIElementCreateApplication(pid);

    // Get all menu bar groups
    $.AXUIElementCopyAttributeValue(app, 'AXChildren', $children);

    for (let g = 0; g < $children[0].js.length; g++) {
        const menuBar = $children[0].js[g];
        const role = getAttr(menuBar, 'AXRole');
        console.log('--- MenuBar group ' + g + ' (role=' + role + ') ---');

        $.AXUIElementCopyAttributeValue(menuBar, 'AXChildren', $children);
        if (typeof $children[0] !== 'function') continue;

        for (let i = 0; i < $children[0].js.length; i++) {
            const item = $children[0].js[i];
            const ident = getAttr(item, 'AXIdentifier') || '';
            const desc = getAttr(item, 'AXDescription') || '';
            const title = getAttr(item, 'AXTitle') || '';
            console.log('  [' + i + '] id="' + ident + '"  desc="' + desc + '"  title="' + title + '"');
        }

        // Re-read from app level for next iteration
        $.AXUIElementCopyAttributeValue(app, 'AXChildren', $children);
    }
    return '';
}

function getAttr(el, name) {
    const $v = Ref();
    if ($.AXUIElementCopyAttributeValue(el, name, $v) !== 0) return null;
    try { return $v[0].js; } catch(e) { return null; }
}
DEBUGSCRIPT
    echo ""
fi

echo "Toggling keyboard & mouse link: $DEVICE_NAME ..."

# Escape single quotes for JS
DEVICE_NAME_JS=$(printf '%s' "$DEVICE_NAME" | sed "s/'/\\\\'/g")

osascript -l JavaScript <<ENDSCRIPT
ObjC.import('Cocoa');
ObjC.bindFunction('AXUIElementPerformAction', ['int', ['id', 'id']]);
ObjC.bindFunction('AXUIElementCreateApplication', ['id', ['unsigned int']]);
ObjC.bindFunction('AXUIElementCopyAttributeValue', ['int', ['id', 'id', 'id*']]);

const DEBUG = $DEBUG_MODE;
function log(msg) { console.log(msg); }
function debug(msg) { if (DEBUG) console.log('[DEBUG] ' + msg); }

function getAttr(el, name) {
    const \$v = Ref();
    if ($.AXUIElementCopyAttributeValue(el, name, \$v) !== 0) return null;
    try { return \$v[0].js; } catch(e) { return null; }
}

function run(_) {
    const TARGET = '$DEVICE_NAME_JS';
    const \$attr = Ref();
    const \$children = Ref();

    const pid = $.NSRunningApplication
        .runningApplicationsWithBundleIdentifier('com.apple.controlcenter')
        .firstObject.processIdentifier;
    const app = $.AXUIElementCreateApplication(pid);

    // Scan all menu bar items for the Universal Control extra
    $.AXUIElementCopyAttributeValue(app, 'AXChildren', \$children);

    let ucItem = null;

    for (let g = 0; g < \$children[0].js.length; g++) {
        const menuBar = \$children[0].js[g];
        const \$items = Ref();
        $.AXUIElementCopyAttributeValue(menuBar, 'AXChildren', \$items);
        if (typeof \$items[0] !== 'function') continue;

        for (const item of \$items[0].js) {
            const ident = getAttr(item, 'AXIdentifier') || '';
            const desc = getAttr(item, 'AXDescription') || '';

            if (ident === 'com.apple.menuextra.display') {
                debug('Found UC menu bar item: id="' + ident + '"  desc="' + desc + '"');
                ucItem = item;
                break;
            }
        }
        if (ucItem) break;
    }

    if (!ucItem) {
        log('Error: Cannot find Universal Control menu bar item');
        log('Make sure the UC icon is visible in the menu bar and a device is connected');
        return 1;
    }

    // Click the menu bar item to open its menu
    $.AXUIElementPerformAction(ucItem, 'AXPress');
    delay(0.5);

    // Read the opened menu/window
    $.AXUIElementCopyAttributeValue(app, 'AXWindows', \$children);
    if (typeof \$children[0] !== 'function' || \$children[0].js.length === 0) {
        // Try reading children of the menu bar item itself
        $.AXUIElementCopyAttributeValue(ucItem, 'AXChildren', \$children);
    }

    if (typeof \$children[0] !== 'function' || \$children[0].js.length === 0) {
        log('Error: Menu did not open');
        return 1;
    }

    // Search for the target device in the opened menu
    const allElements = \$children[0].js;

    if (DEBUG) {
        debug('--- Opened menu elements ---');
        dumpAll(allElements, 0);
    }

    // Deep search for a clickable element matching the target device
    const target = deepFind(allElements, TARGET, 5);

    if (target) {
        debug('Found target: role=' + getAttr(target, 'AXRole') + '  desc="' + getAttr(target, 'AXDescription') + '"');
        $.AXUIElementPerformAction(target, 'AXPress');
        delay(0.3);

        // Dismiss with Escape
        $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateKeyboardEvent(null, 53, true));
        $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateKeyboardEvent(null, 53, false));

        log('Toggled: ' + TARGET);
        return 0;
    }

    log('Error: Cannot find "' + TARGET + '" in the menu');
    log('Run with debug to see available elements');

    // Dismiss
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateKeyboardEvent(null, 53, true));
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateKeyboardEvent(null, 53, false));
    return 1;
}

function deepFind(elements, name, maxDepth) {
    if (maxDepth <= 0) return null;
    for (const el of elements) {
        const role = getAttr(el, 'AXRole') || '';
        const desc = getAttr(el, 'AXDescription') || '';
        const title = getAttr(el, 'AXTitle') || '';
        const ident = getAttr(el, 'AXIdentifier') || '';

        if (role === 'AXCheckBox' || role === 'AXButton' || role === 'AXMenuItem') {
            if (desc === name || desc.includes(name) ||
                title === name || title.includes(name) ||
                ident.includes(name)) {
                return el;
            }
        }

        const children = getAttr(el, 'AXChildren');
        if (children && children.length > 0) {
            const found = deepFind(children, name, maxDepth - 1);
            if (found) return found;
        }
    }
    return null;
}

function dumpAll(elements, indent) {
    const pfx = '  '.repeat(indent);
    for (let i = 0; i < elements.length; i++) {
        const el = elements[i];
        const role = getAttr(el, 'AXRole') || '?';
        const desc = getAttr(el, 'AXDescription') || '';
        const title = getAttr(el, 'AXTitle') || '';
        const ident = getAttr(el, 'AXIdentifier') || '';
        const val = getAttr(el, 'AXValue');

        let line = pfx + '[' + i + '] ' + role;
        if (desc) line += '  desc="' + desc + '"';
        if (title) line += '  title="' + title + '"';
        if (ident) line += '  id="' + ident + '"';
        if (val !== null && val !== undefined) line += '  value=' + val;
        log(line);

        const children = getAttr(el, 'AXChildren');
        if (children && children.length > 0) {
            dumpAll(children, indent + 1);
        }
    }
}
ENDSCRIPT

EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
    echo "Failed - Check: 1) UC icon visible in menu bar 2) Accessibility permission granted"
fi
