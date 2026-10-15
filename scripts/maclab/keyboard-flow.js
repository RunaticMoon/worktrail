/*
 * Keyboard-only regression for a fresh, isolated DEBUG UIReview fixture.
 *   osascript -l JavaScript scripts/maclab/keyboard-flow.js --fixture many
 * Optional: --action capture|main|search (default all), --entry global|command
 * (default command). Global opens from verified foreground TextEdit using the
 * fixture's Ctrl+Option+Space / Ctrl+Option+D shortcuts.
 * Start exactly one After.app --args --ui-test-fixture many, with no open panel
 * or sheet. The actual target PID's launch arguments are checked before AX reads
 * or input. Native AX is read-only; all UI interaction uses System Events keys.
 * App activation and synthetic clipboard writes are the only other mutations.
 * The search test edits one known synthetic memo. No Secret values are read.
 * No AX label, record body, process arguments, or clipboard text is printed.
 * Output contains stage names, booleans, and sanitized error codes only.
 * Static validation is not evidence of a successful run on macOS.
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
    var stage = 'fixture_guard', appAX, reviewPID, running, events, entryMethod;
    var started = Number($.NSProcessInfo.processInfo.systemUptime);
    var result = { ok: false, tests: {}, observations: {
        keyboardOnly: true, fixtureMemoChanged: false, foregroundUsesSystemEvents: true
    } };
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
    function isCollectionRole(role) {
        return ['AXOutline', 'AXTable', 'AXList', 'AXScrollArea'].indexOf(role) >= 0;
    }
    function taskList() {
        var matches = [];
        walk(mainWindow(), function (node, role) {
            if (isCollectionRole(role) && keyboardLabel(node) === '업무 목록') matches.push(node);
            return false;
        }, false);
        // SwiftUI may label both a native list and its scroll container. Accept
        // the deepest node only when every match belongs to its ancestor chain;
        // unrelated controls with the same label must not satisfy this check.
        var candidates = matches.filter(function (candidate) {
            return matches.every(function (other) {
                var ancestor = candidate;
                for (var depth = 0; ancestor && depth < 35; depth += 1) {
                    if (keyboardSame(ancestor, other)) return true;
                    ancestor = keyboardAXRead(ancestor, 'AXParent');
                }
                return false;
            });
        });
        return candidates.length === 1 ? candidates[0] : null;
    }
    function sameFocusedCollection(focused, target) {
        // SwiftUI can export different AX proxies for its focus owner and its
        // tree node. Match only a uniquely labelled collection of the same role
        // in the SAME native window; never infer focus from selection.
        var targetRole = keyboardText(target, 'AXRole');
        if (!isCollectionRole(targetRole) || keyboardText(focused, 'AXRole') !== targetRole) return false;
        var label = keyboardLabel(target);
        if (!label || keyboardLabel(focused) !== label) return false;
        var focusedWindow = owningWindow(focused), targetWindow = owningWindow(target);
        if (!keyboardSame(focusedWindow, targetWindow)) return false;
        var focusedID = keyboardText(focused, 'AXIdentifier'), targetID = keyboardText(target, 'AXIdentifier');
        if (focusedID && targetID && focusedID !== targetID) return false;
        var matches = 0;
        walk(targetWindow, function (node, role) {
            if (role === targetRole && keyboardLabel(node) === label) matches += 1;
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
            if (keyboardSame(focused, root) || sameFocusedCollection(focused, root)) return true;
            focused = keyboardAXRead(focused, 'AXParent');
        }
        var value = keyboardAXRead(root, 'AXFocused');
        var isFocused = value === null ? null : ObjC.unwrap(value);
        return isFocused === true || isFocused === 1;
    }
    function foregroundProcess() {
        // NSWorkspace can retain a stale frontmostApplication in a synchronous
        // JXA run without its notification run loop. Each Apple event asks the
        // window server's current System Events process state instead.
        var foreground = events.processes.whose({ frontmost: true })();
        return foreground.length === 1 ? foreground[0] : null;
    }
    function front() {
        var process = foregroundProcess();
        return process !== null && Number(process.unixId()) === reviewPID;
    }
    function frontBundle() {
        var process = foregroundProcess();
        return process !== null ? String(process.bundleIdentifier()) : '';
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
    function openPanel(title, commandCode, globalCode) {
        if (entryMethod === 'global') {
            Application('TextEdit').activate();
            waitFor(function () { return frontBundle() === 'com.apple.TextEdit'; }, 'TEXTEDIT_NOT_FOREGROUND');
            deadline();
            need(frontBundle() === 'com.apple.TextEdit', 'TEXTEDIT_LOST_FOREGROUND');
            // This fixed global-hotkey event is the only permitted exception to
            // key()'s UIReview foreground guard. No typing goes to TextEdit.
            events.keyCode(globalCode, { using: ['control down', 'option down'] });
        } else {
            key(commandCode, ['command down']);
        }
        waitFor(function () { return front() && windowNamed(title); }, 'PANEL_NOT_OPENED_IN_REVIEW_FOREGROUND');
    }
    function selectedCaptureTab(title) {
        var matches = 0, selected = false;
        walk(windowNamed('빠른 입력'), function (node, role) {
            // A native segmented Picker exports radio buttons. Older fixture
            // builds used buttons with a localized selection value. Match only
            // the exact tab label and explicit true/1 selection, never truthy
            // strings, the group's selected index, or keyboard focus.
            if (role !== 'AXRadioButton' && role !== 'AXButton') return false;
            var label = keyboardLabel(node);
            if (label !== title && label !== title + ', 초안 있음' && label !== title + ' •') return false;
            matches += 1;
            var rawValue = keyboardAXRead(node, 'AXValue');
            var rawSelected = keyboardAXRead(node, 'AXSelected');
            var value = rawValue === null ? null : ObjC.unwrap(rawValue);
            var isSelected = rawSelected === null ? null : ObjC.unwrap(rawSelected);
            selected = value === '선택됨' || value === true || value === 1 ||
                isSelected === true || isSelected === 1;
            return false;
        });
        return matches === 1 && selected;
    }
    function expectTab(title, code) {
        waitFor(function () { return selectedCaptureTab(title); }, code);
    }
    function expectSecretUnlockFocus() {
        return waitFor(function () {
            return focusInside(labelled(windowNamed('빠른 입력'), '잠금 해제', 'AXButton'));
        }, 'SECRET_UNLOCK_NOT_FOCUSED_BEFORE_TAB_SHORTCUT');
    }
    function captureFlow() {
        stage = entryMethod === 'global' ? 'capture_global_hotkey' : 'capture_command_n';
        openPanel('빠른 입력', 45, 49);
        check('captureEntryForegroundVerified', true);
        var body = waitFor(function () {
            return labelled(windowNamed('빠른 입력'), '메모 본문', 'AXTextArea');
        }, 'CAPTURE_MEMO_NOT_OPENED');
        need(keyboardText(body, 'AXValue') === '', 'NONEMPTY_CAPTURE_DRAFT_ABORTED');
        check('captureMemoFocused', waitFor(function () { return focusInside(body); }, 'MEMO_NOT_FOCUSED'));
        for (var round = 1; round <= 3; round += 1) {
            stage = 'capture_numbered_tabs_round_' + round;
            key(19, ['command down']); expectTab('업무', 'COMMAND_2_TASK_TAB_FAILED');
            check('captureTaskNativeFocusRound' + round, waitFor(function () {
                return focusInside(labelled(windowNamed('빠른 입력'), '업무 검색 또는 새 업무 이름', 'AXTextField'));
            }, 'TASK_NATIVE_SEARCH_NOT_FOCUSED'));
            key(20, ['command down']); expectTab('Secret', 'COMMAND_3_SECRET_TAB_FAILED');
            check('captureSecretUnlockFocusRound' + round, expectSecretUnlockFocus());
            key(18, ['command down']); expectTab('메모', 'COMMAND_1_MEMO_TAB_FAILED');
            check('captureMemoNativeFocusRound' + round, waitFor(function () {
                return focusInside(labelled(windowNamed('빠른 입력'), '메모 본문', 'AXTextArea'));
            }, 'MEMO_NATIVE_EDITOR_NOT_FOCUSED'));
        }
        check('captureNumberedTabs', true);
        stage = 'capture_tab_cycle';
        key(48, ['control down']); expectTab('업무', 'CONTROL_TAB_TASK_FAILED');
        key(48, ['control down']); expectTab('Secret', 'CONTROL_TAB_SECRET_FAILED');
        key(48, ['control down']); expectTab('메모', 'CONTROL_TAB_WRAP_FAILED');
        key(48, ['control down', 'shift down']); expectTab('Secret', 'REVERSE_TAB_WRAP_FAILED');
        expectSecretUnlockFocus();
        key(18, ['command down']); expectTab('메모', 'RETURN_TO_MEMO_FAILED');
        body = waitFor(function () { return labelled(windowNamed('빠른 입력'), '메모 본문', 'AXTextArea'); }, 'MEMO_BODY_MISSING');
        check('captureTabCycle', true);
        check('captureFocusAfterTabCycle', waitFor(function () { return focusInside(body); }, 'TAB_CYCLE_FOCUS_LOST'));
        stage = 'capture_tab_focus';
        key(48);
        check('captureTabMovesFocus', waitFor(function () {
            return !focusInside(body) && focusInside(windowNamed('빠른 입력'));
        }, 'TAB_DID_NOT_MOVE_FOCUS'));
        key(48, ['shift down']);
        check('captureShiftTabReturns', waitFor(function () { return focusInside(body); }, 'SHIFT_TAB_DID_NOT_RETURN'));
        check('captureTabDidNotEditBody', keyboardText(body, 'AXValue') === '');
        key(53);
        waitFor(function () { return !windowNamed('빠른 입력'); }, 'CAPTURE_ESCAPE_FAILED');
        check('captureEscapeCloses', true);
        activateMain();
    }
    function mainFlow() {
        stage = 'main_numbered_screens';
        key(19, ['command down']);
        // Native List roles vary by SwiftUI version. Match the semantic region;
        // focusInside still checks actual focus ancestry or a unique AX proxy.
        waitFor(taskList, 'COMMAND_2_TASKS_FAILED');
        key(20, ['command down']);
        waitFor(function () { return labelled(mainWindow(), '프로젝트 목록'); }, 'COMMAND_3_PROJECTS_FAILED');
        key(18, ['command down']);
        key(18, ['command down', 'option down']);
        waitFor(function () { return labelled(mainWindow(), '활동 기록 목록'); }, 'COMMAND_1_DAY_FAILED');
        check('mainNumberedScreens', true);
        stage = 'main_content_focus';
        key(19, ['command down']);
        waitFor(taskList, 'TASK_LIST_MISSING');
        key(29, ['command down']);
        check('mainSidebarFocus', waitFor(function () {
            return focusInside(labelled(mainWindow(), '사이드바')) || focusInside(labelled(mainWindow(), '업무', 'AXButton'));
        }, 'COMMAND_0_SIDEBAR_NOT_FOCUSED'));
        stage = 'main_sidebar_arrow_navigation';
        for (var navigationRound = 0; navigationRound < 3; navigationRound += 1) {
            key(125);
            waitFor(function () { return labelled(mainWindow(), '프로젝트 목록'); }, 'SIDEBAR_DOWN_PROJECTS_FAILED');
            need(focusInside(labelled(mainWindow(), '사이드바')), 'PROJECT_APPEAR_STOLE_SIDEBAR_FOCUS');
            key(126);
            waitFor(taskList, 'SIDEBAR_UP_TASKS_FAILED');
            need(focusInside(labelled(mainWindow(), '사이드바')), 'TASK_APPEAR_STOLE_SIDEBAR_FOCUS');
        }
        check('sidebarRepeatedArrowsKeepFocus', true);
        key(29, ['command down', 'shift down']);
        check('mainContentFocus', waitFor(function () { return focusInside(taskList()); }, 'COMMAND_SHIFT_0_CONTENT_NOT_FOCUSED'));
        stage = 'main_task_roundtrip';
        key(125);
        key(36);
        waitFor(function () { return sheet(mainWindow()); }, 'TASK_DETAIL_NOT_OPENED');
        key(53);
        waitFor(function () { return !sheet(mainWindow()); }, 'TASK_DETAIL_NOT_CLOSED');
        check('taskFocusRestored', waitFor(function () { return focusInside(taskList()); }, 'TASK_LIST_FOCUS_NOT_RESTORED'));
        stage = 'main_day_tabs';
        key(18, ['command down']);
        key(18, ['command down', 'option down']);
        waitFor(function () { return labelled(mainWindow(), '활동 기록 목록'); }, 'DAY_TIMELINE_MISSING');
        key(48, ['control down']);
        waitFor(function () { return labelled(mainWindow(), '하루 업무 목록'); }, 'DAY_TASK_TAB_FAILED');
        key(48, ['control down']);
        waitFor(function () { return labelled(mainWindow(), '하루 메모 목록'); }, 'DAY_MEMO_TAB_FAILED');
        key(48, ['control down', 'shift down']);
        waitFor(function () { return labelled(mainWindow(), '하루 업무 목록'); }, 'DAY_REVERSE_TAB_FAILED');
        check('dayTabs', true);
    }
    function searchSnapshot() {
        var panel = windowNamed('WorkLog 검색');
        var field = labelled(panel, '원문 검색', 'AXTextField');
        var selected = [];
        walk(panel, function (node, role) {
            if (role === 'AXButton' && keyboardText(node, 'AXValue') === '선택됨' && keyboardLabel(node).indexOf('검증 메모 ') >= 0) {
                selected.push(node);
            }
            return false;
        }, false);
        return { panel: panel, queryNode: field, query: field ? keyboardText(field, 'AXValue') : null, selected: selected, sheet: sheet(panel) };
    }
    function fixtureBody(number) {
        return '검증 메모 ' + number + ' · 업무 도중 빠르게 기록한 내용\n첫 번째 관찰: 검색 결과와 원문을 바로 연결할 수 있어야 합니다.\n두 번째 관찰: 화면 크기가 달라도 긴 한국어 문장이 잘리지 않아야 합니다.';
    }
    function editor() { return labelled(sheet(windowNamed('WorkLog 검색')), '메모 본문 편집', 'AXTextArea', true); }
    function searchFlow() {
        stage = entryMethod === 'global' ? 'search_global_hotkey' : 'search_command_f';
        openPanel('WorkLog 검색', 3, 2);
        check('searchEntryForegroundVerified', true);
        var opened = waitFor(function () { var state = searchSnapshot(); return state.queryNode ? state : null; }, 'SEARCH_PANEL_NOT_OPENED');
        need(opened.query === '' || opened.query === KEYBOARD_QUERY, 'UNEXPECTED_SEARCH_QUERY_ABORTED');
        check('searchQueryFocused', waitFor(function () { return focusInside(opened.queryNode); }, 'SEARCH_QUERY_NOT_FOCUSED'));
        pasteKnown(KEYBOARD_QUERY);
        waitFor(function () { return searchSnapshot().query === KEYBOARD_QUERY; }, 'SEARCH_QUERY_NOT_PASTED');
        delay(0.5);
        stage = 'search_result_focus';
        key(125); key(125); key(125); key(48);
        var before = waitFor(function () { var state = searchSnapshot(); return state.selected.length === 1 ? state : null; }, 'SEARCH_SELECTION_MISSING');
        check('searchTabFocusesResult', waitFor(function () { return focusInside(before.selected[0]); }, 'SEARCH_RESULT_NOT_FOCUSED'));
        var identity = keyboardLabel(before.selected[0]).match(/검증 메모 ([0-9]+)/);
        need(identity && Number(identity[1]) >= 1 && Number(identity[1]) <= 36, 'NONFIXTURE_RESULT_ABORTED');
        stage = 'search_return_source';
        key(36);
        waitFor(function () { return searchSnapshot().sheet; }, 'SEARCH_RETURN_DID_NOT_OPEN_SOURCE');
        check('searchReturnOpensSource', true);
        stage = 'search_command_e_edit';
        key(14, ['command down']);
        var body = waitFor(editor, 'COMMAND_E_EDITOR_NOT_OPENED');
        check('memoEditorFocused', waitFor(function () { return focusInside(body); }, 'MEMO_EDITOR_NOT_FOCUSED'));
        var original = keyboardText(body, 'AXValue');
        need(original === fixtureBody(Number(identity[1])), 'NONFIXTURE_MEMO_BODY_ABORTED');
        var updated = original + KEYBOARD_MARKER;
        pasteKnown(updated);
        waitFor(function () { var current = editor(); return current && keyboardText(current, 'AXValue') === updated; }, 'MEMO_EDIT_NOT_ENTERED');
        stage = 'memo_command_s_save';
        key(1, ['command down']);
        waitFor(function () { return !editor() && labelled(sheet(windowNamed('WorkLog 검색')), '편집 ⌘E', 'AXButton', true); }, 'COMMAND_S_DID_NOT_FINISH_EDIT');
        result.observations.fixtureMemoChanged = true;
        check('memoCommandSSaves', true);
        key(53);
        waitFor(function () { return !searchSnapshot().sheet; }, 'MEMO_ESCAPE_DID_NOT_RETURN');
        stage = 'search_focus_restore';
        var after = waitFor(function () {
            var state = searchSnapshot();
            return state.selected.length === 1 && focusInside(state.selected[0]) ? state : null;
        }, 'SEARCH_RESULT_FOCUS_NOT_RESTORED');
        check('searchQueryPreserved', after.query === KEYBOARD_QUERY);
        check('searchSelectionPreserved', keyboardLabel(after.selected[0]).indexOf('검증 메모 ' + identity[1] + ' ·') >= 0);
        check('searchResultFocusRestored', true);
        stage = 'search_direct_edit_persistence';
        key(14, ['command down']);
        body = waitFor(editor, 'RESULT_COMMAND_E_DID_NOT_OPEN_EDITOR');
        check('memoEditPersisted', keyboardText(body, 'AXValue') === updated);
        key(53);
        waitFor(function () { return !searchSnapshot().sheet; }, 'UNCHANGED_EDITOR_ESCAPE_FAILED');
        key(53);
        waitFor(function () { return !windowNamed('WorkLog 검색'); }, 'SEARCH_ESCAPE_DID_NOT_CLOSE_PANEL');
        check('searchEscapeCloses', true);
    }

    try {
        need(option('--fixture', '') === 'many', 'REQUIRE_EXPLICIT_MANY_FIXTURE');
        var action = option('--action', 'all');
        need(['all', 'capture', 'main', 'search'].indexOf(action) >= 0, 'INVALID_ACTION');
        entryMethod = option('--entry', 'command');
        need(['global', 'command'].indexOf(entryMethod) >= 0, 'INVALID_ENTRY_METHOD');
        result.entryMethod = entryMethod;
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
        if (action === 'all' || action === 'capture') captureFlow();
        if (action === 'all' || action === 'main') mainFlow();
        if (action === 'all' || action === 'search') searchFlow();
        result.ok = true;
        result.stage = 'complete';
        return JSON.stringify(result);
    } catch (error) {
        result.stage = stage;
        result.error = error.keyboardCode || 'NATIVE_AX_OR_AUTOMATION_FAILURE';
        throw new Error(JSON.stringify(result));
    }
}
