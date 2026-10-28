/*
 * osascript -l JavaScript scripts/maclab/meeting-ui-check.js --fixture many
 * Requires the DEBUG dev.worklog.UIReview bundle launched with the same fixture.
 * Uses only fake records. Never presses record, login, model download or AI buttons.
 * Creates/edits/deletes/restores one synthetic meeting. Logs assertions, not content.
 */
ObjC.import('AppKit');
ObjC.import('ApplicationServices');
ObjC.import('CoreGraphics');

var deadline, stage = 'initialization', appAX, windowAX, running, pid, events, keyboardRoute = true;
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
function coordinate(node, attribute, component) {
    var description = string(ObjC.castRefToObject($.CFCopyDescription(read(node, attribute))));
    var names = component === 'width' ? '(?:width|w)' : component === 'height' ? '(?:height|h)' : component;
    var match = description.match(new RegExp('\\b' + names + '\\s*[:=]\\s*(-?[0-9]+(?:\\.[0-9]+)?)'));
    requireThat(match, 'BOUNDS_UNREADABLE'); return Number(match[1]);
}
function revealEditor(node) {
    var parent = read(node, 'AXParent'), outer = null;
    for (var i=0; parent && i<15; i++) {
        if (string(read(parent,'AXRole')) === 'AXScrollArea' && read(parent,'AXVerticalScrollBar')) outer=parent;
        parent=read(parent,'AXParent');
    }
    if (!outer) return;
    var bar=read(outer,'AXVerticalScrollBar');
    for (var attempt=0; attempt<20; attempt++) {
        var center=coordinate(node,'AXPosition','y')+coordinate(node,'AXSize','height')/2;
        var top=coordinate(outer,'AXPosition','y'), bottom=top+coordinate(outer,'AXSize','height');
        if(center>=top+8 && center<bottom-8)return;
        var current=Number(ObjC.unwrap(read(bar,'AXValue')));
        var next=Math.max(0,Math.min(1,current+(center>=bottom?0.12:-0.12)));
        requireThat(next!==current,'EDITOR_CANNOT_SCROLL');
        requireThat(Number($.AXUIElementSetAttributeValue(bar,$('AXValue'),$(next)))===0,'SCROLL_FAILED');delay(0.08);
    }
}
function pointerFocus(node) {
    var x = coordinate(node, 'AXPosition', 'x'), y = coordinate(node, 'AXPosition', 'y');
    var width = coordinate(node, 'AXSize', 'width'), height = coordinate(node, 'AXSize', 'height');
    var wx = coordinate(windowAX, 'AXPosition', 'x'), wy = coordinate(windowAX, 'AXPosition', 'y');
    var ww = coordinate(windowAX, 'AXSize', 'width'), wh = coordinate(windowAX, 'AXSize', 'height');
    requireThat(x + width/2 >= wx && x + width/2 < wx + ww && y + height/2 >= wy && y + height/2 < wy + wh, 'EDITOR_OUTSIDE_WINDOW');
    var point = $.CGPointMake(x + width/2, y + height/2);
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseDown, point, $.kCGMouseButtonLeft));
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseUp, point, $.kCGMouseButtonLeft));
    delay(0.2);
}
function edit(node, text) {
    assertFront(); requireThat(node, 'EDITOR_NOT_FOUND');
    $.AXUIElementPerformAction(node, $('AXScrollToVisible'));
    revealEditor(node);
    requireThat(Number($.AXUIElementSetAttributeValue(node, $('AXFocused'), $.kCFBooleanTrue)) === 0, 'FOCUS_FAILED');
    delay(0.2);
    if (!Boolean(ObjC.unwrap(read(node, 'AXFocused')))) pointerFocus(node);
    events.keyCode(0, {using: ['command down']}); delay(0.1);
    events.keystroke(text); delay(0.15);
    requireThat(string(read(node, 'AXValue')) === text, 'KEYBOARD_EDIT_FAILED');
}
function openMeetings() {
    stage = 'keyboard_navigation'; assertFront();
    events.keyCode(25, {using: ['command down']}); // Cmd+9: graph.
    delay(0.15);
    events.keyCode(29, {using: ['command down']}); // Cmd+0: sidebar focus.
    delay(0.5); events.keyCode(125); delay(0.5); // The next route is Meetings.
    if (!control('AXTextField', '회의록 검색')) {
        keyboardRoute = false;
        selectRow('회의록'); delay(0.3);
    }
    requireThat(control('AXTextField', '회의록 검색'), 'MEETINGS_ROUTE_MISSING');
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
    if (Number($.AXUIElementSetAttributeValue(row, $('AXSelected'), $.kCFBooleanTrue)) !== 0) pointerFocus(row);
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
        if (args.indexOf('--small') >= 0) { events.processes.whose({unixId: pid})[0].windows[0].size = [960, 640]; delay(0.3); }
        openMeetings();
        stage = 'create'; press(button('새 회의'));
        var title = 'Synthetic meeting keyboard QA';
        edit(control('AXTextField', '회의 제목'), title);
        edit(control('AXTextArea', '회의 전사 원문'), 'Synthetic transcript: release review on Friday.');
        edit(control('AXTextArea', '회의 메모'), 'Synthetic notes: verify the meeting draft.');
        requireThat(!enabled(button('전사와 메모 요약')), 'AI_ENABLED_IN_OFFLINE_FIXTURE');
        stage = 'manual_summary';
        edit(control('AXTextArea', '직접 작성 요약'), 'Synthetic manual summary without AI.');
        edit(control('AXTextArea', '직접 작성 결정사항'), 'Synthetic approved decision.');
        edit(control('AXTextArea', '직접 작성 할 일'), 'Synthetic reviewed follow-up.');
        edit(control('AXTextArea', '직접 작성 확인사항'), 'Synthetic open question.');
        stage = 'keyboard_save'; events.keystroke('s', {using: ['command down']}); delay(0.2);
        requireThat(!enabled(button('저장')), 'KEYBOARD_SAVE_NOT_PERSISTED');
        stage = 'navigation_preserves_edits';
        var notes = 'Synthetic notes: navigating keeps the edit.';
        edit(control('AXTextArea', '회의 메모'), notes);
        events.keyCode(18, {using: ['command down']}); delay(0.2); // Cmd+1: Today.
        openMeetings();
        requireThat(string(read(control('AXTextField', '회의 제목'), 'AXValue')) === title, 'SELECTION_LOST');
        requireThat(string(read(control('AXTextArea', '회의 메모'), 'AXValue')) === notes, 'EDIT_LOST_ON_NAVIGATION');
        requireThat(string(read(control('AXTextArea', '직접 작성 요약'), 'AXValue')) === 'Synthetic manual summary without AI.', 'MANUAL_SUMMARY_LOST_ON_NAVIGATION');
        requireThat(string(read(control('AXTextArea', '직접 작성 결정사항'), 'AXValue')) === 'Synthetic approved decision.', 'MANUAL_DECISION_LOST_ON_NAVIGATION');
        stage = 'review_cancel';
        press(button('업무 연결 검토…'));
        requireThat(control('AXTextField', '담당자 (미지정 가능)'), 'OPTIONAL_OWNER_FIELD_MISSING');
        requireThat(string(read(control('AXTextField', '담당자 (미지정 가능)'), 'AXValue')) === '', 'OWNER_MUST_DEFAULT_UNASSIGNED');
        press(button('취소'));
        requireThat(control('AXTextArea', '직접 작성 요약'), 'REVIEW_CANCEL_LOST_DRAFT');
        stage = 'delete'; press(button('삭제'));
        press(button('휴지통으로 이동'));
        setLibrary(true); selectRow(title);
        requireThat(button('회의록 복원'), 'SOFT_DELETE_MISSING');
        stage = 'restore'; press(button('회의록 복원'));
        requireThat(string(read(control('AXTextField', '회의 제목'), 'AXValue')) === title, 'RESTORE_TITLE_MISMATCH');
        requireThat(string(read(control('AXTextArea', '회의 메모'), 'AXValue')) === notes, 'RESTORE_NOTES_MISMATCH');
        return JSON.stringify({ok: true, fixtureArgumentsVerified: true, keyboardRoute: keyboardRoute,
            editorFocus: "accessibility-with-pointer-fallback", keyboardEditAndSave: true, navigationPreservesEdits: true, softDeleteAndRestore: true,
            manualSectionsPersisted: true, reviewedTaskCancel: true, ownerUnassigned: true,
            aiDisabled: true, microphoneUsed: false, accountAccessed: false});
    } catch (error) {
        throw new Error(JSON.stringify({ok: false, stage: stage, code: error.message, contentRedacted: true}));
    }
}
