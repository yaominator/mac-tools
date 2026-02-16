#!/bin/bash
# =============================================================================
# sidecar.sh - 通过 Control Center 自动连接/断开 iPad Sidecar
# =============================================================================
#
# 使用方法:
#   chmod +x sidecar.sh
#   ./sidecar.sh              # 使用脚本中默认的设备名
#   ./sidecar.sh "My iPad"    # 指定 iPad 名称
#
# 前提条件:
#   1. 在 系统设置 > 隐私与安全性 > 辅助功能 中授权 Terminal.app
#   2. iPad 与 Mac 登录同一 Apple ID，且在附近/同一 WiFi
#   3. 将下方 DEFAULT_DEVICE_NAME 改为你 iPad 的名称
#      (iPad 上查看: 设置 > 通用 > 关于本机 > 名称)
#
# 工作原理:
#   通过 macOS Accessibility API 操作 Control Center 的屏幕镜像模块，
#   找到 iPad 设备并切换 Sidecar 连接。再次运行即可断开连接。
#
# 兼容性: macOS Sequoia (15.2+) / Tahoe
# =============================================================================

DEFAULT_DEVICE_NAME="13太保"  # <-- 改成你的 iPad 名称

DEVICE_NAME="${1:-$DEFAULT_DEVICE_NAME}"

echo "正在切换 Sidecar 连接: $DEVICE_NAME ..."

osascript -l JavaScript <<EOF
ObjC.import('Cocoa');
ObjC.bindFunction('AXUIElementPerformAction', ['int', ['id', 'id']]);
ObjC.bindFunction('AXUIElementCreateApplication', ['id', ['unsigned int']]);
ObjC.bindFunction('AXUIElementCopyAttributeValue', ['int', ['id', 'id', 'id*']]);
ObjC.bindFunction('AXUIElementCopyAttributeNames', ['int', ['id', 'id*']]);

function run(_) {
    const TARGET_DEVICE_NAME = '$DEVICE_NAME';
    const \$attr = Ref();
    const \$windows = Ref();
    const \$children = Ref();

    // 获取 Control Center 的进程 ID
    const pid = $.NSRunningApplication
        .runningApplicationsWithBundleIdentifier('com.apple.controlcenter')
        .firstObject.processIdentifier;

    const app = $.AXUIElementCreateApplication(pid);

    // 获取 Control Center 菜单栏项
    $.AXUIElementCopyAttributeValue(app, 'AXChildren', \$children);
    $.AXUIElementCopyAttributeValue(\$children[0].js[0], 'AXChildren', \$children);

    // 找到 Control Center 菜单栏按钮
    const ccExtra = \$children[0].js.find((child) => {
        $.AXUIElementCopyAttributeValue(child, 'AXIdentifier', \$attr);
        return \$attr[0].js == 'com.apple.menuextra.controlcenter';
    });

    if (!ccExtra) {
        console.log('错误: 找不到 Control Center 菜单栏项');
        return 1;
    }

    // 打开 Control Center 窗口
    $.AXUIElementPerformAction(ccExtra, 'AXPress');

    // 等待窗口绘制完成
    if (!waitFor(() => {
        $.AXUIElementCopyAttributeValue(app, 'AXWindows', \$windows);
        return typeof \$windows[0] == 'function' && (\$windows[0].js.length ?? 0) > 0;
    }, 2000)) {
        console.log('错误: Control Center 窗口打开超时');
        return 1;
    }

    // 获取 Control Center 窗口的子元素
    $.AXUIElementCopyAttributeValue(\$windows[0].js[0], 'AXChildren', \$children);

    // 找到模块组 (AXGroup)
    const modulesGroup = \$children[0].js.find((child) => {
        $.AXUIElementCopyAttributeValue(child, 'AXRole', \$attr);
        return \$attr[0].js == 'AXGroup';
    });

    if (!modulesGroup) {
        console.log('错误: 找不到 Control Center 模块组');
        dismissControlCenter();
        return 1;
    }

    // 获取模块组中的各个模块
    $.AXUIElementCopyAttributeValue(modulesGroup, 'AXChildren', \$children);

    // 找到屏幕镜像模块
    const screenMirroring = \$children[0].js.find((child) => {
        $.AXUIElementCopyAttributeValue(child, 'AXIdentifier', \$attr);
        return \$attr[0].js == 'controlcenter-screen-mirroring';
    });

    if (!screenMirroring) {
        console.log('错误: 找不到屏幕镜像模块，请确认 Control Center 中有"屏幕镜像"选项');
        dismissControlCenter();
        return 1;
    }

    // 展开屏幕镜像面板
    $.AXUIElementPerformAction(
        screenMirroring,
        'Name:show details\nTarget:0x0\nSelector:(null)'
    );

    // 等待面板展开
    if (!waitFor(() => {
        $.AXUIElementCopyAttributeValue(modulesGroup, 'AXChildren', \$children);
        return typeof \$children[0] == 'function' && (\$children[0].js.length ?? 0) > 0;
    }, 2000)) {
        console.log('错误: 屏幕镜像面板展开超时');
        dismissControlCenter();
        return 1;
    }

    // 获取包含设备列表的滚动区域
    const mirroringOptions = \$children[0].js.find((child) => {
        $.AXUIElementCopyAttributeValue(child, 'AXRole', \$attr);
        return \$attr[0].js == 'AXScrollArea';
    });

    if (!mirroringOptions) {
        console.log('错误: 找不到设备列表区域');
        dismissControlCenter();
        return 1;
    }

    // 获取设备列表
    $.AXUIElementCopyAttributeValue(mirroringOptions, 'AXChildren', \$children);

    // 检查是否已连接 (查找 "Use As Extended Display" 或 "用作扩展显示器")
    const isConnected = checkConnected(\$children, \$attr);

    if (isConnected) {
        // 已连接状态 - 寻找返回按钮来断开
        const backButton = \$children[0].js.find((child) => {
            $.AXUIElementCopyAttributeValue(child, 'AXRole', \$attr);
            return \$attr[0].js === 'AXDisclosureTriangle';
        });

        if (backButton) {
            $.AXUIElementPerformAction(backButton, 'AXPress');
            delay(0.5);
            $.AXUIElementCopyAttributeValue(mirroringOptions, 'AXChildren', \$children);
        }
    }

    // 在设备列表中找到目标 iPad
    let toggle = findDeviceToggle(\$children, \$attr, TARGET_DEVICE_NAME);

    if (!toggle) {
        console.log('错误: 找不到设备 "' + TARGET_DEVICE_NAME + '"');
        console.log('请确认:');
        console.log('  1. iPad 名称拼写正确（区分大小写）');
        console.log('  2. iPad 在附近且已开启');
        console.log('  3. iPad 与 Mac 登录同一 Apple ID');
        dismissControlCenter();
        return 1;
    }

    // 点击设备切换按钮
    $.AXUIElementPerformAction(toggle, 'AXPress');

    // 关闭 Control Center
    delay(0.3);
    dismissControlCenter();

    if (isConnected) {
        console.log('已断开 Sidecar: ' + TARGET_DEVICE_NAME);
    } else {
        console.log('已连接 Sidecar: ' + TARGET_DEVICE_NAME);
    }
    return 0;
}

function waitFor(condition, timeoutMs) {
    const timeout = new Date().getTime() + timeoutMs;
    while (true) {
        if (condition()) return true;
        if (new Date().getTime() > timeout) return false;
        delay(0.1);
    }
}

function dismissControlCenter() {
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateKeyboardEvent(null, 53, true));
    delay(0.1);
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateKeyboardEvent(null, 53, true));
}

function checkConnected(\$children, \$attr) {
    return \$children[0].js.some((child) => {
        $.AXUIElementCopyAttributeValue(child, 'AXRole', \$attr);

        // macOS 15.3+ 可能将选项嵌套在 AXGroup 中
        if (\$attr[0].js === 'AXGroup') {
            const \$groupChildren = Ref();
            $.AXUIElementCopyAttributeValue(child, 'AXChildren', \$groupChildren);
            if (typeof \$groupChildren[0] !== 'function') return false;
            return \$groupChildren[0].js.some((grandchild) => {
                $.AXUIElementCopyAttributeValue(grandchild, 'AXRole', \$attr);
                if (\$attr[0].js !== 'AXCheckBox') return false;
                $.AXUIElementCopyAttributeValue(grandchild, 'AXDescription', \$attr);
                return \$attr[0].js === 'Use As Extended Display';
            });
        }

        if (\$attr[0].js !== 'AXCheckBox') return false;
        $.AXUIElementCopyAttributeValue(child, 'AXDescription', \$attr);
        return \$attr[0].js === 'Use As Extended Display';
    });
}

function findDeviceToggle(\$children, \$attr, deviceName) {
    // 直接在子元素中查找
    let toggle = \$children[0].js.find((child) => {
        $.AXUIElementCopyAttributeValue(child, 'AXRole', \$attr);
        if (\$attr[0].js !== 'AXCheckBox') return false;
        $.AXUIElementCopyAttributeValue(child, 'AXDescription', \$attr);
        return \$attr[0].js === deviceName;
    });

    if (toggle) return toggle;

    // 如果没找到，尝试在 AXGroup 子元素中查找 (macOS 15.3+)
    for (const child of \$children[0].js) {
        $.AXUIElementCopyAttributeValue(child, 'AXRole', \$attr);
        if (\$attr[0].js === 'AXGroup') {
            const \$groupChildren = Ref();
            $.AXUIElementCopyAttributeValue(child, 'AXChildren', \$groupChildren);
            if (typeof \$groupChildren[0] !== 'function') continue;
            toggle = \$groupChildren[0].js.find((grandchild) => {
                $.AXUIElementCopyAttributeValue(grandchild, 'AXRole', \$attr);
                if (\$attr[0].js !== 'AXCheckBox') return false;
                $.AXUIElementCopyAttributeValue(grandchild, 'AXDescription', \$attr);
                return \$attr[0].js === deviceName;
            });
            if (toggle) return toggle;
        }
    }

    // 最后尝试通过 AXIdentifier 查找 (旧版 macOS)
    toggle = \$children[0].js.find((child) => {
        $.AXUIElementCopyAttributeValue(child, 'AXRole', \$attr);
        if (\$attr[0].js !== 'AXCheckBox') return false;
        $.AXUIElementCopyAttributeValue(child, 'AXIdentifier', \$attr);
        return \$attr[0].js === 'screen-mirroring-device-' + deviceName;
    });

    return toggle || null;
}
EOF

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
fi
