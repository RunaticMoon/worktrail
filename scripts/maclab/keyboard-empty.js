/*
 * Keyboard-only empty-state checks for a fresh isolated DEBUG review bundle.
 *   osascript -l JavaScript scripts/maclab/keyboard-empty.js --fixture empty
 * Launch exactly one dev.worklog.UIReview with --args --ui-test-fixture empty.
 * The actual target PID's launch arguments are verified before sending keys.
 * Read-only native AX establishes focus; System Events sends all user input.
 * Secret unlock uses the fixture's fake authenticator. Only fixed empty-state
 * AXStaticText values may be compared; no Secret field value, clipboard,
 * AX mutation, mouse action or production credential is accessed.
 * Results contain booleans and fixed stage/error codes, never inspected content.
 * node --check validates syntax only; actual Mac execution is required.
 */
ObjC.import('AppKit');
ObjC.import('ApplicationServices');

function emptyAXRead(node, attribute) {
    if (!node) return null;
    var output = Ref();
    if (Number($.AXUIElementCopyAttributeValue(node, $(attribute), output)) !== 0) return null;
    return ObjC.castRefToObject(output[0]);
}
function emptyString(value) {
    if (value === null || value === undefined) return '';
    var result = ObjC.unwrap(value);
    return typeof result === 'string' ? result : '';
}
function emptyText(node, attribute) { return emptyString(emptyAXRead(node, attribute)); }
function emptyArray(value) {
    if (value === null || value === undefined) return [];
    var result = [], count = Number(value.count);
    if (!isFinite(count)) throw new Error('AX_ARRAY_BRIDGE_FAILED');
    for (var index = 0; index < count; index += 1) result.push(value.objectAtIndex(index));
    return result;
}
function emptyLabel(node) { return emptyText(node, 'AXDescription') || emptyText(node, 'AXTitle'); }
function emptySame(a, b) { return Boolean(a && b && $.CFEqual(a, b)); }

function main(args) {
    var stage = 'fixture_guard', appAX, reviewPID, running, events;
    var started = Number($.NSProcessInfo.processInfo.systemUptime);
    var result = { ok: false, tests: {}, observations: { keyboardOnly: true, secretValuesRead: false, secretSaveActivated: false } };
    function fail(code) { var error = new Error(code); error.keyboardCode = code; throw error; }
    function need(value, code) { if (!value) fail(code); }
    function check(name, value) { result.tests[name] = Boolean(value); need(value, 'ASSERTION_' + name); }
    function deadline() {
        if (Number($.NSProcessInfo.processInfo.systemUptime) - started > 100) fail('WORKFLOW_DEADLINE');
    }
    function waitFor(read, code) {
        var until = Number($.NSProcessInfo.processInfo.systemUptime) + 8;
        do {
            deadline();
            var value = read();
            if (value) return value;
            delay(0.12);
        } while (Number($.NSProcessInfo.processInfo.systemUptime) < until);
        fail(code);
    }
    function windows() { return emptyArray(emptyAXRead(appAX, 'AXWindows')); }
    function windowNamed(title) {
        return windows().filter(function (node) { return emptyText(node, 'AXTitle') === title; })[0] || null;
    }
    function mainWindow() {
        var matches = windows().filter(function (node) {
            return emptyText(node, 'AXSubrole') === 'AXStandardWindow' &&
                ['빠른 입력', 'WorkLog 검색', '키보드 단축키'].indexOf(emptyText(node, 'AXTitle')) < 0;
        });
        return matches.length === 1 ? matches[0] : null;
    }
    function walk(root, visit, includeSheets) {
        if (!root) return null;
        var queue = [{ node: root, depth: 0 }], count = 0;
        while (queue.length && count < 1000) {
            deadline();
            var item = queue.shift();
            count += 1;
            var role = emptyText(item.node, 'AXRole');
            if (!includeSheets && role === 'AXSheet') continue;
            if (visit(item.node, role)) return item.node;
            if (item.depth < 28) {
                emptyArray(emptyAXRead(item.node, 'AXChildren')).forEach(function (child) {
                    queue.push({ node: child, depth: item.depth + 1 });
                });
            }
        }
        need(queue.length === 0, 'AX_TRAVERSAL_LIMIT');
        return null;
    }
    function labelled(root, label, role) {
        return walk(root, function (node, currentRole) {
            // Native controls can expose a generic description such as "button"
            // alongside their semantic title. Neither may hide the other.
            return (!role || role === currentRole) &&
                (emptyText(node, 'AXDescription') === label || emptyText(node, 'AXTitle') === label);
        }, false);
    }
    function knownTitle(root, title) {
        // SwiftUI may combine the fixed title and explanation into one label.
        // Static title values are compared only to the supplied fixed literal;
        // a text/secure field's AXValue is never requested.
        return walk(root, function (node, role) {
            if (role === 'AXTextField' || role === 'AXTextArea') return false;
            if (emptyLabel(node).indexOf(title) >= 0) return true;
            if (role !== 'AXStaticText') return false;
            var value = emptyText(node, 'AXValue');
            return value === title || value.indexOf(title + ', ') === 0;
        }, false);
    }
    function containsSidebar(root) {
        return Boolean(labelled(root, '사이드바') ||
            (labelled(root, '오늘', 'AXButton') && labelled(root, '업무', 'AXButton')));
    }
    function sheet(root) {
        var attached = emptyArray(emptyAXRead(root, 'AXSheets'));
        return attached[0] || walk(root, function (_, role) { return role === 'AXSheet'; }, true);
    }
    function owningWindow(node) {
        var window = emptyAXRead(node, 'AXWindow');
        if (window) return window;
        for (var depth = 0; node && depth < 35; depth += 1) {
            if (emptyText(node, 'AXRole') === 'AXWindow') return node;
            node = emptyAXRead(node, 'AXParent');
        }
        return null;
    }
    function focusInside(root) {
        if (!root) return false;
        var focused = emptyAXRead(appAX, 'AXFocusedUIElement');
        for (var depth = 0; focused && depth < 35; depth += 1) {
            if (emptySame(focused, root)) return true;
            focused = emptyAXRead(focused, 'AXParent');
        }
        var value = emptyAXRead(root, 'AXFocused');
        return value !== null && Boolean(ObjC.unwrap(value));
    }
    function sidebarFocused(route) {
        var root = mainWindow(), focused = emptyAXRead(appAX, 'AXFocusedUIElement');
        if (!focused || !emptySame(owningWindow(focused), root)) return false;
        return focusInside(labelled(root, '사이드바')) || focusInside(labelled(root, route, 'AXButton'));
    }
    function contentFocusedAt(title) {
        var root = mainWindow(), focused = emptyAXRead(appAX, 'AXFocusedUIElement');
        if (!focused || !root || !emptySame(owningWindow(focused), root)) return false;
        // A generic main-window focus is insufficient. Require a focused element
        // or ancestor containing the known empty state, strictly below the
        // window, whose subtree does not also contain the sidebar. This accepts
        // SwiftUI's native focus-container proxy without relying on selection.
        for (var depth = 0; focused && depth < 35; depth += 1) {
            var role = emptyText(focused, 'AXRole');
            if (role === 'AXWindow' || role === 'AXApplication' || emptySame(focused, root)) return false;
            if (knownTitle(focused, title) && !containsSidebar(focused)) return true;
            focused = emptyAXRead(focused, 'AXParent');
        }
        return false;
    }
    function front() {
        return Number($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier) === reviewPID;
    }
    function key(code, modifiers) {
        deadline();
        need(front(), 'REVIEW_LOST_FOREGROUND');
        events.keyCode(code, { using: modifiers || [] });
    }
    function focusSidebar(route, checkName) {
        key(29, ['command down']);
        check(checkName, waitFor(function () { return sidebarFocused(route); }, 'SIDEBAR_NOT_FOCUSED'));
    }
    function recordTrashUnlockFocus() {
        // Emit only fixed interface names, never arbitrary labels or AXValue.
        var safeNames = ['', '잠금 해제', 'Secret 휴지통 잠금 해제', '휴지통', '사이드바',
            'WorkLog', 'button', 'text', 'group', 'scroll area', '버튼'];
        function safeName(value) { return safeNames.indexOf(value) >= 0 ? value : 'other'; }
        function describe(node) {
            if (!node) return { exists: false };
            var role = emptyText(node, 'AXRole'), focused = emptyAXRead(node, 'AXFocused');
            return {
                exists: true,
                role: /^AX[A-Za-z]+$/.test(role) ? role : 'other',
                title: safeName(emptyText(node, 'AXTitle')),
                description: safeName(emptyText(node, 'AXDescription')),
                focused: focused !== null && Boolean(ObjC.unwrap(focused))
            };
        }
        var root = mainWindow();
        var unlock = labelled(root, '잠금 해제', 'AXButton');
        var helpMatched = walk(root, function (node, role) {
            return role === 'AXButton' && emptyText(node, 'AXHelp') === 'Secret 휴지통 잠금 해제';
        }, false);
        result.observations.trashUnlockFocus = {
            focusedElement: describe(emptyAXRead(appAX, 'AXFocusedUIElement')),
            unlockByLabel: describe(unlock),
            unlockByFixedHelp: describe(helpMatched)
        };
    }

    try {
        need(args.length === 2 && args[0] === '--fixture' && args[1] === 'empty', 'REQUIRE_EXPLICIT_EMPTY_FIXTURE');
        var apps = emptyArray($.NSWorkspace.sharedWorkspace.runningApplications).filter(function (app) {
            return emptyString(app.bundleIdentifier) === 'dev.worklog.UIReview';
        });
        need(apps.length === 1, 'EXACTLY_ONE_REVIEW_APP_REQUIRED');
        running = apps[0];
        reviewPID = Number(running.processIdentifier);
        need(isFinite(reviewPID) && reviewPID > 1 && Math.floor(reviewPID) === reviewPID, 'INVALID_REVIEW_PID');
        var automation = Application.currentApplication();
        automation.includeStandardAdditions = true;
        // Inspect only this bundle's PID; never enumerate unrelated process args.
        var launch = automation.doShellScript('/bin/ps -ww -p ' + reviewPID + ' -o command=');
        need(/(?:^|\s)--ui-test-fixture\s+empty(?:\s|$)/.test(launch), 'REVIEW_LAUNCH_NOT_EMPTY_FIXTURE');
        need((launch.match(/--ui-test-fixture/g) || []).length === 1, 'AMBIGUOUS_FIXTURE_ARGUMENTS');
        launch = null;
        check('actualFixtureLaunchVerified', true);
        appAX = $.AXUIElementCreateApplication(reviewPID);
        $.AXUIElementSetMessagingTimeout(appAX, 0.6);
        need(mainWindow(), 'EXACTLY_ONE_MAIN_WINDOW_REQUIRED');
        need(!windowNamed('빠른 입력') && !windowNamed('WorkLog 검색'), 'CLOSE_EXISTING_PANELS_FIRST');
        windows().forEach(function (window) { need(!sheet(window), 'CLOSE_EXISTING_SHEET_FIRST'); });
        events = Application('System Events');
        running.activateWithOptions(3);
        waitFor(function () { return front() && mainWindow(); }, 'MAIN_WINDOW_NOT_ACTIVE');
        delay(0.2);

        stage = 'empty_projects_focus';
        key(20, ['command down']);
        check('projectEmptyStatePresent', waitFor(function () {
            return knownTitle(mainWindow(), '아직 프로젝트가 없습니다');
        }, 'PROJECTS_NOT_EMPTY'));
        focusSidebar('프로젝트', 'projectSidebarFocused');
        key(29, ['command down', 'shift down']);
        check('projectEmptyContentFocused', waitFor(function () {
            return contentFocusedAt('아직 프로젝트가 없습니다');
        }, 'PROJECT_EMPTY_CONTENT_NOT_FOCUSED'));
        stage = 'empty_projects_return_capture';
        key(36);
        check('projectReturnOpensCapture', waitFor(function () { return windowNamed('빠른 입력'); }, 'PROJECT_RETURN_DID_NOT_OPEN_CAPTURE'));
        key(53);
        check('projectEscapeClosesCapture', waitFor(function () { return !windowNamed('빠른 입력'); }, 'PROJECT_CAPTURE_DID_NOT_CLOSE'));
        running.activateWithOptions(3);
        waitFor(function () { return front() && mainWindow(); }, 'MAIN_WINDOW_NOT_REACTIVATED');

        stage = 'empty_trash_unlock_focus';
        key(25, ['command down']); // Physical 9 key: Trash in the numbered sidebar.
        waitFor(function () { return knownTitle(mainWindow(), '휴지통이 잠겨 있습니다'); }, 'FRESH_LOCKED_TRASH_REQUIRED');
        focusSidebar('휴지통', 'lockedTrashSidebarFocused');
        key(29, ['command down', 'shift down']);
        check('trashUnlockFocused', waitFor(function () {
            return focusInside(labelled(mainWindow(), '잠금 해제', 'AXButton'));
        }, 'TRASH_UNLOCK_NOT_FOCUSED'));
        stage = 'empty_trash_fake_unlock';
        key(49); // Fixture-only fake authenticator, verified by actual launch args.
        check('trashFakeUnlockShowsEmptyState', waitFor(function () {
            return knownTitle(mainWindow(), '휴지통이 비어 있습니다') && !labelled(mainWindow(), '잠금 해제', 'AXButton');
        }, 'TRASH_FAKE_UNLOCK_DID_NOT_SHOW_EMPTY_STATE'));
        stage = 'empty_trash_content_focus';
        focusSidebar('휴지통', 'emptyTrashSidebarFocused');
        key(29, ['command down', 'shift down']);
        check('emptyTrashContentFocusedOutsideSidebar', waitFor(function () {
            return contentFocusedAt('휴지통이 비어 있습니다') && !sidebarFocused('휴지통');
        }, 'EMPTY_TRASH_CONTENT_NOT_FOCUSED'));
        result.ok = true;
        result.stage = 'complete';
        return JSON.stringify(result);
    } catch (error) {
        if (error.keyboardCode === 'TRASH_UNLOCK_NOT_FOCUSED') {
            try { recordTrashUnlockFocus(); }
            catch (_) { result.observations.trashUnlockFocusDiagnosticFailed = true; }
        }
        result.stage = stage;
        result.error = error.keyboardCode || 'NATIVE_AX_OR_AUTOMATION_FAILURE';
        throw new Error(JSON.stringify(result));
    }
}

function run(args) { return main(args); }
