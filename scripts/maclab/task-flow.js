/* DEBUG fake data only. Run after After.app --args --ui-test-fixture many:
 * osascript -l JavaScript scripts/maclab/task-flow.js
 * It never completes/cancels a task or changes projects; it adds one fake activity.
 * Native AX traversal avoids per-node AppleEvents; keyboard paste stays native.
 * Output contains boolean assertions and a stage identifier, not app data.
 * A failed assertion throws sanitized JSON so osascript exits nonzero.
 * Use a fresh fixture; an existing sheet or nonempty composer aborts the run.
 */
ObjC.import('AppKit');
ObjC.import('ApplicationServices');
var reviewRunningApp, reviewPID, reviewAX;
function axRead(reference, attribute) {
    var output = Ref();
    if (Number($.AXUIElementCopyAttributeValue(reference, $(attribute), output)) !== 0) return null;
    return ObjC.castRefToObject(output[0]);
}
function axString(value) {
    if (value === null || value === undefined) return '';
    var unwrapped = ObjC.unwrap(value);
    return typeof unwrapped === 'string' ? unwrapped : '';
}
function axArray(value) {
    if (value === null || value === undefined) return [];
    var output = [], count = Number(value.count);
    if (!isFinite(count)) throw new Error('AX_ARRAY_BRIDGE_FAILED');
    for (var index = 0; index < count; index += 1) output.push(value.objectAtIndex(index));
    return output;
}
function axSet(reference, attribute, value) {
    var nativeValue = typeof value === 'boolean' ? (value ? $.kCFBooleanTrue : $.kCFBooleanFalse) : $(value);
    if (Number($.AXUIElementSetAttributeValue(reference, $(attribute), nativeValue)) !== 0) throw new Error('AX_SET_FAILED');
}
function axWrap(reference) {
    var node = {
        reference: reference,
        role: function () { return axString(axRead(reference, 'AXRole')); },
        subrole: function () { return axString(axRead(reference, 'AXSubrole')); },
        name: function () { return axString(axRead(reference, 'AXTitle')); },
        description: function () { return axString(axRead(reference, 'AXDescription')); },
        value: function () { return axString(axRead(reference, 'AXValue')); },
        enabled: function () { var value = axRead(reference, 'AXEnabled'); return value !== null && Boolean(ObjC.unwrap(value)); },
        uiElements: function () { return axArray(axRead(reference, 'AXChildren')).map(axWrap); },
        sheets: function () { return axArray(axRead(reference, 'AXSheets')).map(axWrap); },
        actions: { byName: function (action) { return { perform: function () {
            if (Number($.AXUIElementPerformAction(reference, $(action))) !== 0) throw new Error('AX_ACTION_FAILED');
        } }; } },
        attributes: { byName: function (attribute) { var property = {};
            Object.defineProperty(property, 'value', { set: function (value) { axSet(reference, attribute, value); } });
            return property;
        } }
    };
    Object.defineProperty(node, 'selected', { set: function (value) { axSet(reference, 'AXSelected', value); } });
    return node;
}
function reviewProcess() {
    var matches = axArray($.NSWorkspace.sharedWorkspace.runningApplications).filter(function (app) {
        return axString(app.bundleIdentifier) === 'dev.worklog.UIReview';
    });
    if (matches.length !== 1) throw new Error('EXACTLY_ONE_REVIEW_APP_REQUIRED');
    reviewRunningApp = matches[0]; reviewPID = Number(reviewRunningApp.processIdentifier);
    reviewAX = $.AXUIElementCreateApplication(reviewPID);
    $.AXUIElementSetMessagingTimeout(reviewAX, 0.6);
    return {
        windows: function () { return axArray(axRead(reviewAX, 'AXWindows')).map(axWrap); },
        unixId: function () { return reviewPID; },
        bundleIdentifier: function () { return axString(reviewRunningApp.bundleIdentifier); }
    };
}
function reviewIsFront() {
    return Number($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier) === reviewPID;
}
function pointerActivateMain(eventApp, nativeWindow) {
    // A shallow window lookup avoids slow per-control AppleEvents. A real pointer
    // event makes the visible main window key after a floating panel was closed.
    var apps = eventApp.processes.whose({ unixId: reviewPID })();
    if (apps.length !== 1) throw new Error('REVIEW_PROCESS_MISSING');
    var windows = apps[0].windows().filter(function (window) { return window.name() === nativeWindow.name(); });
    if (windows.length !== 1) throw new Error('AMBIGUOUS_MAIN_WINDOW');
    var position = windows[0].position(), size = windows[0].size();
    var point = $.CGPointMake(position[0] + size[0] / 2, position[1] + 12);
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseDown, point, $.kCGMouseButtonLeft));
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseUp, point, $.kCGMouseButtonLeft));
}
function nativePress(node) {
    var role = node.role();
    if (role === 'AXTextField' || role === 'AXTextArea') {
        axSet(node.reference, 'AXFocused', true); return;
    }
    if (role === 'AXRow') {
        axSet(node.reference, 'AXSelected', true); return;
    }
    node.actions.byName('AXPress').perform();
}

function run() {
    const start = Number($.NSProcessInfo.processInfo.systemUptime);
    const events = Application('System Events');
    const clipboard = $.NSPasteboard.generalPasteboard;
    const result = { ok: false, checks: {} };
    let stage = 'review_bundle';
    let process;
    let mainWindow;
    const fakeBody = 'UI 검증 진행 기록 · task-flow-' + Math.floor(start);
    function safe(read, fallback) { try { return read(); } catch (_) { return fallback; } }
    function tick() {
        if (Number($.NSProcessInfo.processInfo.systemUptime) - start > 65) throw new Error('deadline');
    }
    function pause() { tick(); delay(0.15); }
    function roots() {
        const windows = mainWindow ? [mainWindow] : process.windows();
        let sheets = [];
        windows.forEach(function (window) {
            sheets = sheets.concat(safe(function () { return window.sheets(); }, []));
        });
        return sheets.length ? sheets : windows;
    }
    function find(role, text, exact) {
        const queue = roots().map(function (node) { return { node: node, depth: 0, parents: [] }; });
        let count = 0;
        while (queue.length && count++ < 700) {
            tick();
            const item = queue.shift(), node = item.node;
            const actualRole = safe(function () { return node.role(); }, '');
            if ((!role || role === actualRole) && (!text || [
                safe(function () { return node.name(); }, ''),
                safe(function () { return node.description(); }, ''),
                actualRole === 'AXStaticText' ? safe(function () { return node.value(); }, '') : ''
            ].some(function (label) { return typeof label === 'string' && (exact ? label === text : label.indexOf(text) >= 0); }))) { node.reviewParents = item.parents; return node; }
            if (item.depth < 16) safe(function () { return node.uiElements(); }, []).forEach(function (child) {
                queue.push({ node: child, depth: item.depth + 1, parents: item.parents.concat([node]) });
            });
        }
        return null;
    }
    function need(role, text) { const node = find(role, text); if (!node) throw new Error('element_missing'); return node; }
    function activateMain() {
        $.NSRunningApplication.runningApplicationWithProcessIdentifier(process.unixId()).activateWithOptions(3);
        reviewRunningApp.activateWithOptions(3);
        safe(function () { mainWindow.actions.byName('AXRaise').perform(); }, null);
        safe(function () { mainWindow.attributes.byName('AXMain').value = true; }, null);
        safe(function () { mainWindow.attributes.byName('AXFocused').value = true; }, null);
        pointerActivateMain(events, mainWindow);
        delay(0.3);
        pause();
        if (!reviewIsFront()) throw new Error('main_activation_failed');
    }
    function click(node) {
        if (!reviewIsFront()) throw new Error('lost_foreground');
        nativePress(node);
        pause();
    }
    function key(value) {
        if (!reviewIsFront()) throw new Error('lost_foreground');
        events.keystroke(value, { using: ['command down'] }); pause();
    }
    function paste(text) {
        clipboard.clearContents;
        if (!clipboard.setStringForType($(text), $.NSPasteboardTypeString)) throw new Error('paste_failed');
        key('v');
    }
    function assert(name, truth) {
        result.checks[name] = Boolean(truth);
        if (!truth) throw new Error('assertion_failed');
    }
    try {
        process = reviewProcess();
        const candidates = process.windows().filter(function (window) {
            return safe(function () { return window.subrole(); }, '') === 'AXStandardWindow' &&
                ['빠른 입력', 'WorkLog 검색'].indexOf(safe(function () { return window.name(); }, '')) < 0;
        });
        if (!candidates.length) throw new Error('main_window_missing');
        mainWindow = candidates[0];
        activateMain();
        assert('reviewBundleFound', process.bundleIdentifier() === 'dev.worklog.UIReview');
        if (roots().some(function (node) { return safe(function () { return node.role(); }, '') === 'AXSheet'; })) {
            throw new Error('dismiss_existing_sheet_first');
        }
        stage = 'find_existing_task';
        const routeButton = find('AXButton', '업무', true);
        if (routeButton) click(routeButton);
        else key('2');
        const searchField = need('AXTextField', '업무 이름 검색');
        click(searchField);
        key('a');
        paste('배포 파이프라인');
        assert('searchQueryEntered', searchField.value() === '배포 파이프라인');
        stage = 'select_filtered_task';
        let open = need('AXButton', '선택한 업무 열기');
        const row = find('AXRow') || find(null, '배포 파이프라인');
        if (!row) throw new Error('filtered_task_element_missing');
        const selectionCandidates = [row].concat((row.reviewParents || []).slice().reverse());
        result.selectionRoles = selectionCandidates.map(function (node) { return safe(function () { return node.role(); }, 'unknown'); });
        for (let index = 0; index < selectionCandidates.length && !open.enabled(); index += 1) {
            const candidate = selectionCandidates[index], role = candidate.role();
            if (['AXWindow', 'AXScrollArea'].indexOf(role) >= 0) continue;
            // SwiftUI List may expose AXUnknown/AXGroup entries instead of AXRow.
            safe(function () { candidate.selected = true; }, null);
            if (!open.enabled() && ['AXButton', 'AXRow', 'AXUnknown', 'AXGroup'].indexOf(role) >= 0) {
                safe(function () { candidate.actions.byName('AXPress').perform(); }, null);
            }
            pause();
        }
        if (!open.enabled()) {
            const list = find('AXList') || find('AXOutline') || find('AXTable') || row;
            axSet(list.reference, 'AXFocused', true);
            events.keyCode(125); pause();
        }
        assert('taskSelected', safe(function () { return open.enabled(); }, false));
        click(open);
        stage = 'focus_activity_composer';
        click(need('AXButton', '진행 기록 추가'));
        let editor = find('AXTextArea', '진행 기록 내용') || need('AXTextArea');
        assert('blankComposerAvailable', safe(function () { return editor.value(); }, null) === '');
        click(editor);
        stage = 'enter_fake_activity';
        paste(fakeBody);
        assert('fakeBodyEntered', safe(function () { return editor.value(); }, null) === fakeBody);
        stage = 'save_activity';
        click(need('AXButton', '진행 기록 저장'));
        editor = find('AXTextArea', '진행 기록 내용') || need('AXTextArea');
        assert('draftClearedAfterSave', safe(function () { return editor.value(); }, null) === '');
        assert('savedActivityPresent', find('AXStaticText', fakeBody) !== null);
        stage = 'verify_after_reopen';
        click(need('AXButton', '닫기'));
        activateMain();
        click(need('AXButton', '선택한 업무 열기'));
        assert('activityPersistedAfterReopen', find('AXStaticText', fakeBody) !== null);
        stage = 'return_to_task_list';
        click(need('AXButton', '닫기'));
        activateMain();
        stage = 'complete';
        result.ok = true;
    } catch (_) { result.failureStage = stage; }
    result.stage = stage;
    result.finishedWithinBudget = Number($.NSProcessInfo.processInfo.systemUptime) - start < 90;
    if (!result.ok) throw new Error(JSON.stringify(result));
    return JSON.stringify(result);
}
