/*
 * Synthetic report workflow for the DEBUG Maclab review app.
 * Usage: osascript -l JavaScript scripts/maclab/report-flow.js --fixture many inspect
 * Actions: open, inspect, edit, save, plan, copy, run (all steps).
 * Uses native Accessibility calls; System Events is used only for Cmd+S / paste.
 * No report body, clipboard contents, arbitrary AX values, or native errors are logged.
 * Linux: syntax checked only. Each action still needs a real Mac execution receipt.
 */
ObjC.import('AppKit');
ObjC.import('ApplicationServices');

var marker = 'UI review synthetic report edit 2026-10-10';
var stage = 'initialize';
var processAX, windowAX, runningApp, events, pid;
var deadline, started, reads = 0, visited = 0;

function now() { return Number($.NSProcessInfo.processInfo.systemUptime); }
function fail(code) { var error = new Error(code); error.reviewCode = code; throw error; }
function requireThat(condition, code) { if (!condition) fail(code); }
function checkTime() { if (now() > deadline) fail('ACTION_DEADLINE_EXCEEDED'); }
function argument(args, name, fallback) {
    var index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : fallback;
}
function read(node, name) {
    checkTime(); reads += 1;
    var result = Ref();
    return Number($.AXUIElementCopyAttributeValue(node, $(name), result)) === 0 ? result[0] : null;
}
function string(value) {
    if (value === null || value === undefined) return '';
    try { var unwrapped = ObjC.unwrap(value); return typeof unwrapped === 'string' ? unwrapped : ''; }
    catch (_) { return ''; }
}
function boolean(value) {
    if (value === null || value === undefined) return null;
    try { return Boolean(ObjC.unwrap(value)); } catch (_) { return null; }
}
function array(value) {
    if (value === null || value === undefined) return [];
    var result = [];
    try {
        var count = Number(value.count);
        for (var index = 0; index < count; index += 1) result.push(value.objectAtIndex(index));
    } catch (_) {}
    return result;
}
function scan(wants, limit) {
    var found = {}, queue = [{ node: windowAX, parents: [] }], remaining = Object.keys(wants).length;
    var count = 0;
    while (queue.length && count < (limit || 180) && remaining > 0) {
        checkTime(); var item = queue.shift(); count += 1; visited += 1;
        item.role = string(read(item.node, 'AXRole'));
        // Read labels only for roles that can match a requested control.
        if (['AXButton', 'AXPopUpButton', 'AXTextArea', 'AXDisclosureTriangle', 'AXCheckBox', 'AXStaticText'].indexOf(item.role) >= 0) {
            item.label = string(read(item.node, 'AXTitle')) + ' ' + string(read(item.node, 'AXDescription'));
            if (item.role === 'AXStaticText') item.label += ' ' + string(read(item.node, 'AXValue')).slice(0, 120);
            Object.keys(wants).forEach(function (key) {
                if (!found[key] && wants[key](item)) { found[key] = item; remaining -= 1; }
            });
        }
        if (item.parents.length < 16) {
            array(read(item.node, 'AXChildren')).forEach(function (child) {
                queue.push({ node: child, parents: item.parents.concat([item.node]) });
            });
        }
    }
    return found;
}
function button(title) {
    return function (item) { return item.role === 'AXButton' && item.label.indexOf(title) >= 0; };
}
function reportControls() {
    return scan({
        editor: function (item) { return item.role === 'AXTextArea'; },
        copy: button('본문 복사'), save: button('저장'), confirm: button('보고서 확정')
    });
}
function assertFront() {
    checkTime();
    requireThat(Number($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier) === pid, 'REVIEW_APP_LOST_FOCUS');
    requireThat(array(read(windowAX, 'AXSheets')).length === 0, 'DISMISS_SHEET_FIRST');
}
function perform(node, action) {
    assertFront(); checkTime();
    requireThat(Number($.AXUIElementPerformAction(node, $(action || 'AXPress'))) === 0, 'AX_ACTION_REJECTED');
}
function activate() {
    runningApp.activateWithOptions($.NSApplicationActivateIgnoringOtherApps);
    delay(0.2); assertFront();
}
function setClipboard(text) {
    $.NSPasteboard.generalPasteboard.clearContents;
    requireThat(Boolean($.NSPasteboard.generalPasteboard.setStringForType($(text), $.NSPasteboardTypeString)), 'PASTEBOARD_WRITE_FAILED');
}
function getClipboard() {
    return string($.NSPasteboard.generalPasteboard.stringForType($.NSPasteboardTypeString));
}
function isEnabled(item) { return item && boolean(read(item.node, 'AXEnabled')) === true; }
function reportValue(item) {
    requireThat(item && item.role === 'AXTextArea', 'REPORT_EDITOR_NOT_FOUND');
    return string(read(item.node, 'AXValue'));
}
function readyControls() {
    var controls = reportControls();
    requireThat(controls.editor && controls.copy && controls.save && controls.confirm, 'SELECT_WEEKLY_REPORT_FIRST');
    return controls;
}
function openReport() {
    stage = 'open'; activate();
    // Click the sidebar's explicit route; Cmd+4 alone can fail without a key main window.
    var route = scan({ route: button('주간보고') }, 90).route;
    requireThat(route, 'WEEKLY_SIDEBAR_BUTTON_NOT_FOUND');
    perform(route.node); delay(0.3);
    readyControls(); return { weeklyOpened: true };
}
function editReport() {
    stage = 'edit'; assertFront();
    var controls = readyControls(), current = reportValue(controls.editor);
    var updated = current.indexOf(marker) >= 0 ? current : current + '\n' + marker;
    var result = 0;
    if (updated !== current) {
        result = Number($.AXUIElementSetAttributeValue(controls.editor.node, $('AXValue'), $(updated)));
        delay(0.15);
        if (result !== 0 || reportValue(controls.editor) !== updated) {
            requireThat(Number($.AXUIElementSetAttributeValue(controls.editor.node, $('AXFocused'), $.kCFBooleanTrue)) === 0, 'EDITOR_FOCUS_FAILED');
            setClipboard(updated);
            events.keystroke('a', { using: ['command down'] });
            events.keystroke('v', { using: ['command down'] });
            delay(0.2);
        }
    }
    requireThat(reportValue(controls.editor) === updated, 'REPORT_EDIT_NOT_APPLIED');
    return { fakeLinePresent: true };
}
function saveReport() {
    stage = 'save'; assertFront();
    var controls = readyControls();
    requireThat(reportValue(controls.editor).indexOf(marker) >= 0, 'EDIT_REPORT_FIRST');
    // Make the report editor the keyboard target before invoking the native shortcut.
    $.AXUIElementSetAttributeValue(controls.editor.node, $('AXFocused'), $.kCFBooleanTrue);
    events.keystroke('s', { using: ['command down'] }); delay(0.3);
    controls = readyControls();
    requireThat(!isEnabled(controls.save) && isEnabled(controls.confirm), 'REPORT_NOT_SAVED');
    requireThat(reportValue(controls.editor).indexOf(marker) >= 0, 'SAVED_LINE_MISSING');
    return { saved: true, editPreserved: true };
}
function openPlan() {
    stage = 'plan'; assertFront();
    var result = scan({
        candidates: button('후보 생성'),
        disclosure: function (item) { return item.label.indexOf('이번 주 계획 검토') >= 0; }
    });
    if (result.candidates) return { planOpened: true, alreadyExpanded: true };
    requireThat(result.disclosure, 'PLAN_DISCLOSURE_NOT_FOUND');
    var target = result.disclosure.node;
    if (['AXDisclosureTriangle', 'AXButton'].indexOf(result.disclosure.role) < 0) {
        var parents = result.disclosure.parents.slice().reverse();
        for (var index = 0; index < parents.length; index += 1) {
            var candidates = array(read(parents[index], 'AXChildren'));
            var triangle = candidates.filter(function (child) { return string(read(child, 'AXRole')) === 'AXDisclosureTriangle'; })[0];
            if (triangle) { target = triangle; break; }
        }
    }
    // This action may be unsupported on the label; its failure is harmless.
    $.AXUIElementPerformAction(target, $('AXScrollToVisible'));
    perform(target); delay(0.2);
    requireThat(scan({ candidates: button('후보 생성') }).candidates, 'PLAN_DID_NOT_EXPAND');
    return { planOpened: true, planDataChanged: false };
}
function copyReport() {
    stage = 'copy'; assertFront();
    var controls = readyControls(), expected = reportValue(controls.editor);
    requireThat(expected.indexOf(marker) >= 0, 'EDIT_REPORT_FIRST');
    requireThat(!isEnabled(controls.save) && isEnabled(controls.confirm), 'SAVE_REPORT_FIRST');
    setClipboard('worklog-review-copy-pending');
    perform(controls.copy.node); delay(0.15);
    requireThat(getClipboard() === expected, 'COPIED_BODY_MISMATCH');
    var after = readyControls();
    requireThat(isEnabled(after.confirm) && !isEnabled(after.save) && reportValue(after.editor) === expected, 'COPY_CHANGED_REPORT_STATE');
    return { clipboardMatchesEditedBody: true, copyDidNotConfirm: true, stillSavedAndEditable: true,
        copiedWithoutAnsweringQuestions: true, pendingQuestionSkipTested: false };
}
function inspectReport() {
    stage = 'inspect'; var controls = reportControls();
    return { editorPresent: Boolean(controls.editor), copyPresent: Boolean(controls.copy),
        savePresent: Boolean(controls.save), confirmationPresent: Boolean(controls.confirm),
        fakeLinePresent: Boolean(controls.editor && reportValue(controls.editor).indexOf(marker) >= 0) };
}
function run(args) {
    started = now(); deadline = started + 12;
    try {
        requireThat(['few', 'many'].indexOf(argument(args, '--fixture', '')) >= 0, 'EXPLICIT_SYNTHETIC_FIXTURE_REQUIRED');
        var matches = array($.NSWorkspace.sharedWorkspace.runningApplications).filter(function (app) {
            return string(app.bundleIdentifier) === 'dev.worklog.UIReview';
        });
        requireThat(matches.length === 1, 'EXACTLY_ONE_REVIEW_APP_REQUIRED');
        runningApp = matches[0]; pid = Number(runningApp.processIdentifier);
        processAX = $.AXUIElementCreateApplication(pid);
        $.AXUIElementSetMessagingTimeout(processAX, 0.8);
        var windows = array(read(processAX, 'AXWindows'));
        windowAX = windows.filter(function (item) { return string(read(item, 'AXSubrole')) === 'AXStandardWindow'; })[0];
        requireThat(windowAX, 'REVIEW_MAIN_WINDOW_NOT_FOUND');
        events = Application('System Events'); activate();
        var actions = ['open', 'inspect', 'edit', 'save', 'plan', 'copy', 'run'];
        var action = args.filter(function (item) { return actions.indexOf(item) >= 0; })[0] || 'inspect';
        // Prefer separate commands; run has a bounded aggregate deadline as well.
        deadline = started + (action === 'run' ? 25 : 12);
        var output = { ok: true, action: action, bundleVerified: true };
        if (action === 'run') {
            output.open = openReport(); output.edit = editReport(); output.save = saveReport();
            output.plan = openPlan(); output.copy = copyReport();
        } else {
            if (action === 'open') output.open = openReport();
            if (action === 'inspect') output.inspect = inspectReport();
            if (action === 'edit') output.edit = editReport();
            if (action === 'save') output.save = saveReport();
            if (action === 'plan') output.plan = openPlan();
            if (action === 'copy') output.copy = copyReport();
        }
        output.durationMs = Math.round((now() - started) * 1000);
        output.axReads = reads; output.visitedNodes = visited;
        return JSON.stringify(output);
    } catch (error) {
        return JSON.stringify({ ok: false, stage: stage, code: error.reviewCode || 'NATIVE_AX_OPERATION_FAILED',
            durationMs: Math.round((now() - started) * 1000), axReads: reads, visitedNodes: visited,
            contentRedacted: true });
    }
}
