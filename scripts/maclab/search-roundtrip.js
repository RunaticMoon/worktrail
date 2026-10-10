/*
 * Native AX search regression for the isolated DEBUG review fixture.
 * Usage: osascript -l JavaScript scripts/maclab/search-roundtrip.js --fixture many
 * Launch exactly one dev.worklog.UIReview with --ui-test-fixture many first.
 * Requires Accessibility/Automation permission and default Ctrl+Option+D hotkey.
 * The fixture flag is an explicit declaration, not proof of the app launch mode.
 *
 * Activates TextEdit, opens search, pastes the fixed synthetic query, presses
 * Down 12 times, opens the selected source with Return, and returns with Escape.
 * Clipboard is replaced; no records are edited or saved. No real data is allowed.
 * Native AX descriptions and field values are compared only in memory and never
 * printed. Output is sanitized JSON; failure throws JSON for a nonzero exit.
 *
 * The underlying native AX round trip was observed on Maclab. This persisted
 * complete script has only received static checks and needs its own Mac run.
 * Selection preservation does not prove a numeric scroll offset was preserved.
 */
ObjC.import('AppKit');
ObjC.import('ApplicationServices');

var SEARCH_REVIEW_BUNDLE = 'dev.worklog.UIReview';
var SEARCH_FAKE_QUERY = '메모';

function searchAXRead(reference, attribute) {
    var output = Ref();
    if (Number($.AXUIElementCopyAttributeValue(reference, $(attribute), output)) !== 0) return null;
    return ObjC.castRefToObject(output[0]);
}
function searchAXString(value) {
    if (value === null || value === undefined) return '';
    var unwrapped = ObjC.unwrap(value);
    return typeof unwrapped === 'string' ? unwrapped : '';
}
function searchAXArray(value) {
    if (value === null || value === undefined) return [];
    var result = [], count = Number(value.count);
    if (!isFinite(count)) throw new Error('AX_ARRAY_BRIDGE_FAILED');
    for (var index = 0; index < count; index += 1) result.push(value.objectAtIndex(index));
    return result;
}
function searchAXText(reference, attribute) {
    return searchAXString(searchAXRead(reference, attribute));
}

function run(args) {
    var stage = 'fixture_guard';
    var result = { ok: false, tests: {}, observations: { downArrowPresses: 0, numericScrollOffsetVerified: false } };
    var started = Number($.NSProcessInfo.processInfo.systemUptime);
    var events, appAX, reviewPID;
    function fail(code) { var error = new Error(code); error.searchReviewCode = code; throw error; }
    function need(truth, code) { if (!truth) fail(code); }
    function deadline() {
        if (Number($.NSProcessInfo.processInfo.systemUptime) - started > 55) fail('WORKFLOW_DEADLINE');
    }
    function frontBundle() { return searchAXString($.NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier); }
    function reviewForeground() {
        return Number($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier) === reviewPID;
    }
    function windows() { return searchAXArray(searchAXRead(appAX, 'AXWindows')); }
    function panel() {
        return windows().filter(function (window) { return searchAXText(window, 'AXTitle') === 'WorkLog 검색'; })[0] || null;
    }
    function sheets(window) { return searchAXArray(searchAXRead(window, 'AXSheets')); }
    function inspectSearch() {
        deadline();
        var window = panel();
        var snapshot = { window: window, queryNode: null, query: null, selected: [], sheets: 0 };
        if (!window) return snapshot;
        snapshot.sheets = sheets(window).length;
        var queue = [{ node: window, depth: 0 }], count = 0;
        while (queue.length && count < 900) {
            deadline();
            var item = queue.shift();
            count += 1;
            var role = searchAXText(item.node, 'AXRole');
            // A sheet is inspected only for existence; source contents stay unread.
            if (role === 'AXSheet') { snapshot.sheets += 1; continue; }
            if (role === 'AXTextField' && searchAXText(item.node, 'AXDescription') === '원문 검색') {
                snapshot.queryNode = item.node;
                snapshot.query = searchAXText(item.node, 'AXValue');
            }
            if (role === 'AXButton' && searchAXText(item.node, 'AXValue') === '선택됨') {
                snapshot.selected.push(searchAXText(item.node, 'AXDescription'));
            }
            if (item.depth < 22) {
                searchAXArray(searchAXRead(item.node, 'AXChildren')).forEach(function (child) {
                    queue.push({ node: child, depth: item.depth + 1 });
                });
            }
        }
        need(queue.length === 0, 'AX_SEARCH_TRAVERSAL_LIMIT');
        return snapshot;
    }
    function waitFor(read, code) {
        var until = Number($.NSProcessInfo.processInfo.systemUptime) + 8;
        do {
            deadline();
            var value = read();
            if (value) return value;
            delay(0.15);
        } while (Number($.NSProcessInfo.processInfo.systemUptime) < until);
        fail(code);
    }
    function queryGuard(snapshot, allowEmpty) {
        need(snapshot.queryNode !== null, 'SEARCH_FIELD_MISSING');
        need(snapshot.query === SEARCH_FAKE_QUERY || (allowEmpty && snapshot.query === ''), 'UNEXPECTED_QUERY_ABORTED');
    }
    function key(code, modifiers) {
        deadline();
        need(reviewForeground(), 'REVIEW_LOST_FOREGROUND');
        events.keyCode(code, { using: modifiers || [] });
    }
    function check(name, value) {
        result.tests[name] = Boolean(value);
        need(value, 'ASSERTION_' + name);
    }

    try {
        var fixtureIndex = args.indexOf('--fixture');
        need(fixtureIndex >= 0 && args[fixtureIndex + 1] === 'many', 'REQUIRE_EXPLICIT_MANY_FIXTURE');
        stage = 'review_bundle';
        var apps = searchAXArray($.NSWorkspace.sharedWorkspace.runningApplications).filter(function (app) {
            return searchAXString(app.bundleIdentifier) === SEARCH_REVIEW_BUNDLE;
        });
        need(apps.length === 1, 'EXACTLY_ONE_REVIEW_APP_REQUIRED');
        reviewPID = Number(apps[0].processIdentifier);
        appAX = $.AXUIElementCreateApplication(reviewPID);
        $.AXUIElementSetMessagingTimeout(appAX, 0.6);
        var initialWindows = windows();
        need(initialWindows.length > 0, 'REVIEW_WINDOW_MISSING');
        initialWindows.forEach(function (window) {
            need(searchAXText(window, 'AXTitle') !== '빠른 입력', 'CLOSE_CAPTURE_FIRST');
            need(searchAXText(window, 'AXRole') !== 'AXSheet' && sheets(window).length === 0, 'CLOSE_EXISTING_SHEET_FIRST');
        });
        var existing = inspectSearch();
        if (existing.window) queryGuard(existing, true);
        events = Application('System Events');

        stage = 'global_search_hotkey';
        Application('TextEdit').activate();
        waitFor(function () { return frontBundle() === 'com.apple.TextEdit'; }, 'TEXTEDIT_NOT_ACTIVE');
        events.keyCode(2, { using: ['control down', 'option down'] });
        var opened = waitFor(function () {
            var snapshot = inspectSearch();
            return snapshot.queryNode && reviewForeground() ? snapshot : null;
        }, 'SEARCH_NOT_OPENED');
        queryGuard(opened, true);
        var focused = searchAXRead(opened.queryNode, 'AXFocused');
        check('queryFocusedOnOpen', focused !== null && Boolean(ObjC.unwrap(focused)));

        stage = 'synthetic_query';
        var clipboard = $.NSPasteboard.generalPasteboard;
        clipboard.clearContents;
        need(Boolean(clipboard.setStringForType($(SEARCH_FAKE_QUERY), $.NSPasteboardTypeString)), 'SYNTHETIC_PASTE_FAILED');
        key(0, ['command down']);
        key(9, ['command down']);
        waitFor(function () { return inspectSearch().query === SEARCH_FAKE_QUERY; }, 'QUERY_NOT_PASTED');
        // Let the local search debounce complete before twelve keyboard moves.
        delay(0.5);

        stage = 'select_later_result';
        queryGuard(inspectSearch(), false);
        for (var index = 0; index < 12; index += 1) {
            key(125);
            result.observations.downArrowPresses += 1;
            delay(0.07);
        }
        var before = waitFor(function () {
            var snapshot = inspectSearch();
            return snapshot.selected.length === 1 ? snapshot : null;
        }, 'SELECTED_RESULT_MISSING');
        queryGuard(before, false);
        need(before.selected[0].length > 0 && before.selected[0].indexOf(SEARCH_FAKE_QUERY) >= 0, 'SYNTHETIC_SELECTION_MISMATCH');

        stage = 'open_source';
        key(36);
        var source = waitFor(function () {
            var snapshot = inspectSearch();
            return snapshot.sheets > 0 ? snapshot : null;
        }, 'SOURCE_SHEET_NOT_OPENED');
        check('sourceOpened', source.sheets > 0);

        stage = 'return_to_search';
        key(53);
        var after = waitFor(function () {
            var snapshot = inspectSearch();
            return snapshot.window && snapshot.sheets === 0 && snapshot.queryNode ? snapshot : null;
        }, 'SEARCH_NOT_RESTORED');
        check('returned', after.sheets === 0 && reviewForeground());
        check('queryPreserved', before.query === SEARCH_FAKE_QUERY && after.query === before.query);
        check('selectionPreserved', after.selected.length === 1 && after.selected[0] === before.selected[0]);
        result.observations.scrollEvidence = 'Selection only; no numeric scrollbar offset assertion.';
        result.ok = true;
        result.stage = 'complete';
        return JSON.stringify(result);
    } catch (error) {
        result.stage = stage;
        result.error = error.searchReviewCode || 'NATIVE_AX_OR_AUTOMATION_FAILURE';
        throw new Error(JSON.stringify(result));
    }
}
