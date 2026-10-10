/*
 * CmdN regression for the isolated DEBUG dev.worklog.UIReview fixture bundle.
 * Run on a fresh fixture process with default Memo capture and default panel size:
 *   osascript -l JavaScript scripts/maclab/capture-shortcut.js
 * Inline executors: osascript -l JavaScript -e SCRIPT --
 *
 * Requires Accessibility permission. Activates the review app and presses CmdN.
 * Does not read field values, type, copy, save, dismiss, or discard a draft.
 * Leaves resulting windows open for a screenshot, including unexpected windows.
 * Emits only window counts, known-title match booleans, geometry, and focus state.
 * Fails if CmdN opens another main window instead of the 660x500 Memo panel.
 * Syntax validation alone does not constitute a successful macOS execution.
 */
ObjC.import('AppKit');

function captureRead(read, fallback) {
    try { return read(); } catch (_) { return fallback; }
}
function captureAttribute(element, key, fallback) {
    return captureRead(function () { return element.attributes.byName(key).value(); }, fallback);
}
function captureLabel(element) {
    // Only compare labels internally; never include them in diagnostics.
    return [captureAttribute(element, 'AXDescription', ''), captureAttribute(element, 'AXTitle', ''),
        captureRead(function () { return element.name(); }, '')]
        .filter(function (value) { return typeof value === 'string'; }).join(' | ');
}
function captureFindBody(root) {
    var queue = [{ element: root, depth: 0 }];
    var count = 0;
    while (queue.length && count < 750) {
        var item = queue.shift();
        count += 1;
        if (captureRead(function () { return item.element.role(); }, '') === 'AXTextArea' &&
            captureLabel(item.element).indexOf('메모 본문') >= 0) return item.element;
        if (item.depth < 22) {
            captureRead(function () { return item.element.uiElements(); }, []).forEach(function (element) {
                queue.push({ element: element, depth: item.depth + 1 });
            });
        }
    }
    return null;
}
function captureFrame(window) {
    var position = captureRead(function () { return window.position(); }, null);
    var size = captureRead(function () { return window.size(); }, null);
    if (!position || !size || position.length !== 2 || size.length !== 2) return null;
    return { x: Number(position[0]), y: Number(position[1]), width: Number(size[0]), height: Number(size[1]) };
}
function captureWindows(process) { return captureRead(function () { return process.windows(); }, []); }
function captureIsPanel(window) { return captureLabel(window).indexOf('빠른 입력') >= 0; }
function captureStandardWindows(items) {
    return items.filter(function (window) {
        return !captureIsPanel(window) &&
            captureRead(function () { return window.subrole(); }, '') === 'AXStandardWindow';
    });
}
function run() {
    var events = Application('System Events');
    var processes = events.processes.whose({ bundleIdentifier: 'dev.worklog.UIReview' })();
    if (processes.length !== 1) throw new Error('Run exactly one isolated UIReview fixture application.');
    var process = processes[0];
    var before = captureWindows(process);
    if (!before.length) throw new Error('Open the fixture main window before testing CmdN.');
    if (before.some(function (window) { return captureIsPanel(window) || Boolean(captureFindBody(window)); })) {
        throw new Error('A capture panel is already open. Close it without discarding before testing CmdN.');
    }
    if (before.some(function (window) {
        return captureRead(function () { return window.sheets().length; }, 0) > 0;
    })) throw new Error('Close the active sheet before testing the main-window CmdN shortcut.');
    var mainCountBefore = captureStandardWindows(before).length;
    if (mainCountBefore === 0) throw new Error('No standard main window is available for the CmdN shortcut.');
    var main = captureStandardWindows(before)[0];
    var running = $.NSRunningApplication.runningApplicationWithProcessIdentifier(process.unixId());
    // Bring an actual main window forward; process.frontmost alone can leave no key window after a panel closes.
    running.activateWithOptions(3);
    process.frontmost = true;
    captureRead(function () { main.actions.byName('AXRaise').perform(); return true; }, false);
    captureRead(function () { main.attributes.byName('AXMain').value = true; return true; }, false);
    captureRead(function () { main.attributes.byName('AXFocused').value = true; return true; }, false);
    delay(0.3);
    if (!captureRead(function () { return process.frontmost(); }, false)) {
        throw new Error('UIReview could not become foreground; no shortcut was sent.');
    }
    events.keyCode(45, { using: ['command down'] });
    var deadline = Date.now() + 8000;
    var panel = null;
    var body = null;
    var after = [];
    do {
        delay(0.15);
        after = captureWindows(process);
        for (var index = 0; index < after.length; index += 1) {
            var candidate = captureFindBody(after[index]);
            if (candidate) { panel = after[index]; body = candidate; break; }
        }
        if (panel) break;
    } while (Date.now() < deadline);
    var frame = panel ? captureFrame(panel) : null;
    var mainCountAfter = captureStandardWindows(after).length;
    var result = {
        action: 'command-n-capture-regression',
        bundleIdentifier: 'dev.worklog.UIReview',
        shortcutSentFromReviewApp: true,
        windowCountBefore: before.length,
        windowCountAfter: after.length,
        mainWindowCountBefore: mainCountBefore,
        mainWindowCountAfter: mainCountAfter,
        openedExtraMainWindow: mainCountAfter > mainCountBefore,
        memoPanelPresent: Boolean(panel),
        captureAXTitleMatches: panel ? captureIsPanel(panel) : false,
        memoBodyFocused: body ? (captureAttribute(body, 'AXFocused', false) === true ||
            captureRead(function () { return body.focused(); }, false) === true) : false,
        panelFrame: frame,
        expectedDefaultSize: { width: 660, height: 500 },
        defaultSizeMatches: frame !== null && Math.abs(frame.width - 660) <= 2 && Math.abs(frame.height - 500) <= 2,
        limitations: ['Requires an after-build fixture with no saved user panel resize.',
            'Leaves the panel or unexpected main windows open; does not test saving or IME.']
    };
    result.passed = result.memoPanelPresent && result.captureAXTitleMatches && result.memoBodyFocused &&
        result.defaultSizeMatches && !result.openedExtraMainWindow;
    if (!result.passed) throw new Error('CmdN capture regression failed: ' + JSON.stringify(result));
    return JSON.stringify(result, null, 2);
}
