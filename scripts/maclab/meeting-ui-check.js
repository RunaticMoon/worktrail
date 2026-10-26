/*
 * osascript -l JavaScript scripts/maclab/meeting-ui-check.js --fixture many
 * Requires the DEBUG dev.worklog.UIReview bundle launched with the same fixture.
 * Uses only fake records. Never presses record, login, model download or AI buttons.
 * Creates/edits/deletes/restores one synthetic meeting. Logs assertions, not content.
 */
ObjC.import('AppKit');
ObjC.import('ApplicationServices');
ObjC.import('CoreGraphics');

var deadline, stage = 'initialization', appAX, windowAX, running, pid, events;
function now() { return Number($.NSProcessInfo.processInfo.systemUptime); }
function requireThat(condition, code) { if (!condition) throw new Error(code); }
function read(node, name) {
    requireThat(now() < deadline, 'DEADLINE_EXCEEDED');
    var result = Ref();
    if (Number($.AXUIElementCopyAttributeValue(node, $(name), result)) !== 0) return null;
    try { return ObjC.castRefToObject(result[0]); } catch (_) { return null; }
}
function string(value) {
    try { var result = ObjC.unwrap(value); return typeof result === 'string' ? result : ''; }
    catch (_) { return ''; }
}
function array(value) {
    var result = [];
    if (!value) return result;
    for (var index = 0; index < Number(value.count); index += 1) result.push(value.objectAtIndex(index));
    return result;
}
function scan(predicate) {
    var queue = [windowAX].concat(array(read(windowAX, 'AXSheets'))), seen = 0;
    while (queue.length && seen < 650) {
        var node = queue.shift(); seen += 1;
        var role = string(read(node, 'AXRole'));
        var label = string(read(node, 'AXTitle')) + ' ' + string(read(node, 'AXDescription')) + ' ' + string(read(node, 'AXPlaceholderValue'));
        if (predicate(node, role, label)) return node;
        queue = queue.concat(array(read(node, 'AXChildren')));
    }
    return null;
}
function control(role, label) {
    return scan(function (_, r, text) { return r === role && text.indexOf(label) >= 0; });
}
function button(label) { return control('AXButton', label); }
function assertFront() {
    requireThat(Number($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier) === pid, 'REVIEW_APP_LOST_FOCUS');
}
function press(node) {
    assertFront(); requireThat(node, 'CONTROL_NOT_FOUND');
    $.AXUIElementPerformAction(node, $('AXScrollToVisible'));
    requireThat(Number($.AXUIElementPerformAction(node, $('AXPress'))) === 0, 'PRESS_FAILED');
    delay(0.15);
}
function enabled(node) { return node && Boolean(ObjC.unwrap(read(node, 'AXEnabled'))); }
function edit(node, text) {
    assertFront(); requireThat(node, 'EDITOR_NOT_FOUND');
    $.AXUIElementPerformAction(node, $('AXScrollToVisible'));
    requireThat(Number($.AXUIElementSetAttributeValue(node, $('AXFocused'), $.kCFBooleanTrue)) === 0, 'FOCUS_FAILED');
    events.keystroke('a', {using: ['command down']});
    events.keystroke(text); delay(0.15);
    requireThat(string(read(node, 'AXValue')) === text, 'KEYBOARD_EDIT_FAILED');
}
function openMeetings() {
    stage = 'keyboard_navigation'; assertFront();
    events.keyCode(25, {using: ['command down']}); // Cmd+9: graph.
    delay(0.15);
    events.keyCode(29, {using: ['command down']}); // Cmd+0: sidebar focus.
    delay(0.15); events.keyCode(125); delay(0.25); // The next route is Meetings.
    requireThat(control('AXTextField', '회의록 검색'), 'MEETINGS_KEYBOARD_ROUTE_MISSING');
}
function setLibrary(deleted) {
    var radios = [];
    scan(function (node, role, label) {
        if (role === 'AXRadioButton') radios.push({node: node, label: label});
        return false;
    });
    var match = radios.filter(function (item) { return item.label.indexOf(deleted ? '휴지통' : '회의록') >= 0; })[0];
    requireThat(match, 'LIBRARY_SEGMENT_NOT_FOUND'); press(match.node);
}
function selectRow(title) {
    var row = scan(function (node, role) {
        if (role !== 'AXRow') return false;
        var children = array(read(node, 'AXChildren')), pending = children.slice(), count = 0;
        while (pending.length && count < 30) {
            var child = pending.shift(); count += 1;
            if (string(read(child, 'AXValue')) === title || string(read(child, 'AXTitle')) === title) return true;
            pending = pending.concat(array(read(child, 'AXChildren')));
        }
        return false;
    });
    requireThat(row, 'MEETING_ROW_NOT_FOUND');
    requireThat(Number($.AXUIElementSetAttributeValue(row, $('AXSelected'), $.kCFBooleanTrue)) === 0, 'ROW_SELECT_FAILED');
    delay(0.2);
}
function run(args) {
    deadline = now() + 45;
    try {
        var index = args.indexOf('--fixture');
        requireThat(index >= 0 && args[index + 1] === 'many', 'EXPLICIT_MANY_FIXTURE_REQUIRED');
        var session = ObjC.castRefToObject($.CGSessionCopyCurrentDictionary());
        requireThat(!session || !Boolean(ObjC.unwrap(session.objectForKey('CGSSessionScreenIsLocked'))), 'MAC_SCREEN_LOCKED');
        requireThat(Boolean($.AXIsProcessTrusted()), 'ACCESSIBILITY_PERMISSION_REQUIRED');
        var matches = array($.NSWorkspace.sharedWorkspace.runningApplications).filter(function (app) {
            return string(app.bundleIdentifier) === 'dev.worklog.UIReview';
        });
        requireThat(matches.length === 1, 'EXACTLY_ONE_REVIEW_APP_REQUIRED');
        running = matches[0]; pid = Number(running.processIdentifier);
        var shell = Application.currentApplication(); shell.includeStandardAdditions = true;
        var command = shell.doShellScript('/bin/ps -p ' + pid + ' -o args=');
        requireThat(/--ui-test-fixture\s+many(?:\s|$)/.test(command), 'SYNTHETIC_PROCESS_ARGUMENTS_REQUIRED');
        appAX = $.AXUIElementCreateApplication(pid);
        $.AXUIElementSetMessagingTimeout(appAX, 0.8);
        windowAX = array(read(appAX, 'AXWindows')).filter(function (node) {
            return string(read(node, 'AXSubrole')) === 'AXStandardWindow';
        })[0];
        requireThat(windowAX, 'MAIN_WINDOW_MISSING');
        events = Application('System Events');
        running.activateWithOptions($.NSApplicationActivateIgnoringOtherApps); delay(0.2);
        openMeetings();
        stage = 'create'; press(button('새 회의'));
        var title = 'Synthetic meeting keyboard QA';
        edit(control('AXTextField', '회의 제목'), title);
        edit(control('AXTextArea', '회의 전사 원문'), 'Synthetic transcript: release review on Friday.');
        edit(control('AXTextArea', '회의 메모'), 'Synthetic notes: verify the meeting draft.');
        requireThat(!enabled(button('전사와 메모 요약')), 'AI_ENABLED_IN_OFFLINE_FIXTURE');
        stage = 'keyboard_save'; events.keystroke('s', {using: ['command down']}); delay(0.2);
        requireThat(!enabled(button('저장')), 'KEYBOARD_SAVE_NOT_PERSISTED');
        stage = 'navigation_preserves_edits';
        var notes = 'Synthetic notes: navigating keeps the edit.';
        edit(control('AXTextArea', '회의 메모'), notes);
        events.keyCode(18, {using: ['command down']}); delay(0.2); // Cmd+1: Today.
        openMeetings();
        requireThat(string(read(control('AXTextField', '회의 제목'), 'AXValue')) === title, 'SELECTION_LOST');
        requireThat(string(read(control('AXTextArea', '회의 메모'), 'AXValue')) === notes, 'EDIT_LOST_ON_NAVIGATION');
        stage = 'delete'; press(button('삭제'));
        press(button('휴지통으로 이동'));
        setLibrary(true); selectRow(title);
        requireThat(button('회의록 복원'), 'SOFT_DELETE_MISSING');
        stage = 'restore'; press(button('회의록 복원'));
        requireThat(string(read(control('AXTextField', '회의 제목'), 'AXValue')) === title, 'RESTORE_TITLE_MISMATCH');
        requireThat(string(read(control('AXTextArea', '회의 메모'), 'AXValue')) === notes, 'RESTORE_NOTES_MISMATCH');
        return JSON.stringify({ok: true, fixtureArgumentsVerified: true, keyboardRoute: true,
            keyboardEditAndSave: true, navigationPreservesEdits: true, softDeleteAndRestore: true,
            aiDisabled: true, microphoneUsed: false, accountAccessed: false});
    } catch (error) {
        throw new Error(JSON.stringify({ok: false, stage: stage, code: error.message, contentRedacted: true}));
    }
}
