/*
 * macOS / Maclab smoke test, using only standard Accessibility containers.
 * Launch the app separately with fake fixtures, for example:
 *   open .build/app/WorkLog.app --args --ui-test-fixture many
 *   osascript -l JavaScript scripts/maclab/verify-ui.js --fixture many
 * Optional: --process WorkLog for a production bundle (default: WorkLogApp).
 * One sample: --phase after --fixture many resize 960 640 2
 * Readiness probe suitable for a gui_boolean step:
 *   osascript -l JavaScript scripts/maclab/verify-ui.js --ready
 *
 * --fixture is an explicit declaration, not proof of the app's launch arguments.
 * This script never opens/unlocks secrets, clicks destructive actions, reads
 * text-field values, copies data, or invokes AI. It changes size/navigation only.
 * It does not validate clipping inside scroll views, overlap, IME, or workflows.
 */
ObjC.import('AppKit');

function option(args, key, fallback) {
    const index = args.indexOf(key);
    return index < 0 || index + 1 >= args.length ? fallback : args[index + 1];
}

function safeRead(read, fallback) {
    try { return read(); } catch (_) { return fallback; }
}

function rect(element) {
    const position = safeRead(function () { return element.position(); }, null);
    const size = safeRead(function () { return element.size(); }, null);
    if (!position || !size || position.length !== 2 || size.length !== 2) return null;
    const result = { x: Number(position[0]), y: Number(position[1]), width: Number(size[0]), height: Number(size[1]) };
    return Object.keys(result).every(function (key) { return isFinite(result[key]); }) ? result : null;
}

function isOutside(frame, boundary) {
    const tolerance = 3; // Window borders and AppKit rounding are not clipping.
    return frame.x < boundary.x - tolerance || frame.y < boundary.y - tolerance ||
        frame.x + frame.width > boundary.x + boundary.width + tolerance ||
        frame.y + frame.height > boundary.y + boundary.height + tolerance;
}

function metadata(process) {
    const bundleID = safeRead(function () { return process.bundleIdentifier(); }, null);
    const version = safeRead(function () {
        const pid = process.unixId();
        const apps = $.NSWorkspace.sharedWorkspace.runningApplications;
        for (let index = 0; index < Number(apps.count); index += 1) {
            const running = apps.objectAtIndex(index);
            if (Number(running.processIdentifier) === Number(pid)) {
                const bundle = $.NSBundle.bundleWithURL(running.bundleURL);
                return ObjC.unwrap(bundle.objectForInfoDictionaryKey('CFBundleShortVersionString')) || null;
            }
        }
        return null;
    }, null);
    return { bundleIdentifier: bundleID, version: version };
}

function visibleScreen() {
    return safeRead(function () {
        const screen = $.NSScreen.mainScreen;
        const visible = screen.visibleFrame;
        const primary = $.NSScreen.screens.objectAtIndex(0).frame;
        // Cocoa uses a bottom-left origin; System Events uses a top-left origin.
        return { x: Number(visible.origin.x),
            y: Number(primary.origin.y + primary.size.height - visible.origin.y - visible.size.height),
            width: Number(visible.size.width), height: Number(visible.size.height) };
    }, null);
}

function inspectWindow(window) {
    const boundary = rect(window);
    const result = { frame: boundary, inspectedElements: 0, checkedControls: 0,
        skippedScrollAreas: 0, outsideWindow: [], routeLabels: [], truncated: false };
    if (!boundary) return result;
    const labels = ['오늘', '날짜별 기록', '업무', '제출용 주간보고', '성과자료', 'Secret'];
    const controlRoles = ['AXButton', 'AXTextField', 'AXTextArea', 'AXPopUpButton', 'AXCheckBox', 'AXRadioButton'];
    const queue = [{ node: window, depth: 0 }];
    while (queue.length && result.inspectedElements < 250) {
        const item = queue.shift();
        const role = safeRead(function () { return item.node.role(); }, 'unknown');
        result.inspectedElements += 1;
        // Off-screen rows in a scroll view are valid. Do not report them as clipping.
        if (role === 'AXScrollArea' || role === 'AXTable' || role === 'AXOutline') {
            result.skippedScrollAreas += 1;
            continue;
        }
        if (role === 'AXStaticText') {
            const label = safeRead(function () { return item.node.name(); }, '');
            if (labels.indexOf(label) >= 0 && result.routeLabels.indexOf(label) < 0) result.routeLabels.push(label);
        }
        if (controlRoles.indexOf(role) >= 0 && safeRead(function () { return item.node.visible(); }, true)) {
            const frame = rect(item.node);
            if (frame && frame.width > 0 && frame.height > 0) {
                result.checkedControls += 1;
                if (isOutside(frame, boundary)) {
                    // Deliberately omit names, values and descriptions of controls.
                    result.outsideWindow.push({ role: role, frame: frame });
                }
            }
        }
        if (item.depth >= 10) { result.truncated = true; continue; }
        const children = safeRead(function () { return item.node.uiElements(); }, []);
        children.forEach(function (node) { queue.push({ node: node, depth: item.depth + 1 }); });
    }
    if (queue.length) result.truncated = true;
    return result;
}

function run(args) {
    const events = Application('System Events');
    const processName = option(args, '--process', 'WorkLogApp');
    const process = events.processes.byName(processName);
    const exists = safeRead(function () { return process.exists(); }, false);
    if (args.indexOf('--ready') >= 0) {
        return Boolean(exists && safeRead(function () { return process.frontmost(); }, false) &&
            safeRead(function () { return process.windows.length > 0; }, false));
    }
    const fixture = option(args, '--fixture', null);
    if (['empty', 'few', 'many'].indexOf(fixture) < 0) {
        throw new Error('Launch an isolated --ui-test-fixture app, then pass --fixture empty|few|many.');
    }
    if (!exists) throw new Error('The requested WorkLog process is not running: ' + processName);
    process.frontmost = true;
    delay(0.3);
    const windows = process.windows();
    if (!windows.length) throw new Error('No app window. Open the main WorkLog window first.');
    // AXStandardWindow avoids capture/search panels without depending on view nesting.
    const window = windows.filter(function (candidate) {
        return safeRead(function () { return candidate.subrole(); }, '') === 'AXStandardWindow';
    })[0] || windows[0];
    if (safeRead(function () { return window.sheets.length > 0; }, false)) {
        throw new Error('Dismiss the active sheet before running the size/navigation sweep.');
    }
    let requestedSizes = [[960, 640], [1280, 800], [1440, 900]];
    const resizeIndex = args.indexOf('resize');
    if (resizeIndex >= 0) {
        const width = Number(args[resizeIndex + 1]), height = Number(args[resizeIndex + 2]);
        if (!isFinite(width) || !isFinite(height) || width < 400 || height < 300) {
            throw new Error('resize requires width >= 400 and height >= 300, followed by a route shortcut.');
        }
        requestedSizes = [[width, height]];
    }
    let routes = [{ key: '1', name: 'day' }, { key: '2', name: 'tasks' },
        { key: '4', name: 'submission' }, { key: '5', name: 'performance' }, { key: '6', name: 'secrets' }];
    if (resizeIndex >= 0) {
        routes = routes.filter(function (route) { return route.key === args[resizeIndex + 3]; });
        if (!routes.length) throw new Error('Supported route shortcuts: 1, 2, 4, 5, 6.');
    }
    const screen = visibleScreen();
    const output = { phase: option(args, '--phase', null), fixtureDeclaration: fixture,
        process: processName, app: metadata(process), visibleScreen: screen,
        windowTitle: safeRead(function () { return window.name(); }, null), samples: [],
        limitations: ['routeRequested records the shortcut sent; routeLabels are partial evidence only',
            'scroll descendants, visual overlap, text truncation, IME and workflows require computer-use review',
            'actualSize may differ when the display or app constrains the requested size'] };
    requestedSizes.forEach(function (size) {
        const appliedSize = screen ? [Math.min(size[0], screen.width), Math.min(size[1], screen.height)] : size;
        window.position = screen ? [screen.x, screen.y] : [20, 40];
        window.size = appliedSize;
        delay(0.3);
        routes.forEach(function (route) {
            // Never type a shortcut into another app if focus was taken externally.
            if (!process.frontmost()) throw new Error('WorkLog lost foreground focus; sweep stopped.');
            events.keystroke(route.key, { using: ['command down'] });
            delay(0.3);
            const sample = inspectWindow(window);
            sample.requestedSize = { width: size[0], height: size[1] };
            sample.appliedSize = { width: appliedSize[0], height: appliedSize[1] };
            sample.clampedToVisibleScreen = size[0] !== appliedSize[0] || size[1] !== appliedSize[1];
            sample.routeRequested = route.name;
            sample.shortcut = 'command+' + route.key;
            sample.actualSizeMatches = sample.frame !== null &&
                Math.abs(sample.frame.width - appliedSize[0]) <= 3 && Math.abs(sample.frame.height - appliedSize[1]) <= 3;
            output.samples.push(sample);
        });
    });
    output.outsideWindowCount = output.samples.reduce(function (sum, sample) { return sum + sample.outsideWindow.length; }, 0);
    return JSON.stringify(output, null, 2);
}
