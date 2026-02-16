#!/bin/bash
# =============================================================================
# sidecar.sh - 通过 Control Center 自动连接/断开 iPad Sidecar
# =============================================================================
#
# 使用方法:
#   chmod +x sidecar.sh
#   ./sidecar.sh                    # 使用默认设备名连接/断开
#   ./sidecar.sh "My iPad"          # 指定 iPad 名称
#   ./sidecar.sh debug              # 调试模式 - 打印屏幕镜像面板的 UI 元素
#   ./sidecar.sh debug "My iPad"    # 调试模式 + 指定设备名
#
# 前提条件:
#   1. 在 系统设置 > 隐私与安全性 > 辅助功能 中授权 Terminal.app
#   2. iPad 与 Mac 登录同一 Apple ID，且在附近/同一 WiFi
#   3. 将下方 DEFAULT_DEVICE_NAME 改为你 iPad 的名称
#
# 兼容性: macOS Sequoia (15.2+) / Tahoe (中英文系统均支持)
# =============================================================================

DEFAULT_DEVICE_NAME="13太保"  # <-- 改成你的 iPad 名称

DEBUG_MODE="false"
DEVICE_NAME=""

# 解析参数
for arg in "$@"; do
    if [ "$arg" = "debug" ]; then
        DEBUG_MODE="true"
    else
        DEVICE_NAME="$arg"
    fi
done

DEVICE_NAME="${DEVICE_NAME:-$DEFAULT_DEVICE_NAME}"

if [ "$DEBUG_MODE" = "true" ]; then
    echo "[调试模式] 将打印屏幕镜像面板的 UI 元素树"
fi
echo "正在切换 Sidecar 连接: $DEVICE_NAME ..."

osascript -l JavaScript <<ENDSCRIPT
ObjC.import('Cocoa');
ObjC.bindFunction('AXUIElementPerformAction', ['int', ['id', 'id']]);
ObjC.bindFunction('AXUIElementCreateApplication', ['id', ['unsigned int']]);
ObjC.bindFunction('AXUIElementCopyAttributeValue', ['int', ['id', 'id', 'id*']]);
ObjC.bindFunction('AXUIElementCopyAttributeNames', ['int', ['id', 'id*']]);
ObjC.bindFunction('AXUIElementCopyActionNames', ['int', ['id', 'id*']]);

const DEBUG = $DEBUG_MODE;

function log(msg) {
    console.log(msg);
}

function debug(msg) {
    if (DEBUG) console.log('[DEBUG] ' + msg);
}

function run(_) {
    const TARGET_DEVICE_NAME = '$DEVICE_NAME';
    const \$attr = Ref();
    const \$windows = Ref();
    const \$children = Ref();

    const pid = $.NSRunningApplication
        .runningApplicationsWithBundleIdentifier('com.apple.controlcenter')
        .firstObject.processIdentifier;

    const app = $.AXUIElementCreateApplication(pid);

    // 获取 Control Center 菜单栏项
    $.AXUIElementCopyAttributeValue(app, 'AXChildren', \$children);
    $.AXUIElementCopyAttributeValue(\$children[0].js[0], 'AXChildren', \$children);

    const ccExtra = \$children[0].js.find((child) => {
        $.AXUIElementCopyAttributeValue(child, 'AXIdentifier', \$attr);
        return \$attr[0].js == 'com.apple.menuextra.controlcenter';
    });

    if (!ccExtra) {
        log('错误: 找不到 Control Center 菜单栏项');
        return 1;
    }

    // 检查 Control Center 是否已经打开
    $.AXUIElementCopyAttributeValue(app, 'AXWindows', \$windows);
    const alreadyOpen = typeof \$windows[0] == 'function' && (\$windows[0].js.length ?? 0) > 0;

    if (alreadyOpen) {
        debug('Control Center 已经打开，先关闭再重新打开');
        $.AXUIElementPerformAction(ccExtra, 'AXPress');
        delay(0.5);
    }

    // 打开 Control Center
    $.AXUIElementPerformAction(ccExtra, 'AXPress');

    if (!waitFor(() => {
        $.AXUIElementCopyAttributeValue(app, 'AXWindows', \$windows);
        return typeof \$windows[0] == 'function' && (\$windows[0].js.length ?? 0) > 0;
    }, 3000)) {
        debug('首次等待超时，可能点击关闭了已打开的窗口，再试一次');
        // 可能第一次点击关闭了已打开的 CC，再点一次打开
        $.AXUIElementPerformAction(ccExtra, 'AXPress');

        if (!waitFor(() => {
            $.AXUIElementCopyAttributeValue(app, 'AXWindows', \$windows);
            return typeof \$windows[0] == 'function' && (\$windows[0].js.length ?? 0) > 0;
        }, 3000)) {
            log('错误: Control Center 窗口打开超时');
            return 1;
        }
    }

    $.AXUIElementCopyAttributeValue(\$windows[0].js[0], 'AXChildren', \$children);

    const modulesGroup = \$children[0].js.find((child) => {
        $.AXUIElementCopyAttributeValue(child, 'AXRole', \$attr);
        return \$attr[0].js == 'AXGroup';
    });

    if (!modulesGroup) {
        log('错误: 找不到 Control Center 模块组');
        dismissControlCenter();
        return 1;
    }

    $.AXUIElementCopyAttributeValue(modulesGroup, 'AXChildren', \$children);

    const screenMirroring = \$children[0].js.find((child) => {
        $.AXUIElementCopyAttributeValue(child, 'AXIdentifier', \$attr);
        return \$attr[0].js == 'controlcenter-screen-mirroring';
    });

    if (!screenMirroring) {
        log('错误: 找不到屏幕镜像模块');
        dismissControlCenter();
        return 1;
    }

    // 展开屏幕镜像面板
    $.AXUIElementPerformAction(
        screenMirroring,
        'Name:show details\\nTarget:0x0\\nSelector:(null)'
    );

    if (!waitFor(() => {
        $.AXUIElementCopyAttributeValue(modulesGroup, 'AXChildren', \$children);
        return typeof \$children[0] == 'function' && (\$children[0].js.length ?? 0) > 0;
    }, 2000)) {
        log('错误: 屏幕镜像面板展开超时');
        dismissControlCenter();
        return 1;
    }

    // 等待 UI 稳定
    delay(0.5);

    // 获取滚动区域
    $.AXUIElementCopyAttributeValue(modulesGroup, 'AXChildren', \$children);
    const scrollArea = \$children[0].js.find((child) => {
        $.AXUIElementCopyAttributeValue(child, 'AXRole', \$attr);
        return \$attr[0].js == 'AXScrollArea';
    });

    if (!scrollArea) {
        log('错误: 找不到设备列表区域');
        dismissControlCenter();
        return 1;
    }

    // 获取滚动区域的所有子元素
    $.AXUIElementCopyAttributeValue(scrollArea, 'AXChildren', \$children);

    if (DEBUG) {
        dumpElements(\$children[0].js, 0);
    }

    // =========================================================
    // 策略 1: 直接在当前视图查找设备
    // =========================================================
    let toggle = findDeviceByName(\$children[0].js, TARGET_DEVICE_NAME);

    if (toggle) {
        debug('策略1成功: 直接找到设备');
        $.AXUIElementPerformAction(toggle, 'AXPress');
        delay(0.3);
        dismissControlCenter();
        log('已切换 Sidecar: ' + TARGET_DEVICE_NAME);
        return 0;
    }

    debug('策略1: 当前视图未直接找到设备，可能在详情页');

    // =========================================================
    // 策略 2: 当前视图可能是已连接设备的详情页
    //         尝试找到返回按钮，回到设备列表，再查找设备
    // =========================================================
    let backButton = findBackButton(\$children[0].js);

    if (backButton) {
        debug('策略2: 找到返回按钮，点击返回');
        $.AXUIElementPerformAction(backButton, 'AXPress');
        delay(0.8);

        // 重新获取滚动区域内容
        $.AXUIElementCopyAttributeValue(scrollArea, 'AXChildren', \$children);

        if (DEBUG) {
            log('[DEBUG] --- 返回后的 UI 元素 ---');
            dumpElements(\$children[0].js, 0);
        }

        toggle = findDeviceByName(\$children[0].js, TARGET_DEVICE_NAME);
        if (toggle) {
            debug('策略2成功: 返回后找到设备');
            $.AXUIElementPerformAction(toggle, 'AXPress');
            delay(0.3);
            dismissControlCenter();
            log('已断开 Sidecar: ' + TARGET_DEVICE_NAME);
            return 0;
        }
    }

    debug('策略2: 未找到返回按钮或返回后仍未找到设备');

    // =========================================================
    // 策略 3: 在嵌套的 AXGroup 中深度查找设备
    // =========================================================
    $.AXUIElementCopyAttributeValue(scrollArea, 'AXChildren', \$children);
    toggle = deepFindDevice(\$children[0].js, TARGET_DEVICE_NAME, 3);

    if (toggle) {
        debug('策略3成功: 深度搜索找到设备');
        $.AXUIElementPerformAction(toggle, 'AXPress');
        delay(0.3);
        dismissControlCenter();
        log('已切换 Sidecar: ' + TARGET_DEVICE_NAME);
        return 0;
    }

    // =========================================================
    // 策略 4: 如果处于已连接详情页，尝试直接点击设备名对应的元素
    //         （可能是 AXStaticText 或带 AXValue 的元素）
    // =========================================================
    $.AXUIElementCopyAttributeValue(scrollArea, 'AXChildren', \$children);
    toggle = findDeviceByAnyAttribute(\$children[0].js, TARGET_DEVICE_NAME);

    if (toggle) {
        debug('策略4成功: 通过属性搜索找到设备');
        $.AXUIElementPerformAction(toggle, 'AXPress');
        delay(0.3);
        dismissControlCenter();
        log('已切换 Sidecar: ' + TARGET_DEVICE_NAME);
        return 0;
    }

    log('错误: 所有策略均未找到设备 "' + TARGET_DEVICE_NAME + '"');
    log('提示: 请运行 ./sidecar.sh debug 查看 UI 元素来排查问题');
    dismissControlCenter();
    return 1;
}

// ============ 工具函数 ============

function waitFor(condition, timeoutMs) {
    const timeout = new Date().getTime() + timeoutMs;
    while (true) {
        if (condition()) return true;
        if (new Date().getTime() > timeout) return false;
        delay(0.1);
    }
}

function dismissControlCenter() {
    // 发送 Escape 键关闭 Control Center (key down + key up)
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateKeyboardEvent(null, 53, true));
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateKeyboardEvent(null, 53, false));
    delay(0.3);
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateKeyboardEvent(null, 53, true));
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateKeyboardEvent(null, 53, false));
    delay(0.3);
    // 第三次确保完全关闭（屏幕镜像子面板 + CC 主面板）
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateKeyboardEvent(null, 53, true));
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateKeyboardEvent(null, 53, false));
}

function getAttr(element, attrName) {
    const \$val = Ref();
    const result = $.AXUIElementCopyAttributeValue(element, attrName, \$val);
    if (result !== 0) return null;
    try {
        return \$val[0].js;
    } catch (e) {
        return null;
    }
}

function getActions(element) {
    const \$actions = Ref();
    const result = $.AXUIElementCopyActionNames(element, \$actions);
    if (result !== 0) return [];
    try {
        return \$actions[0].js;
    } catch (e) {
        return [];
    }
}

// 在直接子元素中通过 AXDescription 或 AXIdentifier 查找设备
function findDeviceByName(elements, deviceName) {
    for (const el of elements) {
        const role = getAttr(el, 'AXRole');
        if (role !== 'AXCheckBox') continue;

        const desc = getAttr(el, 'AXDescription');
        if (desc === deviceName) {
            debug('通过 AXDescription 找到: ' + desc);
            return el;
        }

        const ident = getAttr(el, 'AXIdentifier');
        if (ident === 'screen-mirroring-device-' + deviceName) {
            debug('通过 AXIdentifier 找到: ' + ident);
            return el;
        }

        const title = getAttr(el, 'AXTitle');
        if (title === deviceName) {
            debug('通过 AXTitle 找到: ' + title);
            return el;
        }
    }
    return null;
}

// 深度搜索：递归查找嵌套在 AXGroup 中的设备
function deepFindDevice(elements, deviceName, maxDepth) {
    if (maxDepth <= 0) return null;

    for (const el of elements) {
        const role = getAttr(el, 'AXRole');

        if (role === 'AXCheckBox') {
            const desc = getAttr(el, 'AXDescription');
            const ident = getAttr(el, 'AXIdentifier');
            const title = getAttr(el, 'AXTitle');

            if (desc === deviceName ||
                title === deviceName ||
                ident === 'screen-mirroring-device-' + deviceName) {
                return el;
            }
        }

        // 递归进入 AXGroup 和 AXScrollArea
        if (role === 'AXGroup' || role === 'AXScrollArea' || role === 'AXList') {
            const children = getAttr(el, 'AXChildren');
            if (children && children.length > 0) {
                const found = deepFindDevice(children, deviceName, maxDepth - 1);
                if (found) return found;
            }
        }
    }
    return null;
}

// 查找返回按钮 (AXDisclosureTriangle 或带有 back 相关属性的按钮)
function findBackButton(elements) {
    for (const el of elements) {
        const role = getAttr(el, 'AXRole');

        if (role === 'AXDisclosureTriangle') {
            debug('找到返回按钮: AXDisclosureTriangle');
            return el;
        }

        if (role === 'AXButton') {
            const desc = getAttr(el, 'AXDescription');
            const ident = getAttr(el, 'AXIdentifier');
            if (desc && (desc.toLowerCase().includes('back') || desc.includes('返回'))) {
                debug('找到返回按钮 (AXButton): ' + desc);
                return el;
            }
            if (ident && ident.toLowerCase().includes('back')) {
                debug('找到返回按钮 (AXButton by id): ' + ident);
                return el;
            }
        }
    }

    // 深层查找
    for (const el of elements) {
        const role = getAttr(el, 'AXRole');
        if (role === 'AXGroup') {
            const children = getAttr(el, 'AXChildren');
            if (children && children.length > 0) {
                const found = findBackButton(children);
                if (found) return found;
            }
        }
    }

    return null;
}

// 通过任何属性查找可点击的设备元素
function findDeviceByAnyAttribute(elements, deviceName) {
    for (const el of elements) {
        const role = getAttr(el, 'AXRole');
        const desc = getAttr(el, 'AXDescription');
        const title = getAttr(el, 'AXTitle');
        const value = getAttr(el, 'AXValue');
        const ident = getAttr(el, 'AXIdentifier');

        const matchesName = [desc, title, value, ident].some(
            (v) => v && (v === deviceName || (typeof v === 'string' && v.includes(deviceName)))
        );

        if (matchesName) {
            const actions = getActions(el);
            if (actions.length > 0) {
                debug('策略4找到可点击元素: role=' + role + ' desc=' + desc + ' title=' + title);
                return el;
            }
        }

        // 递归
        if (role === 'AXGroup' || role === 'AXScrollArea' || role === 'AXList') {
            const children = getAttr(el, 'AXChildren');
            if (children && children.length > 0) {
                const found = findDeviceByAnyAttribute(children, deviceName);
                if (found) return found;
            }
        }
    }
    return null;
}

// 调试：打印 UI 元素树
function dumpElements(elements, indent) {
    const prefix = '  '.repeat(indent);
    for (let i = 0; i < elements.length; i++) {
        const el = elements[i];
        const role = getAttr(el, 'AXRole') || '?';
        const desc = getAttr(el, 'AXDescription') || '';
        const title = getAttr(el, 'AXTitle') || '';
        const ident = getAttr(el, 'AXIdentifier') || '';
        const value = getAttr(el, 'AXValue');
        const actions = getActions(el);

        let line = prefix + '[' + i + '] ' + role;
        if (desc) line += '  desc="' + desc + '"';
        if (title) line += '  title="' + title + '"';
        if (ident) line += '  id="' + ident + '"';
        if (value !== null && value !== undefined) line += '  value=' + value;
        if (actions.length > 0) line += '  actions=[' + actions.join(', ') + ']';

        log(line);

        if (role === 'AXGroup' || role === 'AXScrollArea' || role === 'AXList') {
            const children = getAttr(el, 'AXChildren');
            if (children && children.length > 0) {
                dumpElements(children, indent + 1);
            }
        }
    }
}
ENDSCRIPT

EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
    echo ""
    echo "脚本执行失败 (退出码: $EXIT_CODE)"
    echo ""
    echo "常见问题排查:"
    echo "  1. 打开 系统设置 > 隐私与安全性 > 辅助功能"
    echo "     确保 Terminal.app (或你使用的终端) 已被授权"
    echo "  2. 确认 iPad 名称正确: 当前设置为 \"$DEVICE_NAME\""
    echo "  3. 确认 iPad 在附近且已开启"
    echo "  4. 运行 ./sidecar.sh debug 查看详细 UI 信息"
fi
