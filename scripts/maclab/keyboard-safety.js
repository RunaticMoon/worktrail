/*
 * Read-only native AX plus System Events keys for isolated DEBUG fixture safety.
 *   osascript -l JavaScript scripts/maclab/keyboard-safety.js --fixture many
 * Optional: --action checklist|memo|secret (default all).
 * Start exactly one fresh After.app --args --ui-test-fixture many, with no panel
 * or sheet. The actual target PID's launch arguments are checked first.
 * Checklist input is cleared without saving. Memo changes are discarded and the
 * stored original is rechecked. Secret uses fake authentication, creates/removes
 * one blank unsaved row, and focuses Save without activating it. No Secret field
 * values are read. Run secret in each desired caller-configured window size.
 * No clicks, AX writes, original text, clipboard text or Secret values in output.
 * Requires real Mac execution; node --check proves syntax only.
 */
ObjC.import('AppKit');
ObjC.import('ApplicationServices');

var KEYBOARD_BUNDLE = 'dev.worklog.UIReview';
var KEYBOARD_QUERY = '검증 메모';
var KEYBOARD_MARKER = '\nKeyboard-only fixture edit verified.';

function keyboardAXRead(node, attribute) {
    if (!node) return null;
    var output = Ref();
    if (Number($.AXUIElementCopyAttributeValue(node, $(attribute), output)) !== 0) return null;
    return ObjC.castRefToObject(output[0]);
}
function keyboardString(value) {
    if (value === null || value === undefined) return '';
    var result = ObjC.unwrap(value);
    return typeof result === 'string' ? result : '';
}
function keyboardText(node, attribute) { return keyboardString(keyboardAXRead(node, attribute)); }
function keyboardArray(value) {
    if (value === null || value === undefined) return [];
    var result = [], count = Number(value.count);
    if (!isFinite(count)) throw new Error('AX_ARRAY_BRIDGE_FAILED');
    for (var index = 0; index < count; index += 1) result.push(value.objectAtIndex(index));
    return result;
}
function keyboardLabel(node) {
    return keyboardText(node, 'AXDescription') || keyboardText(node, 'AXTitle');
}
function keyboardSame(a, b) { return Boolean(a && b && $.CFEqual(a, b)); }

function run(args) {
    var stage = 'fixture_guard', appAX, reviewPID, running, events;
    var started = Number($.NSProcessInfo.processInfo.systemUptime);
    var result = { ok: false, tests: {}, observations: { keyboardOnly: true, secretValuesRead: false, secretSaveActivated: false } };
    function fail(code) { var error = new Error(code); error.keyboardCode = code; throw error; }
    function need(value, code) { if (!value) fail(code); }
    function check(name, value) { result.tests[name] = Boolean(value); need(value, 'ASSERTION_' + name); }
    function option(name, fallback) {
        var index = args.indexOf(name);
        return index < 0 ? fallback : args[index + 1];
    }
    function deadline() {
        if (Number($.NSProcessInfo.processInfo.systemUptime) - started > 160) fail('WORKFLOW_DEADLINE');
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
    function windows() { return keyboardArray(keyboardAXRead(appAX, 'AXWindows')); }
    function windowNamed(title) {
        return windows().filter(function (node) { return keyboardText(node, 'AXTitle') === title; })[0] || null;
    }
    function mainWindow() {
        return windows().filter(function (node) {
            return keyboardText(node, 'AXSubrole') === 'AXStandardWindow' &&
                ['빠른 입력', 'WorkLog 검색'].indexOf(keyboardText(node, 'AXTitle')) < 0;
        })[0] || null;
    }
    function walk(root, visit, includeSheets) {
        if (!root) return null;
        var queue = [{ node: root, depth: 0 }], count = 0;
        while (queue.length && count < 1600) {
            deadline();
            var item = queue.shift();
            count += 1;
            var role = keyboardText(item.node, 'AXRole');
            if (!includeSheets && role === 'AXSheet') continue;
            if (visit(item.node, role)) return item.node;
            if (item.depth < 28) {
                keyboardArray(keyboardAXRead(item.node, 'AXChildren')).forEach(function (child) {
                    queue.push({ node: child, depth: item.depth + 1 });
                });
            }
        }
        need(queue.length === 0, 'AX_TRAVERSAL_LIMIT');
        return null;
    }
    function labelled(root, label, role, includeSheets) {
        return walk(root, function (node, currentRole) {
            return (!role || role === currentRole) && keyboardLabel(node) === label;
        }, includeSheets);
    }
    function sheet(root) {
        var attached = keyboardArray(keyboardAXRead(root, 'AXSheets'));
        return attached[0] || walk(root, function (_, role) { return role === 'AXSheet'; }, true);
    }
    function owningWindow(node) {
        var window = keyboardAXRead(node, 'AXWindow');
        if (window) return window;
        for (var depth = 0; node && depth < 35; depth += 1) {
            if (keyboardText(node, 'AXRole') === 'AXWindow') return node;
            node = keyboardAXRead(node, 'AXParent');
        }
        return null;
    }
    function sameFocusedScrollArea(focused, target) {
        // SwiftUI can export different AX proxies for its focus owner and its
        // tree node. Match only a uniquely labelled scroll area in the SAME
        // native window; never infer focus from selection or appearance.
        if (keyboardText(focused, 'AXRole') !== 'AXScrollArea' ||
            keyboardText(target, 'AXRole') !== 'AXScrollArea') return false;
        var label = keyboardLabel(target);
        if (!label || keyboardLabel(focused) !== label) return false;
        var focusedWindow = owningWindow(focused), targetWindow = owningWindow(target);
        if (!keyboardSame(focusedWindow, targetWindow)) return false;
        var focusedID = keyboardText(focused, 'AXIdentifier'), targetID = keyboardText(target, 'AXIdentifier');
        if (focusedID && targetID && focusedID !== targetID) return false;
        var matches = 0;
        walk(targetWindow, function (node, role) {
            if (role === 'AXScrollArea' && keyboardLabel(node) === label) matches += 1;
            return matches > 1;
        }, false);
        if (matches !== 1) return false;
        result.observations.scrollFocusProxyMatchedByUniqueLabelAndWindow = true;
        return true;
    }
    function focusInside(root) {
        if (!root) return false;
        var focused = keyboardAXRead(appAX, 'AXFocusedUIElement');
        for (var depth = 0; focused && depth < 35; depth += 1) {
            if (keyboardSame(focused, root) || sameFocusedScrollArea(focused, root)) return true;
            focused = keyboardAXRead(focused, 'AXParent');
        }
        var value = keyboardAXRead(root, 'AXFocused');
        return value !== null && Boolean(ObjC.unwrap(value));
    }
    function front() {
        return Number($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier) === reviewPID;
    }
    function key(code, modifiers) {
        deadline();
        need(front(), 'REVIEW_LOST_FOREGROUND');
        events.keyCode(code, { using: modifiers || [] });
    }
    function pasteKnown(text) {
        var clipboard = $.NSPasteboard.generalPasteboard;
        clipboard.clearContents;
        need(Boolean(clipboard.setStringForType($(text), $.NSPasteboardTypeString)), 'SYNTHETIC_PASTE_FAILED');
        key(0, ['command down']);
        key(9, ['command down']);
    }
    function activateMain() {
        running.activateWithOptions(3);
        waitFor(function () { return front() && mainWindow(); }, 'MAIN_WINDOW_NOT_ACTIVE');
        delay(0.2);
    }

    function pasteAtCursor(text) {
        var clipboard = $.NSPasteboard.generalPasteboard;
        clipboard.clearContents;
        need(Boolean(clipboard.setStringForType($(text), $.NSPasteboardTypeString)), 'SYNTHETIC_PASTE_FAILED');
        key(9, ['command down']);
    }
    function detailField() { return labelled(sheet(mainWindow()), '새 체크리스트 항목', 'AXTextField', true); }
    function checklistFlow() {
        stage = 'checklist_open';
        key(19, ['command down']);
        // Match the scroll-area role; focusInside handles SwiftUI AX proxy identity.
        waitFor(function () { return labelled(mainWindow(), '업무 목록', 'AXScrollArea'); }, 'TASK_LIST_MISSING');
        key(29, ['command down', 'shift down']);
        waitFor(function () { return focusInside(labelled(mainWindow(), '업무 목록', 'AXScrollArea')); }, 'TASK_LIST_NOT_FOCUSED');
        key(36);
        waitFor(function () { return sheet(mainWindow()); }, 'TASK_DETAIL_NOT_OPENED');
        key(38, ['command down', 'shift down']);
        var field = waitFor(detailField, 'CHECKLIST_FIELD_NOT_OPENED');
        waitFor(function () { return focusInside(field); }, 'CHECKLIST_FIELD_NOT_FOCUSED');
        need(keyboardText(field, 'AXValue') === '', 'NONEMPTY_CHECKLIST_DRAFT_ABORTED');
        stage = 'checklist_space_and_cursor';
        pasteKnown('KeyboardSafety');
        waitFor(function () { return keyboardText(detailField(), 'AXValue') === 'KeyboardSafety'; }, 'CHECKLIST_INPUT_FAILED');
        key(49);
        check('checklistSpaceRemainsInField', waitFor(function () {
            var current = detailField();
            return current && focusInside(current) && keyboardText(current, 'AXValue') === 'KeyboardSafety ';
        }, 'CHECKLIST_SPACE_COLLAPSED_OR_LOST'));
        key(123);
        pasteAtCursor('X');
        check('checklistLeftMovesCursor', waitFor(function () {
            var current = detailField();
            return current && focusInside(current) && keyboardText(current, 'AXValue') === 'KeyboardSafetyX ';
        }, 'CHECKLIST_LEFT_INTERCEPTED'));
        key(124);
        pasteAtCursor('Y');
        check('checklistRightMovesCursor', waitFor(function () {
            var current = detailField();
            return current && focusInside(current) && keyboardText(current, 'AXValue') === 'KeyboardSafetyX Y';
        }, 'CHECKLIST_RIGHT_INTERCEPTED'));
        stage = 'checklist_close_without_save';
        key(0, ['command down']); key(51);
        waitFor(function () { return keyboardText(detailField(), 'AXValue') === ''; }, 'CHECKLIST_DRAFT_NOT_CLEARED');
        key(53);
        waitFor(function () { return !sheet(mainWindow()); }, 'CHECKLIST_DETAIL_NOT_CLOSED');
        check('checklistClosedWithoutSubmitting', true);
    }
    function findInWindows(label, role) {
        var found = null;
        windows().some(function (window) {
            // Alerts may be exported through AXSheets instead of AXChildren.
            var roots = [window], first = sheet(window);
            if (first) {
                roots.push(first);
                var second = sheet(first);
                if (second && !keyboardSame(second, first)) roots.push(second);
            }
            return roots.some(function (root) { found = labelled(root, label, role, true); return Boolean(found); });
        });
        return found;
    }
    function unsavedAlert() {
        return findInWindows('계속 편집', 'AXButton') && findInWindows('수정 버리고 닫기', 'AXButton');
    }
    function editor() { return labelled(sheet(windowNamed('WorkLog 검색')), '메모 본문 편집', 'AXTextArea', true); }
    function fixtureBody(number) {
        return '검증 메모 ' + number + ' · 업무 도중 빠르게 기록한 내용\n첫 번째 관찰: 검색 결과와 원문을 바로 연결할 수 있어야 합니다.\n두 번째 관찰: 화면 크기가 달라도 긴 한국어 문장이 잘리지 않아야 합니다.';
    }
    function memoFlow() {
        stage = 'memo_search_open';
        key(3, ['command down']);
        var query = waitFor(function () { return labelled(windowNamed('WorkLog 검색'), '원문 검색', 'AXTextField'); }, 'SEARCH_NOT_OPENED');
        need(['', KEYBOARD_QUERY].indexOf(keyboardText(query, 'AXValue')) >= 0, 'UNEXPECTED_QUERY_ABORTED');
        waitFor(function () { return focusInside(query); }, 'SEARCH_QUERY_NOT_FOCUSED');
        pasteKnown(KEYBOARD_QUERY);
        waitFor(function () { return keyboardText(query, 'AXValue') === KEYBOARD_QUERY; }, 'QUERY_NOT_PASTED');
        delay(0.5);
        key(125); key(48); key(14, ['command down']);
        var body = waitFor(editor, 'MEMO_EDITOR_NOT_OPENED');
        waitFor(function () { return focusInside(body); }, 'MEMO_EDITOR_NOT_FOCUSED');
        var original = keyboardText(body, 'AXValue');
        var identity = original.match(/^검증 메모 ([0-9]+) ·/);
        need(identity && Number(identity[1]) >= 1 && Number(identity[1]) <= 36, 'NONFIXTURE_MEMO_ABORTED');
        var seeded = fixtureBody(Number(identity[1]));
        need(original === seeded || original === seeded + KEYBOARD_MARKER, 'UNEXPECTED_MEMO_BODY_ABORTED');
        var changed = original + '\nKeyboard safety discard check.';
        pasteKnown(changed);
        waitFor(function () { return editor() && keyboardText(editor(), 'AXValue') === changed; }, 'MEMO_DRAFT_NOT_CHANGED');
        stage = 'memo_command_w_unsaved_alert';
        key(13, ['command down']);
        check('memoCommandWShowsUnsavedAlert', waitFor(unsavedAlert, 'COMMAND_W_BYPASSED_UNSAVED_ALERT'));
        key(53);
        waitFor(function () { return !unsavedAlert() && editor() && focusInside(editor()); }, 'ESC_DID_NOT_CONTINUE_EDITING');
        check('memoEscapeKeepsDraft', keyboardText(editor(), 'AXValue') === changed);
        stage = 'memo_discard_close';
        key(13, ['command down']);
        waitFor(unsavedAlert, 'SECOND_COMMAND_W_ALERT_MISSING');
        key(2, ['command down']);
        waitFor(function () { return !sheet(windowNamed('WorkLog 검색')) && !unsavedAlert(); }, 'COMMAND_D_DID_NOT_DISCARD');
        check('memoCommandDClosesDiscardedEdit', Boolean(windowNamed('WorkLog 검색')));
        stage = 'memo_original_preserved';
        key(14, ['command down']);
        body = waitFor(editor, 'MEMO_REOPEN_FAILED');
        check('memoOriginalPreservedAfterDiscard', keyboardText(body, 'AXValue') === original);
        key(53);
        waitFor(function () { return !sheet(windowNamed('WorkLog 검색')); }, 'UNCHANGED_MEMO_DID_NOT_CLOSE');
        key(53);
        waitFor(function () { return !windowNamed('WorkLog 검색'); }, 'SEARCH_PANEL_DID_NOT_CLOSE');
        activateMain();
    }
    function captureControl(label, role) { return labelled(windowNamed('빠른 입력'), label, role); }
    function expectFocus(read, code) {
        return waitFor(function () { var node = read(); return node && focusInside(node); }, code);
    }
    function tabUntil(read, backwards, code) {
        for (var index = 0; index < 14; index += 1) {
            var node = read();
            if (node && focusInside(node)) return true;
            need(focusInside(windowNamed('빠른 입력')), 'CAPTURE_FOCUS_ESCAPED_PANEL');
            key(48, backwards ? ['shift down'] : []);
            delay(0.12);
        }
        fail(code);
    }
    function secretSaveButton() {
        return walk(windowNamed('빠른 입력'), function (node, role) {
            return role === 'AXButton' && (/^저장(?:\s|,|$)/.test(keyboardLabel(node)) ||
                keyboardText(node, 'AXHelp').indexOf('Secret 저장') === 0);
        }, false);
    }
    function secretFlow() {
        stage = 'secret_capture_open';
        key(45, ['command down']);
        var memo = waitFor(function () { return captureControl('메모 본문', 'AXTextArea'); }, 'CAPTURE_NOT_OPENED');
        need(keyboardText(memo, 'AXValue') === '', 'NONEMPTY_CAPTURE_DRAFT_ABORTED');
        key(20, ['command down']);
        var unlock = waitFor(function () { return captureControl('잠금 해제', 'AXButton'); }, 'FRESH_LOCKED_SECRET_REQUIRED');
        expectFocus(function () { return unlock; }, 'SECRET_UNLOCK_NOT_FOCUSED');
        key(48); delay(0.15); key(48, ['shift down']);
        check('secretUnlockTabRoundtrip', expectFocus(function () { return unlock; }, 'SECRET_UNLOCK_SHIFT_TAB_FAILED'));
        key(49); // Fixture authenticator only. No production credential access.
        stage = 'secret_empty_editor_focus';
        var title = waitFor(function () { return captureControl('Secret 제목', 'AXTextField'); }, 'SECRET_FAKE_UNLOCK_FAILED');
        need(!captureControl('행 1 key'), 'EXISTING_SECRET_ROWS_ABORTED');
        check('secretTitleFocused', expectFocus(function () { return title; }, 'SECRET_TITLE_NOT_FOCUSED'));
        key(48);
        check('secretGroupReachable', expectFocus(function () { return captureControl('그룹 (선택 사항)', 'AXTextField'); }, 'SECRET_GROUP_TAB_FAILED'));
        key(48, ['shift down']);
        check('secretGroupShiftTabReturnsTitle', expectFocus(function () { return title; }, 'SECRET_TITLE_SHIFT_TAB_FAILED'));
        key(48); key(48);
        check('secretAddRowReachable', expectFocus(function () { return captureControl('행 추가', 'AXButton'); }, 'SECRET_ADD_ROW_TAB_FAILED'));
        key(49); // Add one blank, unsaved row to exercise both cell focus targets.
        stage = 'secret_blank_row_navigation';
        check('secretKeyReachable', expectFocus(function () { return captureControl('행 1 key', 'AXTextField'); }, 'SECRET_NEW_KEY_NOT_FOCUSED'));
        key(48);
        check('secretHiddenValueReachable', expectFocus(function () { return captureControl('가려진 값'); }, 'SECRET_VALUE_TAB_FAILED'));
        key(48);
        check('secretRowDeleteReachable', expectFocus(function () { return captureControl('행 1 삭제', 'AXButton'); }, 'SECRET_DELETE_TAB_FAILED'));
        key(48);
        expectFocus(function () { return captureControl('행 추가', 'AXButton'); }, 'SECRET_ADD_AFTER_ROW_FAILED');
        stage = 'secret_save_focus_only';
        check('secretSaveReachableWithoutActivation', tabUntil(secretSaveButton, false, 'SECRET_SAVE_UNREACHABLE'));
        check('secretReverseTabReturnsTitle', tabUntil(function () { return captureControl('Secret 제목', 'AXTextField'); }, true, 'SECRET_REVERSE_TAB_FAILED'));
        stage = 'secret_remove_blank_row';
        key(48); key(48);
        expectFocus(function () { return captureControl('행 1 key', 'AXTextField'); }, 'SECRET_KEY_CLEANUP_FOCUS_FAILED');
        key(51, ['command down', 'shift down']);
        waitFor(function () { return !captureControl('행 1 key'); }, 'EMPTY_SECRET_ROW_NOT_REMOVED');
        key(53);
        waitFor(function () { return !windowNamed('빠른 입력'); }, 'EMPTY_SECRET_CAPTURE_NOT_CLOSED');
        check('secretClosedWithoutSaving', true);
    }

    try {
        need(option('--fixture', '') === 'many', 'REQUIRE_EXPLICIT_MANY_FIXTURE');
        var action = option('--action', 'all');
        need(['all', 'checklist', 'memo', 'secret'].indexOf(action) >= 0, 'INVALID_ACTION');
        var apps = keyboardArray($.NSWorkspace.sharedWorkspace.runningApplications).filter(function (app) {
            return keyboardString(app.bundleIdentifier) === KEYBOARD_BUNDLE;
        });
        need(apps.length === 1, 'EXACTLY_ONE_REVIEW_APP_REQUIRED');
        running = apps[0];
        reviewPID = Number(running.processIdentifier);
        need(isFinite(reviewPID) && reviewPID > 1 && Math.floor(reviewPID) === reviewPID, 'INVALID_REVIEW_PID');
        var automation = Application.currentApplication();
        automation.includeStandardAdditions = true;
        // Read only the reviewed process; never enumerate unrelated process args.
        var launch = automation.doShellScript('/bin/ps -ww -p ' + reviewPID + ' -o command=');
        need(/(?:^|\s)--ui-test-fixture\s+many(?:\s|$)/.test(launch), 'REVIEW_LAUNCH_NOT_MANY_FIXTURE');
        need((launch.match(/--ui-test-fixture/g) || []).length === 1, 'AMBIGUOUS_FIXTURE_ARGUMENTS');
        launch = null;
        check('actualFixtureLaunchVerified', true);
        appAX = $.AXUIElementCreateApplication(reviewPID);
        $.AXUIElementSetMessagingTimeout(appAX, 0.6);
        need(mainWindow(), 'REVIEW_MAIN_WINDOW_MISSING');
        need(!windowNamed('빠른 입력') && !windowNamed('WorkLog 검색'), 'CLOSE_EXISTING_PANELS_FIRST');
        windows().forEach(function (window) { need(!sheet(window), 'CLOSE_EXISTING_SHEET_FIRST'); });
        events = Application('System Events');
        activateMain();
        if (action === 'all' || action === 'checklist') checklistFlow();
        if (action === 'all' || action === 'memo') memoFlow();
        if (action === 'all' || action === 'secret') secretFlow();
        result.ok = true;
        result.stage = 'complete';
        return JSON.stringify(result);
    } catch (error) {
        result.stage = stage;
        result.error = error.keyboardCode || 'NATIVE_AX_OR_AUTOMATION_FAILURE';
        throw new Error(JSON.stringify(result));
    }
}
